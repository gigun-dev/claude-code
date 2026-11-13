import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import update_external_plugins as u  # noqa: E402


def npm(name, package, version):
    return {"name": name, "source": {"source": "npm", "package": package, "version": version}}


def registry(package, version):
    return {"package": package, "version": version, "url": f"https://r/{package}-{version}.tgz", "hash": f"sha512-{package}{version}"}


class BuildNpmSources(unittest.TestCase):
    def test_every_entry_comes_from_the_registry(self):
        # A matching version with a hand-edited hash must not survive --write;
        # --check cannot see it offline.
        entries = [npm("rea", "rea-agents", "6.9.0")]
        built = u.build_npm_sources(entries, registry)
        self.assertEqual(built["rea"]["hash"], "sha512-rea-agents6.9.0")
        self.assertEqual(built["$generated"], u.NPM_SOURCES_MARKER)

    def test_only_npm_pins_and_no_leftovers(self):
        entries = [
            npm("rea", "rea-agents", "6.9.0"),
            {"name": "hallmark", "source": {"source": "url", "url": "https://github.com/a/b.git", "sha": "0" * 40}},
        ]
        built = u.build_npm_sources(entries, registry)
        self.assertEqual(sorted(k for k in built if not k.startswith("$")), ["rea"])

    def test_result_passes_the_offline_check(self):
        entries = [npm("rea", "rea-agents", "6.9.0")]
        marketplace = {"plugins": entries}
        self.assertEqual(u.npm_source_problems(marketplace, u.build_npm_sources(entries, registry)), [])


if __name__ == "__main__":
    unittest.main()
