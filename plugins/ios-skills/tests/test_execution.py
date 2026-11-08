import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ios_project", ROOT / "scripts/ios-project.py")
project = importlib.util.module_from_spec(spec)
spec.loader.exec_module(project)
spec_host = importlib.util.spec_from_file_location("ios_host", ROOT / "scripts/ios-host.py")
host = importlib.util.module_from_spec(spec_host)
spec_host.loader.exec_module(host)


class ProjectSelection(unittest.TestCase):
    def test_new_config_keeps_xcodeproj_entry(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "日本語 App.xcodeproj"
            p.mkdir()
            (p / "project.xcproj").write_text('{}')
            self.assertEqual(project.resolve(p), ("-project", str(p.resolve())))

    def test_workspace_precedence_and_ambiguity(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)
            (p / "App.xcodeproj").mkdir()
            (p / "Other.xcodeproj").mkdir()
            with self.assertRaises(ValueError):
                project.resolve(p)
            workspace = p / "App.xcworkspace"
            workspace.mkdir()
            self.assertEqual(project.resolve(p), ("-workspace", str(workspace.resolve())))
            (p / "Other.xcworkspace").mkdir()
            with self.assertRaises(ValueError):
                project.resolve(p)

    def test_missing_project_is_rejected(self):
        with self.assertRaises(ValueError):
            project.resolve('/no-such-ios-project.xcodeproj')


class ExecutionBoundary(unittest.TestCase):
    def run_host(self, *args):
        return subprocess.run([sys.executable, str(ROOT / 'scripts/ios-host.py'), *args],
                              capture_output=True, text=True)

    def test_ssh_options_are_not_hosts(self):
        p = self.run_host('probe', '--host=-oProxyCommand=touch')
        self.assertEqual(p.returncode, 2)
        self.assertIn('one SSH destination', p.stderr)

    def test_only_bundled_tools_can_be_run(self):
        p = self.run_host('run', '--', '../outside.py')
        self.assertEqual(p.returncode, 2)

    def test_arguments_reach_the_real_script_without_shell_evaluation(self):
        p = self.run_host('run', '--', 'scripts/ios-project.py', '$(no-command).xcodeproj')
        self.assertEqual(p.returncode, 4)
        self.assertIn('existing', p.stderr)

    def test_remote_child_failure_survives_successful_transport(self):
        completed = subprocess.CompletedProcess([], 0,
            b'{"ios_execution":1,"exit_code":4,"stdout":""}')
        with patch.object(host.sys, 'stdout') as output:
            output.buffer = io.BytesIO()
            self.assertEqual(host.remote_result(completed), 4)

    def test_missing_remote_result_cannot_report_success(self):
        with self.assertRaises(ValueError):
            host.remote_result(subprocess.CompletedProcess([], 0, b''))

    def test_explicit_stdin_preserves_non_ascii_text(self):
        with tempfile.TemporaryDirectory() as tmp:
            text = Path(tmp) / 'input.txt'
            text.write_text('日本語と絵文字😀')
            p = self.run_host('exec', '--stdin-file', str(text), '--', sys.executable,
                              '-c', 'import sys; print(sys.stdin.read(),end="")')
            self.assertEqual(p.returncode, 0)
            self.assertEqual(p.stdout, text.read_text())


if __name__ == '__main__':
    unittest.main()
