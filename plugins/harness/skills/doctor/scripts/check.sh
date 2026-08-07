#!/usr/bin/env bash
# harness-template v0.9.0 — ベストプラクティス遵守を機械的に検査する(読み取り専用)。
#
# 設計意図(2026-08-05):
#   機械判定できる項目だけを確定的に検査する。スキルやハーネスを作った直後に
#   「本当に守れているか」を答えるのが目的。
#
#   判定基準の出典はベストプラクティス記事(要旨は ../references/audit-*.md)。
#   ただし**閾値や規約は Claude Code 側の仕様変更で陳腐化する**ので、SKILL.md の
#   「判定基準そのものを疑うとき」で一次情報を確認したら、ここの数字も見直すこと。
#
#   読み取り専用・必ず exit 0(検査が作業を止めない)。指摘は ⚠️、致命は ✗、良好は ✓、
#   前提が欠けて検査できなかったものは ⏭。
#
# 追記(2026-08-07・H-10 / --help 整備):
#   (1) pre-push 検査の起点を `.githooks/` 固定から `git config core.hooksPath` の実値へ
#       変えた。詳細は該当箇所のコメント(「pre-push」節)を参照 —— dotfiles
#       (`core.hooksPath=git/hooks`)で「pre-push が無い」と誤検知していた実物のバグ修正。
#   (2) `CLAUDE_MD_MAX` を 200 → 80 に下げた。理由は変数定義の直上コメントを参照。
#   (3) `-h/--help` と未知引数の検知を追加(agentskills.io の script 規約に合わせる)。
#       この検査自体は元々「読み取り専用・必ず exit 0」が契約なので、それは変えていない
#       —— 引数の誤り(使い方の誤り)だけは exit 2 で区別する。
#
# 追記(2026-08-07・盆栽の7原則・原則4「検知器は黙って死ぬ前提で検知器を検証する」対応):
#   これまで「前提が欠けて検査できなかった」と「検査した結果、指摘が0件だった」が
#   出力上も終了コード上も区別できなかった —— python3 が無いと skill の description
#   長の判定が黙って通過し、git が無い/リポジトリの外だと `git ls-files` などが軒並み
#   空振りして **rules の paths が実は有効なのに「どのファイルにもマッチしない」と
#   誤って ✗ を出す**、という実物の壊れ方があった。
#   Why not 終了コードで表現しない: この検査は SKILL.md の `!` 記法で
#   **スキルを読んだだけで無条件に自動実行される**。`!` に置けるのは「必ず成功する
#   読み取り専用スクリプト」だけ、という境界をこのハーネスは明示的に守っている
#   (だから nd-tasks.sh のような fail-closed で非0を返す検知器は `!` に置いていない)。
#   非0を返せるようにするとこの境界そのものが壊れるので、終了コードは 0 のまま変えない。
#   代わりに:
#     (1) 前提(git・python3・ファイル読み取り)が欠けて検査できなかった箇所は `skip`
#         (記号 ⏭。⚠️/✗/✓ と区別できる絵文字を選んだ)を1件として出し、findings に数える。
#         「指摘0件」に埋もれさせない —— 0件は「無い」ではなく「壊れた」を疑わせるため。
#     (2) git 自体が無い/リポジトリの外という**この検査全体の土台が壊れているケース**は、
#         個々の git 呼び出しごとに guard を散らすと壊れ方が中途半端(一部だけ壊れた出力)
#         になるので、冒頭で丸ごと ⏭ 1件を出して打ち切る(finish 経由)。CLAUDE.md 単体の
#         チェックなら git が無くても pwd 起点で続行できなくはないが、rules / 個人設定分離 /
#         セッション引き継ぎ / pre-push の各節はいずれも git 前提で、その状態で続行すると
#         誤った ✗/⚠️ を積み増すほうが実害が大きいと判断した(親への論点として最終報告に残す)。
#     (3) 出力の最後に完走マーカー `=== 検査完了: N 件(check.sh vX.Y.Z) ===` を必ず出す。
#         Why not 完走判定も終了コードでやらないのか: 上と同じ理由(`!` の境界)に加え、
#         **途中で異常終了すると、それまでの部分出力がそのまま「完走した出力」に見えてしまう**
#         (原則4 の「黙って死ぬ」そのもの)。終了コードは常に 0 なので判定に使えないが、
#         最後の1行がこのマーカーかどうかは出力だけで機械的に判定できる —— マーカーが無ければ
#         それより前の内容も含めて信用しないこと。
set -uo pipefail

