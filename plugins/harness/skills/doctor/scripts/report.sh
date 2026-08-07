#!/usr/bin/env bash
# harness-template v0.4.0 — 配布先で見つけた harness の欠陥を、配布元へ起票する。
#
# ⚠️ **2026-08-08 に全面的に作り直した。旧版は実際に情報を漏らした。**
#
#   旧版は `gh issue create` に **check.sh の出力を丸ごと**添付していた(`report.sh:56`)。
#   check.sh は指摘の根拠として **CLAUDE.md を grep した実際の行**を出す設計なので、
#   繋いだ瞬間に「配布先の CLAUDE.md の中身を公開 issue へ送る経路」になっていた。
#   **実害が出た**: private な cf-asc-dashbord から public な gigun-dev/claude-code の
#   issue #4 へ、CLAUDE.md の4行(うち1行は secrets 露出チェックに関する記述)・
#   本番データ破壊インシデントの詳細・commit SHA が公開された。#4 は削除したが、
#   **GH Archive が public イベントを毎時取り込むので取り消しにはならない。**
#
#   **2つの正しい設計が、繋いだ瞬間に漏洩経路になった**形。教訓は
#   「出力を添付するな」ではなく **「報告は2つの別物の混合物だと気づけ」**:
#
#     欠陥 = harness のもの。可視性は**配布元**に従う(公開でよい)
#     証拠 = 配布先のもの。可視性は**配布先**に従う
#
#   だから**証拠は配布先に置き、繋ぐのは ID だけ**にした。見える人だけが証拠を見られ、
#   見えない人にはそもそも存在が伝わらない。**可視性を人が判断しなくても、
#   置き場所が自動的に正しくなる。**(盆栽の7原則・原則7「その場に置くのは事実とポインタ」)
#
# ⚠️ **inbox のような新しい入れ物は作らない。**配布先で見つけた harness の欠陥は、
#   **配布元の「着手順」に起票すべき項目そのもの**。着手順は既に ID・完了条件・
#   証拠ゲート・アーカイブ・lint を持っている(= issue トラッカーの実体)。
#   `nd-tasks.sh` はパスを引数で取るのでリポジトリを跨いで書ける。
#   原則6「新機構を足す前に既存機構で届くか見る」—— 旧版はここを飛ばしていた。
set -uo pipefail

UPSTREAM="${HARNESS_UPSTREAM_REPO:-gigun-dev/claude-code}"
UPSTREAM_ND="${HARNESS_UPSTREAM_ND:-$HOME/ghq/github.com/gigun-dev/claude-code/docs/harness/next-directions.md}"

usage() {
  cat <<'EOF'
使い方: report.sh --title "<一行要約>" [--note "<補足>"]... [--kind bug|idea] [--github]

配布先で見つけた harness の欠陥を配布元へ起票する。**2つに分けて書く:**

  証拠 → ./.harness/reports/<ID>.md        このリポジトリ。**可視性はこのリポジトリに従う**
  欠陥 → 配布元の「着手順」へ --add        ID が採番され、/harness:status が読む

⚠️ 証拠にはこのリポジトリの CLAUDE.md の実際の行などが入る。**private なら private のまま**。
   配布元へ渡るのは欠陥の記述と ID だけで、証拠の中身は1バイトも渡らない。

オプション:
  --title "<要約>"  必須。着手順の項目名になる
  --note "<補足>"   何度でも。欠陥の説明(**配布元へ渡る = 公開されうる**)
  --kind bug|idea   既定 bug
  --github          GitHub issue も作る(opt-in)。
                    ⚠️ 配布先が private で配布元が public なら**拒否する**(fail-closed)
  --upstream-nd <path>  配布元の next-directions.md(既定は $HARNESS_UPSTREAM_ND)
  -h, --help        これ

終了コード:
  0  起票した / 下書きを出した
  2  使い方の誤り / 配布元の正典が見つからない / 可視性の食い違いで拒否した

⚠️ このスクリプトは `!` 記法に置かない —— 書き込みを行い、--github では外向きに通信する。
EOF
}

TITLE=""; KIND="bug"; GITHUB=0; notes=()
while [ $# -gt 0 ]; do
  case "$1" in
    --title) TITLE="${2:-}"; shift 2 ;;
    --note)  notes+=("${2:-}"); shift 2 ;;
    --kind)  KIND="${2:-bug}"; shift 2 ;;
    --github) GITHUB=1; shift ;;
    --upstream-nd) UPSTREAM_ND="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "不明な引数: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$TITLE" ] || { echo "✗ --title は必須です" >&2; usage >&2; exit 2; }

root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
repo_name=$(basename "$root")
gen=$(grep -rhos 'harness-template v[0-9][0-9.]*' "$root/.claude" "$root/.githooks" 2>/dev/null | sort -u | tr '\n' ' ')

[ -r "$UPSTREAM_ND" ] || {
  echo "✗ 配布元の正典が読めない: $UPSTREAM_ND" >&2
  echo "  clone されていないか、パスが違う。--upstream-nd で指定するか、下書きを手で起票すること:" >&2
  printf '\n  [%s] %s\n' "$KIND" "$TITLE" >&2
  for n in ${notes[@]+"${notes[@]}"}; do printf '  - %s\n' "$n" >&2; done
  exit 2
}

