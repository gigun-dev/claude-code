#!/usr/bin/env bash
# telemetry-template v0.1.0 — Langfuse から自セッションの傾向を集計する(読み取り専用)。
#
# 設計意図(2026-08-05):
#   SKILL.md の `!` 記法から、スキル読み込み時に無条件で実行される。したがって:
#   - **読み取り専用。** 何も変更しない(GET のみ)。
#   - **絶対に失敗しない。** 資格情報が無い/ネットワークが死んでいる場合も exit 0 で
#     理由だけ出す(スキル読み込み自体を壊さない)。
#   - **出力を絞る。** 毎回コンテキストに載るので、判断に要る集計だけを短く出す。
#
#   使うのは v2 エンドポイント。v3(/api/public/traces, /api/public/metrics)は
#   deprecation 警告を返すので使わない。
set -uo pipefail

DAYS="${1:-7}"   # 集計期間(日)。既定7日
ENV_FILE="${HOME}/.config/claude-code/langfuse.env"

if [ ! -r "$ENV_FILE" ]; then
  echo "(Langfuse 未設定: $ENV_FILE が無いため集計をスキップ)"
  exit 0
fi
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
if [ -z "${LANGFUSE_PUBLIC_KEY:-}" ] || [ -z "${LANGFUSE_SECRET_KEY:-}" ]; then
  echo "(Langfuse の鍵が空のため集計をスキップ)"
  exit 0
fi

BASE="${LANGFUSE_BASE_URL:-https://cloud.langfuse.com}"
AUTH=$(printf '%s:%s' "$LANGFUSE_PUBLIC_KEY" "$LANGFUSE_SECRET_KEY" | base64 | tr -d '\n')
FROM=$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=$DAYS)).strftime('%Y-%m-%dT%H:%M:%SZ'))" 2>/dev/null) || exit 0
TO=$(python3 -c "import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))" 2>/dev/null) || exit 0

# metrics API を叩いて JSON を返す。失敗しても空を返して呼び出し側を止めない。
metrics() {
  curl -s --max-time 20 -H "Authorization: Basic $AUTH" \
    --get --data-urlencode "query=$1" "${BASE}/api/public/v2/metrics" 2>/dev/null || echo '{}'
}

echo "== Langfuse 集計(直近 ${DAYS} 日 / ${FROM} 〜) =="

# --- ツール別: 実行数と平均レイテンシ ---------------------------------------
# 「何にどれだけ時間を使っているか」= 改善の投資先を決める材料。
metrics "{\"view\":\"observations\",\"metrics\":[{\"measure\":\"count\",\"aggregation\":\"count\"},{\"measure\":\"latency\",\"aggregation\":\"avg\"},{\"measure\":\"latency\",\"aggregation\":\"p95\"}],\"dimensions\":[{\"field\":\"name\"}],\"fromTimestamp\":\"$FROM\",\"toTimestamp\":\"$TO\"}" \
| python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("  (取得失敗)"); raise SystemExit
rows=[r for r in d.get("data",[]) if r.get("name")]
if not rows: print("  (データ無し — まだトレースが溜まっていない可能性)"); raise SystemExit
rows.sort(key=lambda r:-int(r.get("count_count") or 0))
print("\n## ツール別 実行数 / 平均・p95 レイテンシ")
for r in rows[:14]:
    n=r.get("name"); c=int(r.get("count_count") or 0)
    avg=float(r.get("avg_latency") or 0)/1000; p95=float(r.get("p95_latency") or 0)/1000
    print(f"  {n:<28} {c:>5}回  avg {avg:>7.1f}s  p95 {p95:>7.1f}s")
' 2>/dev/null

# --- 失敗(level=ERROR)の分布 -------------------------------------------------
# フックがツール失敗を level=ERROR で送っているので、どのツールが転んでいるか出る。
metrics "{\"view\":\"observations\",\"metrics\":[{\"measure\":\"count\",\"aggregation\":\"count\"}],\"dimensions\":[{\"field\":\"name\"}],\"filters\":[{\"column\":\"level\",\"operator\":\"=\",\"value\":\"ERROR\",\"type\":\"string\"}],\"fromTimestamp\":\"$FROM\",\"toTimestamp\":\"$TO\"}" \
| python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
rows=[r for r in d.get("data",[]) if r.get("name")]
print("\n## 失敗(level=ERROR)")
if not rows: print("  (なし)"); raise SystemExit
rows.sort(key=lambda r:-int(r.get("count_count") or 0))
for r in rows[:10]:
    name = r.get("name"); cnt = int(r.get("count_count") or 0)
    print(f"  {name:<28} {cnt:>5}回")
print("  ※ ERROR 判定はツール出力に \"rror\" を含むかの粗い一致。出力に error の語が出るだけの")
print("     成功も拾うので、件数は上振れする。個別確認は query.sh で。")
' 2>/dev/null

# --- ターン(root span)の規模 -------------------------------------------------
metrics "{\"view\":\"observations\",\"metrics\":[{\"measure\":\"count\",\"aggregation\":\"count\"},{\"measure\":\"latency\",\"aggregation\":\"avg\"}],\"dimensions\":[],\"filters\":[{\"column\":\"name\",\"operator\":\"=\",\"value\":\"claude-code turn\",\"type\":\"string\"}],\"fromTimestamp\":\"$FROM\",\"toTimestamp\":\"$TO\"}" \
| python3 -c '
import json,sys
try: d=json.load(sys.stdin); r=(d.get("data") or [{}])[0]
except Exception: raise SystemExit
c=int(r.get("count_count") or 0); avg=float(r.get("avg_latency") or 0)/1000
if c: print(f"\n## ターン\n  {c} ターン / 1ターン平均 {avg:.0f}s")
' 2>/dev/null

echo
echo "  (詳細は ${BASE} の UI。個別トレースを掘るときは scripts/query.sh を使う)"
exit 0