usage() {
  cat <<'EOF'
使い方: check.sh [-h|--help]

ベストプラクティス遵守を機械的に検査する(読み取り専用)。
CLAUDE.md・.claude/rules・個人設定の分離・セッション引き継ぎハーネス(next-directions.md /
SessionStart フック / pre-push)・skills を検査し、指摘を本文へ
⚠️(要検討)/ ✗(致命)/ ✓(良好)/ ⏭(前提が欠けて検査できなかった)/ 素の行(参考情報)で出す。

オプション:
  引数なし    通常の検査を実行する(既定)。
  -h, --help  これ。

使用例:
  bash check.sh    # git rev-parse --show-toplevel を起点にこのリポジトリを検査する

終了コード:
  0  常に。SKILL.md の `!` 記法は「必ず成功する読み取り専用スクリプト」だけを置ける
     境界を守るため、意図的にこの検査を失敗させない設計にしている(検査できなかった
     ことも指摘の1つとして本文の ⏭ で表現するだけで、非0では返さない)。
  2  使い方の誤り(不明な引数)。これは `!` 記法での自動実行時には起きない
     (呼び出し側が引数を渡さないため)ので、上の境界とは無関係に区別できる。

検査の完走判定(終了コードが常に0なので、代わりにこれで判定すること):
  - 出力の最終行が `=== 検査完了: N 件(check.sh vX.Y.Z) ===` になっているか確認する。
    この行が無ければ検査は途中で異常終了しており、それより前の出力も信用しないこと。
  - 本文中の ⏭ は「指摘0件」ではなく「前提(git・python3・ファイル読み取りなど)が
    欠けて検査できなかった」を表す。0件に見えても ⏭ があれば壊れている可能性を疑うこと。
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "不明な引数: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# --- 閾値 -----------------------------------------------------------------
# CLAUDE_MD_MAX: ルート CLAUDE.md の推奨上限行数。
#   2026-08-05 時点は記事の明示値である 200 行だったが、2026-08-07 に 80 行へ下げた。
#   理由: next-directions.md の「頭」の予算は 8,000B / 80行(nd-tasks.sh の HEAD_WARN_BYTES /
#   このリポジトリの .claude/rules/harness.md にある頭の予算と同じ数字に揃えてある)。
#   CLAUDE.md は**無条件・毎セッション全文ロード**される —— 頭は SessionStart フックの
#   出来次第で切り詰め・pointer 化ができるが、CLAUDE.md は Claude Code 本体が常に全文読む
#   ぶん、むしろ頭より条件が悪い。それなのに閾値が2.5倍緩いのは逆転している。
#   盆栽の7原則・原則3「⚠️ 閾値を上げて警告を消すのは禁止。下げ直すのは可」に従い、
#   緩い方(200)ではなく厳しい方(80)へ揃え直す。
#   ⚠️ この変更で新たに警告対象になる配布済みリポジトリがある(2026-08-07 実測:
#      swift-mcp-app 109行 / cf-asc-dashbord 89行 / figmate 88行 / dotfiles 169行)。
#      これは意図した結果 —— 個別に閾値を戻したり例外を作ったりしないこと。
CLAUDE_MD_MAX=80
SECTION_MAX=30         # CLAUDE.md 内の1節がこれを超えたら skill 化を検討
findings=0

note() { printf '  %s\n' "$*"; }
warn() { printf '  ⚠️ %s\n' "$*"; findings=$((findings+1)); }
bad()  { printf '  ✗ %s\n' "$*"; findings=$((findings+1)); }
ok()   { printf '  ✓ %s\n' "$*"; }
# skip: 「前提が欠けて検査できなかった」専用。⚠️/✗/✓ と見分けが付く ⏭ を使う。
# findings に数えるのは意図的 —— ここを note 相当(無カウント)にすると「指摘0件」に
# 埋もれ、原則4「0件は壊れたを疑う」が機能しなくなる。メッセージには必ず
# 「何が無くて検査できなかったか」を書くこと(次に何をすれば直るかが分かる形)。
skip() { printf '  ⏭ %s\n' "$*"; findings=$((findings+1)); }

# finish: 出力の最後に完走マーカーを1行出してから exit 0 する共通の出口。
# Why not 個々の exit 0 のままにしないのか: マーカーを出す場所が複数箇所に分散すると
# 書式が揃わなくなる/出し忘れる箇所ができる(実際に旧実装は `cd "$root" || exit 0` の
# ようにマーカー無しの出口が複数あった)。**完走マーカーは「途中で死んでいないか」を
# 出力だけで判定するための唯一の手がかり**なので、出口を1関数に集約して出し忘れを防ぐ。
finish() {
  echo
  if [ "$findings" -eq 0 ]; then
    echo "指摘なし。"
  else
    echo "指摘 ${findings} 件。各指摘の意味と直し方はこの skill の本文を参照。"
  fi
  echo "=== 検査完了: ${findings} 件(check.sh v0.9.0) ==="
  exit 0
}

# --- 前提: git -----------------------------------------------------------
# 以降ほぼ全ての節(rules の paths 判定・個人設定分離・セッション引き継ぎハーネス・
# pre-push・skills の一部)が `git ls-files` / `git log` / `git config` の結果を土台に
# している。旧実装は `git rev-parse --show-toplevel 2>/dev/null || pwd` で非リポジトリ時に
# 黙って pwd へフォールバックしていたが、それだと後続の git 系コマンドが軒並み空振りし、
# 「rules の paths がどのファイルにもマッチしない = ✗」のような**誤った致命判定**が
# 積み上がる(paths 自体は正しいのに、単に git ls-files が動いていないだけ)。
# ボツ案: git コマンドごとに個別 guard を挟む。→ 分散させると一部だけ壊れた中途半端な
# 出力になり、「どこまでが信用できる出力か」が読み手に伝わらない。土台が壊れているなら
# 検査全体を諦めて ⏭ 1件を出し切り上げるほうが、原則4「0件は壊れたを疑う」に忠実。
if ! command -v git >/dev/null 2>&1; then
  echo "=== harness:doctor ==="
  skip "git コマンドが見つからない。この検査は git 依存のため実行できなかった(PATH を確認すること)"
  finish
fi
if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "=== harness:doctor ==="
  skip "git リポジトリの外(または壊れたリポジトリ)なので実行できなかった。git リポジトリのルートで実行すること"
  finish
fi
root=$(git rev-parse --show-toplevel)
cd "$root" || { skip "リポジトリのルート ($root) へ移動できなかった"; finish; }
echo "=== harness:doctor — $(basename "$root") ==="

# --- CLAUDE.md ---------------------------------------------------------------
echo
echo "## CLAUDE.md(常時ロード = 全行が毎セッションのコスト)"
if [ ! -e CLAUDE.md ]; then
  warn "CLAUDE.md が無い(プロジェクトの基盤情報が毎回ゼロから推測される)"
elif [ ! -r CLAUDE.md ]; then
  # 権限で読めないファイルを「無い」扱いにすると存在しないと誤って伝わり、逆に
  # 中身をそのまま読もうとすると wc/grep が空文字を返して「0行=ok」のような
  # 誤った良好判定に化ける(旧実装はここが素通りだった)。読めない、と正直に言う。
  skip "CLAUDE.md の読み取り権限が無く検査できなかった"
else
  lines=$(wc -l < CLAUDE.md | tr -d ' ')
  if [ "$lines" -gt "$CLAUDE_MD_MAX" ]; then
    warn "CLAUDE.md が ${lines} 行(推奨 ${CLAUDE_MD_MAX} 行以下)。無条件・毎セッション全文ロードされるコストなので他より厳しめの閾値にしてある — 手順は skill、ファイル限定の制約は paths 付き rules へ"
  else
    ok "CLAUDE.md ${lines} 行(推奨 ${CLAUDE_MD_MAX} 行以下)"
  fi
  # 「毎回X したら Y」= 指示は必ず守られるとは限らない → Hook が正解(記事のアンチパターン)。
  if grep -nE '毎回|必ず[^。]*(実行|走ら|チェック)|する前に必ず|常に.*(実行|確認)' CLAUDE.md >/dev/null 2>&1; then
    warn "CLAUDE.md に「毎回/必ず〜する」系の自動化指示がある。指示は守られないことがあるので Hook(決定論的)へ移すのが正解:"
    grep -nE '毎回|必ず[^。]*(実行|走ら|チェック)|する前に必ず|常に.*(実行|確認)' CLAUDE.md | head -3 | sed 's/^/       /'
  fi
  # 「絶対に〜するな」= 長いセッションで破綻しうる → permissions/hooks で強制するのが正解。
  # ただし「コードから絶対に読み取れない」のような**可能表現**は禁止指示ではない。
  # 2026-08-05 に cf-asc-dashbord の CLAUDE.md(コメント方針の説明文)で誤検知したため、
  # 可能形(読み取れ/分から/でき/見え/得られ)が続く場合は除外する。
  prohibit_re='絶対に[^。]*(な|禁止)|してはいけない|してはならない|しないこと'
  capability_re='絶対に[^。]*(読み取れ|分から|でき|見え|得られ|判断でき)'
  if grep -nE "$prohibit_re" CLAUDE.md 2>/dev/null | grep -vE "$capability_re" | head -1 | grep -q .; then
    warn "CLAUDE.md に強い禁止指示がある。サーバー側(permissions / PreToolUse hook)で止める方が確実:"
    grep -nE "$prohibit_re" CLAUDE.md | grep -vE "$capability_re" | head -3 | sed 's/^/       /'
  fi
  # 長い手順が埋まっていないか(節ごとの行数)。
  awk '/^## /{if(name && n>'"$SECTION_MAX"') print "       " name " (" n " 行)"; name=$0; n=0; next} {n++} END{if(name && n>'"$SECTION_MAX"') print "       " name " (" n " 行)"}' CLAUDE.md > /tmp/.doctor_sections 2>/dev/null
  if [ -s /tmp/.doctor_sections ]; then
    warn "CLAUDE.md に長い節がある(${SECTION_MAX} 行超)。手順なら skill へ移すと常時コストが消える:"
    cat /tmp/.doctor_sections
  fi
  rm -f /tmp/.doctor_sections
fi

# --- rules -------------------------------------------------------------------
echo
echo "## .claude/rules(paths 付きなら該当ファイル操作時のみロード)"
if [ ! -d .claude/rules ]; then
  note "rules 無し"
else
  for f in .claude/rules/*.md; do
    [ -e "$f" ] || continue
    if [ ! -r "$f" ]; then
      # 読めないファイルを `head -1 | grep -q '^---'` にそのまま通すと、grep が
      # 空入力で「マッチしない」を返し「frontmatter が無い」という**間違った**指摘に
      # 化ける(実際は「有るかどうか読めていない」のに)。読めない、を先に言う。
      skip "$(basename "$f"): 読み取り権限が無く検査できなかった"
      continue
    fi
    if ! head -1 "$f" | grep -q '^---'; then
      warn "$(basename "$f"): frontmatter が無い = 常時ロード。paths を付けると無関係な作業でのコストが消える"
      continue
    fi
    if ! awk 'NR==1&&/^---/{f=1;next} f&&/^---/{exit} f' "$f" | grep -q '^paths:'; then
      warn "$(basename "$f"): paths: が無い = 常時ロード"
      continue
    fi
    # ⚠️ 最重要: glob が1つも実ファイルにマッチしないと silent に無効化される
    #    (swift-mcp-app で 2026-07-22 に実際に起きた。CLAUDE.md は「自動ロード」と
    #     書いてあったのに、TypeScript 用の src/** を Swift リポへ持ち込んで死んでいた)。
    globs=$(awk 'NR==1&&/^---/{f=1;next} f&&/^---/{exit} f' "$f" | awk '/^paths:/{p=1;next} p&&/^[a-zA-Z]/{exit} p' | grep -oE '"[^"]+"' | tr -d '"')
    matched=0
    for g in $globs; do
      # ** を含む glob は git ls-files のパターンで概ね評価できる
      if git ls-files -- "$g" 2>/dev/null | head -1 | grep -q .; then matched=1; break; fi
    done
    if [ "$matched" -eq 1 ]; then
      ok "$(basename "$f"): paths 有効(マッチするファイルあり)"
    else
      bad "$(basename "$f"): paths がどのファイルにもマッチしない = 一度もロードされない。glob をこのリポジトリの構成に合わせること: $(echo "$globs" | tr '\n' ' ')"
    fi
  done
fi

# --- 個人設定の混入 -----------------------------------------------------------
echo
echo "## 個人環境の分離"
if git ls-files --error-unmatch .claude/settings.local.json >/dev/null 2>&1; then
  bad ".claude/settings.local.json が git 追跡されている(個人の permission が共有される)。git rm --cached で外すこと"
elif grep -qs 'settings.local.json' .gitignore; then
  ok ".claude/settings.local.json は gitignore 済み"
else
  warn ".gitignore に .claude/settings.local.json が無い(生成されるとコミットされうる)"
fi

# --- ハーネス本体 -------------------------------------------------------------
echo
echo "## セッション引き継ぎハーネス"
nd=""
for cand in docs/next-directions.md docs/*/next-directions.md; do
  [ -f "$cand" ] && { nd="$cand"; break; }
done
if [ -z "$nd" ]; then
  warn "next-directions.md が無い(セッション間の引き継ぎが会話履歴頼みになる)。/harness:init で導入できる"
else
  ok "正典: $nd"
  if grep -q '^<!-- session-head-end' "$nd"; then
    head_lines=$(( $(grep -n '^<!-- session-head-end' "$nd" | head -1 | cut -d: -f1) - 1 ))
    [ "$head_lines" -gt 80 ] && warn "頭が ${head_lines} 行(目安 80)。棚卸しを検討" || ok "頭 ${head_lines} 行"
  else
    # pointer 方式(マーケットプレイス型)なら頭注入しないのでマーカーは不要。
    if grep -qs 'next-directions' .claude/hooks/session-start.sh 2>/dev/null; then
      note "マーカー無し(pointer 方式のフックなら正常)"
    else
      warn "$nd に session-head-end マーカーが無い(頭注入型フックでは fail-closed で止まる)"
    fi
  fi
  # 鮮度: 現在地の日付より新しいコミットがあるか。
  hd=$(grep -oE '20[0-9]{2}-[0-9]{2}-[0-9]{2}' "$nd" | head -1)
  lc=$(git log -1 --format=%cs 2>/dev/null)
  if [ -n "$hd" ] && [ -n "$lc" ] && [ "$lc" \> "$hd" ]; then
    warn "正典の日付($hd)より新しいコミット($lc)がある = 更新漏れの可能性"
  fi
fi
[ -e .claude/hooks/session-start.sh ] && ok "SessionStart フックあり" || warn "SessionStart フックが無い(正典が自動で思い出されない)"

# --- pre-push(H-10・2026-08-07 修正) -----------------------------------------
# ⚠️ Why not 「.githooks/pre-push の有無」を起点にしない: 旧実装はここが起点で、無ければ
#    即「pre-push が無い」と判定していた。**git 自身が pre-push をどこから読むかは
#    core.hooksPath で決まる**のに、起点をこのハーネスの配布物の置き場所(.githooks/)に
#    固定していたのが誤り。実例: dotfiles は `core.hooksPath=git/hooks` で運用しており
#    `git/hooks/pre-push` が実在して正しく動いているのに、`.githooks/pre-push` が無いという
#    理由だけで「pre-push が無い」と誤検知していた(2026-08-07 実測)。
#    あるべき形は git の設定を起点にすること: core.hooksPath があればそのディレクトリ、
#    無ければ git の既定(.git/hooks。ただし submodule / worktree では GIT_DIR が repo 直下の
#    .git ではないことがあるので `git rev-parse --git-path hooks` で正しく解決する)。
hp=$(git config --get core.hooksPath 2>/dev/null || true)
if [ -n "$hp" ]; then
  hookdir="$hp"                                                    # 相対でも絶対でも git はそのまま使う
else
  hookdir=$(git rev-parse --git-path hooks 2>/dev/null || printf '.git/hooks')
fi
active_pp="$hookdir/pre-push"

# .githooks/pre-push は「harness がここに置く配布物」の場所であって、git が実際に読む場所
# とは限らない。**「置いたのに配線し忘れている」は本物の壊れ方なので個別に先に判定し残す**
# (install.sh がここへ配置したのに core.hooksPath を向け忘れているケースが実在する。
#  H-1 の完了記録を参照)。ここを先に分岐させて一般判定と統合しないのは、二重報告
# (「pre-push が無い」+「.githooks/pre-push はあるが…」)を避けるため。
if [ -x .githooks/pre-push ] && [ -z "$hp" ]; then
  bad ".githooks/pre-push はあるが core.hooksPath 未設定 = 動いていない。git config core.hooksPath .githooks"
elif [ -x .githooks/pre-push ] && [ -n "$hp" ]; then
  # core.hooksPath は相対(.githooks)でも絶対(/path/to/repo/.githooks)でも設定できる。
  # 文字列一致で見ると絶対パス設定を「未配線」と誤検知するので、末尾で判定する。
  case "$hp" in
    .githooks|*/.githooks)
      if grep -qs 'harness-template v' .githooks/pre-push; then
        ok "pre-push 配線済み(harness-template)"
      else
        # 刻印(harness-template vX.Y.Z)が無い pre-push を harness 製と決めつけない。
        # 他人の文化を侵さないのがこのハーネスの方針 —— warn ではなく note(情報)に留める。
        note "pre-push はあるが harness 製ではない(.githooks 配下・刻印なし)"
      fi
      ;;
    *) warn ".githooks/pre-push はあるが core.hooksPath が別の場所($hp)を指している" ;;
  esac
