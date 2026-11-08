#!/usr/bin/env python3
"""Compare vendored upstream skills with upstream HEAD, and re-copy them on request.

vendor/upstream-skills.json records repo, path, pinned commit SHA and destination
of every skill copied verbatim from upstream.

  (default) / --dry-run   report skills whose upstream HEAD content differs from
                          the local copy; change nothing; exit 0
  --write                 re-copy changed skills and update their pinned SHA
  --report FILE           also write a Markdown summary (PR body) to FILE

Needs the gh CLI (authenticated) for the GitHub API. Local files are never
edited by hand: a skill is "changed" when upstream HEAD differs from the
local copy, which also catches accidental local edits.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "vendor" / "upstream-skills.json"


def gh(endpoint: str) -> dict:
    out = subprocess.run(["gh", "api", endpoint], check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def fetch(repo: str, path: str, ref: str) -> dict[str, tuple[str, bytes]]:
    """relative path -> (git mode, content) for every blob under path at ref."""
    tree = gh(f"repos/{repo}/git/trees/{ref}?recursive=1")
    if tree.get("truncated"):
        raise SystemExit(f"{repo}: tree truncated")
    prefix = path.rstrip("/") + "/"
    files = {}
    for e in tree["tree"]:
        if e["type"] == "blob" and e["path"].startswith(prefix):
            blob = gh(f"repos/{repo}/git/blobs/{e['sha']}")
            files[e["path"][len(prefix):]] = (e["mode"], base64.b64decode(blob["content"]))
    if not files:
        raise SystemExit(f"{repo}:{path} not found at {ref}")
    return files


def local_files(dest: Path) -> dict[str, bytes]:
    if not dest.is_dir():
        return {}
    return {str(p.relative_to(dest)): p.read_bytes() for p in sorted(dest.rglob("*")) if p.is_file()}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="report only (default)")
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--report", type=Path)
    args = ap.parse_args()

    data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    heads: dict[str, str] = {}
    lines: list[str] = []
    for s in data["skills"]:
        repo = s["repo"]
        if repo not in heads:
            heads[repo] = gh(f"repos/{repo}/commits/HEAD")["sha"]
        head = heads[repo]
        upstream = fetch(repo, s["path"], head)
        dest = ROOT / s["dest"]
        local = local_files(dest)
        changed = {k: v[1] for k, v in upstream.items()} != local
        old = s["sha"]
        if not changed and old == head:
            print(f"= {s['name']}: up to date ({head[:7]})")
            continue
        if not changed:
            print(f"= {s['name']}: content identical, pin {old[:7] or '-'} -> {head[:7]}")
        else:
            print(f"! {s['name']}: upstream differs (pin {old[:7] or '-'} -> HEAD {head[:7]})")
            link = f"https://github.com/{repo}/compare/{old}...{head}" if old else f"https://github.com/{repo}/tree/{head}/{s['path']}"
            lines.append(f"- `{s['name']}` ({repo}): {link}")
        if args.write:
            if changed:
                if dest.exists():
                    shutil.rmtree(dest)
                for rel, (mode, content) in upstream.items():
                    t = dest / rel
                    t.parent.mkdir(parents=True, exist_ok=True)
                    t.write_bytes(content)
                    t.chmod(0o755 if mode == "100755" else 0o644)
            s["sha"] = head
    if args.write:
        MANIFEST.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    if args.report and lines:
        args.report.write_text(
            "Upstream skills changed. Review the compare links; this PR is not merged automatically.\n\n" + "\n".join(lines) + "\n",
            encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
