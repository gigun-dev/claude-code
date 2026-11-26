#!/usr/bin/env python3
"""Turn an unpacked external Claude Code plugin into an Antigravity CLI (agy) plugin.

External plugins ship .claude-plugin/ but no agy manifest, so agy skips them.
nix/external-plugins.nix runs this script on each pinned Git plugin it copies,
and scripts/build_external_plugin.py uses write_agy() and split_skill() for the
agy variant of each npm plugin:

  .antigravity-plugin/plugin.json  name/version/description/author from
                                   .claude-plugin/plugin.json
  mcp_config.json                  the Claude mcpServers (inline or .mcp.json),
                                   mapped as scripts/generate_manifests.py does
                                   for our own plugins; "node" becomes --node
                                   and --env adds per-server environment
  skills/*/SKILL.md                bodies over agy's load limit are split

agy loads only the first 24,000 bytes of a SKILL.md body when the skill is
invoked as a slash command (agy 1.5.5; `agy plugin validate` warns about it).
The split moves whole "## " sections, largest first, into references/ and leaves
the heading, its opening paragraph and a pointer telling the agent to read the
moved file before acting. Text is moved, never rewritten, except that links
starting with references/ lose that prefix because the text now lives there.
The split refuses (exit 1) instead of producing a skill that still does not fit
or has a broken link, so an upstream restructure fails the Nix build. The same
goes for a package without a Claude manifest or with an unreadable MCP list:
those exit 1 with a one-line message naming the file, while any other error
keeps its traceback.

usage: agy_wrap_plugin.py PLUGIN_DIR [--node PATH] [--env JSON]
       agy_wrap_plugin.py PLUGIN_DIR --smoke
  --env    {"<server>": {"KEY": "value"}}; keys override the plugin's own env
  --smoke  start every stdio server in the wrapped mcp_config.json the way agy
           would and require initialize and a non-empty tools/list (the Nix
           install check; it catches a runtime the server refuses, such as a
           Node.js outside the package's engines range)
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import re
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_manifests import GENERATED_PLUGIN_FIELDS, convert_mcp_server, fmt_json  # noqa: E402

BODY_LIMIT = 24000
LEAD_MAX = 600  # an opening paragraph longer than this moves with the rest
MARKER_KEY = "$generated"
MARKER = "nix/external-plugins.nix (scripts/agy_wrap_plugin.py), from the upstream package."
FRONTMATTER = re.compile(r"---\n.*?\n---\n", re.S)


class WrapError(Exception):
    """The upstream package is not in a shape this script can wrap.

    main() prints the message alone and exits 1, so the Nix build log names
    what upstream changed. Anything else is a bug here and keeps its traceback.
    """


class SplitError(WrapError):
    pass


def read_json(path: Path, what: str) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise WrapError(f"{path}: missing; the upstream package does not ship {what}") from None
    except json.JSONDecodeError as error:
        raise WrapError(f"{path}: {what} is not valid JSON ({error})") from None
    if not isinstance(data, dict):
        raise WrapError(f"{path}: {what} is not a JSON object")
    return data


def size(text: str) -> int:
    return len(text.encode())


def sections(body: str) -> list[tuple[str | None, str]]:
    """[(title, text)] split at "## " headings outside code fences; the first
    item (title None) is whatever precedes the first heading."""
    out: list[tuple[str | None, list[str]]] = [(None, [])]
    fenced = False
    for line in body.splitlines(keepends=True):
        if line.startswith("```"):
            fenced = not fenced
        if not fenced and line.startswith("## "):
            out.append((line[3:].strip(), []))
        out[-1][1].append(line)
    return [(title, "".join(lines)) for title, lines in out]


def slug(title: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")


def split_skill(skill_dir: Path, limit: int = BODY_LIMIT) -> list[str]:
    """Split skill_dir/SKILL.md in place until its body fits; return moved titles."""
    text = (skill_dir / "SKILL.md").read_text(encoding="utf-8")
    match = FRONTMATTER.match(text)
    if not match:
        raise SplitError(f"{skill_dir}: SKILL.md has no frontmatter")
    front, parts = match.group(0), sections(text[match.end():])
    references = skill_dir / "references"
    moved: list[str] = []
    while size("".join(t for _, t in parts)) > limit:
        left = [i for i, (title, _) in enumerate(parts) if title and title not in moved]
        if not left:
            raise SplitError(f"{skill_dir}: body still over {limit} bytes with every section moved")
        i = max(left, key=lambda k: size(parts[k][1]))
        title, section = parts[i]
        heading, _, rest = section.partition("\n")
        rest = rest.lstrip("\n")
        target = references / f"{slug(title)}.md"
        if target.exists():
            raise SplitError(f"{skill_dir}: {target.name} already exists")
        relocated = rest.replace("](references/", "](")
        for link in re.findall(r"\]\((?!https?://|#|mailto:)([^)\s]+)\)", relocated):
            if not (references / link.split("#")[0]).exists():
                raise SplitError(f"{skill_dir}: moving {title!r} would break the link {link}")
        lead, sep, _ = rest.partition("\n\n")
        keep_lead = bool(sep) and size(lead) <= LEAD_MAX and not lead.lstrip().startswith(("-", "*", "|", "#", "```", "1."))
        references.mkdir(exist_ok=True)
        target.write_text(f"# {title}\n\n{relocated}", encoding="utf-8")
        stub = f"{heading}\n\n" + (f"{lead}\n\n" if keep_lead else "")
        stub += (
            f"The rest of this section is in [{title}](references/{target.name}).\n"
            "Read that file in full before acting on this section. It is part of these\n"
            f"instructions, moved unchanged because this host loads only the first\n"
            f"{limit} bytes of a skill body.\n\n"
        )
        parts[i] = (title, stub)
        moved.append(title)
    if moved:
        (skill_dir / "SKILL.md").write_text(front + "".join(t for _, t in parts), encoding="utf-8")
    return moved


def mcp_servers(plugin_dir: Path, claude: dict) -> dict:
    inline = claude.get("mcpServers")
    if isinstance(inline, dict):
        return inline
    pointer = inline if isinstance(inline, str) else ".mcp.json"
    path = plugin_dir / pointer
    if not path.is_file():
        if isinstance(inline, str):
            raise WrapError(f"{path}: missing; .claude-plugin/plugin.json points mcpServers at it")
        return {}
    servers = read_json(path, "the MCP server list").get("mcpServers")
    if not isinstance(servers, dict):
        raise WrapError(f"{path}: has no \"mcpServers\" object")
    return servers


def skill_roots(plugin_dir: Path, claude: dict) -> list[Path]:
    declared = claude.get("skills", "./skills")
    paths = declared if isinstance(declared, list) else [declared]
    return [plugin_dir / p for p in paths if (plugin_dir / p).is_dir()]


def read_claude_manifest(plugin_dir: Path) -> dict:
    manifest_path = plugin_dir / ".claude-plugin" / "plugin.json"
    claude = read_json(manifest_path, "a Claude plugin manifest")
    name = claude.get("name")
    if not isinstance(name, str) or not name:
        raise WrapError(f"{manifest_path}: has no \"name\"")
    return claude


def wrap(plugin_dir: Path, node: str | None, env: dict[str, dict[str, str]]) -> list[str]:
    claude = read_claude_manifest(plugin_dir)
    log = write_agy(plugin_dir, claude, mcp_servers(plugin_dir, claude), node, env)
    for root in skill_roots(plugin_dir, claude):
        log += split_skills(root, claude["name"])
    return log


def split_skills(root: Path, name: str) -> list[str]:
    log = []
    for skill_md in sorted(root.glob("*/SKILL.md")):
        moved = split_skill(skill_md.parent)
        if moved:
            log.append(f"{name}: {skill_md.parent.name} split, moved {moved} to references/")
    return log


def write_agy(
    plugin_dir: Path, claude: dict, servers: dict, node: str | None, env: dict[str, dict[str, str]]
) -> list[str]:
    """Write .antigravity-plugin/plugin.json and, if there are servers, mcp_config.json."""
    name = claude["name"]
    manifest = {MARKER_KEY: MARKER} | {f: claude[f] for f in GENERATED_PLUGIN_FIELDS if f in claude}
    (plugin_dir / ".antigravity-plugin").mkdir(exist_ok=True)
    (plugin_dir / ".antigravity-plugin" / "plugin.json").write_text(fmt_json(manifest, compact=False), encoding="utf-8")
    log = [f"{name}: .antigravity-plugin/plugin.json"]

    unknown = set(env) - set(servers)
    if unknown:
        raise SystemExit(f"{name}: --env names servers the plugin does not have: {sorted(unknown)}")
    if servers:
        converted = {}
        for server, spec in servers.items():
            out = convert_mcp_server(name, server, spec)
            if node and out.get("command") == "node":
                out["command"] = node
            if server in env:
                out["env"] = out.get("env", {}) | env[server]
            converted[server] = out
        config = {MARKER_KEY: MARKER, "mcpServers": converted}
        (plugin_dir / "mcp_config.json").write_text(fmt_json(config, compact=False), encoding="utf-8")
        log.append(f"{name}: mcp_config.json ({', '.join(converted)})")
    return log


def probe(name: str, argv: list[str], cwd: str, env: dict[str, str], timeout: float = 120) -> str:
    """Start one stdio MCP server and run the handshake a host runs.

    initialize must succeed before notifications/initialized and tools/list
    are sent, and tools/list must return tools. The whole exchange has one
    deadline: stdout and stderr are drained by threads, so a server that never
    writes fails at the deadline instead of blocking the build.
    """
    proc = subprocess.Popen(
        argv, cwd=cwd, env=env,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        # Own process group, so the cleanup below also stops descendants that
        # inherited the pipes; killing only the child left the readers waiting.
        start_new_session=True,
    )
    lines: queue.Queue[str | None] = queue.Queue()
    stderr: list[str] = []

    def drain_stdout() -> None:
        for line in proc.stdout:
            lines.put(line)
        lines.put(None)

    readers = [
        threading.Thread(target=drain_stdout, daemon=True),
        threading.Thread(target=lambda: stderr.extend(proc.stderr), daemon=True),
    ]
    for reader in readers:
        reader.start()
    deadline = time.monotonic() + timeout

    def fail(why: str) -> SystemExit:
        return SystemExit(f"{name}: {why} from {argv[0]}\n{''.join(stderr).strip()[-2000:]}")

    def send(*messages: dict) -> None:
        proc.stdin.write("".join(json.dumps(m) + "\n" for m in messages))
        proc.stdin.flush()

    def reply(request_id: int, method: str) -> dict:
        while True:
            left = deadline - time.monotonic()
            try:
                line = lines.get(timeout=max(left, 0)) if left > 0 else None
            except queue.Empty:
                line = None
            if line is None:
                raise fail(f"no {method} reply within {timeout:g}s")
            if line.startswith("{"):
                message = json.loads(line)
                if message.get("id") == request_id:
                    if "result" not in message:
                        raise fail(f"{method} failed: {message.get('error')}")
                    return message["result"]

    try:
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "external-plugin-smoke", "version": "0"}}})
        info = reply(1, "initialize").get("serverInfo", {})
        send({"jsonrpc": "2.0", "method": "notifications/initialized"},
             {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        tools = reply(2, "tools/list").get("tools", [])
        if not tools:
            raise fail("empty tools/list")
    finally:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()
        for reader in readers:
            reader.join(timeout=2)
        if not any(reader.is_alive() for reader in readers):
            # Closing a pipe a reader still blocks on can itself block.
            for pipe in (proc.stdin, proc.stdout, proc.stderr):
                pipe.close()
    return f"{name}: {info.get('name')} {info.get('version')}, {len(tools)} tools"


def smoke(plugin_dir: Path, timeout: float = 120) -> list[str]:
    config = json.loads((plugin_dir / "mcp_config.json").read_text(encoding="utf-8"))
    root = str(plugin_dir.resolve())
    log = []
    for name, server in config["mcpServers"].items():
        if "command" not in server:
            log.append(f"{name}: remote server, not started")
            continue
        argv = [server["command"], *(a.replace("${PLUGIN_ROOT}", root) for a in server.get("args", []))]
        log.append(probe(name, argv, root, os.environ | server.get("env", {}), timeout))
    return log


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("plugin_dir", type=Path)
    ap.add_argument("--node", help="absolute path that replaces a bare `node` command")
    ap.add_argument("--env", default="{}", help='{"<server>": {"KEY": "value"}}')
    ap.add_argument("--smoke", action="store_true", help="start the wrapped MCP servers and list their tools")
    args = ap.parse_args()
    if args.smoke:
        print("\n".join(smoke(args.plugin_dir)))
        return 0
    try:
        for line in wrap(args.plugin_dir, args.node, json.loads(args.env)):
            print(line)
    except WrapError as error:
        print(f"agy_wrap_plugin: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
