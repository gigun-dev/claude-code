#!/usr/bin/env python3
"""Run blinded, isolated Claude/Codex skill and plugin evaluation cases."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import sys
import time
from typing import Any


EXIT_ARGUMENT = 2
EXIT_CLI = 3
EXIT_TIMEOUT = 4
EXIT_PROVIDER = 5
EXIT_ARTIFACT = 6
LIVE_CONFIRMATION = "I_UNDERSTAND_LIVE_EVAL"
EXPECTED_VERSIONS = {"claude": "2.1.220", "codex": "0.145.0"}
CONDITIONS = {"ios-skills-old", "ios-skills-new", "build-ios-apps", "none"}
SECRET_NAME = re.compile(r"(^\.env($|\.)|credential|secret|auth\.json$|token)", re.IGNORECASE)
EMPTY_MCP_CONFIG = json.dumps({"mcpServers": {}}, separators=(",", ":"))
CLAUDE_AUTH_FAILURE_PREFIXES = ("Not logged in", "Invalid API key")


class EvalError(Exception):
    def __init__(self, message: str, exit_code: int = EXIT_ARGUMENT) -> None:
        super().__init__(message)
        self.exit_code = exit_code


def diagnostic(message: str) -> None:
    print(message, file=sys.stderr)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run reproducible Claude or Codex component evaluations in fresh workspaces.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--provider", required=True, choices=("claude", "codex"))
    parser.add_argument("--suite", required=True, help="Absolute or cwd-relative suite JSON path")
    parser.add_argument("--case", action="append", dest="cases", required=True, help="Case ID; repeat to select multiple")
    parser.add_argument("--condition", action="append", required=True, choices=sorted(CONDITIONS))
    parser.add_argument(
        "--skill-path",
        action="append",
        default=[],
        metavar="CONDITION=ABSOLUTE_PATH",
        help="Codex candidate skill, skills directory, or plugin root; repeat per condition",
    )
    parser.add_argument(
        "--plugin-path",
        action="append",
        default=[],
        metavar="CONDITION=ABSOLUTE_PATH",
        help="Claude plugin root; repeat per condition",
    )
    parser.add_argument("--model", required=True, help="Pinned full model ID")
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--timeout", type=int, default=600, help="Per-run timeout in seconds")
    parser.add_argument("--output-dir", required=True, help="Directory for raw run artifacts")
    parser.add_argument("--seed", type=int, help="Randomization seed; generated and recorded when omitted")
    parser.add_argument("--expected-cli-version", help="Exact version substring required before running")
    parser.add_argument("--allow-live", action="store_true", help="Allow live/write cases")
    parser.add_argument("--confirm-live", help=f"Must equal {LIVE_CONFIRMATION} for live/write cases")
    parser.add_argument("--dry-run", action="store_true", help="Write plans without invoking an agent")
    return parser.parse_args()


def load_json(path: Path) -> Any:
    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise EvalError(f"cannot read JSON {path}: {error}") from error


def validate_suite(data: Any, path: Path) -> dict[str, Any]:
    if not isinstance(data, dict) or data.get("schema_version") != 1:
        raise EvalError(f"{path}: unsupported or missing schema_version")
    if not isinstance(data.get("id"), str) or not isinstance(data.get("cases"), list):
        raise EvalError(f"{path}: id and cases are required")
    seen: set[str] = set()
    required = {"id", "kind", "layer", "mode", "prompt", "conditions", "rubric", "safety_assertions"}
    for case in data["cases"]:
        if not isinstance(case, dict) or not required.issubset(case):
            raise EvalError(f"{path}: every case must contain {sorted(required)}")
        case_id = case["id"]
        if not isinstance(case_id, str) or case_id in seen:
            raise EvalError(f"{path}: duplicate or invalid case id {case_id!r}")
        seen.add(case_id)
        if case["kind"] not in {"skill", "plugin", "mcp"}:
            raise EvalError(f"{path}: invalid kind in {case_id}")
        if case["mode"] not in {"read-only", "live", "write"}:
            raise EvalError(f"{path}: invalid mode in {case_id}")
        if not set(case["conditions"]).issubset(CONDITIONS):
            raise EvalError(f"{path}: invalid condition in {case_id}")
    return data


def parse_path_map(values: list[str], flag: str) -> dict[str, Path]:
    result: dict[str, Path] = {}
    for value in values:
        if "=" not in value:
            raise EvalError(f"{flag} must use CONDITION=ABSOLUTE_PATH: {value!r}")
        condition, raw_path = value.split("=", 1)
        if condition not in CONDITIONS or condition == "none":
            raise EvalError(f"{flag}: invalid mapped condition {condition!r}")
        if condition in result:
            raise EvalError(f"{flag}: duplicate mapping for {condition}")
        path = Path(raw_path).expanduser()
        if not path.is_absolute():
            raise EvalError(f"{flag}: path must be absolute for {condition}")
        path = path.resolve(strict=True)
        if not path.is_dir() and path.name != "SKILL.md":
            raise EvalError(f"{flag}: expected a directory or SKILL.md: {path}")
        result[condition] = path
    return result


def reject_unsafe_tree(path: Path) -> None:
    roots = [path] if path.is_file() else [path, *path.rglob("*")]
    for item in roots:
        if item.is_symlink():
            raise EvalError(f"candidate/fixture may not contain symlinks: {item}")
        if SECRET_NAME.search(item.name):
            raise EvalError(f"candidate/fixture appears to contain a secret-bearing file: {item}")


def copy_candidate(source: Path, destination: Path) -> Path:
    reject_unsafe_tree(source)
    source_root = source.parent if source.is_file() else source
    shutil.copytree(source_root, destination)
    return destination


def discover_skill_roots(candidate: Path) -> list[Path]:
    if (candidate / "SKILL.md").is_file():
        return [candidate]
    roots = sorted({item.parent for item in candidate.rglob("SKILL.md")})
    if not roots:
        raise EvalError(f"no SKILL.md found under {candidate}")
    return roots


def validate_claude_plugin(candidate: Path) -> None:
    if not ((candidate / ".claude-plugin" / "plugin.json").is_file() or (candidate / "plugin.json").is_file()):
        raise EvalError(f"Claude candidate is not an unambiguous plugin root: {candidate}")


def claude_plugin_commands(candidate: Path) -> set[str]:
    """Return plugin-qualified skill commands expected in Claude's init event."""
    validate_claude_plugin(candidate)
    manifest_path = candidate / ".claude-plugin" / "plugin.json"
    if not manifest_path.is_file():
        manifest_path = candidate / "plugin.json"
    manifest = load_json(manifest_path)
    plugin_name = manifest.get("name") if isinstance(manifest, dict) else None
    if not isinstance(plugin_name, str) or not plugin_name:
        raise EvalError(f"Claude plugin manifest has no valid name: {manifest_path}")
    skills_dir = candidate / "skills"
    commands = {
        f"{plugin_name}:{skill_file.parent.name}"
        for skill_file in skills_dir.glob("*/SKILL.md")
        if skill_file.is_file()
    }
    if not commands:
        raise EvalError(f"Claude plugin exposes no skills under {skills_dir}")
    return commands


