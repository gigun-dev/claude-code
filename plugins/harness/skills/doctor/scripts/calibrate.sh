#!/usr/bin/env bash
# harness-template v0.2.0 — トークン係数を**実際のトークナイザ**で較正する(明示起動専用)。
#
# 設計意図(2026-08-08):
#   harness の予算は2軸ある —— **文字**(切り詰め。正確・ベンダー非依存)と
#   **概算トークン**(毎リクエストの実費。ベンダー依存で、既定値は Claude 4.7+ の文献値)。
#   後者はどうしても概算になる: Claude Code 自身がローカルトークナイザを持たず
#   (バイナリ 2.1.222 で確認)、正確な数は API 経由でしか取れないため。
#   **このスクリプトはその「たまに正確に測る」側**で、測った結果から係数を逆算して出す。
#
# ⚠️ **このスクリプトは絶対に `!` 記法に置かない。**
#   `!` は「スキルを読んだだけで無条件に走る」ので、そこに置けるのは
#   **必ず成功する・読み取り専用・オフラインで完結する**スクリプトだけ、という境界を
#   このハーネスは明示的に守っている(だから check.sh は `!`、install.sh は違う)。
#   **これは外向きの通信を行いうる**ので、引数なしでは何もせず、必ず人が意図して叩く。
#   Why not check.sh に --exact フラグとして足さないのか: check.sh は `!` で自動実行される。
#   フラグで守っても「ネットワークを叩きうるスクリプトが `!` にある」状態そのものが
#   境界の侵食で、次に誰かが既定を変えたら黙って毎回通信するようになる。**入口を分ける。**
#
# ⚠️ **--claude では、渡したファイルの中身そのものが送信される。**
#   next-directions.md や CLAUDE.md には内部の意思決定・ボツ案が入る。実行前に必ず
#   ユーザーの合意を取ること(SKILL.md「外向きの操作を黙って実行しない」)。
#   --gpt はローカルの tiktoken で完結するので送信は発生しない。
set -uo pipefail

usage() {
  cat <<'EOF'
使い方: calibrate.sh (--claude | --gpt) <ファイル> [<ファイル> ...] [--model <id>]

トークン係数を実際のトークナイザで測り、harness の概算式との差と、
そのまま貼れる `export HARNESS_TOK_*` を出す。

⚠️ **ファイルは2本以上渡すこと。** 未知数が2つ(ASCII 係数・非ASCII 係数)あるので、
   1本では原理的に解けない。**日本語率が離れた組**にするほど精度が上がる
   (例: 英語の SKILL.md + 日本語の next-directions.md)。
   1本だけ渡した場合は概算とのズレだけを出し、係数は出さない。

モード(どちらか必須。既定は無い = 引数なしでは何もしない):
  --claude   `POST /v1/messages/count_tokens` で正確に数える。
             **ファイルの全文が Anthropic の API へ送られる。**
             ANTHROPIC_API_KEY が要る。API は無料(RPM 制限のみ)。
  --gpt      ローカルの tiktoken(o200k_base)で数える。**送信は発生しない。**
             Codex / GPT 系クライアントで harness を使う場合の係数を出す。
             tiktoken が無ければ uv があれば一時実行する(環境は汚さない)。

オプション:
  --model <id>  --claude のときのモデル。既定 claude-opus-5。
                ⚠️ **4.7 未満と 4.7 以降でトークナイザが違う**(同じ文字列で約 30% 差)。
                実際に使うモデルを指定すること。
  -h, --help    これ。

使用例:
  bash calibrate.sh --gpt plugins/harness/skills/status/SKILL.md docs/next-directions.md
  ANTHROPIC_API_KEY=... bash calibrate.sh --claude CLAUDE.md docs/next-directions.md --model claude-sonnet-5

終了コード:
  0  測れた
  2  使い方の誤り / 前提が無い(API キー・python3・tiktoken・ネットワーク)
     ⚠️ **前提が無いときに黙って概算へ落ちない。**測れなかったことを終了コードで表に出す
        (原則4: 検知器は黙って死ぬ前提)。
EOF
}

MODE=""; MODEL="claude-opus-5"; FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --claude) MODE=claude; shift ;;
    --gpt)    MODE=gpt; shift ;;
    --model)  MODEL="${2:-}"; [ -n "$MODEL" ] || { echo "--model に値が無い" >&2; exit 2; }; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "不明な引数: $1" >&2; usage >&2; exit 2 ;;
    *)  FILES+=("$1"); shift ;;
  esac