# --- 1. 配布元の着手順へ起票して ID を得る ---------------------------------
# ⚠️ ここへ渡すのは **--title と --note だけ**。doctor の出力も CLAUDE.md の行も渡さない。
#    「何が渡るか」を引数の形で人が見切れる状態にしておくのが、この設計の要点。
nd_tasks=""
for c in "${CLAUDE_SKILL_DIR:-}/../status/scripts/nd-tasks.sh" \
         "$(dirname "$0")/../../status/scripts/nd-tasks.sh"; do
  [ -r "$c" ] && { nd_tasks=$c; break; }
done
[ -n "$nd_tasks" ] || { echo "✗ nd-tasks.sh が見つからない(status skill が必要)" >&2; exit 2; }

criteria="配布元で再現し、直したうえで、配布先($repo_name)へ再配布して解消を確認する"
detail=$(for n in ${notes[@]+"${notes[@]}"}; do printf '%s ' "$n"; done)
add_out=$(bash "$nd_tasks" "$UPSTREAM_ND" --add "[$KIND] ${TITLE}${detail:+ — $detail}" --criteria "$criteria" 2>&1) || {
  echo "✗ 着手順への起票に失敗した:" >&2; echo "$add_out" >&2; exit 2; }
echo "$add_out"
ID=$(printf '%s' "$add_out" | grep -oE '`[A-Z]+-[0-9]+`' | head -1 | tr -d '`')
[ -n "$ID" ] || { echo "✗ 採番された ID を読み取れなかった(着手順は更新されている可能性がある)" >&2; exit 2; }

# --- 2. 証拠は**このリポジトリ**に置く ---------------------------------------
# doctor の出力はここでだけ取る。配布元へは渡さない。
mkdir -p "$root/.harness/reports"
evidence="$root/.harness/reports/${ID}.md"
skill_dir="${CLAUDE_SKILL_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
{
  printf '# %s — %s\n\n' "$ID" "$TITLE"
  printf '**配布元の着手順 `%s` の証拠。**この内容は %s のものなので、ここから出さないこと。\n\n' "$ID" "$repo_name"
  printf '- 発生リポジトリ: `%s`\n- 配布物の世代: %s\n- 種別: %s\n\n' "$repo_name" "${gen:-(未導入 / 刻印なし)}" "$KIND"
  for n in ${notes[@]+"${notes[@]}"}; do printf '%s\n' "- $n"; done
  printf '\n## そのときの doctor 出力\n\n```\n'
  if [ -r "$skill_dir/scripts/check.sh" ]; then bash "$skill_dir/scripts/check.sh" 2>&1; else echo "(check.sh が見つからず未取得)"; fi
  printf '```\n'
} > "$evidence"
echo "✓ 証拠を書いた: ${evidence#"$root"/}(**このリポジトリの外へ出さないこと**)"

# --- 3. GitHub issue は opt-in + 可視性の照合(fail-closed) -------------------
[ "$GITHUB" -eq 1 ] || { echo "  (GitHub issue は作っていない。要るなら --github)"; exit 0; }
command -v gh >/dev/null 2>&1 || { echo "⏭ gh が無いので issue は作れない。着手順への起票は済んでいる。" >&2; exit 0; }

# **公開状態は照会して確かめる。推測しない。**取れなければ拒否(fail-closed)——
# 「取れなかった」を「public ではない」と読むと、まさに漏らした側に倒れる。
here_vis=$(gh repo view --json visibility -q .visibility 2>/dev/null || echo UNKNOWN)
up_vis=$(gh repo view "$UPSTREAM" --json visibility -q .visibility 2>/dev/null || echo UNKNOWN)
echo "  可視性: このリポジトリ=$here_vis / 配布元($UPSTREAM)=$up_vis"
if [ "$here_vis" != PUBLIC ] && [ "$up_vis" = PUBLIC ]; then
  echo "✗ **拒否**: このリポジトリは $here_vis なのに配布元は PUBLIC。" >&2
  echo "   --note の文面も配布先の事情を含みうるので、GitHub へは出さない。" >&2
  echo "   着手順への起票($ID)は済んでいるので、配布元で作業するときに読める。" >&2
  exit 2
fi
if [ "$here_vis" = UNKNOWN ] || [ "$up_vis" = UNKNOWN ]; then
  echo "✗ **拒否**: 公開状態を照会できなかった($here_vis / $up_vis)。" >&2
  echo "   分からないときは出さない —— 推測して出す側に倒れると取り返しがつかない。" >&2
  exit 2
fi
body=$(printf '## %s\n\n- 発生リポジトリ: `%s`(可視性 %s)\n- 配布物の世代: %s\n\n%s\n\n---\n*証拠は発生リポジトリの `.harness/reports/%s.md`。配布元の着手順は `%s`。*\n' \
  "$TITLE" "$repo_name" "$here_vis" "${gen:-(未導入)}" \
  "$(for n in ${notes[@]+"${notes[@]}"}; do printf '%s\n' "- $n"; done)" "$ID" "$ID")
echo "=== 起票する内容(doctor 出力は含まれない) ==="; echo "$body"
gh issue create --repo "$UPSTREAM" --title "[$KIND] $ID $TITLE" --body "$body" 2>&1 \
  || echo "✗ issue の作成に失敗した。着手順への起票($ID)は済んでいる。" >&2
exit 0
