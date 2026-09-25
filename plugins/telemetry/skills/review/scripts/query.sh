#!/usr/bin/env bash
# telemetry-template v0.3.0 — Langfuse を任意条件で掘る(読み取り専用)。
#
# summary.sh が「傾向」を出すのに対し、こちらは「個別の確認」用。
# 集計で見えた異常(このツールだけ失敗が多い/このターンだけ極端に長い)の裏を取る。
#
# **一覧 API の落とし穴、2026-08-08 版と 2026-09-25 版**:
#   2026-08-08 に踏んだときは、一覧 API `/api/public/v2/observations` のレスポンスに
#   model / usage / input / output が**既定では含まれない**ため「コストが入っていない」
#   と誤診した(実際に誤診した)。原因は `fields` パラメータの既定値が `core,basic` のみ
#   だったこと。**現行 API では `fields=io,usage,model` 等を指定すればこの一覧 API だけで
#   入出力本文・usage・cost まで取れる**(2026-09-25 に実機で確認)。当時使っていた単体取得
#   `/api/public/observations/{id}` は、配置が Langfuse v4 events_only モードに移行した後は
#   404 でレガシー扱いになった(本文は
#   `{"message":"This endpoint is not available on deployments running in Langfuse v4
#   events_only mode..."}`)。そのため `gen` は単体取得をやめ、一覧 API に
#   `filter=[{"type":"string","column":"id","operator":"=","value":<id>}]` を渡して
#   1件に絞る方式に変えた(OpenAPI `/api/public/v2/observations` の `filter` パラメータの
#   説明に `id` が絞り込み可能な列として明記されている。実機でも 1 件だけ返ることを確認)。
#   正典は配置自身が出す OpenAPI(`${LANGFUSE_BASE_URL}/generated/api/openapi.yml`)。
#   self-host はインストール版と一致するので langfuse.com の docs より優先する。
#
# **Python ブロックの書き方の約束**:
#   python3 -c のコードは必ずシングルクォートで囲み、パラメータは**環境変数**で渡す。
#   ダブルクォートで囲むと、シェルの $ 展開と Python の f-string がぶつかり、
#   さらに f-string 内でバックスラッシュが使えず `\"` を書いて構文エラーになる
#   (実際にそれで一度壊した)。同じ理由で、API エラーの `message` を f-string に埋めるときも
#   `d['message']`(シングルクォート)を使い、f-string の外枠のダブルクォートと衝突させない。
set -uo pipefail

usage() {
  cat <<'EOF'
使い方:
  query.sh errors [days]           ツール失敗(PostToolUseFailure 由来)を一覧(既定 7日)
  query.sh slow   [days] [n]       レイテンシ上位 n 件(既定 10)
  query.sh cost   [days] [n]       コストの高い LLM 応答 上位 n 件(既定 10)
  query.sh trace  <trace_id>       1ターンを時系列で(型・レイテンシつき)
  query.sh gen    <observation_id> LLM 応答の中身を id 指定で1件だけ見る(入出力・usage・コスト)
  query.sh raw    <path+query>     任意の API パス(例: 'v2/observations?limit=5')
EOF
}

ENV_FILE="${HOME}/.config/claude-code/langfuse.env"
ENDPOINTS_FILE="${HOME}/.config/claude-code/langfuse-endpoints.env"
[ -r "$ENV_FILE" ] || { echo "Langfuse 未設定: $ENV_FILE"; exit 0; }
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; [ ! -r "$ENDPOINTS_FILE" ] || . "$ENDPOINTS_FILE"; set +a
if [ -z "${LANGFUSE_PUBLIC_KEY:-}" ] || [ -z "${LANGFUSE_SECRET_KEY:-}" ]; then
  echo "Langfuse API keys are missing from $ENV_FILE"
  exit 0
fi
BASE="${LANGFUSE_BASE_URL:-${LANGFUSE_HOST:-}}"
if [ -z "$BASE" ]; then
  echo "Langfuse API endpoint is missing; configure $ENDPOINTS_FILE"
  exit 0
fi
AUTH=$(printf '%s:%s' "$LANGFUSE_PUBLIC_KEY" "$LANGFUSE_SECRET_KEY" | base64 | tr -d '\n')

api() { curl -s --max-time 30 -H "Authorization: Basic $AUTH" "$@"; }
since() { python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))"; }

