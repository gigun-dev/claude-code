#!/usr/bin/env bash
# telemetry-template v0.2.0 — Langfuse を任意条件で掘る(読み取り専用)。
#
# summary.sh が「傾向」を出すのに対し、こちらは「個別の確認」用。
# 集計で見えた異常(このツールだけ失敗が多い/このターンだけ極端に長い)の裏を取る。
#
# **一覧 API の落とし穴(2026-08-08 に実際に踏んだ)**:
#   /api/public/v2/observations のレスポンスには model / usage / input / output が
#   **含まれない**。そのため一覧だけ見て「コストが入っていない」と誤診できる(実際に
#   誤診した)。中身を見るときは必ず単体取得 /api/public/observations/{id} を使う。
#   このスクリプトの `gen` サブコマンドがそれをやる。
#
# **Python ブロックの書き方の約束**:
#   python3 -c のコードは必ずシングルクォートで囲み、パラメータは**環境変数**で渡す。
#   ダブルクォートで囲むと、シェルの $ 展開と Python の f-string がぶつかり、
#   さらに f-string 内でバックスラッシュが使えず `\"` を書いて構文エラーになる
#   (実際にそれで一度壊した)。
set -uo pipefail

usage() {
  cat <<'EOF'
使い方:
  query.sh errors [days]           ツール失敗(PostToolUseFailure 由来)を一覧(既定 7日)
  query.sh slow   [days] [n]       レイテンシ上位 n 件(既定 10)
  query.sh cost   [days] [n]       コストの高い LLM 応答 上位 n 件(既定 10)
  query.sh trace  <trace_id>       1ターンを時系列で(型・レイテンシつき)
  query.sh gen    <observation_id> LLM 応答の中身を単体取得で見る(入出力・usage・コスト)
  query.sh raw    <path+query>     任意の API パス(例: 'v2/observations?limit=5')
EOF
}

ENV_FILE="${HOME}/.config/claude-code/langfuse.env"
[ -r "$ENV_FILE" ] || { echo "Langfuse 未設定: $ENV_FILE"; exit 0; }
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
BASE="${LANGFUSE_BASE_URL:-https://cloud.langfuse.com}"
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
    N="$n" api "${BASE}/api/public/v2/observations?fromStartTime=$(since "$days")&limit=200" | python3 -c '
import json,sys,os
n=int(os.environ.get("N","10"))
d=json.load(sys.stdin)
rows=[o for o in d.get("data",[]) if o.get("latency")]
rows.sort(key=lambda o:-(o.get("latency") or 0))
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
    N="$n" api "${BASE}/api/public/v2/observations?fromStartTime=$(since "$days")&type=GENERATION&limit=200" | python3 -c '
import json,sys,os
n=int(os.environ.get("N","10"))
d=json.load(sys.stdin)
rows=[o for o in d.get("data",[]) if (o.get("calculatedTotalCost") or o.get("totalPrice"))]
if not rows:
    print("  (一覧 API はコストを返さないことがある。合計は summary.sh、個別は query.sh gen <id>)")
    raise SystemExit
rows.sort(key=lambda o:-(o.get("calculatedTotalCost") or o.get("totalPrice") or 0))
for o in rows[:n]:
    c   = o.get("calculatedTotalCost") or o.get("totalPrice") or 0
    nm  = o.get("name") or ""
    tid = o.get("traceId") or ""
    oid = o.get("id") or ""
    print(f"${c:>7.4f}  {nm:<24} trace={tid}  id={oid}")
'
    ;;
  trace)
    [ $# -ge 1 ] || { usage; exit 2; }
    api "${BASE}/api/public/v2/observations?traceId=$1&limit=200" | python3 -c '
import json,sys
d=json.load(sys.stdin)
rows=sorted(d.get("data",[]), key=lambda o:o.get("startTime") or "")
for o in rows:
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
    # 単体取得。ここでしか model / usage / cost / 入出力本文は返ってこない。
    api "${BASE}/api/public/observations/$1" | python3 -c '
import json,sys
o=json.load(sys.stdin)
if not o.get("id"):
    print("  (見つからない — id が正しいか確認)")
    raise SystemExit
name  = o.get("name"); ty = o.get("type"); lvl = o.get("level")
model = o.get("model"); lat = o.get("latency")
usage = json.dumps(o.get("usageDetails") or {}, ensure_ascii=False)
cost  = o.get("calculatedTotalCost")
print(f"name   : {name}   type={ty}  level={lvl}")
print(f"model  : {model}   latency={lat}s")
print(f"usage  : {usage}")
print(f"cost   : {cost}")
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
