#!/usr/bin/env bash
# telemetry-template v0.2.0 — Langfuse から自セッションの傾向を集計する(読み取り専用)。
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
#
# v0.2.0(2026-08-08)の変更 — フック側が observation を型で撃ち分けるようになったため:
#   - **コストとトークンを出す。** フックが transcript から generation を復元し、
#     usage_details を送るようになった。Langfuse がモデル価格表と突き合わせて
#     コストを計算してくれるので、ここで合計するだけで済む。
#   - **型でフィルタする。** 以前は name だけで集計していたので、ツールと LLM 応答が
#     同じ表に混ざった。いまは TOOL / GENERATION / SPAN(ターン) / AGENT を分けて見る。
#   - **ERROR の意味が変わった。** 以前はツール出力の "rror" 文字列一致だったので
#     実測で 64 倍に上振れしていた。いまは PostToolUseFailure イベントで判定する。
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

# type でフィルタするクエリを組む(dimensions と metrics は呼び出し側で指定)。
q_by_type() { # $1=type $2=metrics-json $3=dimensions-json
  echo "{\"view\":\"observations\",\"metrics\":$2,\"dimensions\":$3,\"filters\":[{\"column\":\"type\",\"operator\":\"=\",\"value\":\"$1\",\"type\":\"string\"}],\"fromTimestamp\":\"$FROM\",\"toTimestamp\":\"$TO\"}"
}

echo "== Langfuse 集計(直近 ${DAYS} 日 / ${FROM} 〜) =="

# --- コストとトークン --------------------------------------------------------
# 一番上に置く。ここが「この期間に何を消費したか」の答えで、他は全部その内訳。
metrics "{\"view\":\"observations\",\"metrics\":[{\"measure\":\"count\",\"aggregation\":\"count\"},{\"measure\":\"totalCost\",\"aggregation\":\"sum\"},{\"measure\":\"totalTokens\",\"aggregation\":\"sum\"}],\"dimensions\":[{\"field\":\"providedModelName\"}],\"fromTimestamp\":\"$FROM\",\"toTimestamp\":\"$TO\"}" \
| python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("  (コスト取得失敗)"); raise SystemExit
rows=[r for r in d.get("data",[]) if r.get("providedModelName")]
if not rows:
    print("\n## コスト\n  (まだ generation が無い — フックが transcript を送れているか確認)")
    raise SystemExit
rows.sort(key=lambda r:-(float(r.get("sum_totalCost") or 0)))
total=sum(float(r.get("sum_totalCost") or 0) for r in rows)
print(f"\n## コスト / トークン  合計 ${total:,.2f}")
for r in rows:
    m=r.get("providedModelName"); c=float(r.get("sum_totalCost") or 0)
    tok=int(r.get("sum_totalTokens") or 0); n=int(r.get("count_count") or 0)
    print(f"  {m:<28} ${c:>8,.2f}  {tok/1_000_000:>7.1f}M tok  {n:>5} 応答")
' 2>/dev/null

# --- ツール別: 実行数と平均レイテンシ ---------------------------------------
# 「何にどれだけ時間を使っているか」= 改善の投資先を決める材料。
metrics "$(q_by_type TOOL '[{"measure":"count","aggregation":"count"},{"measure":"latency","aggregation":"avg"},{"measure":"latency","aggregation":"p95"}]' '[{"field":"name"}]')" \
| python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("  (取得失敗)"); raise SystemExit
rows=[r for r in d.get("data",[]) if r.get("name")]
if not rows: print("\n## ツール\n  (データ無し — まだトレースが溜まっていない可能性)"); raise SystemExit
rows.sort(key=lambda r:-int(r.get("count_count") or 0))
print("\n## ツール別 実行数 / 平均・p95 レイテンシ")
def fmt(ms):
    # duration_ms は Claude Code の実測値なので Read/Edit は数十 ms になる。
    # 秒固定で出すと軒並み "0.0s" になって情報が消えるため、1秒未満は ms で出す。
    return f"{ms:>5.0f}ms" if ms < 1000 else f"{ms/1000:>5.1f}s "
for r in rows[:12]:
    n=r.get("name") or ""; c=int(r.get("count_count") or 0)
    avg=float(r.get("avg_latency") or 0); p95=float(r.get("p95_latency") or 0)
    print(f"  {n:<28} {c:>5}回  avg {fmt(avg)}  p95 {fmt(p95)}")
' 2>/dev/null

# --- 失敗 --------------------------------------------------------------------
# PostToolUseFailure イベントで送った span だけがここに出る(推測ではなくイベント由来)。
metrics "{\"view\":\"observations\",\"metrics\":[{\"measure\":\"count\",\"aggregation\":\"count\"}],\"dimensions\":[{\"field\":\"name\"}],\"filters\":[{\"column\":\"type\",\"operator\":\"=\",\"value\":\"TOOL\",\"type\":\"string\"},{\"column\":\"level\",\"operator\":\"=\",\"value\":\"ERROR\",\"type\":\"string\"}],\"fromTimestamp\":\"$FROM\",\"toTimestamp\":\"$TO\"}" \
| python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
rows=[r for r in d.get("data",[]) if r.get("name")]
print("\n## ツール失敗(PostToolUseFailure)")
if not rows: print("  (なし)"); raise SystemExit
rows.sort(key=lambda r:-int(r.get("count_count") or 0))
for r in rows[:10]:
    # f-string 内でバックスラッシュは使えないので、値は先に変数へ取り出す。
    nm = r.get("name") or ""
    cnt = int(r.get("count_count") or 0)
    print(f"  {nm:<28} {cnt:>5}回")
' 2>/dev/null

# --- ターンとサブエージェント ------------------------------------------------
metrics "$(q_by_type SPAN '[{"measure":"count","aggregation":"count"},{"measure":"latency","aggregation":"avg"}]' '[{"field":"name"}]')" \
| python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
rows=[r for r in d.get("data",[]) if r.get("name")=="claude-code turn"]
if rows:
    r=rows[0]; c=int(r.get("count_count") or 0); avg=float(r.get("avg_latency") or 0)/1000
    print(f"\n## ターン\n  {c} ターン / 1ターン平均 {avg:.0f}s")
' 2>/dev/null

metrics "$(q_by_type AGENT '[{"measure":"count","aggregation":"count"},{"measure":"latency","aggregation":"avg"}]' '[{"field":"name"}]')" \
| python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
rows=[r for r in d.get("data",[]) if r.get("name")]
if rows:
    rows.sort(key=lambda r:-int(r.get("count_count") or 0))
    print("\n## サブエージェント")
    for r in rows[:6]:
        nm = r.get("name") or ""
        c=int(r.get("count_count") or 0); avg=float(r.get("avg_latency") or 0)/1000
        print(f"  {nm:<28} {c:>5}回  avg {avg:>7.1f}s")
' 2>/dev/null

echo
echo "  (詳細は ${BASE} の UI。個別トレースを掘るときは scripts/query.sh を使う)"
exit 0
