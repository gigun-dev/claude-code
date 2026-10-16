#!/usr/bin/env python3
"""Generate the Codex-side manifests from the Claude-side ones they duplicated.

Two things used to be written by hand in two places:

  1. plugins/<name>/.claude-plugin/plugin.json's "name", "version",
     "description", and "author"
     generated into: plugins/<name>/.codex-plugin/plugin.json (same four
       fields, verbatim from the Claude side). Everything else in that
       file — homepage, repository, keywords, the mcpServers/skills
       pointer, interface — has no Claude-side equivalent, so it stays
       hand-edited directly in that file. The $generatedFrom marker next
       to "name" says which fields are generated and which are not.

  2. the published plugin list
     source: .claude-plugin/marketplace.json (name, source, order,
       and each entry's marketing "description" — the two-line blurb that
       is allowed to read differently from plugin.json's own description
       and does not get generated)
     generated (in full): .agents/plugins/marketplace.json

  The category shown in .agents/plugins/marketplace.json comes from
  plugins/<name>/.codex-plugin/plugin.json → interface.category. Every
  plugin's .codex-plugin/plugin.json already carries this field except
  telemetry and worktree, which had it only in .agents/plugins/marketplace.json
  before this script existed; a minimal `"interface": {"category": ...}` was
  added to those two files' .codex-plugin/plugin.json (verbatim from the value
  that used to live in .agents/plugins/marketplace.json) so a single source
  exists for every plugin. See CLAUDE.md for the command to run.

  3. the Antigravity CLI (agy) native plugin files, generated in full for every
     plugin that has a non-empty skills/ directory or a .mcp.json:
       plugins/<name>/.antigravity-plugin/plugin.json  (name/version/
         description/author from .claude-plugin/plugin.json)
       plugins/<name>/mcp_config.json  (from the canonical .mcp.json:
         stdio -> command/args/env, http -> serverUrl, and
         ${CLAUDE_PLUGIN_ROOT} -> ${PLUGIN_ROOT})
     skills/ is shared as-is (same SKILL.md format). Skipped on purpose:
     hooks (agy events/tool names differ), commands, agents.
     mcp_config.json has to sit at the plugin root (agy reads it from there
     even when the manifest lives in .antigravity-plugin/); the dedicated
     .antigravity-plugin/ dir keeps the manifest out of Claude/Codex discovery.

Run `scripts/generate_manifests.py --check` to detect drift (used by
scripts/verify.sh) or `scripts/generate_manifests.py --write` to regenerate.
Default (no flag) behaves like --check: it reports and exits 1 without
writing, so running this by accident never silently changes files.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
PLUGINS_ROOT = REPO_ROOT / "plugins"
CLAUDE_MARKETPLACE = REPO_ROOT / ".claude-plugin" / "marketplace.json"
CODEX_MARKETPLACE = REPO_ROOT / ".agents" / "plugins" / "marketplace.json"

# Fields plugin.json generation copies verbatim from .claude-plugin/plugin.json,
# in the order they are written into .codex-plugin/plugin.json.
GENERATED_PLUGIN_FIELDS = ["name", "version", "description", "author"]
GENERATED_FROM_KEY = "$generatedFrom"
GENERATED_FROM_VALUE = (
    "../.claude-plugin/plugin.json (scripts/generate_manifests.py --write); "
    "generates " + "/".join(GENERATED_PLUGIN_FIELDS) + " here — "
    "homepage, repository, keywords, the mcpServers/skills pointer, and "
    "interface stay hand-edited in this file"
)
# Marker key names this script used to write and no longer does — dropped on
# regeneration so a previous run's marker doesn't linger as a stray
# hand-written-looking field.
LEGACY_MARKER_KEYS = {"$versionGeneratedFrom"}

MARKETPLACE_MARKER_KEY = "$generated"
MARKETPLACE_MARKER_VALUE = (
    "scripts/generate_manifests.py --write, from .claude-plugin/marketplace.json "
    "(name/source/order/description) and each plugin's .codex-plugin/plugin.json "
    "(interface.category). Do not hand-edit this file."
)

# Verified constant across every current entry (2026-09-18); not derivable
# from anywhere else, so it is a literal here rather than a second file to
# maintain for a value that has never varied.
CODEX_POLICY = {"installation": "AVAILABLE", "authentication": "ON_INSTALL"}


def fmt_json(data: object, *, compact: bool) -> str:
    if compact:
        return json.dumps(data, ensure_ascii=False, separators=(",", ":")) + "\n"
    return json.dumps(data, ensure_ascii=False, indent=2) + "\n"


def plugin_dirs() -> list[Path]:
    return sorted(p for p in PLUGINS_ROOT.iterdir() if p.is_dir())


# ---------------------------------------------------------------------------
# 1. plugin.json — name/version/description/author
# ---------------------------------------------------------------------------


def generate_codex_plugin_json(claude_path: Path, codex_path: Path) -> str | None:
    """Return the codex plugin.json text generate would write, or None if
    there is no paired .codex-plugin/plugin.json to generate (Codex-less
    plugin — not this script's concern).

    Rebuilds the whole object: the generated fields (in GENERATED_PLUGIN_FIELDS
    order) come from the Claude side, everything else is carried over
    unchanged from the current Codex file, in its existing order. This means
    a full re-serialize (indent=2) rather than a byte-preserving text patch —
    once more than one field is generated, patching text fragments in place
    stops being simpler or safer than parse-merge-reserialize."""
    if not codex_path.is_file():
        return None

    claude_data = json.loads(claude_path.read_text(encoding="utf-8"))
    codex_data = json.loads(codex_path.read_text(encoding="utf-8"))

    for field in GENERATED_PLUGIN_FIELDS:
        if field not in claude_data:
            raise SystemExit(
                f"{claude_path}: missing \"{field}\", needed to generate {codex_path}"
            )

    merged = {GENERATED_FROM_KEY: GENERATED_FROM_VALUE}
    for field in GENERATED_PLUGIN_FIELDS:
        merged[field] = claude_data[field]
    for key, value in codex_data.items():
        if key in (GENERATED_FROM_KEY, *LEGACY_MARKER_KEYS) or key in GENERATED_PLUGIN_FIELDS:
            continue
        merged[key] = value

    return fmt_json(merged, compact=False)


def sync_plugin_manifests(write: bool) -> list[str]:
    """Return the list of plugin dirs whose .codex-plugin/plugin.json is
    stale (or, in write mode, that were rewritten)."""
    stale: list[str] = []
    npairs = 0
    for plugin_dir in plugin_dirs():
        claude_path = plugin_dir / ".claude-plugin" / "plugin.json"
        codex_path = plugin_dir / ".codex-plugin" / "plugin.json"
        if not claude_path.is_file():
            continue
        generated = generate_codex_plugin_json(claude_path, codex_path)
        if generated is None:
            continue
        npairs += 1
        current = codex_path.read_text(encoding="utf-8")
        if generated == current:
            continue
        stale.append(str(plugin_dir.relative_to(REPO_ROOT)))
        if write:
            codex_path.write_text(generated, encoding="utf-8")
    if npairs == 0:
        raise SystemExit(
            "no plugin has both .claude-plugin/plugin.json and "
            ".codex-plugin/plugin.json — collection looks broken"
        )
    return stale


# ---------------------------------------------------------------------------
# 3. agy (Antigravity CLI) native plugin files — generated in full
# ---------------------------------------------------------------------------

AGY_MANIFEST_DIR = ".antigravity-plugin"
AGY_MARKER_KEY = "$generated"
AGY_MARKER_VALUE = (
    "scripts/generate_manifests.py --write, from ../.claude-plugin/plugin.json. "
    "Do not hand-edit this file."
)
AGY_MCP_MARKER_VALUE = (
    "scripts/generate_manifests.py --write, from .mcp.json. Do not hand-edit this file."
)


def has_skills(plugin_dir: Path) -> bool:
    skills = plugin_dir / "skills"
    return skills.is_dir() and any(skills.glob("*/SKILL.md"))


def convert_mcp_server(plugin: str, name: str, server: dict) -> dict:
    """Map one Claude/Codex .mcp.json server to agy's mcp_config.json shape.

    agy 1.3.5 validates "command or serverUrl" (its newer docs call the key
    "url" with serverUrl as legacy; 1.3.5 rejects plain "url", so serverUrl)."""
    kind = server.get("type", "stdio")
    if kind == "stdio":
        out: dict = {"command": server["command"]}
        if "args" in server:
            out["args"] = server["args"]
        if "env" in server:
            out["env"] = server["env"]
    elif kind == "http":
        out = {"serverUrl": server["url"]}
    else:
        raise SystemExit(f"{plugin}: MCP server {name!r} has unsupported type {kind!r}")
    unknown = set(server) - {"type", "command", "args", "env", "url"}
    if unknown:
        raise SystemExit(f"{plugin}: MCP server {name!r} has fields agy mapping drops: {sorted(unknown)}")
    return json.loads(json.dumps(out).replace("${CLAUDE_PLUGIN_ROOT}", "${PLUGIN_ROOT}"))


def generate_agy_files(plugin_dir: Path) -> dict[Path, str]:
    """Return {path: text} of agy files this plugin should have ({} if none)."""
    claude_path = plugin_dir / ".claude-plugin" / "plugin.json"
    mcp_path = plugin_dir / ".mcp.json"
    if not claude_path.is_file() or not (has_skills(plugin_dir) or mcp_path.is_file()):
        return {}
    claude_data = json.loads(claude_path.read_text(encoding="utf-8"))
    manifest = {AGY_MARKER_KEY: AGY_MARKER_VALUE}
    for field in GENERATED_PLUGIN_FIELDS:
        if field not in claude_data:
            raise SystemExit(f"{claude_path}: missing \"{field}\", needed for agy plugin.json")
        manifest[field] = claude_data[field]
    files = {plugin_dir / AGY_MANIFEST_DIR / "plugin.json": fmt_json(manifest, compact=False)}
    if mcp_path.is_file():
        servers = json.loads(mcp_path.read_text(encoding="utf-8"))["mcpServers"]
        mcp = {
            AGY_MARKER_KEY: AGY_MCP_MARKER_VALUE,
            "mcpServers": {
                n: convert_mcp_server(plugin_dir.name, n, srv) for n, srv in servers.items()
            },
        }
        files[plugin_dir / "mcp_config.json"] = fmt_json(mcp, compact=False)
    return files


def sync_agy(write: bool) -> list[str]:
    stale: list[str] = []
    for plugin_dir in plugin_dirs():
        expected = generate_agy_files(plugin_dir)
        # A previously generated mcp_config.json whose .mcp.json is gone is stale too.
        leftover = plugin_dir / "mcp_config.json"
        if leftover not in expected and leftover.is_file():
            stale.append(str(leftover.relative_to(REPO_ROOT)))
            if write:
                leftover.unlink()
        for path, text in expected.items():
            if path.is_file() and path.read_text(encoding="utf-8") == text:
                continue
            stale.append(str(path.relative_to(REPO_ROOT)))
            if write:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text, encoding="utf-8")
    return stale


# ---------------------------------------------------------------------------
# 2. marketplace.json
# ---------------------------------------------------------------------------


def load_category(name: str) -> str:
    codex_plugin_path = PLUGINS_ROOT / name / ".codex-plugin" / "plugin.json"
    if not codex_plugin_path.is_file():
        raise SystemExit(
            f"{name}: no .codex-plugin/plugin.json, cannot derive category for "
            f"{CODEX_MARKETPLACE.relative_to(REPO_ROOT)}"
        )
    data = json.loads(codex_plugin_path.read_text(encoding="utf-8"))
    category = data.get("interface", {}).get("category")
    if not category:
        raise SystemExit(
            f"{name}: .codex-plugin/plugin.json has no interface.category — "
            "add one (see CLAUDE.md) before generating"
        )
    return category


def generate_codex_marketplace() -> str:
    claude_mp = json.loads(CLAUDE_MARKETPLACE.read_text(encoding="utf-8"))
    entries = []
    for p in claude_mp["plugins"]:
        name = p["name"]
        source = p["source"]
        if isinstance(source, str):
            codex_source = {"source": "local", "path": source}
            category = load_category(name)
        elif isinstance(source, dict) and source.get("source") == "url":
            codex_source = source
            category = p.get("category")
            if not category:
                raise SystemExit(f"{name}: external plugin needs a marketplace category")
        else:
            raise SystemExit(f"{name}: unsupported marketplace source {source!r}")
        entries.append(
            {
                "name": name,
                "source": codex_source,
                "policy": CODEX_POLICY,
                "category": category,
            }
        )
    data = {
        MARKETPLACE_MARKER_KEY: MARKETPLACE_MARKER_VALUE,
        "name": claude_mp["name"],
        "interface": {"displayName": claude_mp["name"]},
        "plugins": entries,
    }
    return fmt_json(data, compact=False)


def sync_marketplace(write: bool) -> bool:
    """Return True if .agents/plugins/marketplace.json was (or would be) stale."""
    if not CLAUDE_MARKETPLACE.is_file():
        raise SystemExit(f"missing {CLAUDE_MARKETPLACE.relative_to(REPO_ROOT)}")
    generated = generate_codex_marketplace()
    current = CODEX_MARKETPLACE.read_text(encoding="utf-8") if CODEX_MARKETPLACE.is_file() else ""
    if generated == current:
        return False
    if write:
        CODEX_MARKETPLACE.parent.mkdir(parents=True, exist_ok=True)
        CODEX_MARKETPLACE.write_text(generated, encoding="utf-8")
    return True


# ---------------------------------------------------------------------------


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="fail when manifests are stale (default)")
    mode.add_argument("--write", action="store_true", help="regenerate stale manifests")
    args = parser.parse_args()
    write = args.write

    stale_plugins = sync_plugin_manifests(write)
    marketplace_stale = sync_marketplace(write)
    stale_agy = sync_agy(write)

    problems = []
    if stale_plugins:
        verb = "regenerated" if write else "out of sync"
        problems.append(
            f".codex-plugin/plugin.json ({'/'.join(GENERATED_PLUGIN_FIELDS)}) {verb} in: "
            + ", ".join(stale_plugins)
        )
    if marketplace_stale:
        verb = "regenerated" if write else "out of sync"
        problems.append(
            f"{CODEX_MARKETPLACE.relative_to(REPO_ROOT)} {verb}"
        )

    if stale_agy:
        verb = "regenerated" if write else "out of sync"
        problems.append(f"agy plugin files {verb}: " + ", ".join(stale_agy))

    if not problems:
        print("generated manifests are in sync.")
        return

    for line in problems:
        print(line)
    if not write:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
