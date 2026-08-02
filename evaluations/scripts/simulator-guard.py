#!/usr/bin/env python3
"""`live` case の前後で Simulator の状態を突き合わせ、後始末と違反検出を行う。

**Why 必要か**: runner には後始末が一切無い(2026-08-02 時点)。
前の run が残した端末が次の run の近道になる —— 実際に起きた事故として、
`METHODOLOGY.md` §11 に「baseline が既存の種端末を見つけて `simctl clone` し、
知識が要るはずの eval を同等の時間で完了した」がある。**環境が答えを持つと差が出ない。**

**Why 全削除にしないか**: この機械には実作業用の端末が同居している
(`CalDAV-Golden` / `CalDAV-Seed-webcal` / `DEMO-MCPHost` など、実測で23台)。
一括削除は他人の作業を壊す。**「run が作ったものだけ」を消す**のが唯一安全な後始末。

分類:

| 状況 | 扱い |
|---|---|
| run 前から在った端末 | **触らない** |
| run 中に増えた + 名前が eval prefix | **削除する**(後始末) |
| run 中に増えた + prefix 以外の名前 | ⚠ **報告のみ。削除しない** —— 人が見て判断する |
| run 前から在った端末が**消えた** | 🔴 **違反**。取り返せないので大きく鳴らす |
| run 前から在った端末の**状態が変わった** | 🔴 **違反**(boot/shutdown/erase された) |

prefix 以外を自動削除しないのは、**被験エージェントが勝手な名前で作った端末**と
**人間が同時刻に手で作った端末**を、このスクリプトからは区別できないため。
消してよいと確信できないものは消さない。

使い方:
    python3 simulator-guard.py snapshot --out before.json
    # ... live run ...
    python3 simulator-guard.py reconcile --snapshot before.json --prefix EVAL- [--apply]

`--apply` を付けない限り**何も削除しない**(既定は dry-run)。
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

EXIT_VIOLATION = 5


class GuardError(RuntimeError):
    pass


def list_devices(runner=subprocess.run) -> dict[str, dict[str, str]]:
    """UDID -> {name, state} を返す。availability に関わらず全件見る。

    Why available だけに絞らないか: run 中に壊れて unavailable になった端末を
    「消えた」と誤検出しないため。
    """
    result = runner(
        ["xcrun", "simctl", "list", "devices", "--json"],
        capture_output=True, text=True, check=False, timeout=60,
    )
    if result.returncode != 0:
        raise GuardError(f"simctl list failed: {result.stderr.strip()[:200]}")
    payload = json.loads(result.stdout)
    devices: dict[str, dict[str, str]] = {}
    for entries in payload.get("devices", {}).values():
        for entry in entries:
            devices[entry["udid"]] = {"name": entry.get("name", ""), "state": entry.get("state", "")}
    return devices


def classify(before: dict[str, dict[str, str]], after: dict[str, dict[str, str]], prefix: str) -> dict[str, Any]:
    """スナップショットの差分を分類する。**副作用なし** —— テストしやすさのため分離。"""
    created = {udid: info for udid, info in after.items() if udid not in before}
    disposable = {u: i for u, i in created.items() if i["name"].startswith(prefix)}
    unexpected = {u: i for u, i in created.items() if not i["name"].startswith(prefix)}
    vanished = {udid: info for udid, info in before.items() if udid not in after}
    mutated = {
        udid: {"before": before[udid]["state"], "after": after[udid]["state"], "name": before[udid]["name"]}
        for udid in before.keys() & after.keys()
        if before[udid]["state"] != after[udid]["state"]
    }
    return {
        "disposable": disposable,      # 消してよい
        "unexpected": unexpected,      # 報告のみ
        "vanished": vanished,          # 違反
        "mutated": mutated,            # 違反
        "violations": len(vanished) + len(mutated),
    }


def delete(udids: list[str], runner=subprocess.run) -> list[str]:
    failed: list[str] = []
    for udid in udids:
        result = runner(["xcrun", "simctl", "delete", udid],
                        capture_output=True, text=True, check=False, timeout=120)
        if result.returncode != 0:
            failed.append(f"{udid}: {result.stderr.strip()[:120]}")
    return failed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    snap = sub.add_parser("snapshot", help="run の前に端末一覧を保存する")
    snap.add_argument("--out", required=True)

    rec = sub.add_parser("reconcile", help="run の後に突き合わせ、prefix 一致の新規だけ削除する")
    rec.add_argument("--snapshot", required=True)
    rec.add_argument("--prefix", default="EVAL-", help="この接頭辞の新規端末だけを削除対象にする")
    rec.add_argument("--apply", action="store_true", help="実際に削除する。付けなければ dry-run")

    args = parser.parse_args()
    try:
        if args.command == "snapshot":
            devices = list_devices()
            Path(args.out).write_text(json.dumps(devices, ensure_ascii=False, indent=2) + "\n")
            print(json.dumps({"status": "ok", "devices": len(devices), "path": args.out}, ensure_ascii=False))
            return 0

        before = json.loads(Path(args.snapshot).read_text())
        report = classify(before, list_devices(), args.prefix)
        report["applied"] = False
        if args.apply and report["disposable"]:
            failures = delete(list(report["disposable"]), )
            report["applied"] = True
            report["delete_failures"] = failures
        report["status"] = "violation" if report["violations"] else "ok"
        print(json.dumps(report, ensure_ascii=False, indent=2))
        # 違反があれば非ゼロ。**後続の run を止めるのはバッチ側の判断**だが、
        # 気づかず走り続けるのが最悪なので exit code で鳴らす。
        return EXIT_VIOLATION if report["violations"] else 0
    except (GuardError, OSError, json.JSONDecodeError, subprocess.SubprocessError) as error:
        print(json.dumps({"status": "error", "message": str(error)}, ensure_ascii=False))
        return 2


if __name__ == "__main__":
    sys.exit(main())
