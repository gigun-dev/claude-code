from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location(
    "make_grading_bundle",
    Path(__file__).resolve().parent.parent / "scripts" / "make-grading-bundle.py",
)
BUNDLE = importlib.util.module_from_spec(_SPEC)
assert _SPEC.loader is not None
_SPEC.loader.exec_module(BUNDLE)


def fake_batch(root: Path, *, stdout_text: str = '{"type":"result"}') -> Path:
    """runner が作る batch ディレクトリの最小再現。"""
    batch = root / "20260101T000000Z-abcd1234"
    run = batch / "run-001-deadbeef"
    (run / "workspace" / "candidate" / "skills" / "ios-simulator").mkdir(parents=True)
    (run / "tmp").mkdir()
    (run / "workspace" / "candidate" / "skills" / "ios-simulator" / "SKILL.md").write_text("x\n" * 114)
    (run / "stdout.jsonl").write_text(stdout_text)
    (run / "stderr.log").write_text("")
    (run / "final.json").write_text(json.dumps({"case_id": "c1"}))
    (run / "metadata.json").write_text(json.dumps({"blinded_run_id": "run-001-deadbeef"}))
    (batch / "schedule.json").write_text(json.dumps({"suite": "ios-skills"}))
    (batch / "condition-map.json").write_text(json.dumps({
        "sealed": True,
        "runs": {"run-001-deadbeef": {"condition": "ios-skills-old"}},
    }))
    return batch


class BundleTests(unittest.TestCase):
    def test_excludes_sealed_map_workspace_and_tmp(self) -> None:
        """workspace/candidate は SKILL.md の行数だけで版が割れるので絶対に含めない。"""
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            result = BUNDLE.build(fake_batch(root), root / "bundle")
            names = {p.name for p in (root / "bundle").rglob("*")}
        self.assertEqual(result["runs"], 1)
        self.assertNotIn("condition-map.json", names)
        self.assertNotIn("workspace", names)
        self.assertNotIn("tmp", names)
        self.assertIn("stdout.jsonl", names)
        self.assertIn("schedule.json", names)

    def test_fails_when_condition_name_appears_in_contents(self) -> None:
        """runner の staging 方法が変わって transcript に候補パスが載り始めたら止める。

        いまは中立名 `candidate/` へ staging されているので漏れていないが、
        「漏れていないはず」を前提にしない。
        """
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            batch = fake_batch(root, stdout_text='{"cwd":"/candidates/ios-skills-old/skills"}')
            with self.assertRaises(BUNDLE.BundleError) as caught:
                BUNDLE.build(batch, root / "bundle")
        self.assertIn("ios-skills-old", str(caught.exception))

    def test_refuses_non_empty_output_dir(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            out = root / "bundle"
            out.mkdir()
            (out / "stale.json").write_text("{}")
            with self.assertRaises(BUNDLE.BundleError):
                BUNDLE.build(fake_batch(root), out)


if __name__ == "__main__":
    unittest.main()
