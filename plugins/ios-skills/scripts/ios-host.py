#!/usr/bin/env python3
"""Inspect the actual iOS executor, or run a bundled tool on an explicit Mac."""
import argparse
import base64
import json
import os
from pathlib import Path
import platform
import select
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def command(argv, timeout=15):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return {"ok": p.returncode == 0, "exit_code": p.returncode,
                "output": (p.stdout if p.returncode == 0 else p.stderr).strip()[:1600]}
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"ok": False, "error": str(exc)}


def mcp_tools():
    """A binary on disk is not proof that the IDE bridge can start."""
    errors = tempfile.TemporaryFile()
    p = subprocess.Popen(["xcrun", "mcpbridge"], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=errors)
    deadline = time.monotonic() + 15
    pending = b""

    def send(msg):
        p.stdin.write(json.dumps(msg).encode() + b"\n")
        p.stdin.flush()

    def receive(wanted):
        nonlocal pending
        while time.monotonic() < deadline:
            while b"\n" in pending:
                line, pending = pending.split(b"\n", 1)
                try:
                    msg = json.loads(line)
                except (ValueError, UnicodeError):
                    continue
                if msg.get("id") == wanted:
                    return msg
            if not select.select([p.stdout], [], [], max(0, deadline - time.monotonic()))[0]:
                break
            chunk = os.read(p.stdout.fileno(), 65536)
            if not chunk:
                break
            pending += chunk
        raise RuntimeError("MCP response timed out or bridge exited")

    try:
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-03-26", "capabilities": {},
            "clientInfo": {"name": "ios-skills-probe", "version": "1"}}})
        if "result" not in receive(1):
            raise RuntimeError("MCP initialization rejected")
        send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        result = receive(2)
        if "result" not in result:
            raise RuntimeError("MCP tools/list rejected")
        return {"ok": True, "tools": [t["name"] for t in result["result"].get("tools", [])]}
    except (OSError, RuntimeError) as exc:
        return {"ok": False, "error": str(exc)}
    finally:
        p.terminate()
        try:
            p.wait(timeout=2)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
        errors.seek(0)
        diagnostic = errors.read(1600).decode(errors="replace").strip()
        if diagnostic:
            print(diagnostic, file=sys.stderr)
        p.stdin.close()
        p.stdout.close()
        errors.close()


def probe(check_mcp=False):
    mac = platform.system() == "Darwin"
    data = {"hostname": platform.node(), "system": platform.system(),
            "architecture": platform.machine(), "native_ios": mac,
            "executables": {n: shutil.which(n) for n in
                            ("xcrun", "xcodebuild", "python3", "node", "npx", "idb", "idb_companion", "asc")},
            "mcp": {"checked": check_mcp, "ok": False}}
    if mac and shutil.which("xcrun"):
        data["xcode"] = command(["xcodebuild", "-version"])
        data["tools"] = {n: command(["xcrun", "--find", n]) for n in
                         ("simctl", "devicectl", "mcpbridge", "agent", "xcodeproj", "ictool")}
        data["simulator_runtimes"] = command(["xcrun", "simctl", "list", "runtimes", "-j"])
        if check_mcp and data["tools"]["mcpbridge"]["ok"]:
            data["mcp"].update(mcp_tools())
    data["next"] = ("Select tools actually exposed to the agent; CLI availability alone does not expose MCP tools."
                    if mac else "Select an explicit Mac executor with --host; Linux cannot run Xcode or Simulator.")
    print(json.dumps(data, ensure_ascii=False))


# SSH receives only these tool files and arguments, never the caller's environment.
BOOTSTRAP = r'''
import base64,json,os,pathlib,subprocess,sys,tempfile
p=json.load(sys.stdin)
with tempfile.TemporaryDirectory(prefix="ios-skills-") as tmp:
    root=pathlib.Path(tmp)
    for name,body in p["files"].items():
        path=root/name
        if pathlib.PurePosixPath(name).is_absolute() or ".." in pathlib.PurePosixPath(name).parts:
            raise SystemExit("invalid bundled path")
        path.parent.mkdir(parents=True,exist_ok=True)
        path.write_bytes(base64.b64decode(body))
        path.chmod(0o700)
    if p.get("script"):
        script=root/p["script"]
        interpreter={".py":"python3",".sh":"/bin/bash",".swift":"swift"}[script.suffix]
        argv=[interpreter,str(script)]+p["args"]
    else:
        argv=p["argv"]
    options={"input":base64.b64decode(p["stdin"])} if p.get("stdin") is not None else {"stdin":subprocess.DEVNULL}
    result=subprocess.run(argv,cwd=p["cwd"],stdout=subprocess.PIPE,**options)
    code=result.returncode if result.returncode>=0 else 128-result.returncode
    print(json.dumps({"ios_execution":1,"exit_code":code,
                      "stdout":base64.b64encode(result.stdout).decode()}))
'''


