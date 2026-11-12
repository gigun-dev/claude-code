#!/usr/bin/env python3
"""Pin the external plugins in .claude-plugin/marketplace.json, and move the pins.

An external plugin is a marketplace entry whose source is npm, url or git-subdir
(docs/adr). Each one carries an exact pin, so what a host installs is decided by
this repository and not by when, where or with which Node the install ran:

  npm              "version": "<exact x.y.z>"
  url, git-subdir  "sha": "<40-hex commit>"   (next to "ref", which names the branch)

  --check                 offline: fail if an external entry has no exact pin
  (default) / --dry-run   report pins that upstream has moved past; change nothing
  --write                 move the pins in .claude-plugin/marketplace.json
  --report FILE           also write a Markdown summary (PR body) to FILE
  --min-age-days N        only adopt a release or commit at least N days old (default 3)

After --write, run scripts/generate_manifests.py --write to carry the pins into
.agents/plugins/marketplace.json.

Every npm pin also has an entry in nix/npm-sources.json (tarball URL and the
registry's SRI integrity), which nix/agy-external-plugins.nix fetches to build
the agy copy of the plugin. --write keeps that file on the pinned versions in
the same change, and --check fails when the two disagree, so the version a host
installs through the marketplace and the one Nix builds cannot drift apart.

Why a minimum age: the weekly workflow merges its own PR, so nobody reads the
diff first. Waiting a few days leaves time for a bad release to be noticed and
withdrawn upstream. A pin never moves backwards: a candidate older than the
current pin is ignored.

npm candidates must also ship both plugin manifests at the candidate version;
rea-agents 6.8.0 and earlier have none and would install as a plugin that
cannot start.

Uses only the public npm registry and GitHub REST API. GH_TOKEN, when set,
raises the GitHub rate limit; nothing else needs credentials.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import io
import json
import os
import re
import sys
import tarfile
import urllib.parse
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
MARKETPLACE = REPO_ROOT / ".claude-plugin" / "marketplace.json"
NPM_SOURCES = REPO_ROOT / "nix" / "npm-sources.json"
NPM_SOURCES_MARKER = (
    "scripts/update_external_plugins.py --write, from the npm pins in "
    ".claude-plugin/marketplace.json. Do not hand-edit this file."
)
NPM_REGISTRY = "https://registry.npmjs.org"
EXACT_VERSION = re.compile(r"\d+\.\d+\.\d+")
COMMIT_SHA = re.compile(r"[0-9a-f]{40}")
GITHUB_URL = re.compile(r"https://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?")
PLUGIN_MANIFESTS = (".claude-plugin/plugin.json", ".codex-plugin/plugin.json")


def http(url: str, *, headers: dict[str, str] | None = None) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "update-external-plugins", **(headers or {})})
    with urllib.request.urlopen(req, timeout=120) as res:
        return res.read()


def github(endpoint: str) -> object:
    headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return json.loads(http(f"https://api.github.com/{endpoint}", headers=headers))


def parse_time(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def external_entries(marketplace: dict) -> list[dict]:
    return [p for p in marketplace["plugins"] if isinstance(p["source"], dict)]


def pin_problem(entry: dict) -> str | None:
    """Return why this external entry is not exactly pinned, or None."""
    source = entry["source"]
    kind = source.get("source")
    if kind == "npm":
        if not EXACT_VERSION.fullmatch(source.get("version", "")):
            return f"{entry['name']}: npm source needs an exact \"version\" (x.y.z)"
    elif kind in {"url", "git-subdir"}:
        if not COMMIT_SHA.fullmatch(source.get("sha", "")):
            return f"{entry['name']}: {kind} source needs a 40-hex \"sha\""
        if not GITHUB_URL.fullmatch(source.get("url", "")):
            return f"{entry['name']}: only https://github.com/<owner>/<repo>.git URLs can be pinned"
    else:
        return f"{entry['name']}: unsupported external source {kind!r}"
    return None


def npm_source_problems(marketplace: dict, sources: dict) -> list[str]:
    """Offline: nix/npm-sources.json holds exactly the marketplace's npm pins."""
    pins = {e["name"]: e["source"] for e in external_entries(marketplace) if e["source"].get("source") == "npm"}
    problems = [f"nix/npm-sources.json: {n} is not an npm pin in the marketplace" for n in sources if n not in pins and not n.startswith("$")]
    for name, source in pins.items():
        entry = sources.get(name)
        if not entry:
            problems.append(f"nix/npm-sources.json: no entry for {name}")
        elif (entry.get("package"), entry.get("version")) != (source["package"], source.get("version")):
            problems.append(
                f"nix/npm-sources.json: {name} is {entry.get('package')}@{entry.get('version')}, "
                f"the marketplace pins {source['package']}@{source.get('version')}"
            )
        elif not str(entry.get("hash", "")).startswith("sha512-") or not str(entry.get("url", "")).startswith("https://"):
            problems.append(f"nix/npm-sources.json: {name} needs an https url and a sha512- hash")
    return problems


def npm_source_entry(package: str, version: str) -> dict:
    dist = json.loads(http(f"{NPM_REGISTRY}/{urllib.parse.quote(package, safe='@')}/{version}"))["dist"]
    return {"package": package, "version": version, "url": dist["tarball"], "hash": dist["integrity"]}


def load_npm_sources() -> dict:
    return json.loads(NPM_SOURCES.read_text(encoding="utf-8")) if NPM_SOURCES.is_file() else {}


