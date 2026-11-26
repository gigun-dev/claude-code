import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_external_plugin as b  # noqa: E402

FRONT = "---\nname: demo-skill\ndescription: Demo skill.\n---\n"
NODE = "/nix/store/x-node/bin/node"


class BuildTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name)
        self.package = self.out / "lib" / "demo"
        (self.package / ".claude-plugin").mkdir(parents=True)
        skill = self.package / "skills" / "demo-skill"
        skill.mkdir(parents=True)
        # Over agy's limit, so the agy variant is split and the shared one is not.
        body = "# Demo\n\n## Small\n\nshort\n\n## Big\n\n" + "- line of the big section\n" * 1200
        (skill / "SKILL.md").write_text(FRONT + body)
        self.claude = {
            "name": "demo", "version": "1.2.3", "description": "Demo.",
            "author": {"name": "someone", "url": "https://x"}, "license": "MIT",
            "icon": "./assets/icon.png", "skills": "./skills",
            "mcpServers": {"demo": {
                "command": "node", "args": ["${CLAUDE_PLUGIN_ROOT}/run.mjs", "1.2.3"], "env": {"A": "1"},
            }},
        }
        self.write_manifest()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write_manifest(self) -> None:
        (self.package / ".claude-plugin" / "plugin.json").write_text(json.dumps(self.claude))

    def build(self, env=None, servers=("demo",), skills=("demo-skill",)):
        return b.build(self.out, "demo", NODE, "/bin/sh", env or {}, list(servers), list(skills))

    def read(self, *parts) -> dict:
        return json.loads(self.out.joinpath(*parts).read_text())

    def test_one_executable_that_every_manifest_names(self) -> None:
        self.build({"demo": {"B": "two words", "A": "9"}})
        exe = self.out / "bin" / "demo-mcp"
        script = exe.read_text()
        self.assertIn(f"exec {NODE} {self.package}/run.mjs 1.2.3 \"$@\"", script)
        self.assertIn("export A=9\n", script)
        self.assertIn("export B='two words'\n", script)
        shared = self.out / "share" / "agent-plugins" / "demo"
        self.assertEqual(self.read(shared, "mcp.json")["mcpServers"]["demo"], {"type": "stdio", "command": str(exe)})
        self.assertEqual(self.read(shared, ".claude-plugin", "plugin.json")["mcpServers"]["demo"], {"command": str(exe)})
        agy = self.out / "share" / "agy-plugins" / "demo"
        self.assertEqual(self.read(agy, "mcp_config.json")["mcpServers"]["demo"], {"command": str(exe)})

    def test_agent_plugins_manifest_keeps_only_schema_fields(self) -> None:
        self.build()
        manifest = self.read("share", "agent-plugins", "demo", "plugin.json")
        self.assertEqual(manifest["$schema"], b.PLUGIN_SCHEMA)
        self.assertEqual(set(manifest) - {"$schema"}, {"name", "version", "description", "author", "license"})
        self.assertNotIn("icon", self.read("share", "agent-plugins", "demo", ".claude-plugin", "plugin.json"))

    def test_agy_split_stays_out_of_the_shared_skill(self) -> None:
        self.build()
        original = (self.package / "skills" / "demo-skill" / "SKILL.md").read_text()
        shared = self.out / "share" / "agent-plugins" / "demo" / "skills" / "demo-skill"
        agy = self.out / "share" / "agy-plugins" / "demo" / "skills" / "demo-skill"
        self.assertEqual((shared / "SKILL.md").read_text(), original)
        self.assertFalse((shared / "references").exists())
        self.assertLess(len((agy / "SKILL.md").read_bytes()), 24000)
        self.assertTrue((agy / "references" / "big.md").is_file())
        self.assertFalse((self.out / "share" / "agent-plugins" / "demo" / ".antigravity-plugin").exists())
        self.assertFalse((self.out / "share" / "agy-plugins" / "demo" / ".claude-plugin").exists())

    def test_names_that_differ_from_the_pin_fail(self) -> None:
        with self.assertRaisesRegex(b.WrapError, "npm-sources.json records"):
            self.build(skills=("other",))
        with self.assertRaisesRegex(b.WrapError, "npm-sources.json records"):
            self.build(servers=())

    def test_bare_command_other_than_node_fails(self) -> None:
        # npx would be resolved from the host's PATH.
        self.claude["mcpServers"]["demo"]["command"] = "npx"
        self.write_manifest()
        with self.assertRaisesRegex(b.WrapError, "neither node nor inside the package"):
            self.build()

    def test_env_for_an_unknown_server_fails(self) -> None:
        with self.assertRaisesRegex(b.WrapError, "mcpEnv names servers"):
            self.build({"other": {"A": "1"}})

    def test_executable_runs_without_path(self) -> None:
        # The command is absolute, so an empty PATH (Codex clears the
        # environment) still starts it. /bin/sh stands in for node here.
        self.claude["mcpServers"]["demo"] = {"command": "/bin/sh", "args": ["-c", "echo $A"], "env": {"A": "ok"}}
        self.write_manifest()
        self.build()
        result = subprocess.run([str(self.out / "bin" / "demo-mcp")], env={}, capture_output=True, text=True)
        self.assertEqual(result.stdout.strip(), "ok")


if __name__ == "__main__":
    unittest.main()
