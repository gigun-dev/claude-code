#!/usr/bin/env python3
"""Keep Claude MCP wrapper manifests synchronized with the Codex canonical map."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
PLUGINS_ROOT = REPO_ROOT / "plugins"


def main() -> None:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="fail when manifests are stale")
    mode.add_argument("--write", action="store_true", help="rewrite stale Claude manifests")
    args = parser.parse_args()

    stale: list[Path] = []
    for plugin_root in sorted(PLUGINS_ROOT.iterdir()):
        mcp_path = plugin_root / ".mcp.json"
        claude_manifest_path = plugin_root / ".claude-plugin" / "plugin.json"
        if not mcp_path.is_file() or not claude_manifest_path.is_file():
            continue

        canonical = json.loads(mcp_path.read_text(encoding="utf-8"))["mcpServers"]
        manifest = json.loads(claude_manifest_path.read_text(encoding="utf-8"))
        if manifest.get("mcpServers") == canonical:
            continue

        stale.append(plugin_root)
        if args.write:
            manifest["mcpServers"] = canonical
            claude_manifest_path.write_text(
                json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )

    if stale:
        action = "updated" if args.write else "out of sync"
        for plugin_root in stale:
            print(f"{action}: {plugin_root.relative_to(REPO_ROOT)}")
        if not args.write:
            raise SystemExit(1)
    else:
        print("MCP wrapper manifests are synchronized.")


if __name__ == "__main__":
    main()