def npm_tarball_has_manifests(package: str, version: str, dist: dict) -> str | None:
    """Return why this npm version cannot be a plugin, or None."""
    data = http(dist["tarball"])
    algo, _, expected = dist["integrity"].partition("-")
    actual = base64.b64encode(hashlib.new(algo, data).digest()).decode()
    if actual != expected:
        return f"{package}@{version}: tarball does not match the registry integrity"
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
        for manifest in PLUGIN_MANIFESTS:
            try:
                member = tar.extractfile(f"package/{manifest}")
            except KeyError:
                member = None
            if member is None:
                return f"{package}@{version}: no {manifest}"
            found = json.load(member).get("version")
            if found != version:
                return f"{package}@{version}: {manifest} says {found}"
    return None


def npm_candidate(source: dict, cutoff: dt.datetime) -> tuple[str | None, str]:
    """Newest usable version at least as old as cutoff, plus a note for the report."""
    package = source["package"]
    doc = json.loads(http(f"{NPM_REGISTRY}/{urllib.parse.quote(package, safe='@')}"))
    times = {v: parse_time(t) for v, t in doc["time"].items() if v in doc["versions"]}
    current = source.get("version")
    latest = doc["dist-tags"]["latest"]
    newest_first = sorted(
        (v for v in times if EXACT_VERSION.fullmatch(v) and times[v] <= times[latest]),
        key=lambda v: times[v],
        reverse=True,
    )
    for version in newest_first:
        if current in times and times[version] <= times[current]:
            break
        if times[version] > cutoff:
            continue
        problem = npm_tarball_has_manifests(package, version, doc["versions"][version]["dist"])
        if problem:
            return None, f"skipped: {problem}"
        return version, f"published {times[version].date()}"
    waiting = latest if latest != current and times[latest] > cutoff else None
    return None, f"{waiting} is newer but younger than the minimum age" if waiting else "up to date"


def git_candidate(source: dict, cutoff: dt.datetime) -> tuple[str | None, str]:
    owner, repo = GITHUB_URL.fullmatch(source["url"]).groups()
    ref = urllib.parse.quote(source.get("ref", "HEAD"), safe="")
    until = cutoff.strftime("%Y-%m-%dT%H:%M:%SZ")
    commits = github(f"repos/{owner}/{repo}/commits?sha={ref}&until={until}&per_page=1")
    if not commits:
        return None, "no commit old enough"
    candidate = commits[0]
    current = source.get("sha")
    if candidate["sha"] == current:
        head = github(f"repos/{owner}/{repo}/commits?sha={ref}&per_page=1")[0]["sha"]
        return None, "up to date" if head == current else "newer commits are younger than the minimum age"
    candidate_time = parse_time(candidate["commit"]["committer"]["date"])
    if current:
        pinned = github(f"repos/{owner}/{repo}/commits/{current}")
        if parse_time(pinned["commit"]["committer"]["date"]) >= candidate_time:
            return None, "newer commits are younger than the minimum age"
    return candidate["sha"], f"committed {candidate_time.date()}"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true", help="offline: every external entry is pinned")
    ap.add_argument("--dry-run", action="store_true", help="report only (default)")
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--report", type=Path)
    ap.add_argument("--min-age-days", type=float, default=3)
    args = ap.parse_args()

    text = MARKETPLACE.read_text(encoding="utf-8")
    marketplace = json.loads(text)
    entries = external_entries(marketplace)

    sources = load_npm_sources()
    if args.check:
        problems = [p for p in map(pin_problem, entries) if p]
        if not problems:
            problems = npm_source_problems(marketplace, sources)
        print("\n".join(problems) if problems else f"{len(entries)} external plugins pinned, npm sources match")
        return 1 if problems else 0

    cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=args.min_age_days)
    rows = []
    for entry in entries:
        source = entry["source"]
        if source["source"] == "npm":
            key, find = "version", npm_candidate
        else:
            key, find = "sha", git_candidate
        old = source.get(key)
        new, note = find(source, cutoff)
        print(f"{entry['name']}: {(old or 'unpinned')[:12]} -> {new[:12] if new else 'unchanged'} ({note})")
        if new:
            source[key] = new
            rows.append(f"| {entry['name']} | `{(old or 'unpinned')[:12]}` | `{new[:12]}` | {note} |")

    if args.report and rows:
        header = "| plugin | from | to | note |\n|---|---|---|---|\n"
        args.report.write_text(
            f"External plugin pins moved (minimum age {args.min_age_days:g} days).\n\n{header}" + "\n".join(rows) + "\n",
            encoding="utf-8",
        )
    if args.write and rows:
        # Same form the file already has (ASCII-escaped, 2-space indent), so a
        # pin move is the only line that changes.
        MARKETPLACE.write_text(json.dumps(marketplace, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    if args.write and npm_source_problems(marketplace, sources):
        # Rebuilt from the pins rather than patched, so a removed plugin leaves no entry.
        fresh = {"$generated": NPM_SOURCES_MARKER}
        for entry in entries:
            source = entry["source"]
            if source.get("source") == "npm":
                kept = sources.get(entry["name"], {})
                same = (kept.get("package"), kept.get("version")) == (source["package"], source["version"])
                fresh[entry["name"]] = kept if same else npm_source_entry(source["package"], source["version"])
        NPM_SOURCES.parent.mkdir(exist_ok=True)
        NPM_SOURCES.write_text(json.dumps(fresh, indent=2) + "\n", encoding="utf-8")
        print(f"wrote {NPM_SOURCES.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