done
[ -n "$MODE" ] || { echo "モードが無い(--claude か --gpt)。引数なしでは何もしない —— このスクリプトは外向きの通信を行いうるため。" >&2; usage >&2; exit 2; }
[ "${#FILES[@]}" -gt 0 ] || { echo "ファイルが無い" >&2; usage >&2; exit 2; }
for f in "${FILES[@]}"; do [ -r "$f" ] || { echo "読めない: $f" >&2; exit 2; }; done

command -v python3 >/dev/null 2>&1 || { echo "⏭ python3 が無いので測れない(JSON の組み立てと解析に要る)。" >&2; exit 2; }

# 実測を1本ぶん返す。標準出力にトークン数だけを出し、失敗したら空を返す。
read -r -d '' TIKTOKEN_PY <<'PY' || true
import sys, tiktoken
enc = tiktoken.get_encoding("o200k_base")
print(len(enc.encode(open(sys.argv[1], encoding="utf-8").read())))
PY
read -r -d '' COUNTAPI_PY <<'PY' || true
import json, os, sys, urllib.request
text = open(sys.argv[1], encoding="utf-8").read()
body = json.dumps({"model": sys.argv[2], "messages": [{"role": "user", "content": text}]}).encode()
req = urllib.request.Request(
    "https://api.anthropic.com/v1/messages/count_tokens", data=body,
    headers={"x-api-key": os.environ["ANTHROPIC_API_KEY"],
             "anthropic-version": "2023-06-01", "content-type": "application/json"})
print(json.load(urllib.request.urlopen(req, timeout=30))["input_tokens"])
PY

# tiktoken は必須依存にしない。**入っていれば使い、無ければ uv で一時実行する。**
# Why: 「pip install してください」で止まると、較正という**たまにしかやらない作業**が
# そのまま実行されなくなる(2026-08-08 の初回は実際にここで止まった)。uv があれば
# 環境を汚さずに解決できるので、諦める前に一段だけ試す。⚠️ どちらも無ければ exit 2。
GPT_RUNNER=""
if [ "$MODE" = gpt ]; then
  if printf '%s' "$TIKTOKEN_PY" | python3 - /dev/null >/dev/null 2>&1; then
    GPT_RUNNER=python3
  elif command -v uv >/dev/null 2>&1; then
    GPT_RUNNER=uv
    echo "  (tiktoken が無いので uv で一時実行します。環境は汚しません)" >&2
  else
    echo "⏭ tiktoken が使えないので測れない(pip install tiktoken、または uv を入れる)。**送信は発生していない。**" >&2
    exit 2
  fi
  LABEL="GPT/o200k_base"
else
  [ -n "${ANTHROPIC_API_KEY:-}" ] || { echo "⏭ ANTHROPIC_API_KEY が無いので測れない。Claude Code の OAuth 資格情報はこの API には使えない(別物)。" >&2; exit 2; }
  printf '⚠️ 次のファイルの全文を Anthropic の API(%s)へ送信します: %s\n' "$MODEL" "${FILES[*]}" >&2
  LABEL="$MODEL"
fi

printf '\n=== トークン係数の較正 — %s ===\n\n' "$LABEL"
printf '  %-46s %8s %8s %8s %9s %8s\n' "ファイル" "ASCII" "非ASCII" "実測tok" "harness概算" "ずれ"

# 中間データ: 1行 "ascii wide actual" を溜めて、最後にまとめて解く。
OBS=$(mktemp); trap 'rm -f "$OBS"' EXIT
for f in "${FILES[@]}"; do
  chars=$(LC_ALL=C tr -d '\200-\277' < "$f" | wc -c | tr -d ' ')
  ascii=$(LC_ALL=C tr -cd '\000-\177' < "$f" | wc -c | tr -d ' ')
  wide=$((chars - ascii))
  est=$(( (ascii * ${HARNESS_TOK_ASCII_PCT:-33} + wide * ${HARNESS_TOK_WIDE_PCT:-140}) / 100 ))
  if [ "$MODE" = gpt ]; then
    if [ "$GPT_RUNNER" = uv ]; then
      actual=$(printf '%s' "$TIKTOKEN_PY" | uv run --quiet --with tiktoken python - "$f" 2>/dev/null)
    else
      actual=$(printf '%s' "$TIKTOKEN_PY" | python3 - "$f" 2>/dev/null)
    fi
  else
    actual=$(printf '%s' "$COUNTAPI_PY" | python3 - "$f" "$MODEL" 2>/dev/null)
  fi
  # ⚠️ 1本でも測れなかったら**そこで落とす。**残りだけで解くと、どのファイルが
  #    落ちたか分からないまま係数が出てしまう(黙って精度が落ちるのが最悪)。
  [ -n "$actual" ] || { echo "⏭ 測れなかった: $f(キー / ネットワーク / レート制限)。**係数は変えないこと。**" >&2; exit 2; }
  printf '  %-46s %8s %8s %8s %9s %+7.1f%%\n' "$(basename "$f")" "$ascii" "$wide" "$actual" "$est" \
    "$(python3 -c "print(($est - $actual) / $actual * 100)")"
  echo "$ascii $wide $actual" >> "$OBS"
