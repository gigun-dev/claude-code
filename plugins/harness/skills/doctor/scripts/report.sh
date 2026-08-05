#!/usr/bin/env bash
# harness-template v0.9.0 — doctor/init が誤動作したとき、その場から harness へ起票する。
#
# 設計意図(2026-08-05):
#   ハーネスは**配布先のリポジトリで動く**が、直す場所は配布元(gigun-dev/claude-code)。
#   誤検知や配線ミスに気づくのは配布先での作業中なので、そこから直接起票できないと
#   「あとで直す」が失われる(実際、doctor の誤検知は口頭で報告されただけで消えかけた)。
#
#   ドキュメントの置き場としては、コードの近く(コメント)→ repo の docs → Issue の順で
#   遠くなる。**リポジトリを跨ぐ経緯は Issue が唯一の受け皿**なのでここだけは外に出す。
#
#   既定は下書きの表示のみ。`--create` を明示したときだけ実際に issue を作る
#   (外向きの操作を暗黙に実行しない)。
set -uo pipefail

UPSTREAM="gigun-dev/claude-code"
CREATE=0
KIND="bug"
TITLE=""
BODY_NOTE=""

usage() {
  cat <<'EOF'
使い方: report.sh --title "<一行要約>" [options]

  --title <text>    必須。何が起きたか(例: "doctor が禁止指示を誤検知する")
  --note <text>     詳細(誤検知した文面・期待した挙動など)。複数回指定可
  --kind <bug|idea> 既定 bug
  --create          実際に GitHub issue を作る(既定は下書き表示のみ)

環境の情報(リポジトリ・テンプレート世代・doctor の出力)は自動で本文に入る。
EOF
}

notes=()
while [ $# -gt 0 ]; do
  case "$1" in
    --title) TITLE="${2:-}"; shift 2 ;;
    --note) notes+=("${2:-}"); shift 2 ;;
    --kind) KIND="${2:-bug}"; shift 2 ;;
    --create) CREATE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "不明な引数: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$TITLE" ] || { echo "✗ --title は必須です" >&2; usage >&2; exit 2; }

repo_name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
# 配布物の世代。どの版で起きたかが分からないと再現できない。
gen=$(grep -rhos 'harness-template v[0-9.]*' .claude .githooks 2>/dev/null | sort -u | tr '\n' ' ')
skill_dir="${CLAUDE_SKILL_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

# doctor の実際の出力を添付する。「こう出た」を再現材料として残すため。
doctor_out=""
if [ -x "$skill_dir/scripts/check.sh" ]; then
  doctor_out=$(bash "$skill_dir/scripts/check.sh" 2>&1 | sed 's/^/    /')
fi

body=$(cat <<EOF
## 状況

- 発生リポジトリ: \`$repo_name\`
- 配布物の世代: ${gen:-(未導入 / 刻印なし)}
- 種別: $KIND

$(for n in "${notes[@]+"${notes[@]}"}"; do printf -- '- %s\n' "$n"; done)

## そのときの doctor 出力

\`\`\`
${doctor_out:-(未取得)}
\`\`\`

---
*\`/harness:doctor\` の report.sh から起票*
EOF
)

if [ "$CREATE" -eq 0 ]; then
  echo "=== 下書き(まだ起票していません) ==="
  echo "リポジトリ: $UPSTREAM"
  echo "タイトル: [$KIND] $TITLE"
  echo
  echo "$body"
  echo
  echo "=== 起票するには同じコマンドに --create を付ける ==="
  exit 0
fi

command -v gh >/dev/null 2>&1 || { echo "✗ gh が無いため起票できません。上の下書きを手で起票してください" >&2; exit 0; }
gh issue create --repo "$UPSTREAM" --title "[$KIND] $TITLE" --body "$body" 2>&1 || {
  echo "✗ 起票に失敗しました。下書きは上に出ています" >&2; exit 0; }
