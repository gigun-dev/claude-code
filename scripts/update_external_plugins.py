#!/usr/bin/env python3
"""Pin the external plugins, and move the pins.

External plugins (docs/adr) are pinned in one of two places:

  nix/npm-sources.json          npm plugins, built by nix/external-plugins.nix and
                                placed by the consumer's home-manager module.
                                This file is the only pin; the marketplace has
                                no npm entries.
                                  "package", "version" (exact x.y.z), and what
                                  --write fills from the registry: "url",
                                  "hash" (SRI), "mcpServers", "skills"
  .claude-plugin/marketplace.json  Git plugins (url, git-subdir):
                                  "sha" (40-hex commit, next to "ref")

  --check                 offline: every pin is exact and complete, and no npm
                          plugin is also in the marketplace
  (default) / --dry-run   report pins that upstream has moved past; change nothing
  --write                 move the pins and rewrite nix/npm-sources.json
  --report FILE           also write a Markdown summary (PR body) to FILE
  --min-age-days N        only adopt a release or commit at least N days old (default 3)

To add an npm plugin, add {"package", "version"} under its name in
nix/npm-sources.json and run --write. After --write, run
scripts/generate_manifests.py --write to carry Git pins into
.agents/plugins/marketplace.json.

--write rebuilds every npm entry from the registry, including the server and
skill names read from the tarball, which nix/external-plugins.nix uses to name
bin/<server>-mcp and the skill paths at evaluation time and checks against the
package at build time. --check cannot verify the url or hash offline; the weekly
workflow builds the Nix package before it merges, and that fetch is what
checks them.

Why a minimum age: the weekly workflow merges its own PR, so nobody reads the
diff first. Waiting a few days leaves time for a bad release to be noticed and
withdrawn upstream. A pin never moves backwards: an npm candidate must be a
higher version number than the pin, a Git candidate a later commit. A release
that renames an MCP server or skill stops --write with exit 1 before anything
is written, because the consumer's mcpEnv and placement use those names.
--report is written whenever --write changes a file, a metadata-only
correction (url, hash) included.

npm candidates must also ship .claude-plugin/plugin.json at the candidate
version, because the build derives the MCP command from it; rea-agents 6.8.0
and earlier have none. The Codex manifest is no longer required: no host reads
it, Codex gets the build's Agent Plugins 1.0 manifest or its own config.

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
    "The only pin of the npm plugins. scripts/update_external_plugins.py --write moves "
    "\"version\" and fills url, hash, mcpServers and skills from the registry; to add a "
    "plugin, add its package and version by hand and run --write."
)
NPM_REGISTRY = "https://registry.npmjs.org"
EXACT_VERSION = re.compile(r"\d+\.\d+\.\d+")
COMMIT_SHA = re.compile(r"[0-9a-f]{40}")
GITHUB_URL = re.compile(r"https://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?")
CLAUDE_MANIFEST = ".claude-plugin/plugin.json"
NPM_FIELDS = ("package", "version", "url", "hash", "mcpServers", "skills")


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
    """Return why this external marketplace entry is not exactly pinned, or None."""
    source = entry["source"]
    kind = source.get("source")
    if kind == "npm":
        # Why not allow it: Claude prefers a same-named marketplace plugin over
        # the skills-dir plugin the Nix build provides, and the two pins would
        # drift apart again.
        return f"{entry['name']}: npm plugins are pinned in nix/npm-sources.json, not the marketplace"
    elif kind in {"url", "git-subdir"}:
        if not COMMIT_SHA.fullmatch(source.get("sha", "")):
            return f"{entry['name']}: {kind} source needs a 40-hex \"sha\""
        if not GITHUB_URL.fullmatch(source.get("url", "")):
            return f"{entry['name']}: only https://github.com/<owner>/<repo>.git URLs can be pinned"
    else:
        return f"{entry['name']}: unsupported external source {kind!r}"
    return None


def npm_names(sources: dict) -> list[str]:
    return [n for n in sources if not n.startswith("$")]


def one_sided(entry: dict) -> str | None:
    """Why an entry records only one of mcpServers/skills, or None.

    Both are compared with the package on --write; neither means a newly added
    plugin that takes what it declares. One alone would let --write adopt the
    other side unchecked.
    """
    recorded = [f for f in ("mcpServers", "skills") if f in entry]
    return f"records only {recorded[0]}" if len(recorded) == 1 else None


def npm_source_problems(marketplace: dict, sources: dict) -> list[str]:
    """Offline: every npm pin is exact and complete, and none is also a marketplace plugin."""
    listed = {p["name"] for p in marketplace["plugins"]}
    problems = []
    for name in npm_names(sources):
        entry = sources[name]
        where = f"nix/npm-sources.json: {name}"
        if one_sided(entry):
            problems.append(f"{where} {one_sided(entry)}; record both or neither by hand")
            continue
        missing = [f for f in NPM_FIELDS if f not in entry]
        if missing:
            problems.append(f"{where} lacks {', '.join(missing)}; run scripts/update_external_plugins.py --write")
            continue
        if not EXACT_VERSION.fullmatch(str(entry["version"])):
            problems.append(f"{where} needs an exact \"version\" (x.y.z)")
        if not str(entry["hash"]).startswith("sha512-") or not str(entry["url"]).startswith("https://"):
            problems.append(f"{where} needs an https url and a sha512- hash")
        for field in ("mcpServers", "skills"):
            if not isinstance(entry[field], list) or not all(isinstance(x, str) and x for x in entry[field]):
                problems.append(f"{where}: \"{field}\" must be a list of names")
        if name in listed:
            problems.append(f"{where} is also in .claude-plugin/marketplace.json; npm plugins are pinned only here")
    return problems


def tar_json(tar: tarfile.TarFile, path: str) -> dict | None:
    try:
        member = tar.extractfile(f"package/{path}")
    except KeyError:
        return None
    return json.load(member) if member else None


def declared(tar: tarfile.TarFile) -> dict:
    """MCP server and skill names the package's Claude manifest declares.

    Same reading as scripts/agy_wrap_plugin.py mcp_servers() and skill_roots(),
    which the Nix build uses on the unpacked package and compares with these.
    """
    claude = tar_json(tar, CLAUDE_MANIFEST) or {}
    inline = claude.get("mcpServers")
    if isinstance(inline, dict):
        servers = inline
    else:
        pointer = inline if isinstance(inline, str) else ".mcp.json"
        servers = (tar_json(tar, pointer.removeprefix("./")) or {}).get("mcpServers", {})
    roots = claude.get("skills", "./skills")
    roots = [r.removeprefix("./").rstrip("/") for r in (roots if isinstance(roots, list) else [roots])]
    skills = set()
    for member in tar.getnames():
        for root in roots:
            rest = member.removeprefix(f"package/{root}/")
            parts = rest.split("/")
            if rest != member and len(parts) == 2 and parts[1] == "SKILL.md":
                skills.add(parts[0])
    return {"mcpServers": sorted(servers), "skills": sorted(skills)}


def inspect_npm_tarball(package: str, version: str, dist: dict) -> tuple[dict | None, str | None]:
    """(declared names, None), or (None, why this version cannot be built)."""
    data = http(dist["tarball"])
    algo, _, expected = dist["integrity"].partition("-")
    actual = base64.b64encode(hashlib.new(algo, data).digest()).decode()
    if actual != expected:
        return None, f"{package}@{version}: tarball does not match the registry integrity"
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
        claude = tar_json(tar, CLAUDE_MANIFEST)
        if claude is None:
            return None, f"{package}@{version}: no {CLAUDE_MANIFEST}"
        if claude.get("version") != version:
            return None, f"{package}@{version}: {CLAUDE_MANIFEST} says {claude.get('version')}"
        return declared(tar), None


def npm_source_entry(package: str, version: str) -> dict:
    dist = json.loads(http(f"{NPM_REGISTRY}/{urllib.parse.quote(package, safe='@')}/{version}"))["dist"]
    names, problem = inspect_npm_tarball(package, version, dist)
    if problem:
        raise SystemExit(problem)
    return {"package": package, "version": version, "url": dist["tarball"], "hash": dist["integrity"]} | names


class PinError(SystemExit):
    """A pin change that must not land without a person (exit 1, nothing written)."""


def build_npm_sources(sources: dict, fetch) -> dict:
    """nix/npm-sources.json with every entry fetched from the registry.

    Why not keep an entry whose package and version already match: --check is
    offline and cannot see the url, hash or names, so a kept entry would carry a
    hand-edited or stale value forward and only a consumer's Nix build would
    notice.

    Server and skill names that differ from the pin stop the update instead: the
    consumer keys mcpEnv and its placement on them, and the weekly build runs
    without mcpEnv, so a rename would pass here and break the consumer later.
    An entry without names (a plugin being added) takes whatever it declares.
    """
    fresh = {"$generated": NPM_SOURCES_MARKER}
    for name in npm_names(sources):
        pin = sources[name]
        if one_sided(pin):
            raise PinError(f"{name}: {one_sided(pin)}; record both or neither by hand")
        entry = fetch(pin["package"], pin["version"])
        for field in ("mcpServers", "skills"):
            if field in pin and sorted(pin[field]) != sorted(entry[field]):
                raise PinError(
                    f"{name}: {pin['package']}@{pin['version']} declares {field} {sorted(entry[field])}, "
                    f"the pin has {sorted(pin[field])}. Update the pin and the consumer (mcpEnv, "
                    "placement) together by hand; the automatic update stops here."
                )
        fresh[name] = entry
    return fresh


def metadata_rows(old: dict, fresh: dict) -> list[str]:
    """Report rows for entries whose version stayed but url, hash or names changed."""
    rows = []
    for name in npm_names(fresh):
        before, after = old.get(name, {}), fresh[name]
        if before.get("version") != after["version"]:
            continue
        changed = [f for f in NPM_FIELDS if before.get(f) != after.get(f)]
        if changed:
            rows.append(f"| {name} | `{after['version']}` | `{after['version']}` | corrected {', '.join(changed)} |")
    return rows


def load_npm_sources() -> dict:
    return json.loads(NPM_SOURCES.read_text(encoding="utf-8")) if NPM_SOURCES.is_file() else {}


def version_key(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in version.split("."))


def below_latest(version: str, latest: str) -> bool:
    """version (stable x.y.z) is at most latest, which may be a prerelease.

    A prerelease latest (6.11.0-rc.1) ranks below its own stable core, so a
    stable 6.11.0 that is not yet latest is excluded.
    """
    core, _, pre = latest.partition("-")
    return version_key(version) < version_key(core) if pre else version_key(version) <= version_key(core)


def npm_versions_to_try(doc: dict, current: str, cutoff: dt.datetime) -> tuple[list[str], str | None]:
    """Versions to try, highest first, and the newest one still too young (or None).

    Why by number and not by publish date: a maintenance release of an older
    line (6.9.3 after 6.10.1) is published later but would move the pin back.
    The number also works when the pinned version is gone from the listing.
    """
    times = {v: parse_time(t) for v, t in doc["time"].items() if v in doc["versions"]}
    latest = doc["dist-tags"]["latest"]
    newer = sorted(
        (v for v in times if EXACT_VERSION.fullmatch(v)
         and version_key(current) < version_key(v) and below_latest(v, latest)),
        key=version_key,
        reverse=True,
    )
    young = [v for v in newer if times[v] > cutoff]
    return [v for v in newer if times[v] <= cutoff], (young[0] if young else None)


def npm_candidate(source: dict, cutoff: dt.datetime) -> tuple[str | None, str]:
    """Highest usable version at least as old as cutoff, plus a note for the report."""
    package = source["package"]
    doc = json.loads(http(f"{NPM_REGISTRY}/{urllib.parse.quote(package, safe='@')}"))
    tries, waiting = npm_versions_to_try(doc, source["version"], cutoff)
    for version in tries:
        _, problem = inspect_npm_tarball(package, version, doc["versions"][version]["dist"])
        if problem:
            return None, f"skipped: {problem}"
        return version, f"published {parse_time(doc['time'][version]).date()}"
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
    ap.add_argument("--check", action="store_true", help="offline: every pin is exact and complete")
    ap.add_argument("--dry-run", action="store_true", help="report only (default)")
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--report", type=Path)
    ap.add_argument("--min-age-days", type=float, default=3)
    args = ap.parse_args()

    marketplace = json.loads(MARKETPLACE.read_text(encoding="utf-8"))
    entries = external_entries(marketplace)
    sources = load_npm_sources()
    if args.check:
        problems = [p for p in map(pin_problem, entries) if p] + npm_source_problems(marketplace, sources)
        print("\n".join(problems) if problems else (
            f"{len(entries)} Git plugins pinned in the marketplace, "
            f"{len(npm_names(sources))} npm plugins pinned in nix/npm-sources.json"
        ))
        return 1 if problems else 0

    cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=args.min_age_days)
    pins = [(name, sources[name], "version", npm_candidate) for name in npm_names(sources)]
    pins += [(entry["name"], entry["source"], "sha", git_candidate) for entry in entries]
    rows, git_moved = [], False
    for name, source, key, find in pins:
        old = source.get(key)
        new, note = find(source, cutoff)
        print(f"{name}: {(old or 'unpinned')[:12]} -> {new[:12] if new else 'unchanged'} ({note})")
        if new:
            source[key] = new
            git_moved |= key == "sha"
            rows.append(f"| {name} | `{(old or 'unpinned')[:12]}` | `{new[:12]}` | {note} |")

    # Everything is fetched and checked before anything is written, so a stop
    # (PinError) leaves the tree clean and the workflow opens no PR.
    fresh = build_npm_sources(sources, npm_source_entry) if args.write else None
    if fresh is not None:
        # A metadata-only correction still changes a file, and the workflow
        # needs a PR body for every change it pushes.
        rows += metadata_rows(load_npm_sources(), fresh)
        if not rows and fresh != load_npm_sources():
            rows.append("| nix/npm-sources.json | | | regenerated |")
    if args.report and rows:
        header = "| plugin | from | to | note |\n|---|---|---|---|\n"
        args.report.write_text(
            f"External plugin pins moved (minimum age {args.min_age_days:g} days).\n\n{header}" + "\n".join(rows) + "\n",
            encoding="utf-8",
        )
    if args.write and git_moved:
        # Same form the file already has (ASCII-escaped, 2-space indent), so a
        # pin move is the only line that changes.
        MARKETPLACE.write_text(json.dumps(marketplace, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    if fresh is not None and fresh != load_npm_sources():
        NPM_SOURCES.parent.mkdir(exist_ok=True)
        NPM_SOURCES.write_text(json.dumps(fresh, indent=2) + "\n", encoding="utf-8")
        print(f"wrote {NPM_SOURCES.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
