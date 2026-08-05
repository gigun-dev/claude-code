#!/usr/bin/env bash
# telemetry-template v0.1.0 — Langfuse を任意条件で掘る(読み取り専用)。
#
# summary.sh が「傾向」を出すのに対し、こちらは「個別の確認」用。
# 集計で見えた異常(このツールだけ失敗が多い/このターンだけ極端に長い)の裏を取る。
set -uo pipefail

usage() {
  cat <<'EOF'
使い方:
  query.sh errors [days] [name]   失敗(level=ERROR)の観測を一覧(既定 7日)
  query.sh slow   [days] [n]      レイテンシ上位 n 件(既定 10)
  query.sh trace  <trace_id>      1トレースの観測を時系列で表示
  query.sh raw    <path+query>    任意の API パス(例: 'v2/observations?limit=5')
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
    days="${1:-7}"; name="${2:-}"
    url="${BASE}/api/public/v2/observations?fromStartTime=$(since "$days")&level=ERROR&limit=50"
    [ -n "$name" ] && url="${url}&name=${name}"
    api "$url" | python3 -c '
import json,sys
d=json.load(sys.stdin)
# f-string 内でバックスラッシュ退避が要らないよう、値は先に変数へ取り出す
# (シェルの引用符と Python の引用符が二重に絡むと壊れやすい)。
for o in d.get("data",[])[:50]:
    ts = (o.get("startTime") or "")[:19]
    nm = o.get("name") or ""
    msg = o.get("statusMessage") or ""
    print(f"{ts}  {nm:<24} {msg}")
    print("    trace=" + str(o.get("traceId")))
'
    ;;
  slow)
    days="${1:-7}"; n="${2:-10}"
    api "${BASE}/api/public/v2/observations?fromStartTime=$(since "$days")&limit=200" | python3 -c "
import json,sys
d=json.load(sys.stdin)
rows=[o for o in d.get('data',[]) if o.get('latency')]
rows.sort(key=lambda o:-(o.get('latency') or 0))
for o in rows[:$n]:
    print(f\"{(o.get('latency') or 0):>8.1f}s  {o.get('name',''):<24} trace={o.get('traceId')}\")
"
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
    lvl = o.get("level") or ""
    nm = o.get("name") or ""
    print(f"{hhmmss}  {lat:>7.1f}s  {lvl:<7} {nm}")
'
    ;;
  raw)
    [ $# -ge 1 ] || { usage; exit 2; }
    api "${BASE}/api/public/$1"
    ;;
  *) usage; exit 2 ;;
esac
