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


def toml_skill_config(skill_roots: list[Path]) -> str:
    entries = ",".join(
        "{path=" + json.dumps(str(path)) + ",enabled=true}" for path in skill_roots
    )
    return f"skills.config=[{entries}]"


def clean_environment(provider: str, tmpdir: Path) -> dict[str, str]:
    allowed = ["PATH", "HOME", "LANG", "LC_ALL", "SSL_CERT_FILE"]
    if provider == "claude":
        allowed.extend(["ANTHROPIC_API_KEY", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX"])
    else:
        allowed.append("CODEX_HOME")
    environment = {name: os.environ[name] for name in allowed if name in os.environ}
    environment["TMPDIR"] = str(tmpdir)
    return environment


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
            "claude", "--bare", "-p", prompt,
            "--output-format", "stream-json", "--verbose", "--no-session-persistence",
            "--model", args.model,
            "--json-schema", json.dumps(load_json(response_schema), separators=(",", ":")),
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


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


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
            artifact_error = validate_final(final_path, case["id"]) if completed.returncode == 0 else None
            if completed.returncode != 0:
                status = "provider-error"
            elif artifact_error is not None:
                status = "artifact-error"
            else:
                status = "completed"
            sealed_record.update({
                "duration_seconds": time.monotonic() - started,
                "status": status,
                "provider_exit_code": completed.returncode,
                "artifact_error": artifact_error,
            })
            write_json(batch_dir / "condition-map.json", sealed_map)
            summaries.append({"run_id": blinded_id, "status": status, "path": str(run_dir)})
            if completed.returncode != 0:
                overall_exit = max(overall_exit, EXIT_PROVIDER)
            elif artifact_error is not None:
                overall_exit = max(overall_exit, EXIT_ARTIFACT)

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
