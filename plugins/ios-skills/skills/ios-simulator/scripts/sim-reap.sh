#!/usr/bin/env bash
# 使い捨て端末(worker)を棚卸しし、古いものを回収する。
#
# Why: 端末は「誰が何のために作ったか」を持たない(simctl は udid/name/state/lastBootedAt
# しか返さない)。名前だけがライフサイクル信号なので、`w-` 接頭辞を廃棄可能の宣言として扱う。
# 実測(2026-08-02): 放置された種端末が評価の baseline の近道になり、スキルの効果を消した。
# 「あとで消す」は消さない。作った側は trap で消し、取りこぼしをこれで回収する。
#
# Why not 名前を見ずに古い端末を全部消すか: seed と既定端末を巻き込む。
# **接頭辞に一致するものだけ**を対象にする。既定は dry-run。
set -euo pipefail

PREFIX='w-'
MAX_AGE_HOURS=12
APPLY=0

usage() {
  cat <<'EOF'
Usage: sim-reap.sh [--prefix w-] [--max-age-hours 12] [--apply]

`--prefix` で始まり、作成から `--max-age-hours` 以上経った Simulator を一覧する。
`--apply` を付けたときだけ削除する(既定は dry-run)。

stdout は JSON。診断は stderr。

  --prefix          回収対象の名前接頭辞(既定 w-)。seed や既定端末に一致させないこと
  --max-age-hours   これより古いものだけ対象(既定 12)。作業中の worker を巻き込まないため
  --apply           実際に削除する
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --max-age-hours) MAX_AGE_HOURS="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;      # 明示できるように受ける(既定と同じ)
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$PREFIX" in
  ''|seed*|iPhone*|iPad*)
    # seed / 既定端末を巻き込む接頭辞は受け付けない。事故の芽を構造で潰す。
    echo "refusing prefix '$PREFIX': would match seeds or default devices" >&2
    exit 2 ;;
esac

command -v xcrun >/dev/null || { echo "xcrun not found" >&2; exit 3; }

xcrun simctl list devices --json \
  | PREFIX="$PREFIX" MAX_AGE_HOURS="$MAX_AGE_HOURS" APPLY="$APPLY" python3 -c '
import json, os, subprocess, sys, time

prefix = os.environ["PREFIX"]
max_age = float(os.environ["MAX_AGE_HOURS"]) * 3600
apply_changes = os.environ["APPLY"] == "1"
now = time.time()

payload = json.load(sys.stdin)
candidates, kept = [], 0
for entries in payload.get("devices", {}).values():
    for entry in entries:
        if not entry.get("name", "").startswith(prefix):
            continue
        # simctl は作成時刻を返さないので、デバイスディレクトリの birth time を使う。
        # dataPath は .../Devices/<UDID>/data なので親を見る。
        data_path = entry.get("dataPath") or ""
        device_dir = os.path.dirname(data_path) if data_path else ""
        try:
            born = os.stat(device_dir).st_birthtime
        except OSError:
            kept += 1
            continue                      # 作成時刻が読めないものは触らない
        age = now - born
        record = {
            "udid": entry["udid"], "name": entry["name"],
            "state": entry.get("state", ""), "age_hours": round(age / 3600, 1),
        }
        if age >= max_age:
            candidates.append(record)
        else:
            kept += 1

deleted, failed = [], []
if apply_changes:
    for record in candidates:
        if record["state"] == "Booted":
            subprocess.run(["xcrun", "simctl", "shutdown", record["udid"]],
                           capture_output=True, check=False)
        result = subprocess.run(["xcrun", "simctl", "delete", record["udid"]],
                                capture_output=True, text=True, check=False)
        (deleted if result.returncode == 0 else failed).append(record["udid"])

print(json.dumps({
    "prefix": prefix, "max_age_hours": max_age / 3600,
    "candidates": candidates, "kept_too_young": kept,
    "applied": apply_changes, "deleted": deleted, "failed": failed,
}, ensure_ascii=False, indent=2))
'