def remote_result(result):
    # macOS Tailscale SSH can report transport success after a failing command.
    # Trust only the child process result emitted by our fixed bootstrap.
    if result.returncode:
        return result.returncode
    try:
        response = json.loads(result.stdout)
        code = response["exit_code"]
        if response["ios_execution"] != 1 or type(code) is not int or not 0 <= code <= 255:
            raise ValueError("invalid executor status")
        output = base64.b64decode(response["stdout"], validate=True)
    except (ValueError, KeyError, TypeError) as exc:
        raise ValueError("remote executor did not return a valid completion result") from exc
    sys.stdout.buffer.write(output)
    sys.stdout.buffer.flush()
    return code


def execute(host, cwd, script, args, stdin_data=None):
    relative = Path(script)
    if relative.is_absolute() or ".." in relative.parts or not (ROOT / relative).is_file():
        raise ValueError("script must name a bundled tool relative to ios-skills")
    if relative.suffix not in (".py", ".sh", ".swift") or "scripts" not in relative.parts:
        raise ValueError("only bundled scripts can be executed")
    if cwd and not Path(cwd).is_absolute():
        raise ValueError("--cwd must be an absolute path on the executor")
    if not host:
        interpreter = {".py": sys.executable, ".sh": "/bin/bash", ".swift": "swift"}[relative.suffix]
        options = {"input": stdin_data} if stdin_data is not None else {"stdin": subprocess.DEVNULL}
        return subprocess.run([interpreter, str(ROOT / relative)] + args, cwd=cwd, **options).returncode
    files = {}
    for directory in ("scripts", "lib", "skills"):
        for path in (ROOT / directory).rglob("*"):
            if path.is_symlink():
                raise ValueError("symlinks are not transferred")
            if path.is_file() and "__pycache__" not in path.parts:
                files[path.relative_to(ROOT).as_posix()] = base64.b64encode(path.read_bytes()).decode()
    payload = {"files": files, "script": relative.as_posix(), "args": args, "cwd": cwd,
               "stdin": base64.b64encode(stdin_data).decode() if stdin_data is not None else None}
    return send_remote(host, payload)


def send_remote(host, payload):
    if host.startswith("-") or any(c.isspace() for c in host) or "\x00" in host:
        raise ValueError("--host must be one SSH destination, not options or a command")
    result = subprocess.run(["ssh", "-T", "-oBatchMode=yes", "-oConnectTimeout=10", "--", host,
                             shlex.join(["python3", "-c", BOOTSTRAP])],
                            input=json.dumps(payload).encode(), stdout=subprocess.PIPE)
    return remote_result(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    p = sub.add_parser("probe", help="read-only executor capabilities; no install, build, or GUI launch")
    p.add_argument("--host", help="explicit SSH destination; no implicit fallback")
    p.add_argument("--mcp", action="store_true", help="initialize bridge and list tools (bounded, requires IDE service)")
    r = sub.add_parser("run", help="run bundled scripts; paths and outputs belong to the selected executor")
    r.add_argument("--host")
    r.add_argument("--cwd", help="absolute working directory on the executor")
    r.add_argument("--stdin-file", help="explicit input file, or - for stdin; default is no input")
    r.add_argument("command", nargs=argparse.REMAINDER, help="-- skills/<skill>/scripts/<tool> [arguments]")
    e = sub.add_parser("exec", help="run explicit argv on the executor; no shell or environment forwarding")
    e.add_argument("--host")
    e.add_argument("--cwd", help="absolute working directory on the executor")
    e.add_argument("--stdin-file", help="explicit input file, or - for stdin; default is no input")
    e.add_argument("command", nargs=argparse.REMAINDER, help="-- executable [arguments]")
    args = parser.parse_args()
    try:
        if args.action == "probe":
            if args.host:
                return execute(args.host, None, "scripts/ios-host.py", ["probe"] + (["--mcp"] if args.mcp else []))
            probe(args.mcp)
            return 0
        argv = args.command[1:] if args.command[:1] == ["--"] else args.command
        if not argv:
            parser.error("an executable or bundled script is required after --")
        stdin_data = (sys.stdin.buffer.read() if args.stdin_file == "-" else
                      Path(args.stdin_file).read_bytes()) if args.stdin_file else None
        if args.action == "exec":
            if args.cwd and not Path(args.cwd).is_absolute():
                raise ValueError("--cwd must be an absolute path on the executor")
            if not args.host:
                options = {"input": stdin_data} if stdin_data is not None else {"stdin": subprocess.DEVNULL}
                return subprocess.run(argv, cwd=args.cwd, **options).returncode
            return send_remote(args.host, {"files": {}, "argv": argv, "cwd": args.cwd,
                               "stdin": base64.b64encode(stdin_data).decode() if stdin_data is not None else None})
        return execute(args.host, args.cwd, argv[0], argv[1:], stdin_data)
    except (OSError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    code = main()
    sys.exit(code if code >= 0 else 128 - code)
