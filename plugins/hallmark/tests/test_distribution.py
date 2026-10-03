"""Distribution checks run locally without installing plugins or accessing networks."""
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[3]
PLUGIN = ROOT / "plugins" / "hallmark"


def read_json(path):
    return json.loads(path.read_text())


class HallmarkDistribution(unittest.TestCase):
    def test_both_hosts_share_skill_and_version(self):
        claude = read_json(PLUGIN / ".claude-plugin/plugin.json")
        codex = read_json(PLUGIN / ".codex-plugin/plugin.json")
        for key in ("name", "version", "description", "author"):
            self.assertEqual(claude[key], codex[key], key)
        self.assertEqual(claude["name"], "hallmark")
        self.assertEqual(claude["version"], "1.1.0")
        self.assertEqual(codex["skills"], "./skills/")
        skill = PLUGIN / "skills/hallmark/SKILL.md"
        self.assertIn("version: 1.1.0", skill.read_text())
        self.assertEqual(list((PLUGIN / "skills").glob("*/SKILL.md")), [skill])

    def test_marketplaces_point_to_same_local_plugin(self):
        claude = read_json(ROOT / ".claude-plugin/marketplace.json")
        codex = read_json(ROOT / ".agents/plugins/marketplace.json")
        a = [p for p in claude["plugins"] if p["name"] == "hallmark"]
        b = [p for p in codex["plugins"] if p["name"] == "hallmark"]
        self.assertEqual(len(a), 1)
        self.assertEqual(len(b), 1)
        self.assertEqual(a[0]["source"], "./plugins/hallmark")
        self.assertEqual(b[0]["source"], {"source": "local", "path": "./plugins/hallmark"})

    def test_reference_links_stay_bundled_and_resolve(self):
        files = list((PLUGIN / "skills").rglob("*.md"))
        self.assertGreater(len(files), 40)
        checked = 0
        for file in files + [PLUGIN / "README.md"]:
            text = re.sub(r"```.*?```", "", file.read_text(), flags=re.S)
            for link in re.findall(r'\]\(([^)\s]+)(?:\s+"[^"]*")?\)', text):
                target = link.strip("<>").split("#", 1)[0]
                if not target or ":" in target:
                    continue
                resolved = (file.parent / target).resolve()
                self.assertTrue(resolved.is_relative_to(PLUGIN), (file, link))
                self.assertTrue(resolved.exists(), (file, link))
                checked += 1
        self.assertGreater(checked, 100)
        self.assertTrue((PLUGIN / "site/css/tokens.css").is_file())

    def test_license_and_fixed_upstream_are_present(self):
        license = (PLUGIN / "LICENSE").read_text()
        self.assertIn("MIT License", license)
        self.assertIn("Permission is hereby granted", license)
        upstream = (PLUGIN / "UPSTREAM.md").read_text()
        self.assertIn("https://github.com/Nutlope/hallmark", upstream)
        self.assertIn("13ac0ec7e148655948100b6396439e481361d690", upstream)
        self.assertIn("Version: 1.1.0", upstream)

    def test_package_adds_no_hooks_servers_or_symlinks(self):
        for manifest in (".claude-plugin/plugin.json", ".codex-plugin/plugin.json"):
            data = read_json(PLUGIN / manifest)
            for forbidden in ("hooks", "mcpServers", "commands", "agents"):
                self.assertNotIn(forbidden, data)
        self.assertFalse((PLUGIN / ".mcp.json").exists())
        self.assertFalse((PLUGIN / "hooks").exists())
        self.assertFalse(any(p.is_symlink() for p in PLUGIN.rglob("*")))


if __name__ == "__main__":
    unittest.main()
