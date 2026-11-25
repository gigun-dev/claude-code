import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import agy_wrap_plugin as wrap  # noqa: E402

# Stand-in MCP servers. Each answers by request id, so the order of the
# client's messages decides what it sees.
SERVER = """
import json, sys, time
MODE = sys.argv[1]
if MODE == "silent":
    time.sleep(60)
if MODE == "grandchild":
    # A descendant inherits stdout/stderr and outlives the server.
    import subprocess
    subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
    time.sleep(60)
for line in sys.stdin:
    msg = json.loads(line)
    if msg.get("method") == "initialize":
        if MODE == "init-error":
            out = {"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32603, "message": "boom"}}
        else:
            out = {"jsonrpc": "2.0", "id": msg["id"], "result": {"serverInfo": {"name": "demo", "version": "1"}}}
    elif msg.get("method") == "tools/list":
        if MODE == "needs-initialized" and not seen_initialized:
            out = {"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32002, "message": "not initialized"}}
        else:
            out = {"jsonrpc": "2.0", "id": msg["id"], "result": {"tools": [{"name": "t"}]}}
    else:
        seen_initialized = msg.get("method") == "notifications/initialized"
        continue
    print(json.dumps(out), flush=True)
"""


class ProbeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.server = Path(self.tmp.name) / "server.py"
        self.server.write_text("seen_initialized = False\n" + SERVER)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def probe(self, mode: str, timeout: float = 30):
        argv = [sys.executable, str(self.server), mode]
        return wrap.probe("demo", argv, self.tmp.name, {}, timeout=timeout)

    def test_working_server(self) -> None:
        self.assertEqual(self.probe("ok"), "demo: demo 1, 1 tools")

    def test_silent_server_fails_at_the_deadline(self) -> None:
        start = time.monotonic()
        with self.assertRaises(SystemExit):
            self.probe("silent", timeout=2)
        self.assertLess(time.monotonic() - start, 10)

    def test_grandchild_holding_the_pipes_does_not_extend_the_deadline(self) -> None:
        start = time.monotonic()
        with self.assertRaises(SystemExit):
            self.probe("grandchild", timeout=0.5)
        self.assertLess(time.monotonic() - start, 3)

    def test_initialize_error_fails_even_with_tools(self) -> None:
        with self.assertRaisesRegex(SystemExit, "initialize"):
            self.probe("init-error")


if __name__ == "__main__":
    unittest.main()
