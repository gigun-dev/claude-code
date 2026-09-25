"""Run the shipped query script with a local curl fixture, without credentials/network."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

QUERY = Path(__file__).resolve().parents[1] / 'skills/review/scripts/query.sh'


class QueryTests(unittest.TestCase):
    def run_query(self, command, count=3, *args):
        with tempfile.TemporaryDirectory(prefix='telemetry-query-') as directory:
            root = Path(directory)
            credentials = root / 'credentials'
            credentials.write_text('LANGFUSE_PUBLIC_KEY=test\nLANGFUSE_SECRET_KEY=test\nLANGFUSE_BASE_URL=http://unused.invalid\n')
            query = root / 'query.sh'
            # Change only credential discovery; execute the real Shell/Python quoting.
            source = QUERY.read_text()
            needle = 'ENV_FILE="${HOME}/.config/claude-code/langfuse.env"'
            self.assertIn(needle, source)
            query.write_text(source.replace(needle, 'ENV_FILE="${TELEMETRY_TEST_ENV}"'))
            # totalCost is the current API field (see query.sh's 2026-09-25 comment);
            # the legacy calculatedTotalCost/totalPrice names are no longer returned.
            payload = json.dumps({'data': [
                {'id': str(n), 'name': f'fixture-{n}', 'type': 'GENERATION',
                 'latency': n, 'totalCost': n, 'usageDetails': {'total': n * 100}}
                for n in range(1, count + 1)
            ]})
            curl = root / 'curl'
            curl.write_text("#!/bin/sh\nprintf '%s\\n' '" + payload + "'\n")
            curl.chmod(0o755)
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'],
                       TELEMETRY_TEST_ENV=str(credentials))
            return subprocess.run(['bash', str(query), command, *args], env=env,
                                  text=True, capture_output=True, check=True, timeout=10).stdout

    def test_rankings_honor_requested_count_and_disclose_sample(self):
        for command in ('slow', 'cost'):
            with self.subTest(command=command):
                output = self.run_query(command, 3, '7', '1')
                self.assertEqual(output.count('fixture-'), 1)
                self.assertIn('fixture-3', output)
                self.assertIn('sample', output)
                self.assertIn('whole period', output)

    def test_trace_warns_at_retrieval_limit(self):
        self.assertIn('truncat', self.run_query('trace', 200, 'trace-id').lower())


if __name__ == '__main__':
    unittest.main()
