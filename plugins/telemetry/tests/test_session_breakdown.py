import importlib.machinery
import importlib.util
import json
import os
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "bin" / "session-breakdown"
LOADER = importlib.machinery.SourceFileLoader("session_breakdown", str(SCRIPT))
SPEC = importlib.util.spec_from_loader("session_breakdown", LOADER)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def ts(second):
    return f"2026-01-01T00:00:{second:02d}Z"


def claude_line(second, message, **extra):
    value = {"type": "assistant", "timestamp": ts(second), "message": message}
    value.update(extra)
    return value


def codex_line(second, record_type, payload, ordinal):
    return {"timestamp": ts(second), "ordinal": ordinal, "type": record_type,
            "payload": payload}


class SessionBreakdownTests(unittest.TestCase):
    def test_claude_pairs_cross_boundary_and_counts_only_selected_tools(self):
        records = [
            claude_line(0, {"role": "assistant", "content": [{
                "type": "tool_use", "id": "cross", "name": "Bash",
                "input": {"command": "sleep 4"},
            }]}),
            # Two concurrent calls overlap for three seconds.
            claude_line(2, {"role": "assistant", "content": [
                {"type": "tool_use", "id": "a", "name": "Bash", "input": {"command": "npm test"}},
                {"type": "tool_use", "id": "b", "name": "Bash", "input": {"command": "rg test"}},
            ]}),
            {"type": "user", "timestamp": ts(4), "message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": "cross", "content": "ok"},
            ]}},
            {"type": "user", "timestamp": ts(5), "message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": "a", "content": "ok"},
                {"type": "tool_result", "tool_use_id": "b", "content": "ok"},
            ]}},
            claude_line(1, {"role": "assistant", "id": "outside", "usage": {
                "input_tokens": 99, "output_tokens": 9,
            }, "content": []}),
            claude_line(3, {"role": "assistant", "id": "inside", "usage": {
                "input_tokens": 10, "output_tokens": 2,
            }, "content": []}),
            claude_line(8, {"role": "assistant", "content": [{
                "type": "tool_use", "id": "outside-tool", "name": "Bash",
                "input": {"command": "npm test"},
            }]}),
            {"type": "user", "timestamp": ts(9), "message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": "outside-tool", "content": "ok"},
            ]}},
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "claude.jsonl"
            path.write_text("".join(json.dumps(record) + "\n" for record in records))
            body = MODULE.parse_claude_file(str(path))
        start = MODULE.parse_ts(ts(2))
        end = MODULE.parse_ts(ts(6))
        body.finalize(start, end)

        # The 0-4 call is clipped to 2-4; the two 2-5 calls union to 3s.
        self.assertAlmostEqual(body.tool_union, 3.0)
        self.assertEqual(body.tools["Bash"], 3)
        self.assertEqual(body._token_summary()["total_tokens"], 12)
        self.assertEqual(body._token_summary()["records"], 1)
        self.assertEqual(body.bash_n["test"], 1)
        self.assertEqual(body.bash_n["read"], 1)

    def test_missing_claude_usage_is_unavailable(self):
        records = [claude_line(1, {"role": "assistant", "content": [{
            "type": "text", "text": "hello",
        }]})]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "claude.jsonl"
            path.write_text(json.dumps(records[0]) + "\n")
            body = MODULE.parse_claude_file(str(path))
        body.finalize(MODULE.parse_ts(ts(0)), MODULE.parse_ts(ts(2)))
        self.assertEqual(body._token_summary()["status"], "unavailable")
        self.assertIsNone(body._token_summary()["total_tokens"])

    def test_empty_codex_usage_is_unavailable_and_parent_group_is_partial(self):
        parent = MODULE.Body("codex", "main", "parent", "parent.jsonl")
        child = MODULE.Body("codex", "subagent", "child", "child.jsonl",
                            parent_id="parent")
        start = MODULE.parse_ts(ts(0))
        end = MODULE.parse_ts(ts(4))
        parent.add_activity(MODULE.parse_ts(ts(1)))
        parent.add_activity(MODULE.parse_ts(ts(2)))
        parent.add_usage(MODULE.parse_ts(ts(1)), {})
        parent.add_usage(MODULE.parse_ts(ts(1)), {"token_count": 999}, response_id="snapshot")
        child.add_activity(MODULE.parse_ts(ts(1)))
        child.add_activity(MODULE.parse_ts(ts(2)))
        child.add_usage(MODULE.parse_ts(ts(1)), {
            "input_tokens": 10, "output_tokens": 2, "total_tokens": 12,
        }, response_id="child-response")
        parent.finalize(start, end)
        child.finalize(start, end)
        self.assertEqual(parent._token_summary()["status"], "unavailable")
        self.assertIsNone(parent._token_summary()["total_tokens"])
        MODULE._set_roots([parent, child])
        group = MODULE.build_groups([parent, child])[0]
        self.assertEqual(group["tokens"]["status"], "partial")
        self.assertEqual(group["tokens"]["incomplete_body_ids"], ["parent"])
        self.assertEqual(group["tokens"]["total_tokens"], 12)

    def test_codex_usage_dedup_subsets_and_token_count_snapshot(self):
        records = [
            codex_line(0, "session_meta", {
                "id": "root", "session_id": "root", "cwd": "/repo",
                "thread_source": "user",
            }, 0),
            codex_line(0, "event_msg", {
                "type": "task_started", "thread_id": "root", "turn_id": "turn",
                "started_at": 0,
            }, 1),
            codex_line(1, "response_item", {
                "type": "function_call", "id": "call", "call_id": "call",
                "name": "exec", "arguments": json.dumps({"cmd": "npm test"}),
                "internal_chat_message_metadata_passthrough": {"turn_id": "turn"},
            }, 2),
            # The call starts before the window and ends inside it.
            codex_line(4, "response_item", {
                "type": "function_call_output", "call_id": "call", "output": "ok",
                "internal_chat_message_metadata_passthrough": {"turn_id": "turn"},
            }, 3),
            codex_line(3, "token_usage_record", {
                "thread_id": "root", "turn_id": "turn", "response_id": "r1",
                "usage": {
                    "input_tokens": 100, "cached_input_tokens": 80,
                    "output_tokens": 20, "reasoning_output_tokens": 5,
                    "total_tokens": 120,
                },
            }, 4),
            # Same response and an event snapshot must not be counted again.
            codex_line(3, "token_usage_record", {
                "thread_id": "root", "turn_id": "turn", "response_id": "r1",
                "usage": {
                    "input_tokens": 100, "cached_input_tokens": 80,
                    "output_tokens": 20, "reasoning_output_tokens": 5,
                    "total_tokens": 120,
                },
            }, 5),
            codex_line(3, "event_msg", {
                "type": "token_count", "thread_id": "root", "turn_id": "turn",
                "info": {"total_token_usage": {"total_tokens": 999}},
            }, 6),
            codex_line(6, "token_usage_record", {
                "thread_id": "root", "turn_id": "turn", "response_id": "at-to",
                "usage": {"input_tokens": 500, "output_tokens": 500, "total_tokens": 1000},
            }, 7),
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "root.jsonl"
            path.write_text("".join(json.dumps(record) + "\n" for record in records))
            body = MODULE.parse_codex_file(str(path))
        body.finalize(MODULE.parse_ts(ts(2)), MODULE.parse_ts(ts(6)))

        self.assertAlmostEqual(body.tool_union, 2.0)
        self.assertEqual(body.tools["exec"], 1)
        tokens = body._token_summary()
        self.assertEqual(tokens["records"], 1)
        self.assertEqual(tokens["total_tokens"], 120)
        self.assertEqual(tokens["cached_input_tokens"], 80)
        self.assertEqual(tokens["uncached_input_tokens"], 20)
        self.assertEqual(tokens["visible_output_tokens"], 15)

    def test_codex_parent_selection_discovers_nested_subagent_parent(self):
        child_id = "child"
        parent_id = "parent"
        parent = [codex_line(1, "session_meta", {
            "id": parent_id, "session_id": parent_id, "cwd": "/repo",
            "thread_source": "user",
        }, 0)]
        child = [codex_line(2, "session_meta", {
            "id": child_id, "session_id": parent_id, "cwd": "/repo",
            "source": {"subagent": {"thread_spawn": {
                "parent_thread_id": parent_id,
            }}},
        }, 0)]
        # A regular conversation fork must not become a subagent child.
        fork = [codex_line(2, "session_meta", {
            "id": "fork", "session_id": "fork", "cwd": "/repo",
            "thread_source": "user", "forked_from_id": parent_id,
        }, 0)]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sessions = root / "sessions"
            sessions.mkdir()
            (sessions / "parent.jsonl").write_text("".join(json.dumps(r) + "\n" for r in parent))
            (sessions / "child.jsonl").write_text("".join(json.dumps(r) + "\n" for r in child))
            (sessions / "fork.jsonl").write_text("".join(json.dumps(r) + "\n" for r in fork))
            old = os.environ.copy()
            os.environ["CODEX_SESSIONS_DIR"] = str(sessions)
            os.environ["CODEX_ARCHIVED_SESSIONS_DIR"] = str(root / "archived")
            try:
                bodies = MODULE.collect_codex(sessions=[parent_id])
            finally:
                os.environ.clear()
                os.environ.update(old)
        by_id = {body.id: body for body in bodies}
        self.assertEqual(set(by_id), {parent_id, child_id})
        self.assertEqual(by_id[child_id].parent_id, parent_id)
        self.assertIsNone(by_id["parent"].parent_id)

    def test_codex_all_projects_disables_cwd_filter(self):
        record = codex_line(1, "session_meta", {
            "id": "other", "session_id": "other", "cwd": "/other-project",
        }, 0)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sessions = root / "sessions"
            sessions.mkdir()
            (sessions / "other.jsonl").write_text(json.dumps(record) + "\n")
            old = os.environ.copy()
            os.environ["CODEX_SESSIONS_DIR"] = str(sessions)
            os.environ["CODEX_ARCHIVED_SESSIONS_DIR"] = str(root / "archived")
            try:
                filtered = MODULE.collect_codex(project="/repo")
                all_projects = MODULE.collect_codex(project="/repo", all_projects=True)
            finally:
                os.environ.clear()
                os.environ.update(old)
        self.assertEqual(filtered, [])
        self.assertEqual([body.id for body in all_projects], ["other"])

    def test_parent_group_unions_overlapping_elapsed_intervals(self):
        parent = MODULE.Body("codex", "main", "parent", "parent.jsonl")
        child = MODULE.Body("codex", "subagent", "child", "child.jsonl",
                            parent_id="parent")
        parent.add_task_interval(MODULE.parse_ts(ts(1)), MODULE.parse_ts(ts(8)), "p")
        child.add_task_interval(MODULE.parse_ts(ts(3)), MODULE.parse_ts(ts(6)), "c")
        start = MODULE.parse_ts(ts(0))
        end = MODULE.parse_ts(ts(9))
        parent.finalize(start, end)
        child.finalize(start, end)
        MODULE._set_roots([parent, child])
        group = MODULE.build_groups([parent, child])[0]
        self.assertEqual(group["body_ids"], ["child", "parent"])
        self.assertEqual(group["elapsed_s"], 7.0)


if __name__ == "__main__":
    unittest.main()