def toml_skill_config(skill_roots: list[Path]) -> str:
    entries = ",".join(
        "{path=" + json.dumps(str(path)) + ",enabled=true}" for path in skill_roots
    )
    return f"skills.config=[{entries}]"


def clean_environment(provider: str, tmpdir: Path) -> dict[str, str]:
    # USER は必須。macOS の Keychain エントリ(service "Claude Code-credentials")は
    # acct = ユーザー名で引かれるため、USER が無いと subscription 認証が解決できず
    # 全 run が "Not logged in · Please run /login" になる(2026-08-02 実測)。
    # Why not LOGNAME: 実測で LOGNAME だけでは解決しない。USER でなければならない。
    # 検算: env -i PATH=... HOME=... claude -p → Not logged in / + USER → 通常応答。
    allowed = ["PATH", "HOME", "USER", "LANG", "LC_ALL", "SSL_CERT_FILE"]
    if provider == "codex":
        allowed.append("CODEX_HOME")
    environment = {name: os.environ[name] for name in allowed if name in os.environ}
    environment["TMPDIR"] = str(tmpdir)
    return environment


def candidate_mcp_config(candidate: Path | None) -> str:
    """候補が manifest で宣言した MCP だけを、そのアームに与える。

    Why 全アーム一律に空 MCP にしないか(CLAUDE-RUNTIME-CONSTRAINTS.md §6-c):
    `ios-skills` は `xcrun simctl` + `idb` の CLI 専業なので空 MCP でも無傷だが、
    `build-ios-apps` の `ios-debugger-agent` は本文の全手順が
    `mcp__XcodeBuildMCP__*` の呼び出しで、**MCP を切ると1行目から実行不能**になる。
    一律に切ると `ios-skills` が構造的に勝つ —— 測定ではなく設計の産物になる。

    Why not ホストの MCP 設定をそのまま使うか: 環境の 15 サーバーがロードされ、
    起動だけで 2 分を超えて 1 run も完走しない(§5 実測)。
    **候補が自分で宣言した依存だけ**を与えるのが、公平さと実行可能性の両立点。
    """
    if candidate is None:
        return EMPTY_MCP_CONFIG            # none アーム: 何も与えない
    manifest = candidate / ".claude-plugin" / "plugin.json"
    if not manifest.is_file():
        return EMPTY_MCP_CONFIG
    declared = load_json(manifest).get("mcpServers")
    if not declared:
        return EMPTY_MCP_CONFIG            # ios-skills はここ(宣言なし = CLI 専業)
    if isinstance(declared, str):          # "./.mcp.json" のようなファイル参照
        referenced = (candidate / declared).resolve()
        if not referenced.is_file():
            raise EvalError(f"plugin declares mcpServers {declared!r} but {referenced} is missing")
        declared = load_json(referenced).get("mcpServers", {})
    return json.dumps({"mcpServers": declared}, separators=(",", ":"))