cmd="${1:-}"; shift || true
case "$cmd" in
  errors)
    days="${1:-7}"
    # type=TOOL に絞る。絞らないと、旧実装が文字列一致で ERROR にした SPAN の残骸も混ざる。
    api "${BASE}/api/public/v2/observations?fromStartTime=$(since "$days")&level=ERROR&type=TOOL&limit=50" \
    | python3 -c '
import json,sys
d=json.load(sys.stdin)
msg = d.get("message") if isinstance(d, dict) else None
if msg and "data" not in d:
    # events_only で塞がれた経路など、バックエンドの拒否応答。
    # これを黙って空扱いにすると「失敗なし」と誤読される(実際に誤診した実例あり)。
    print(f"API エラー: {msg}")
    raise SystemExit
rows=d.get("data",[])
if not rows:
    print("  (失敗なし)")
    raise SystemExit
for o in rows[:50]:
    ts  = (o.get("startTime") or "")[:19].replace("T"," ")
    nm  = o.get("name") or ""
    tid = o.get("traceId") or ""
    oid = o.get("id") or ""
    print(f"{ts}  {nm:<20} trace={tid}")
    print(f"    中身: query.sh gen {oid}")
'
    ;;
  slow)
    days="${1:-7}"; n="${2:-10}"
    # Langfuse returns the first sample only.  Do not label this a ranking of
    # the whole period; pass the requested output count to the Python process.
    api "${BASE}/api/public/v2/observations?fromStartTime=$(since "$days")&limit=200" | N="$n" python3 -c '
import json,sys,os
n=int(os.environ.get("N","10"))
d=json.load(sys.stdin)
msg = d.get("message") if isinstance(d, dict) else None
if msg and "data" not in d:
    print(f"API エラー: {msg}")
    raise SystemExit
rows=[o for o in d.get("data",[]) if o.get("latency")]
rows.sort(key=lambda o:-(o.get("latency") or 0))
sample_count = len(d.get("data", []))
print("  retrieved sample: {} observations (limit=200); ranking is within this sample, not the whole period".format(sample_count))
for o in rows[:n]:
    lat = o.get("latency") or 0
    ty  = o.get("type") or ""
    nm  = o.get("name") or ""
    tid = o.get("traceId") or ""
    print(f"{lat:>8.1f}s  {ty:<11} {nm:<26} trace={tid}")
'
    ;;
  cost)
    days="${1:-7}"; n="${2:-10}"
    # コストは generation にしか付かない(ツール実行に値段は無い)。
    # totalCost / usageDetails / costDetails は `fields=usage` を渡さないと返らない
    # (既定は core,basic のみ。2026-09-25 に判明)。旧実装が読んでいた
    # calculatedTotalCost / totalPrice というフィールド名は現行 API に存在しない。
    api "${BASE}/api/public/v2/observations?fromStartTime=$(since "$days")&type=GENERATION&limit=200&fields=core,basic,usage" | N="$n" python3 -c '
import json,sys,os
n=int(os.environ.get("N","10"))
d=json.load(sys.stdin)
msg = d.get("message") if isinstance(d, dict) else None
if msg and "data" not in d:
    print(f"API エラー: {msg}")
    raise SystemExit
rows_all=d.get("data",[])
sample_count=len(rows_all)
print("  retrieved sample: {} generations (limit=200); ranking is within this sample, not the whole period".format(sample_count))
if not rows_all:
    print("  (該当する generation なし)")
    raise SystemExit
priced=[o for o in rows_all if o.get("totalCost") is not None]
unpriced=len(rows_all)-len(priced)
if not priced:
    # 金額が全滅する原因は API 側の欠落ではなく、Langfuse の /api/public/models に
    # そのモデルの単価が未登録なケースがほとんど(実測: claude-opus-5-5 は未登録、
    # claude-opus-5 は登録済みで金額が出る)。ここを「返らないことがある」と曖昧に
    # 書くと、単価を登録すれば直る問題なのか API の限界なのか利用者に伝わらない。
    print(f"  ({sample_count} 件とも単価未登録のモデル。トークン数は usageDetails にあるが金額は出ない。"
          "Langfuse の /api/public/models にそのモデルの単価を登録すれば出るようになる)")
    raise SystemExit
if unpriced:
    print(f"  (うち {unpriced} 件は単価未登録のため金額なし。以下は単価が登録済みの {len(priced)} 件のみ)")
