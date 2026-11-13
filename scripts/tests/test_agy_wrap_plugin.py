import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import agy_wrap_plugin as wrap  # noqa: E402

FRONT = "---\nname: demo\ndescription: Demo skill.\n---\n"


def words(text: str) -> list[str]:
    """Every non-empty source line, whitespace-normalised, for loss checks."""
    return [re.sub(r"\s+", " ", line).strip() for line in text.splitlines() if line.strip()]


class SplitSkillTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.skill = Path(self.tmp.name) / "demo"
        (self.skill / "references").mkdir(parents=True)
        (self.skill / "references" / "guide.md").write_text("# Guide\n")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write(self, body: str) -> None:
        (self.skill / "SKILL.md").write_text(FRONT + body)

    def body(self) -> str:
        return (self.skill / "SKILL.md").read_text()[len(FRONT):]

    def test_body_within_limit_is_untouched(self) -> None:
        self.write("# Demo\n\n## Small\n\ntext\n")
        self.assertEqual(wrap.split_skill(self.skill, limit=1000), [])
        self.assertEqual(self.body(), "# Demo\n\n## Small\n\ntext\n")

    def test_moves_largest_section_and_keeps_every_line(self) -> None:
        big = "Choose the route first.\n\n" + "".join(
            f"- item {i}: see [guide](references/guide.md).\n" for i in range(40)
        )
        original = f"# Demo\n\n## Small\n\nshort\n\n## Big\n\n{big}\n## Tail\n\nend\n"
        self.write(original)
        self.assertEqual(wrap.split_skill(self.skill, limit=600), ["Big"])
        body = self.body()
        moved = (self.skill / "references" / "big.md").read_text()
        self.assertLessEqual(len(body.encode()), 600)
        self.assertIn("## Big\n\nChoose the route first.\n\n", body)
        self.assertIn("[Big](references/big.md)", body)
        self.assertIn("see [guide](guide.md)", moved)
        combined = body + moved.replace("](guide.md)", "](references/guide.md)")
        for line in words(original):
            self.assertIn(line, words(combined) + ["## Big"], line)

    def test_list_lead_is_not_kept_in_the_stub(self) -> None:
        self.write("## Big\n\n" + "- x\n" * 300)
        wrap.split_skill(self.skill, limit=400)
        self.assertNotIn("- x", self.body())

    def test_heading_inside_code_fence_is_not_a_section(self) -> None:
        self.write("## Real\n\n```\n## not a heading\n" + "y\n" * 300 + "```\n")
        self.assertEqual(wrap.split_skill(self.skill, limit=300), ["Real"])

    def test_refuses_a_move_that_breaks_a_link(self) -> None:
        self.write("## Big\n\n" + "see [x](docs/missing.md)\n" * 50)
        with self.assertRaises(wrap.SplitError):
            wrap.split_skill(self.skill, limit=300)
        self.assertFalse((self.skill / "references" / "big.md").exists())

    def test_refuses_when_nothing_left_to_move(self) -> None:
        self.write("# Demo\n\n" + "preamble line\n" * 100)
        with self.assertRaises(wrap.SplitError):
            wrap.split_skill(self.skill, limit=300)


class WrapTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.plugin = Path(self.tmp.name) / "demo"
        (self.plugin / ".claude-plugin").mkdir(parents=True)
        (self.plugin / "skills" / "demo").mkdir(parents=True)
        (self.plugin / "skills" / "demo" / "SKILL.md").write_text(FRONT + "# Demo\n")
        claude = {
            "name": "demo",
            "version": "1.2.3",
            "description": "Demo.",
            "author": {"name": "someone"},
            "license": "MIT",
            "skills": "./skills",
            "mcpServers": {
                "demo": {"command": "node", "args": ["${CLAUDE_PLUGIN_ROOT}/run.mjs"], "env": {"A": "1"}}
            },
        }
        (self.plugin / ".claude-plugin" / "plugin.json").write_text(json.dumps(claude))

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_writes_agy_manifest_and_mcp_config(self) -> None:
        wrap.wrap(self.plugin, "/nix/store/x-node/bin/node", {"demo": {"B": "2", "A": "9"}})
        manifest = json.loads((self.plugin / ".antigravity-plugin" / "plugin.json").read_text())
        self.assertEqual(
            {k: manifest[k] for k in ("name", "version", "description", "author")},
            {"name": "demo", "version": "1.2.3", "description": "Demo.", "author": {"name": "someone"}},
        )
        self.assertNotIn("license", manifest)
        server = json.loads((self.plugin / "mcp_config.json").read_text())["mcpServers"]["demo"]
        self.assertEqual(server["command"], "/nix/store/x-node/bin/node")
        self.assertEqual(server["args"], ["${PLUGIN_ROOT}/run.mjs"])
        self.assertEqual(server["env"], {"A": "9", "B": "2"})

    def test_env_for_an_unknown_server_is_an_error(self) -> None:
        with self.assertRaises(SystemExit):
            wrap.wrap(self.plugin, None, {"other": {"B": "2"}})

    def run_main(self) -> subprocess.CompletedProcess:
        script = Path(wrap.__file__)
        return subprocess.run([sys.executable, str(script), str(self.plugin)], capture_output=True, text=True)

    def test_upstream_without_manifest_fails_with_one_line(self) -> None:
        # rea-agents 6.8.0 and earlier ship no .claude-plugin/plugin.json.
        (self.plugin / ".claude-plugin" / "plugin.json").unlink()
        result = self.run_main()
        self.assertEqual(result.returncode, 1)
        self.assertIn(".claude-plugin/plugin.json: missing; the upstream package does not ship", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_mcp_pointer_to_a_missing_file_fails_with_one_line(self) -> None:
        manifest = self.plugin / ".claude-plugin" / "plugin.json"
        manifest.write_text(json.dumps(json.loads(manifest.read_text()) | {"mcpServers": "./mcp.json"}))
        result = self.run_main()
        self.assertEqual(result.returncode, 1)
        self.assertIn("mcp.json: missing; .claude-plugin/plugin.json points mcpServers at it", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_unexpected_failure_keeps_its_traceback(self) -> None:
        # Only known upstream shapes are turned into one line; a bug here must
        # still show where it happened.
        skill_md = self.plugin / "skills" / "demo" / "SKILL.md"
        skill_md.unlink()
        skill_md.mkdir()  # reading it raises IsADirectoryError, which is not a WrapError
        result = self.run_main()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