def claude_json_schema(path: Path) -> dict[str, Any]:
    """`--json-schema` へ渡す形へ整える。

    Claude CLI の validator は `$schema` の meta-schema ref を解決できず、
    draft 2020-12 を宣言したスキーマをそのまま渡すと起動前に落ちる(2026-08-02 実測):

        Error: --json-schema is not a valid JSON Schema:
               no schema with key or ref "https://json-schema.org/draft/2020-12/schema"

    Why not スキーマ側から `$schema` を消すか: 同じファイルを Codex の `--output-schema` と
    リポジトリ内の検証にも使っており、そちらでは meta-schema 宣言があった方がよい。
    **provider 固有の都合は adapter 側で吸収する**(evaluations/README.md の方針)。
    """
    schema = load_json(path)
    schema.pop("$schema", None)
    return schema


def cli_version(provider: str, expected: str) -> str:
    binary = provider
    if shutil.which(binary) is None:
        raise EvalError(f"{binary} is not installed", EXIT_CLI)
    try:
        result = subprocess.run(
            [binary, "--version"],
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise EvalError(f"cannot determine {binary} version: {error}", EXIT_CLI) from error
    version = (result.stdout or result.stderr).strip()
    if result.returncode != 0 or expected not in version:
        raise EvalError(f"expected {binary} {expected}, got {version!r}", EXIT_CLI)
    return version


def candidate_prompt(case: dict[str, Any], fixture: Path | None) -> str:
    fixture_note = f"\nFixture is available at: {fixture}" if fixture is not None else ""
    return (
        f"Evaluation case ID: {case['id']}\n"
        "Solve only the following user task. Do not inspect evaluation suites, rubrics, expected answers, "
        "or sibling run directories. Do not claim that an action ran unless the transcript proves it. "
        "Return only an object matching the supplied JSON schema.\n\n"
        f"User task:\n{case['prompt']}{fixture_note}"
    )


def build_command(
    args: argparse.Namespace,
    case: dict[str, Any],
    workspace: Path,
    candidate: Path | None,
    fixture: Path | None,
    final_path: Path,
    response_schema: Path,
) -> list[str]:
    prompt = candidate_prompt(case, fixture)
    writable = case["mode"] != "read-only"
    if args.provider == "claude":
        command = [
            "claude", "-p", prompt,
            "--output-format", "stream-json", "--verbose", "--no-session-persistence",
            "--strict-mcp-config", "--mcp-config", candidate_mcp_config(candidate),
            "--model", args.model,
            "--json-schema", json.dumps(claude_json_schema(response_schema), separators=(",", ":")),
        ]
        if candidate is not None:
            validate_claude_plugin(candidate)
            command.extend(["--plugin-dir", str(candidate)])
        if writable:
            command.extend(["--permission-mode", "acceptEdits", "--tools", "default"])
        else:
            command.extend(["--permission-mode", "dontAsk", "--tools", "Read,Glob,Grep"])
        return command

    sandbox = "workspace-write" if writable else "read-only"
    command = [
        "codex", "exec", "--ephemeral", "--ignore-user-config", "--sandbox", sandbox,
        "--json", "--output-schema", str(response_schema), "--output-last-message", str(final_path),
        "--model", args.model, "--cd", str(workspace),
    ]
    skill_roots = discover_skill_roots(candidate) if candidate is not None else []
    command.extend(["-c", toml_skill_config(skill_roots), prompt])
    return command


def build_claude_preflight_command(args: argparse.Namespace) -> list[str]:
    """Build an unscored subscription-auth and plugin-leak preflight."""
    return [
        "claude", "-p", "Reply with OK only.",
        "--output-format", "stream-json", "--verbose", "--no-session-persistence",
        "--strict-mcp-config", "--mcp-config", EMPTY_MCP_CONFIG,
        "--model", args.model,
        "--permission-mode", "dontAsk", "--tools", "", "--max-turns", "1",
    ]


def extract_claude_final(stdout: str, final_path: Path) -> None:
    final: Any = None
    for line in stdout.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(event, dict) and event.get("type") == "result":
            final = event.get("structured_output", event.get("result"))
    if final is None:
        final_path.write_text("", encoding="utf-8")
    elif isinstance(final, (dict, list)):
        final_path.write_text(json.dumps(final, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    else:
        final_path.write_text(str(final), encoding="utf-8")


def assert_condition_took_effect(
    stdout: str,
    expect_present: set[str],
    expect_absent: set[str],
) -> str | None:
    """Verify that Claude exposed exactly the target skills needed by this condition."""
    for line in stdout.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue
        if event.get("type") == "system" and event.get("subtype") == "init":
            commands = set(event.get("slash_commands") or [])
            missing = expect_present - commands
            leaked = expect_absent & commands
            if missing or leaked:
                return (
                    "condition did not take effect: "
                    f"missing={sorted(missing)} leaked={sorted(leaked)}"
                )
            return None
    return "no init event found; cannot verify condition"


def claude_auth_error(stdout: str) -> str | None:
    """Surface subscription/authentication failures that Claude reports with exit code zero."""
    for line in stdout.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict) or event.get("type") != "result":
            continue
        result = event.get("result")
        if isinstance(result, str) and result.startswith(CLAUDE_AUTH_FAILURE_PREFIXES):
            return result
    return None


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def run_claude_preflight(
    args: argparse.Namespace,
    batch_dir: Path,
    expect_absent: set[str],
) -> None:
    """Fail the batch before scoring if subscription auth or plugin isolation is invalid."""
    preflight_dir = batch_dir / "claude-preflight"
    workspace = preflight_dir / "workspace"
    tmpdir = preflight_dir / "tmp"
    workspace.mkdir(parents=True)
    tmpdir.mkdir()
    stdout_path = preflight_dir / "stdout.jsonl"
    stderr_path = preflight_dir / "stderr.log"
    command = build_claude_preflight_command(args)
    metadata: dict[str, Any] = {
        "provider": "claude",
        "model": args.model,
        "expected_absent": sorted(expect_absent),
        "dry_run": args.dry_run,
        "command": command,
    }
    if args.dry_run:
        stdout_path.write_text("", encoding="utf-8")
        stderr_path.write_text("", encoding="utf-8")
        metadata["status"] = "planned"
        write_json(preflight_dir / "metadata.json", metadata)
        return

    started = time.monotonic()
    try:
        completed = subprocess.run(
            command,
            cwd=workspace,
            env=clean_environment("claude", tmpdir),
            capture_output=True,
            text=True,
            timeout=args.timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout if isinstance(error.stdout, str) else ""
        stderr = error.stderr if isinstance(error.stderr, str) else ""
        stdout_path.write_text(stdout, encoding="utf-8")
        stderr_path.write_text(stderr, encoding="utf-8")
        metadata.update({"status": "timeout", "duration_seconds": time.monotonic() - started})
        write_json(preflight_dir / "metadata.json", metadata)
        raise EvalError(f"Claude preflight timed out; inspect {preflight_dir}", EXIT_TIMEOUT)

    stdout_path.write_text(completed.stdout, encoding="utf-8")
    stderr_path.write_text(completed.stderr, encoding="utf-8")
    auth_error = claude_auth_error(completed.stdout)
    condition_error = assert_condition_took_effect(completed.stdout, set(), expect_absent)
    if auth_error is not None:
        status = "provider-error"
        failure = f"Claude preflight authentication failed: {auth_error}"
    elif completed.returncode != 0:
        status = "provider-error"
        failure = f"Claude preflight exited {completed.returncode}"
    elif condition_error is not None:
        status = "condition-error"
        failure = (
            f"Claude preflight plugin isolation failed: {condition_error}. "
            "Disable the installed comparison plugin before starting the batch."
        )
    else:
        status = "completed"
        failure = None
    metadata.update({
        "status": status,
        "duration_seconds": time.monotonic() - started,
        "provider_exit_code": completed.returncode,
        "auth_error": auth_error,
        "condition_error": condition_error,
    })
    write_json(preflight_dir / "metadata.json", metadata)
    if failure is not None:
        raise EvalError(f"{failure} Inspect {preflight_dir}", EXIT_PROVIDER)


def validate_final(path: Path, case_id: str) -> str | None:
    try:
        value = load_json(path)
    except EvalError as error:
        return str(error)
    required = {"case_id", "selected_capability", "approach", "commands", "safety_checks"}
    if not isinstance(value, dict) or not required.issubset(value):
        return f"final response does not contain required fields: {sorted(required)}"
    if value["case_id"] != case_id:
        return f"final response case_id {value['case_id']!r} does not match {case_id!r}"
    return None


def main() -> int:
    args = parse_args()
    try:
        suite_path = Path(args.suite).expanduser().resolve(strict=True)
        suite = validate_suite(load_json(suite_path), suite_path)
        output_dir = Path(args.output_dir).expanduser().resolve()
        output_dir.mkdir(parents=True, exist_ok=True)
        if not output_dir.is_dir():
            raise EvalError(f"output-dir is not a directory: {output_dir}")
        if args.repetitions < 1:
            raise EvalError("repetitions must be at least 1")
        minimum_repetitions = suite.get("preregistration", {}).get("minimum_repetitions", 1)
        if args.repetitions < minimum_repetitions:
            raise EvalError(
                f"suite preregisters at least {minimum_repetitions} repetitions; got {args.repetitions}"
            )
        if args.timeout < 1:
            raise EvalError("timeout must be at least 1 second")

        case_by_id = {case["id"]: case for case in suite["cases"]}
        selected_cases = args.cases
        unknown = sorted(set(selected_cases) - set(case_by_id))
        if unknown:
            raise EvalError(f"unknown case IDs: {', '.join(unknown)}")
        if len(selected_cases) != len(set(selected_cases)):
            raise EvalError("duplicate --case values are not allowed")
        conditions = list(dict.fromkeys(args.condition))
        if len(conditions) != len(args.condition):
            raise EvalError("duplicate --condition values are not allowed")

        selected: list[tuple[dict[str, Any], str]] = []
        for case_id in selected_cases:
            case = case_by_id[case_id]
            for condition in conditions:
                if condition not in case["conditions"]:
                    raise EvalError(f"case {case_id} does not allow condition {condition}")
                if case["mode"] != "read-only" and not (
                    args.allow_live and args.confirm_live == LIVE_CONFIRMATION
                ):
                    raise EvalError(
                        f"case {case_id} is {case['mode']}; require --allow-live "
                        f"--confirm-live {LIVE_CONFIRMATION}"
                    )
                for _ in range(args.repetitions):
                    selected.append((case, condition))

        path_map = parse_path_map(
            args.plugin_path if args.provider == "claude" else args.skill_path,
            "--plugin-path" if args.provider == "claude" else "--skill-path",
        )
        unused_other = args.skill_path if args.provider == "claude" else args.plugin_path
        if unused_other:
            raise EvalError(f"{args.provider} does not use {'--skill-path' if args.provider == 'claude' else '--plugin-path'}")
        needed = set(conditions) - {"none"}
        missing = sorted(needed - set(path_map))
        extra = sorted(set(path_map) - needed)
        if missing or extra:
            raise EvalError(f"candidate path mapping mismatch; missing={missing}, extra={extra}")
        if {"ios-skills-old", "ios-skills-new"}.issubset(path_map):
            if path_map["ios-skills-old"] == path_map["ios-skills-new"]:
                raise EvalError("old and new conditions must use different candidate paths")

        claude_commands_by_condition: dict[str, set[str]] = {}
        if args.provider == "claude":
            claude_commands_by_condition = {
                condition: claude_plugin_commands(path)
                for condition, path in path_map.items()
            }
        all_claude_candidate_commands = set().union(
            *claude_commands_by_condition.values()
        ) if claude_commands_by_condition else set()

        expected_version = args.expected_cli_version or EXPECTED_VERSIONS[args.provider]
        version = cli_version(args.provider, expected_version)
        seed = args.seed if args.seed is not None else random.SystemRandom().randrange(2**63)
        random.Random(seed).shuffle(selected)
        jobs = [
            {
                "case": case,
                "condition": condition,
                "blinded_run_id": f"run-{ordinal:03d}-{os.urandom(4).hex()}",
            }
            for ordinal, (case, condition) in enumerate(selected, 1)
        ]
        response_schema = (Path(__file__).resolve().parent.parent / "schemas" / "agent-response.schema.json").resolve(strict=True)
        batch_id = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + os.urandom(4).hex()
        batch_dir = output_dir / batch_id
        batch_dir.mkdir()
        write_json(batch_dir / "schedule.json", {
            "suite": suite["id"], "provider": args.provider, "model": args.model,
            "cli_version": version, "seed": seed,
            "jobs": [{"ordinal": index + 1, "case": job["case"]["id"],
                      "blinded_run_id": job["blinded_run_id"]}
                     for index, job in enumerate(jobs)],
        })
        sealed_map: dict[str, Any] = {
            "sealed": True,
            "warning": "analyst-only; never include in grader or HITL bundles",
            "runs": {
                job["blinded_run_id"]: {"condition": job["condition"]}
                for job in jobs
            },
        }
        write_json(batch_dir / "condition-map.json", sealed_map)
        if args.provider == "claude":
            run_claude_preflight(args, batch_dir, all_claude_candidate_commands)

        summaries: list[dict[str, Any]] = []
        overall_exit = 0
        for job in jobs:
            case = job["case"]
            condition = job["condition"]
            blinded_id = job["blinded_run_id"]
            run_dir = batch_dir / blinded_id
            workspace = run_dir / "workspace"
            tmpdir = run_dir / "tmp"
            run_dir.mkdir()
            workspace.mkdir()
            tmpdir.mkdir()
            candidate: Path | None = None
            if condition != "none":
                candidate = copy_candidate(path_map[condition], workspace / "candidate")
            fixture: Path | None = None
            if "fixture" in case:
                fixture_source = (suite_path.parent / case["fixture"]).resolve(strict=True)
                evaluations_root = Path(__file__).resolve().parent.parent
                if not fixture_source.is_relative_to(evaluations_root):
                    raise EvalError(f"fixture escapes evaluations root: {fixture_source}")
                fixture = copy_candidate(fixture_source, workspace / "fixture")
            final_path = run_dir / "final.json"
            command = build_command(args, case, workspace, candidate, fixture, final_path, response_schema)
            sealed_record = sealed_map["runs"][blinded_id]
            sealed_record.update({
                "kind": case["kind"],
                "layer": case["layer"],
                "mode": case["mode"],
                "cli_version": version,
                "command": command,
                "cwd": str(workspace),
                "seed": seed,
                "dry_run": args.dry_run,
            })
            write_json(batch_dir / "condition-map.json", sealed_map)
            metadata = {
                "blinded_run_id": blinded_id,
                "case": case["id"],
                "provider": args.provider,
                "model": args.model,
            }
            write_json(run_dir / "metadata.json", metadata)
            if args.dry_run:
                (run_dir / "stdout.jsonl").write_text("", encoding="utf-8")
                (run_dir / "stderr.log").write_text("", encoding="utf-8")
                final_path.write_text("", encoding="utf-8")
                sealed_record["status"] = "planned"
                write_json(batch_dir / "condition-map.json", sealed_map)
                summaries.append({"run_id": blinded_id, "status": "planned", "path": str(run_dir)})
                continue

            started = time.monotonic()
            try:
                completed = subprocess.run(
                    command,
                    cwd=workspace,
                    env=clean_environment(args.provider, tmpdir),
                    capture_output=True,
                    text=True,
                    timeout=args.timeout,
                    check=False,
                )
            except subprocess.TimeoutExpired as error:
                stdout = error.stdout if isinstance(error.stdout, str) else ""
                stderr = error.stderr if isinstance(error.stderr, str) else ""
                (run_dir / "stdout.jsonl").write_text(stdout, encoding="utf-8")
                (run_dir / "stderr.log").write_text(stderr, encoding="utf-8")
                sealed_record.update({"duration_seconds": time.monotonic() - started, "status": "timeout"})
                write_json(batch_dir / "condition-map.json", sealed_map)
                summaries.append({"run_id": blinded_id, "status": "timeout", "path": str(run_dir)})
                overall_exit = max(overall_exit, EXIT_TIMEOUT)
                continue

            (run_dir / "stdout.jsonl").write_text(completed.stdout, encoding="utf-8")
            (run_dir / "stderr.log").write_text(completed.stderr, encoding="utf-8")
            if args.provider == "claude":
                extract_claude_final(completed.stdout, final_path)
            if not final_path.exists():
                final_path.write_text("", encoding="utf-8")
            auth_error: str | None = None
            condition_error: str | None = None
            if args.provider == "claude":
                auth_error = claude_auth_error(completed.stdout)
                expected_present = claude_commands_by_condition.get(condition, set())
                expected_absent = all_claude_candidate_commands - expected_present
                condition_error = assert_condition_took_effect(
                    completed.stdout,
                    expected_present,
                    expected_absent,
                )
            artifact_error = (
                validate_final(final_path, case["id"])
                if completed.returncode == 0
                and auth_error is None
                and condition_error is None
                else None
            )
            if auth_error is not None:
                status = "provider-error"
            elif completed.returncode != 0:
                status = "provider-error"
            elif condition_error is not None:
                status = "condition-error"
            elif artifact_error is not None:
                status = "artifact-error"
            else:
                status = "completed"
            sealed_record.update({
                "duration_seconds": time.monotonic() - started,
                "status": status,
                "provider_exit_code": completed.returncode,
                "auth_error": auth_error,
                "condition_error": condition_error,
                "artifact_error": artifact_error,
            })
            write_json(batch_dir / "condition-map.json", sealed_map)
            summaries.append({"run_id": blinded_id, "status": status, "path": str(run_dir)})
            if completed.returncode != 0 or auth_error is not None or condition_error is not None:
                overall_exit = max(overall_exit, EXIT_PROVIDER)
            elif artifact_error is not None:
                overall_exit = max(overall_exit, EXIT_ARTIFACT)
            if auth_error is not None or condition_error is not None:
                break

        print(json.dumps({
            "status": "planned" if args.dry_run else ("completed" if overall_exit == 0 else "completed-with-errors"),
            "batch_dir": str(batch_dir), "provider": args.provider, "cli_version": version,
            "model": args.model, "seed": seed, "runs": summaries,
        }, ensure_ascii=False, separators=(",", ":")))
        return overall_exit
    except EvalError as error:
        diagnostic(f"error: {error}")
        print(json.dumps({"status": "error", "exit_code": error.exit_code, "message": str(error)}, ensure_ascii=False, separators=(",", ":")))
        return error.exit_code
    except OSError as error:
        diagnostic(f"error: filesystem operation failed: {error}")
        print(json.dumps({
            "status": "error", "exit_code": EXIT_ARTIFACT,
            "message": f"filesystem operation failed: {error}",
        }, ensure_ascii=False, separators=(",", ":")))
        return EXIT_ARTIFACT


if __name__ == "__main__":
    raise SystemExit(main())
