import io
import json
import sys
import tarfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import update_external_plugins as u  # noqa: E402


def registry(package, version):
    return {
        "package": package, "version": version, "url": f"https://r/{package}-{version}.tgz",
        "hash": f"sha512-{package}{version}", "mcpServers": ["rea"], "skills": ["reverse-engineer-anything"],
    }


def tarball(files: dict[str, str]) -> tarfile.TarFile:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for path, text in files.items():
            data = text.encode()
            info = tarfile.TarInfo(f"package/{path}")
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    buf.seek(0)
    return tarfile.open(fileobj=buf, mode="r:gz")


class BuildNpmSources(unittest.TestCase):
    def test_every_entry_comes_from_the_registry(self):
        # A matching version with a hand-edited hash must not survive --write;
        # --check cannot see it offline.
        sources = {"rea": {"package": "rea-agents", "version": "6.9.0", "hash": "sha512-edited"}}
        built = u.build_npm_sources(sources, registry)
        self.assertEqual(built["rea"]["hash"], "sha512-rea-agents6.9.0")
        self.assertEqual(built["$generated"], u.NPM_SOURCES_MARKER)

    def test_a_hand_added_package_and_version_is_filled_in(self):
        built = u.build_npm_sources({"$generated": "x", "rea": {"package": "rea-agents", "version": "6.9.0"}}, registry)
        self.assertEqual(u.npm_source_problems({"plugins": []}, built), [])


class NameChange(unittest.TestCase):
    """S1: a renamed server or skill must stop the automatic update.

    The consumer keys mcpEnv and its placement on these names, and CI builds
    without mcpEnv, so the build passing says nothing about the consumer.
    """

    def test_renamed_server_stops_the_update(self):
        pinned = {"rea": registry("rea-agents", "6.9.0")}
        renamed = lambda p, v: registry(p, v) | {"mcpServers": ["rea-server"]}  # noqa: E731
        with self.assertRaisesRegex(u.PinError, r"rea: .*mcpServers \['rea-server'\], the pin has \['rea'\]"):
            u.build_npm_sources(pinned, renamed)

    def test_renamed_skill_stops_the_update(self):
        pinned = {"rea": registry("rea-agents", "6.9.0")}
        renamed = lambda p, v: registry(p, v) | {"skills": ["re"]}  # noqa: E731
        with self.assertRaisesRegex(u.PinError, "skills"):
            u.build_npm_sources(pinned, renamed)


    def test_pin_with_only_one_name_list_stops_the_update(self):
        # Comparing only the recorded side would let the other side be
        # adopted unchecked; only "both" or "neither" (a new plugin) is valid.
        for missing in ("mcpServers", "skills"):
            pin = {k: v for k, v in registry("rea-agents", "6.9.0").items() if k != missing}
            with self.subTest(missing=missing), self.assertRaisesRegex(u.PinError, "records only"):
                u.build_npm_sources({"rea": pin}, registry)

    def test_check_rejects_a_pin_with_only_one_name_list(self):
        pin = {k: v for k, v in registry("rea-agents", "6.9.0").items() if k != "skills"}
        problems = u.npm_source_problems({"plugins": []}, {"rea": pin})
        self.assertTrue(any("records only" in p for p in problems), problems)


def registry_doc(published: dict[str, str], latest: str) -> dict:
    return {
        "time": {v: f"{d}T00:00:00Z" for v, d in published.items()} | {"modified": "2026-11-20T00:00:00Z"},
        "versions": {v: {"dist": {}} for v in published},
        "dist-tags": {"latest": latest},
    }


class NpmVersionsToTry(unittest.TestCase):
    """S2: a candidate must be numerically newer than the pin, not just published later."""

    cutoff = u.parse_time("2026-11-15T00:00:00Z")

    def test_later_published_lower_version_is_not_a_candidate(self):
        doc = registry_doc({"6.10.1": "2026-11-01", "6.9.3": "2026-11-05", "6.11.0": "2026-11-20"}, "6.11.0")
        tries, waiting = u.npm_versions_to_try(doc, "6.10.1", self.cutoff)
        self.assertEqual(tries, [])
        self.assertEqual(waiting, "6.11.0")

    def test_pin_missing_from_the_registry_listing(self):
        doc = registry_doc({"6.9.3": "2026-11-05", "6.10.2": "2026-11-06"}, "6.10.2")
        tries, _ = u.npm_versions_to_try(doc, "6.10.1", self.cutoff)
        self.assertEqual(tries, ["6.10.2"])

    def test_npm_candidate_does_not_move_backwards(self):
        doc = registry_doc({"6.10.1": "2026-11-01", "6.9.3": "2026-11-05", "6.11.0": "2026-11-20"}, "6.11.0")
        with mock.patch.object(u, "http", return_value=json.dumps(doc).encode()), \
                mock.patch.object(u, "inspect_npm_tarball", return_value=({}, None)):
            new, note = u.npm_candidate({"package": "rea-agents", "version": "6.10.1"}, self.cutoff)
        self.assertIsNone(new, note)

    def test_prerelease_latest_excludes_its_own_stable_core(self):
        # 6.11.0 is old enough but is not latest yet; latest is its rc.
        doc = registry_doc({"6.10.1": "2026-11-01", "6.10.2": "2026-11-02", "6.11.0": "2026-11-03",
                            "6.11.0-rc.1": "2026-11-04"}, "6.11.0-rc.1")
        tries, waiting = u.npm_versions_to_try(doc, "6.10.1", self.cutoff)
        self.assertEqual(tries, ["6.10.2"])
        self.assertIsNone(waiting)

    def test_prerelease_in_the_list_is_never_a_candidate(self):
        doc = registry_doc({"6.10.1": "2026-11-01", "6.10.3-beta.1": "2026-11-02", "6.10.2": "2026-11-03"}, "6.10.2")
        tries, _ = u.npm_versions_to_try(doc, "6.10.1", self.cutoff)
        self.assertEqual(tries, ["6.10.2"])

    def test_highest_old_enough_version_first(self):
        doc = registry_doc({"6.10.1": "2026-11-01", "7.0.0": "2026-11-03", "6.10.2": "2026-11-04"}, "7.0.0")
        tries, _ = u.npm_versions_to_try(doc, "6.10.1", self.cutoff)
        self.assertEqual(tries, ["7.0.0", "6.10.2"])


