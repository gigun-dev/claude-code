from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock


RUNNER_PATH = Path(__file__).resolve().parents[1] / "scripts" / "run-agent-eval.py"
SPEC = importlib.util.spec_from_file_location("run_agent_eval", RUNNER_PATH)
assert SPEC is not None and SPEC.loader is not None
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


def event(**values: object) -> str:
    return json.dumps(values, separators=(",", ":"))


class ClaudeRuntimeTests(unittest.TestCase):
    def make_plugin(self, root: Path) -> Path:
        plugin = root / "plugin"
        (plugin / ".claude-plugin").mkdir(parents=True)
        (plugin / ".claude-plugin" / "plugin.json").write_text(
            json.dumps({"name": "ios-skills"}),
            encoding="utf-8",
        )
        for name in ("ios-simulator", "ios-device-build"):
            skill = plugin / "skills" / name
            skill.mkdir(parents=True)
            (skill / "SKILL.md").write_text(
                f"---\nname: {name}\ndescription: test\n---\n",
                encoding="utf-8",
            )
        return plugin

    def test_claude_command_uses_subscription_and_empty_mcp(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            plugin = self.make_plugin(root)
            schema = root / "schema.json"
            schema.write_text(json.dumps({"type": "object"}), encoding="utf-8")
            args = argparse.Namespace(provider="claude", model="claude-test")
            command = RUNNER.build_command(
                args,
                {"id": "case", "mode": "read-only", "prompt": "test"},
                root,
                plugin,
                None,
                root / "final.json",
                schema,
            )

        self.assertNotIn("--bare", command)
        self.assertIn("--strict-mcp-config", command)
        mcp_index = command.index("--mcp-config")
        self.assertEqual(json.loads(command[mcp_index + 1]), {"mcpServers": {}})
        self.assertEqual(command[command.index("--plugin-dir") + 1], str(plugin))

    def test_plugin_commands_are_qualified(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            commands = RUNNER.claude_plugin_commands(self.make_plugin(Path(raw)))
        self.assertEqual(
            commands,
            {"ios-skills:ios-simulator", "ios-skills:ios-device-build"},
        )

    def test_condition_assertion_accepts_expected_commands(self) -> None:
        stdout = event(
            type="system",
            subtype="init",
            slash_commands=["ios-skills:ios-simulator", "other:skill"],
        )
        self.assertIsNone(
            RUNNER.assert_condition_took_effect(
                stdout,
                {"ios-skills:ios-simulator"},
                {"ios-skills:ios-device-build"},
            )
        )

    def test_condition_assertion_reports_missing_and_leaked(self) -> None:
        stdout = event(
            type="system",
            subtype="init",
            slash_commands=["ios-skills:ios-device-build"],
        )
        error = RUNNER.assert_condition_took_effect(
            stdout,
            {"ios-skills:ios-simulator"},
            {"ios-skills:ios-device-build"},
        )
        self.assertEqual(
            error,
            "condition did not take effect: "
            "missing=['ios-skills:ios-simulator'] leaked=['ios-skills:ios-device-build']",
        )

    def test_condition_assertion_rejects_missing_init(self) -> None:
        self.assertEqual(
            RUNNER.assert_condition_took_effect(event(type="result", result="OK"), set(), set()),
            "no init event found; cannot verify condition",
        )

    def test_auth_failure_is_not_misclassified_as_artifact_error(self) -> None:
        stdout = event(type="result", result="Not logged in · Please run /login")
        self.assertEqual(
            RUNNER.claude_auth_error(stdout),
            "Not logged in · Please run /login",
        )

    def test_claude_environment_does_not_forward_api_auth(self) -> None:
        with tempfile.TemporaryDirectory() as raw, mock.patch.dict(
            os.environ,
            {
                "PATH": "/usr/bin",
                "HOME": "/tmp/home",
                "ANTHROPIC_API_KEY": "must-not-leak",
                "CLAUDE_CODE_USE_BEDROCK": "1",
            },
            clear=True,
        ):
            environment = RUNNER.clean_environment("claude", Path(raw))
        self.assertEqual(environment["HOME"], "/tmp/home")
        self.assertNotIn("ANTHROPIC_API_KEY", environment)
        self.assertNotIn("CLAUDE_CODE_USE_BEDROCK", environment)

    def test_claude_environment_forwards_user_for_keychain_auth(self) -> None:
        """USER を落とすと subscription 認証が解決できず全 run が Not logged in になる。

        実測(2026-08-02): macOS の Keychain エントリ service "Claude Code-credentials" は
        acct = ユーザー名で引かれる。USER 無しでは解決せず、LOGNAME では代替できない。
        api key を渡さない実装(上のテスト)と対になる制約なので、両方を固定しておく。
        """
        with tempfile.TemporaryDirectory() as raw, mock.patch.dict(
            os.environ,
            {"PATH": "/usr/bin", "HOME": "/tmp/home", "USER": "someone"},
            clear=True,
        ):
            environment = RUNNER.clean_environment("claude", Path(raw))
        self.assertEqual(environment["USER"], "someone")

    def test_mcp_config_is_empty_for_none_arm_and_cli_only_plugin(self) -> None:
        """MCP を宣言しない候補(= ios-skills)と none アームは空 MCP のまま。"""
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw) / "ios-skills"
            (root / ".claude-plugin").mkdir(parents=True)
            (root / ".claude-plugin" / "plugin.json").write_text(
                json.dumps({"name": "ios-skills", "skills": "./skills/"})
            )
            self.assertEqual(RUNNER.candidate_mcp_config(root), RUNNER.EMPTY_MCP_CONFIG)
        self.assertEqual(RUNNER.candidate_mcp_config(None), RUNNER.EMPTY_MCP_CONFIG)

    def test_mcp_config_follows_plugin_declared_servers(self) -> None:
        """MCP を宣言する候補(= build-ios-apps)にはそれを与える。

        一律に空 MCP を渡すと build-ios-apps の ios-debugger-agent が
        1行目から実行不能になり、ios-skills が構造的に勝つ
        (CLAUDE-RUNTIME-CONSTRAINTS.md §6-c)。
        """
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw) / "build-ios-apps"
            (root / ".claude-plugin").mkdir(parents=True)
            (root / ".claude-plugin" / "plugin.json").write_text(
                json.dumps({"name": "build-ios-apps", "mcpServers": "./.mcp.json"})
            )
            (root / ".mcp.json").write_text(
                json.dumps({"mcpServers": {"xcodebuildmcp": {"command": "npx"}}})
            )
            config = json.loads(RUNNER.candidate_mcp_config(root))
        self.assertIn("xcodebuildmcp", config["mcpServers"])

    def test_mcp_config_rejects_dangling_reference(self) -> None:
        """宣言だけあってファイルが無いのを黙って空 MCP に落とさない。

        黙って落とすと「MCP を与えたつもりのアームが実は空」という
        静かな偽の対照になる。
        """
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw) / "broken"
            (root / ".claude-plugin").mkdir(parents=True)
            (root / ".claude-plugin" / "plugin.json").write_text(
                json.dumps({"name": "broken", "mcpServers": "./missing.json"})
            )
            with self.assertRaises(RUNNER.EvalError):
                RUNNER.candidate_mcp_config(root)

    def test_simulator_delta_flags_vanished_and_mutated_as_violations(self) -> None:
        """safety assertion「指定外の端末をbootまたはeraseしない」を実状態で裏取りする。"""
        before = {"AAA": {"name": "seed-caldav", "state": "Shutdown"},
                  "BBB": {"name": "iPhone 17 Pro", "state": "Shutdown"}}
        after = {"BBB": {"name": "iPhone 17 Pro", "state": "Booted"}}
        delta = RUNNER.simulator_delta(before, after)
        self.assertIn("AAA", delta["vanished"])
        self.assertIn("BBB", delta["mutated"])
        self.assertEqual(delta["violations"], 2)

    def test_simulator_delta_counts_leftovers_separately_from_violations(self) -> None:
        """片付け漏れは違反ではない。rubric の lifecycle で採点する別軸。"""
        before = {"AAA": {"name": "seed-caldav", "state": "Shutdown"}}
        after = dict(before, ZZZ={"name": "w-eval-1", "state": "Booted"})
        delta = RUNNER.simulator_delta(before, after)
        self.assertEqual(delta["violations"], 0)
        self.assertEqual(delta["leaked"], 1)

    def test_simulator_delta_is_none_without_a_snapshot(self) -> None:
        """Simulator を触らない環境でも runner は動く(read-only case はそこで完結する)。"""
        self.assertIsNone(RUNNER.simulator_delta(None, {}))
        self.assertIsNone(RUNNER.simulator_delta({}, None))

    def test_claude_json_schema_drops_meta_schema_ref(self) -> None:
        """`$schema` を残すと Claude CLI が起動前に落ちる(2026-08-02 実測)。

        no schema with key or ref "https://json-schema.org/draft/2020-12/schema"
        """
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "schema.json"
            path.write_text(json.dumps({
                "$schema": "https://json-schema.org/draft/2020-12/schema",
                "type": "object",
                "required": ["case_id"],
            }))
            schema = RUNNER.claude_json_schema(path)
        self.assertNotIn("$schema", schema)
        self.assertEqual(schema["required"], ["case_id"])

    def test_preflight_rejects_installed_comparison_plugin(self) -> None:
        stdout = "\n".join([
            event(
                type="system",
                subtype="init",
                slash_commands=["ios-skills:ios-simulator"],
            ),
            event(type="result", result="OK"),
        ])
        completed = mock.Mock(returncode=0, stdout=stdout, stderr="")
        args = argparse.Namespace(model="claude-test", dry_run=False, timeout=10)
        with tempfile.TemporaryDirectory() as raw, mock.patch.object(
            RUNNER.subprocess,
            "run",
            return_value=completed,
        ):
            batch = Path(raw) / "batch"
            batch.mkdir()
            with self.assertRaises(RUNNER.EvalError) as caught:
                RUNNER.run_claude_preflight(
                    args,
                    batch,
                    {"ios-skills:ios-simulator"},
                )
            metadata = json.loads(
                (batch / "claude-preflight" / "metadata.json").read_text(encoding="utf-8")
            )
        self.assertEqual(caught.exception.exit_code, RUNNER.EXIT_PROVIDER)
        self.assertEqual(metadata["status"], "condition-error")
        self.assertIn("ios-skills:ios-simulator", metadata["condition_error"])

    def test_preflight_accepts_clean_subscription_session(self) -> None:
        stdout = "\n".join([
            event(type="system", subtype="init", slash_commands=["other:skill"]),
            event(type="result", result="OK"),
        ])
        completed = mock.Mock(returncode=0, stdout=stdout, stderr="")
        args = argparse.Namespace(model="claude-test", dry_run=False, timeout=10)
        with tempfile.TemporaryDirectory() as raw, mock.patch.object(
            RUNNER.subprocess,
            "run",
            return_value=completed,
        ):
            batch = Path(raw) / "batch"
            batch.mkdir()
            RUNNER.run_claude_preflight(
                args,
                batch,
                {"ios-skills:ios-simulator"},
            )
            metadata = json.loads(
                (batch / "claude-preflight" / "metadata.json").read_text(encoding="utf-8")
            )
        self.assertEqual(metadata["status"], "completed")

    def test_preflight_reports_auth_error_even_with_nonzero_exit(self) -> None:
        stdout = "\n".join([
            event(type="system", subtype="init", slash_commands=[]),
            event(type="result", result="Not logged in · Please run /login"),
        ])
        completed = mock.Mock(returncode=1, stdout=stdout, stderr="")
        args = argparse.Namespace(model="claude-test", dry_run=False, timeout=10)
        with tempfile.TemporaryDirectory() as raw, mock.patch.object(
            RUNNER.subprocess,
            "run",
            return_value=completed,
        ):
            batch = Path(raw) / "batch"
            batch.mkdir()
            with self.assertRaises(RUNNER.EvalError) as caught:
                RUNNER.run_claude_preflight(args, batch, set())
        self.assertIn("authentication failed: Not logged in", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