elif [ -x "$active_pp" ]; then
  # ここに来るのは .githooks/pre-push が無いケース = core.hooksPath が指す先に
  # 別の pre-push が実在する(dotfiles の git/hooks/pre-push のような運用)。
  if grep -qs 'harness-template v' "$active_pp"; then
    ok "pre-push 配線済み(harness-template。hooksPath: ${hp:-既定 .git/hooks})"
  else
    # 「harness 製か」は刻印で判定する。刻印が無ければ他人の pre-push を尊重し、
    # 警告でも良好でもなく事実だけを伝える(置き換えの提案はしない)。
    note "pre-push はあるが harness 製ではない(hooksPath: ${hp:-既定 .git/hooks})。既存の運用を尊重する"
  fi
else
  warn "pre-push が無い(壊れたコードが main へ push されうる)"
fi

# --- skills ------------------------------------------------------------------
echo
echo "## skills"
# description 長の判定は python3 の YAML パースもどきに依存している(下記)。
# 無い環境(最小構成のコンテナ等)では従来 `python3 -c ... || echo 0` が黙って
# desc_len=0 を返し、「description が無い」という**間違った**指摘に化けていた
# ("description は書いてあるのに python3 が無いだけ" を区別できなかった実例)。
# ループの中で毎回 command -v するのは無駄なので、ここで1回だけ判定して使い回す。
has_python3=1
command -v python3 >/dev/null 2>&1 || has_python3=0
[ "$has_python3" -eq 1 ] || skip "python3 が無いため skill の description 長を検査できなかった(該当する全 skill が対象外。以下は名前/frontmatter/scripts 実行権限のみ検査する)"
found_skill=0
for s in .claude/skills/*/SKILL.md plugins/*/skills/*/SKILL.md; do
  [ -e "$s" ] || continue
  found_skill=1
  d=$(dirname "$s"); n=$(basename "$d")
  if [ ! -r "$s" ]; then
    skip "$n: SKILL.md の読み取り権限が無く検査できなかった"
    continue
  fi
  head -1 "$s" | grep -q '^---' || { bad "$n: frontmatter が無い"; continue; }
  fm=$(awk 'NR==1&&/^---/{g=1;next} g&&/^---/{exit} g' "$s")
  echo "$fm" | grep -q '^name:' || warn "$n: name が無い"
  # description は YAML の折り畳みスカラー(`description: >-` + 字下げ続き行)で書かれることが
  # 多い。1行目だけ見ると空に見えて「短い」と誤検知するので、続き行も連結して測る。
  if [ "$has_python3" -eq 0 ]; then
    note "$n: description 長は python3 が無いため未検査(上記の ⏭ を参照)"
  else
    desc_len=$(printf '%s' "$fm" | python3 -c '
import sys
lines = sys.stdin.read().split("\n")
out, capture = [], False
for ln in lines:
    if ln.startswith("description:"):
        rest = ln[len("description:"):].strip()
        if rest in (">", ">-", "|", "|-"):
            capture = True
        else:
            out.append(rest)
        continue
    if capture:
        if ln.startswith((" ", "\t")):
            out.append(ln.strip())
        else:
            capture = False
print(len(" ".join(out).strip()))
' 2>/dev/null || echo 0)
    if [ "${desc_len:-0}" -eq 0 ]; then
      warn "$n: description が無い(自動トリガーされない)"; continue
    fi
    [ "$desc_len" -lt 40 ] && warn "$n: description が ${desc_len} 字と短い。いつ使うかが書かれていないと自動で呼ばれない"
  fi
  # scripts があるなら実行可能か(chmod 忘れは頻出)
  for sc in "$d"/scripts/*.sh; do
    [ -e "$sc" ] || continue
    [ -x "$sc" ] || bad "$n: $(basename "$sc") に実行権限が無い"
  done
done
[ "$found_skill" -eq 1 ] || note "skill 無し"

finish
