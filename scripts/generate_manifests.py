#!/usr/bin/env python3
"""Generate the Codex-side manifests from the Claude-side ones they duplicated.

Two things used to be written by hand in two places:

  1. plugin version
     source: plugins/<name>/.claude-plugin/plugin.json  ("version")
     generated: plugins/<name>/.codex-plugin/plugin.json  ("version" only;
       every other field in that file — description, interface, keywords,
       homepage, etc. — is still hand-edited directly in that file. This
       script never touches anything but the "version" value and the
       $versionGeneratedFrom marker next to it.)

  2. the published plugin list
     source: .claude-plugin/marketplace.json (name, source path, order,
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

Run `scripts/generate_manifests.py --check` to detect drift (used by
scripts/verify.sh) or `scripts/generate_manifests.py --write` to regenerate.
Default (no flag) behaves like --check: it reports and exits 1 without
writing, so running this by accident never silently changes files.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
PLUGINS_ROOT = REPO_ROOT / "plugins"
CLAUDE_MARKETPLACE = REPO_ROOT / ".claude-plugin" / "marketplace.json"
CODEX_MARKETPLACE = REPO_ROOT / ".agents" / "plugins" / "marketplace.json"

VERSION_MARKER_KEY = "$versionGeneratedFrom"
VERSION_MARKER_VALUE = (
    "../.claude-plugin/plugin.json (scripts/generate_manifests.py --write); "
    "only \"version\" is generated here, the rest of this file is hand-edited"
)
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
# 1. plugin.json version
# ---------------------------------------------------------------------------


_VERSION_FIELD_RE = re.compile(r'("version"\s*:\s*")[^"]*(")')
# A JSON string value: any run of characters that are not a bare quote or
# backslash, or a backslash-escaped pair (\", \\, \n, ...). Matches the
# whole '"$versionGeneratedFrom": "...",' key-value pair (with its trailing
# comma and any leading whitespace/newline) so it can be stripped cleanly
# before a fresh one is inserted, however it was last written.
_MARKER_KV_RE = re.compile(
    r'\s*"\$versionGeneratedFrom"\s*:\s*"(?:[^"\\]|\\.)*"\s*,'
)


def generate_codex_plugin_json(claude_path: Path, codex_path: Path) -> str | None:
    """Return the codex plugin.json text generate would write, or None if
    there is no paired .codex-plugin/plugin.json to generate (Codex-less
    plugin — not this script's concern).

    This patches the raw text in place (strip any existing marker, insert a
    fresh one, substitute the version value) instead of parsing and
    re-serializing the whole object, because everything past "version" in
    this file is hand-edited directly here and must keep its own formatting
    untouched."""
    if not codex_path.is_file():
        return None

    claude_version = json.loads(claude_path.read_text(encoding="utf-8"))["version"]
    codex_raw = codex_path.read_text(encoding="utf-8")
    json.loads(codex_raw)  # fail loudly on already-broken JSON before patching

    # json.dumps(str) round-trips through the JSON string grammar (escaping
    # any quotes/backslashes in the marker text), so this cannot emit broken
    # JSON regardless of what the marker text contains.
    marker_value_json = json.dumps(VERSION_MARKER_VALUE, ensure_ascii=False)

    text = _MARKER_KV_RE.sub("", codex_raw, count=1)
    pretty = text.startswith("{\n")
    if pretty:
        # Insert as its own line right after the opening "{\n", not right
        # after "{" — otherwise the marker lands on the same line as "{".
        insertion = f'  "{VERSION_MARKER_KEY}": {marker_value_json},\n'
        text = text[:2] + insertion + text[2:]
    else:
        insertion = f'"{VERSION_MARKER_KEY}":{marker_value_json},'
        text = text[:1] + insertion + text[1:]

    text, n = _VERSION_FIELD_RE.subn(
        lambda m: f'{m.group(1)}{claude_version}{m.group(2)}', text, count=1
    )
    if n == 0:
        raise SystemExit(f'{codex_path}: no "version" field found to patch')

    # Validate the patched text is still well-formed JSON carrying the right
    # data before handing it back — a regex patch that produced broken or
    # silently-wrong JSON must fail loudly, not get written.
    patched = json.loads(text)
    if patched.get("version") != claude_version or patched.get(VERSION_MARKER_KEY) != VERSION_MARKER_VALUE:
        raise SystemExit(f"{codex_path}: patch did not produce the expected version/marker")
    return text


def sync_plugin_versions(write: bool) -> list[str]:
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
        entries.append(
            {
                "name": name,
                "source": {"source": "local", "path": p["source"]},
                "policy": CODEX_POLICY,
                "category": load_category(name),
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

    stale_versions = sync_plugin_versions(write)
    marketplace_stale = sync_marketplace(write)

    problems = []
    if stale_versions:
        verb = "regenerated" if write else "out of sync"
        problems.append(
            f"plugin.json version {verb} in: " + ", ".join(stale_versions)
        )
    if marketplace_stale:
        verb = "regenerated" if write else "out of sync"
        problems.append(
            f"{CODEX_MARKETPLACE.relative_to(REPO_ROOT)} {verb}"
        )

    if not problems:
        print("generated manifests are in sync.")
        return

    for line in problems:
        print(line)
    if not write:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