priced.sort(key=lambda o:-(o.get("totalCost") or 0))
for o in priced[:n]:
    c   = o.get("totalCost") or 0
    tok = (o.get("usageDetails") or {}).get("total")
    nm  = o.get("name") or ""
    tid = o.get("traceId") or ""
    oid = o.get("id") or ""
    print(f"${c:>7.4f}  {tok!s:>8}tok  {nm:<24} trace={tid}  id={oid}")
'
    ;;
  trace)
    [ $# -ge 1 ] || { usage; exit 2; }
    api "${BASE}/api/public/v2/observations?traceId=$1&limit=200" | TRACE_LIMIT=200 python3 -c '
import json,sys,os
limit=int(os.environ.get("TRACE_LIMIT","200"))
d=json.load(sys.stdin)
msg = d.get("message") if isinstance(d, dict) else None
if msg and "data" not in d:
    print(f"API エラー: {msg}")
    raise SystemExit
rows=sorted(d.get("data",[]), key=lambda o:o.get("startTime") or "")
returned=len(rows)
truncation=("output may be truncated when the limit is reached"
            if returned >= limit else "all returned sample rows shown")
print(f"  retrieved trace sample: {returned} observations (limit={limit}); {truncation}")
for o in rows[:limit]:
    lat = o.get("latency") or 0   # observations API は秒(metrics API はミリ秒。単位が非対称)
    hhmmss = (o.get("startTime") or "")[11:19]
    ty  = (o.get("type") or "")[:10]
    lvl = "ERR" if (o.get("level") == "ERROR") else "   "
    nm  = o.get("name") or ""
    print(f"{hhmmss}  {lat:>7.1f}s  {ty:<11} {lvl} {nm}")
print("")
print("  LLM 応答の中身は: query.sh gen <observation_id>")
'
    ;;
  gen)
    [ $# -ge 1 ] || { usage; exit 2; }
    # 単体取得 /api/public/observations/{id} は events_only で 404(レガシー扱い)。
    # 代わりに一覧 API へ `filter` で id 一致条件を渡し、1件だけを取り、
    # fields で io/usage/model/metrics を明示的に足す(既定は core,basic のみで
    # 入出力・usage・cost は含まれない)。OpenAPI の filter 説明に id は文字列列として
    # 「=」演算子で絞り込める旨が明記されており、実機でも1件だけ返ることを確認済み。
    FILTER=$(OID="$1" python3 -c '
import json, os, urllib.parse
cond = [{"type": "string", "column": "id", "operator": "=", "value": os.environ["OID"]}]
print(urllib.parse.quote(json.dumps(cond)))
')
    api "${BASE}/api/public/v2/observations?filter=${FILTER}&fields=core,basic,io,usage,model,metrics" | python3 -c '
import json,sys
d=json.load(sys.stdin)
msg = d.get("message") if isinstance(d, dict) else None
if msg and "data" not in d:
    print(f"API エラー: {msg}")
    raise SystemExit
rows=d.get("data",[]) if isinstance(d, dict) else []
if not rows:
    print("  (見つからない — id が正しいか確認)")
    raise SystemExit
o=rows[0]
name  = o.get("name"); ty = o.get("type"); lvl = o.get("level")
model = o.get("model"); lat = o.get("latency")
usage = json.dumps(o.get("usageDetails") or {}, ensure_ascii=False)
cost  = o.get("totalCost")
# totalCost が None なのは API の欠落ではなく、Langfuse の /api/public/models に
# そのモデルの単価が未登録なケースがほとんど(実測: claude-opus-5-5 は未登録)。
cost_note = "" if cost is not None else "  (単価未登録の可能性。models にモデルが無いとトークン数のみ)"
print(f"name   : {name}   type={ty}  level={lvl}")
print(f"model  : {model}   latency={lat}s")
print(f"usage  : {usage}")
print(f"cost   : {cost}{cost_note}")
for k in ("input","output"):
    v = o.get(k)
    if v is None:
        continue
    s = v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)
    print("")
    print(f"--- {k} ---")
    print(s[:2000])
'
    ;;
  raw)
    [ $# -ge 1 ] || { usage; exit 2; }
    api "${BASE}/api/public/$1"
    ;;
  *) usage; exit 2 ;;
esac
