#!/usr/bin/env python3
"""採点者へ渡す blinded bundle を batch ディレクトリから組み立てる。

**Why スクリプトにするか**: `evaluations/README.md` は bundle に含めてよいものを
明記しているが、**手作業で組むと漏れる**。実測(2026-08-02)で確認した漏洩経路:

- `workspace/candidate/` に**候補プラグインが丸ごと入っている**。
  `skills/ios-simulator/SKILL.md` の行数だけで old(358行系)か new(114行)か判別できる。
  → **condition を完全に露出する。**
- `condition-map.json` は sealed な対応表そのもの。

逆に、以下は実測で**漏れていなかった**(runner が候補を中立名 `candidate/` へ
staging しているため):`stdout.jsonl` / `stderr.log` / `final.json` / `metadata.json`。
それでも本スクリプトは**コピー後に全文を走査して検算する** ——
runner 側の staging 方法が変われば静かに漏れ始めるため、
「漏れていないはず」を前提にしない。

使い方:
    python3 evaluations/scripts/make-grading-bundle.py --batch <batch-dir> --out <bundle-dir>
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
from pathlib import Path
from typing import Any

# run ディレクトリからコピーしてよいファイル。**allowlist であることが重要** ——
# denylist にすると、runner が新しい成果物を吐き始めたときに黙って混入する。
RUN_ALLOWLIST = (
    "stdout.jsonl", "stderr.log", "final.json", "metadata.json",
    # live/write のときだけ出る。**採点者が safety assertion を自己申告ではなく
    # 実状態で裏取りするための唯一の材料**なので必ず渡す。
    # condition 名が混ざる可能性は下の leak scan が捕まえる。
    "simulator-delta.json",
)
BATCH_ALLOWLIST = ("schedule.json",)
NEVER_COPY = ("condition-map.json", "workspace", "tmp")

EXIT_LEAK = 4


class BundleError(RuntimeError):
    pass


def condition_names(batch_dir: Path) -> set[str]:
    """このバッチに実在した condition 名を、sealed map から読む。

    Why sealed map を読むのか(渡さないのに): **検算する側は答えを知っている必要がある。**
    このスクリプトの出力に condition 名が混ざっていないことを確かめるのが仕事であって、
    出力に含めるわけではない。
    """
    sealed = json.loads((batch_dir / "condition-map.json").read_text())
    return {entry["condition"] for entry in sealed.get("runs", {}).values()}


def scan_for_leaks(bundle_dir: Path, needles: set[str]) -> list[str]:
    findings: list[str] = []
    patterns = {needle: re.compile(re.escape(needle)) for needle in needles if needle}
    for path in sorted(bundle_dir.rglob("*")):
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for needle, pattern in patterns.items():
            if pattern.search(text):
                findings.append(f"{path.relative_to(bundle_dir)}: contains condition name {needle!r}")
    return findings


def build(batch_dir: Path, out_dir: Path) -> dict[str, Any]:
    if not (batch_dir / "condition-map.json").is_file():
        raise BundleError(f"not a batch directory (no condition-map.json): {batch_dir}")
    if out_dir.exists() and any(out_dir.iterdir()):
        raise BundleError(f"output directory is not empty: {out_dir}")
    out_dir.mkdir(parents=True, exist_ok=True)

    for name in BATCH_ALLOWLIST:
        source = batch_dir / name
        if source.is_file():
            shutil.copy2(source, out_dir / name)

    copied_runs = 0
    skipped: list[str] = []
    for run_dir in sorted(p for p in batch_dir.iterdir() if p.is_dir() and p.name.startswith("run-")):
        target = out_dir / run_dir.name
        target.mkdir()
        for name in RUN_ALLOWLIST:
            source = run_dir / name
            if source.is_file():
                shutil.copy2(source, target / name)
            else:
                skipped.append(f"{run_dir.name}/{name}")
        copied_runs += 1

    # 検算1: 決して入れてはならないものが無いこと
    for forbidden in NEVER_COPY:
        hits = [str(p.relative_to(out_dir)) for p in out_dir.rglob(forbidden)]
        if hits:
            raise BundleError(f"forbidden entry leaked into bundle: {hits}")

    # 検算2: 中身に condition 名が現れないこと(staging 方法の変更で静かに漏れ始めるのを捕まえる)
    leaks = scan_for_leaks(out_dir, condition_names(batch_dir))
    if leaks:
        raise BundleError("condition leaked into bundle contents:\n  " + "\n  ".join(leaks))

    return {"status": "ok", "bundle_dir": str(out_dir), "runs": copied_runs, "missing_files": skipped}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--batch", required=True, help="run-agent-eval.py が作った batch ディレクトリ")
    parser.add_argument("--out", required=True, help="採点者へ渡す bundle の出力先(空であること)")
    args = parser.parse_args()
    try:
        result = build(Path(args.batch).expanduser().resolve(strict=True), Path(args.out).expanduser().resolve())
    except (BundleError, OSError, json.JSONDecodeError) as error:
        print(json.dumps({"status": "error", "message": str(error)}, ensure_ascii=False))
        return EXIT_LEAK
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