done

python3 - "$OBS" "${HARNESS_TOK_ASCII_PCT:-33}" "${HARNESS_TOK_WIDE_PCT:-140}" <<'PY'
import sys
rows = [tuple(int(v) for v in l.split()) for l in open(sys.argv[1]) if l.strip()]
cur_a, cur_w = int(sys.argv[2]), int(sys.argv[3])
print()
if len(rows) < 2:
    print("  ⚠️ ファイルが1本なので**係数は出さない。** 未知数が2つ(ASCII 係数・非ASCII 係数)")
    print("     あるので1本では原理的に解けない —— 固定して解いたつもりになると、日本語率の")
    print("     低いファイルで負の係数が出る(2026-08-08 に実際に -679 が出た)。")
    print("     日本語率の離れた2本目を渡すこと(例: 英語の SKILL.md + 日本語の正典)。")
    sys.exit(0)

# 切片なしの2変数最小二乗: tok = a*ascii + w*wide。正規方程式を直に解く
# (原点を通るのが正しい —— 空文字列は 0 トークン)。numpy には依存しない。
saa = sum(r[0]*r[0] for r in rows); saw = sum(r[0]*r[1] for r in rows)
sww = sum(r[1]*r[1] for r in rows); sat = sum(r[0]*r[2] for r in rows)
swt = sum(r[1]*r[2] for r in rows)
det = saa*sww - saw*saw
if abs(det) < 1e-9:
    print("  ⚠️ 渡されたファイルの**日本語率が近すぎて解けない**(行列が特異)。")
    print("     英語主体のファイルと日本語主体のファイルを混ぜること。")
    sys.exit(0)
a = (sat*sww - swt*saw) / det
w = (swt*saa - sat*saw) / det
if a <= 0 or w <= 0:
    print(f"  ⚠️ 解が非物理的(ASCII {a*100:.0f} / 非ASCII {w*100:.0f})。日本語率の分布が偏りすぎている。")
    print("     日本語率がもっと離れたファイルで測り直すこと。**この値は採用しない。**")
    sys.exit(0)

print(f"  最小二乗で解いた係数({len(rows)} 本から。切片なし = 空文字列は 0 トークン):")
print(f"    export HARNESS_TOK_ASCII_PCT={a*100:.0f}   # いまの既定 {cur_a}")
print(f"    export HARNESS_TOK_WIDE_PCT={w*100:.0f}   # いまの既定 {cur_w}")
print()
print("  当てはまり(この係数で各ファイルを再計算した残差):")
worst = 0
for ascii_n, wide_n, actual in rows:
    fit = a*ascii_n + w*wide_n
    err = (fit - actual) / actual * 100
    worst = max(worst, abs(err))
    print(f"    {actual:>7} tok 実測  →  {fit:>7.0f} tok 当てはめ  ({err:+.1f}%)")
print()
if worst > 10:
    print(f"  ⚠️ 最大残差 {worst:.1f}% —— **線形モデルで説明しきれていない。**")
    print("     非ASCII を1種類として扱っているのが効いている可能性がある(かな・漢字・")
    print("     絵文字・記号でトークン単価は違う)。採用する前にもう1本増やして確かめること。")
else:
    print(f"  ✓ 最大残差 {worst:.1f}% —— 線形モデルで十分に説明できている。")
PY

printf '\n  ⚠️ 実測は「このファイルをそのまま user メッセージにしたとき」の値で、system prompt や\n'
printf '     ツール定義は含まない。**文書の相対コストを見るための数字**であって、\n'
printf '     セッション全体の実費ではない。全体は `/context` が出す。\n'
printf '\n=== 較正完了(calibrate.sh v0.2.0) ===\n'
exit 0