class MetadataRows(unittest.TestCase):
    """S4: a --write that only corrects metadata still changes a file, so it needs a PR body."""

    def test_hash_correction_is_reported(self):
        old = {"rea": registry("rea-agents", "6.9.0") | {"hash": "sha512-stale"}}
        fresh = {"$generated": u.NPM_SOURCES_MARKER, "rea": registry("rea-agents", "6.9.0")}
        rows = u.metadata_rows(old, fresh)
        self.assertEqual(len(rows), 1)
        self.assertIn("hash", rows[0])

    def test_version_move_alone_is_not_a_metadata_row(self):
        old = {"rea": registry("rea-agents", "6.8.0")}
        fresh = {"rea": registry("rea-agents", "6.9.0")}
        # url and hash follow the version; the version row already covers them.
        self.assertEqual(u.metadata_rows(old, fresh), [])


class MainWrite(unittest.TestCase):
    """--write end to end, with the network replaced: what lands on disk and in the PR body."""

    def setUp(self):
        import tempfile
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.marketplace, self.sources, self.report = root / "m.json", root / "s.json", root / "body.md"
        self.marketplace.write_text(json.dumps({"plugins": []}))
        self.pinned = {"$generated": u.NPM_SOURCES_MARKER, "rea": registry("rea-agents", "6.9.0") | {"hash": "sha512-stale"}}
        self.sources.write_text(json.dumps(self.pinned, indent=2) + "\n")

    def tearDown(self):
        self.tmp.cleanup()

    def run_main(self, fetch):
        argv = ["x", "--write", "--report", str(self.report)]
        with mock.patch.object(u, "MARKETPLACE", self.marketplace), mock.patch.object(u, "NPM_SOURCES", self.sources), \
                mock.patch.object(u, "REPO_ROOT", Path(self.tmp.name)), mock.patch.object(sys, "argv", argv), \
                mock.patch.object(u, "npm_candidate", return_value=(None, "up to date")), \
                mock.patch.object(u, "npm_source_entry", side_effect=fetch):
            return u.main()

    def test_rename_writes_nothing(self):
        before = self.sources.read_text()
        with self.assertRaises(SystemExit) as raised:
            self.run_main(lambda p, v: registry(p, v) | {"mcpServers": ["rea-server"]})
        self.assertNotEqual(raised.exception.code, 0)
        self.assertEqual(self.sources.read_text(), before)
        self.assertFalse(self.report.exists())

    def test_hash_correction_writes_a_report(self):
        self.assertEqual(self.run_main(registry), 0)
        self.assertEqual(json.loads(self.sources.read_text())["rea"]["hash"], "sha512-rea-agents6.9.0")
        self.assertIn("corrected hash", self.report.read_text())


class CheckNpmSources(unittest.TestCase):
    def test_incomplete_entry_fails(self):
        problems = u.npm_source_problems({"plugins": []}, {"rea": {"package": "rea-agents", "version": "6.9.0"}})
        self.assertIn("lacks url, hash, mcpServers, skills", problems[0])

    def test_npm_plugin_also_in_the_marketplace_fails(self):
        # Claude would load the marketplace copy instead of the Nix build.
        marketplace = {"plugins": [{"name": "rea", "source": "./plugins/rea"}]}
        problems = u.npm_source_problems(marketplace, {"rea": registry("rea-agents", "6.9.0")})
        self.assertEqual(len(problems), 1)
        self.assertIn("also in .claude-plugin/marketplace.json", problems[0])

    def test_npm_source_in_the_marketplace_is_a_pin_problem(self):
        entry = {"name": "rea", "source": {"source": "npm", "package": "rea-agents", "version": "6.9.0"}}
        self.assertIn("nix/npm-sources.json", u.pin_problem(entry))


class Declared(unittest.TestCase):
    def test_inline_servers_and_skills(self):
        claude = {"name": "rea", "skills": "./skills", "mcpServers": {"rea": {"command": "node"}}}
        tar = tarball({
            ".claude-plugin/plugin.json": json.dumps(claude),
            "skills/a/SKILL.md": "x", "skills/a/references/r.md": "x", "skills/b/SKILL.md": "x",
            ".cursor-plugin/skills/c/SKILL.md": "x",
        })
        self.assertEqual(u.declared(tar), {"mcpServers": ["rea"], "skills": ["a", "b"]})

    def test_servers_from_a_pointer(self):
        claude = {"name": "x", "mcpServers": "./mcp/servers.json"}
        tar = tarball({
            ".claude-plugin/plugin.json": json.dumps(claude),
            "mcp/servers.json": json.dumps({"mcpServers": {"one": {}, "two": {}}}),
        })
        self.assertEqual(u.declared(tar), {"mcpServers": ["one", "two"], "skills": []})


if __name__ == "__main__":
    unittest.main()
