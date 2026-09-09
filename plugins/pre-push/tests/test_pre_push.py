#!/usr/bin/env python3
"""Exercise the shipped hook through Git against disposable local remotes."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


TEMPLATE = Path(__file__).resolve().parents[1] / 'skills/pre-push/assets/pre-push'


class PrePushTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pre-push test ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / 'source'
        self.remote = self.root / 'remote.git'
        # The caller may be verify.sh with a temporary index, or itself a Git hook.
        # Neither its index, hook config nor credentials belong in these fixtures.
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
        self.env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull)
        self.git('init', '--quiet', '--initial-branch=main', str(self.repo), cwd=self.root)
        self.git('init', '--quiet', '--bare', str(self.remote), cwd=self.root)
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'commit.gpgSign', 'false')
        self.git('config', 'core.hooksPath', '.repo hooks')
        self.git('remote', 'add', 'origin', str(self.remote))
        self.git('config', 'receive.denyDeleteCurrent', 'ignore', cwd=self.remote)
        hook = self.repo / '.repo hooks/pre-push'
        hook.parent.mkdir()
        shutil.copy2(TEMPLATE, hook)
        (self.repo / 'scripts').mkdir()
        self.verifier('exit 0')
        self.git('add', '.')
        self.git('commit', '--quiet', '-m', 'fixture')
        self.head = self.git('rev-parse', 'HEAD').stdout.strip()

    def git(self, *args, cwd=None, check=True):
        return subprocess.run(
            ['git', *args], cwd=cwd or self.repo, env=self.env,
            text=True, capture_output=True, check=check, timeout=15,
        )

    def verifier(self, body):
        script = self.repo / 'scripts/verify.sh'
        script.write_text(
            '#!/bin/sh\n'
            'printf x >> "$(git rev-parse --git-path verification-runs)"\n'
            + body + '\n'
        )
        script.chmod(0o755)

    def pushes(self, *refs, success, cwd=None):
        result = self.git('push', 'origin', *refs, check=False, cwd=cwd)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stderr)
        return result

    def remote_ref(self, branch):
        result = self.git('rev-parse', '--verify', f'refs/heads/{branch}', cwd=self.remote, check=False)
        return result.stdout.strip() if result.returncode == 0 else None

    def runs(self, cwd=None):
        cwd = cwd or self.repo
        path = Path(self.git('rev-parse', '--git-path', 'verification-runs', cwd=cwd).stdout.strip())
        if not path.is_absolute():
            path = cwd / path
        return len(path.read_text()) if path.exists() else 0

    def test_successful_main_push_runs_check_once(self):
        self.pushes('HEAD:main', success=True)
        self.assertEqual(self.remote_ref('main'), self.head)
        self.assertEqual(self.runs(), 1)

    def test_failing_check_leaves_existing_remote_unchanged(self):
        self.pushes('HEAD:main', success=True)
        (self.repo / 'new-file').write_text('new commit\n')
        self.git('add', 'new-file')
        self.git('commit', '--quiet', '-m', 'next')
        self.verifier('exit 23')
        self.pushes('HEAD:main', success=False)
        self.assertEqual(self.remote_ref('main'), self.head)
        self.assertEqual(self.runs(), 2)

    def test_non_target_branch_skips_failing_check(self):
        self.verifier('exit 23')
        self.pushes('HEAD:feature', success=True)
        self.assertEqual(self.remote_ref('feature'), self.head)
        self.assertEqual(self.runs(), 0)

    def test_main_deletion_skips_failing_check(self):
        self.pushes('HEAD:main', success=True)
        self.verifier('exit 23')
        self.pushes(':main', success=True)
        self.assertIsNone(self.remote_ref('main'))
        self.assertEqual(self.runs(), 1)

    def test_multi_ref_failure_pushes_neither_ref(self):
        self.verifier('exit 23')
        self.pushes('HEAD:feature', 'HEAD:main', success=False)
        self.assertIsNone(self.remote_ref('main'))
        self.assertIsNone(self.remote_ref('feature'))
        self.assertEqual(self.runs(), 1)

    def test_multi_ref_success_checks_once(self):
        self.pushes('HEAD:feature', 'HEAD:main', success=True)
        self.assertEqual(self.remote_ref('main'), self.head)
        self.assertEqual(self.remote_ref('feature'), self.head)
        self.assertEqual(self.runs(), 1)

    def test_missing_verifier_blocks_push(self):
        (self.repo / 'scripts/verify.sh').unlink()
        self.pushes('HEAD:main', success=False)
        self.assertIsNone(self.remote_ref('main'))

    def test_non_executable_verifier_blocks_push(self):
        (self.repo / 'scripts/verify.sh').chmod(0o644)
        self.pushes('HEAD:main', success=False)
        self.assertIsNone(self.remote_ref('main'))

    def test_compound_check_preserves_early_failure(self):
        self.verifier('false && printf unexpected')
        self.pushes('HEAD:main', success=False)
        self.assertIsNone(self.remote_ref('main'))
        self.assertEqual(self.runs(), 1)

    def test_target_ref_can_be_adapted(self):
        hook = self.repo / '.repo hooks/pre-push'
        hook.write_text(hook.read_text().replace('refs/heads/main', 'refs/heads/release'))
        self.verifier('exit 23')
        self.pushes('HEAD:main', success=True)
        self.pushes('HEAD:release', success=False)
        self.assertEqual(self.remote_ref('main'), self.head)
        self.assertIsNone(self.remote_ref('release'))
        self.assertEqual(self.runs(), 1)

    def test_linked_worktree_uses_its_copied_hook(self):
        worktree = self.root / 'linked worktree'
        self.git('worktree', 'add', '--quiet', '-b', 'topic', str(worktree))
        self.pushes('HEAD:main', success=True, cwd=worktree)
        self.assertEqual(self.remote_ref('main'), self.head)
        self.assertEqual(self.runs(cwd=worktree), 1)
        self.assertEqual(self.runs(), 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
