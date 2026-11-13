#!/usr/bin/env python3
"""Turn an unpacked external Claude Code plugin into an Antigravity CLI (agy) plugin.

External plugins (docs/adr/0004) ship .claude-plugin/ and .codex-plugin/ but no
agy manifest, so agy skips them. nix/agy-external-plugins.nix unpacks each npm
source pinned in nix/npm-sources.json and runs this script on the copy:

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
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_manifests import GENERATED_PLUGIN_FIELDS, convert_mcp_server, fmt_json  # noqa: E402

BODY_LIMIT = 24000
LEAD_MAX = 600  # an opening paragraph longer than this moves with the rest
MARKER_KEY = "$generated"
MARKER = "nix/agy-external-plugins.nix (scripts/agy_wrap_plugin.py), from the upstream package."
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


def wrap(plugin_dir: Path, node: str | None, env: dict[str, dict[str, str]]) -> list[str]:
    manifest_path = plugin_dir / ".claude-plugin" / "plugin.json"
    claude = read_json(manifest_path, "a Claude plugin manifest")
    name = claude.get("name")
    if not isinstance(name, str) or not name:
        raise WrapError(f"{manifest_path}: has no \"name\"")
    manifest = {MARKER_KEY: MARKER} | {f: claude[f] for f in GENERATED_PLUGIN_FIELDS if f in claude}
    (plugin_dir / ".antigravity-plugin").mkdir(exist_ok=True)
    (plugin_dir / ".antigravity-plugin" / "plugin.json").write_text(fmt_json(manifest, compact=False), encoding="utf-8")
    log = [f"{name}: .antigravity-plugin/plugin.json"]

    servers = mcp_servers(plugin_dir, claude)
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

    for root in skill_roots(plugin_dir, claude):
        for skill_md in sorted(root.glob("*/SKILL.md")):
            moved = split_skill(skill_md.parent)
            if moved:
                log.append(f"{name}: {skill_md.parent.name} split, moved {moved} to references/")
    return log


def smoke(plugin_dir: Path, timeout: float = 120) -> list[str]:
    config = json.loads((plugin_dir / "mcp_config.json").read_text(encoding="utf-8"))
    root = str(plugin_dir.resolve())
    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "agy-wrap-smoke", "version": "0"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
    ]
    log = []
    for name, server in config["mcpServers"].items():
        if "command" not in server:
            log.append(f"{name}: remote server, not started")
            continue
        argv = [server["command"], *(a.replace("${PLUGIN_ROOT}", root) for a in server.get("args", []))]
        proc = subprocess.Popen(
            argv, cwd=root, env=os.environ | server.get("env", {}),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        replies: dict[int, dict] = {}
        try:
            proc.stdin.write("".join(json.dumps(r) + "\n" for r in requests))
            proc.stdin.flush()
            deadline = time.monotonic() + timeout
            while len(replies) < 2 and time.monotonic() < deadline:
                line = proc.stdout.readline()
                if not line:
                    break
                if line.startswith("{"):
                    message = json.loads(line)
                    if message.get("id") in (1, 2):
                        replies[message["id"]] = message
        finally:
            proc.kill()
            stderr = proc.communicate()[1]
        tools = replies.get(2, {}).get("result", {}).get("tools", [])
        if not tools:
            raise SystemExit(f"{name}: no tools/list reply from {argv[0]}\n{stderr.strip()[-2000:]}")
        info = replies[1].get("result", {}).get("serverInfo", {})
        log.append(f"{name}: {info.get('name')} {info.get('version')}, {len(tools)} tools")
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
