#!/usr/bin/env bash
# harness-template v0.11.0 — 導入判断に必要な事実を集める(読み取り専用)。
#
# 設計意図(2026-08-05):
#   SKILL.md の `!` 記法から、スキル読み込み時に**無条件で**実行される。したがって:
#   - **絶対に何も変更しない。** `!` は「スキルを読んだだけ」でも走るので、破壊的な
#     install.sh をここに置いてはいけない(読むつもりが repo が変わる事故になる)。
#   - **絶対に失敗しない。** 何が起きても exit 0(スキル読み込み自体を壊さない)。
#   - **出力を絞る。** 毎回コンテキストに載るので、判断に要る事実だけを短く出す。
#
#   狙いは「調査の決定論化」— 手順書に散文で「言語を確認せよ」と書くと読み飛ばしが起きるが、
#   ここに書けば必ず同じ検査が走る。判断そのものはモデルに残す。
#
# 追記(2026-08-07): `-h/--help` と未知引数の検知を追加(agentskills.io の script 規約に
#   合わせる)。**`!` 記法での自動実行という契約は変えていない** —— 引数無しで呼ばれた
#   ときの挙動(=無条件で調査を実行し必ず exit 0)は従来のまま。使い方の誤り(不明な引数)
#   だけを exit 2 で区別する。
#
# 追記(2026-08-07・盆栽の7原則・原則4「検知器は黙って死ぬ前提で検知器を検証する」対応):
#   「絶対に失敗しない」の実装が `2>/dev/null` と `|| true` の多用だったため、前提
#   (git・python3・ファイル読み取り)が欠けても**何も言わずに事実が1件減るだけ**だった
#   —— 導入判断をする側からは「その事実は無かった」のか「調べられなかった」のか
#   区別が付かない。git が丸ごと使えない場合は最悪で、旧実装は「git リポジトリではない」
#   の1行だけを ✗ で出して終わっており、「git コマンド自体が無い」場合と「git はあるが
#   このディレクトリはリポジトリの外」の場合が同じ文言になっていた。
#   Why not 終了コードで表現しないのか: この調査は SKILL.md の `!` 記法で
#   **スキルを読んだだけで無条件に自動実行される**契約であり、`!` に置けるのは
#   「必ず成功する読み取り専用スクリプト」だけという境界を守るため。非0を返せるように
#   するとこの境界が崩れるので、終了コードは 0 のまま変えない。代わりに:
#     (1) 前提が欠けて調べられなかった箇所は `skip`(記号 ⏭)で明示し、末尾の完走マーカーに
#         件数を出す(0件なら「何も削れず全部調べられた」ことがそのまま分かる)。
#     (2) 出力の最後に完走マーカー `=== 調査完了: skip N 件(survey.sh vX.Y.Z) ===` を
#         必ず出す。終了コードが常に0なので、途中で異常終了しても検知できない
#         —— 最後の1行がこのマーカーかどうかだけが出力上の完走判定の手がかりになる。
#
# 追記(2026-08-08・敵対的検証で発覚した SIGPIPE 問題の修正):
#   check.sh と同じ壊れ方が survey.sh にもあった。「必ず exit 0」の契約は SKILL.md の
#   `!` 記法から**無条件**で自動実行されるために存在するが、出力を `head` 等で
#   打ち切られると SIGPIPE を受け取り、trap していなければ既定動作(プロセス終了)で
#   **141**(128+13)を返す —— 契約違反の実例。
#   実測(このリポジトリで): `bash survey.sh | head -3; echo "rc=${PIPESTATUS[0]}"` → rc=141。
#   直し方・副作用の検討は check.sh の同名の追記コメントと同じ(読み取り専用スクリプトが
#   標準出力への書き込みだけを諦める形になるので、状態が壊れる経路は無い)。
#   実測の副作用も check.sh と同じ: 適用後は rc=0 になるが、閉じたパイプへの書き込みの
#   たびに `printf: write error: Broken pipe` 等が標準エラーへ複数回出る。`!` 記法の
#   通常実行では発生せず、ユーザーが手動で出力を打ち切った場合だけの副作用なので許容する。
set -uo pipefail
# ⚠️ 「常に exit 0」の契約を守るための最後のピース。上の追記コメントを参照。
#    このスクリプトも check.sh と同じく読み取り専用(ファイルへは1バイトも書かない)
#    なので、SIGPIPE を無視した結果の書き込み失敗は「出力が途中で見えなくなる」
#    だけで、状態が壊れる経路は無い。
trap '' PIPE

usage() {
  cat <<'EOF'
使い方: survey.sh [-h|--help]

harness 導入判断に必要な事実を集める(読み取り専用)。
SKILL.md の `!` 記法から**無条件で**実行される —— 何も変更せず、必ず成功する契約。
コード配置(拡張子分布・トップ階層)/ 検証コマンドの候補(package.json・Makefile)/
docs/ の用途(公開サイトかどうか)/ 既存ハーネスの状態(初回導入か再導入か・世代刻印)/
現在地の材料(直近コミット・未コミット・ブランチ)を出す。

オプション:
  引数なし    通常の調査を実行する(既定)。
  -h, --help  これ。

使用例:
  bash survey.sh    # git rev-parse --show-toplevel を起点にこのリポジトリを調査する

終了コード:
  0  常に。SKILL.md の `!` 記法は「必ず成功する読み取り専用スクリプト」だけを置ける
     境界を守るため、意図的にこの調査を失敗させない設計にしている(調べられなかった
     ことも本文の ⏭ で表現するだけで、非0では返さない)。
  2  使い方の誤り(不明な引数)。`!` 記法での自動実行時には起きない。

調査の完走判定(終了コードが常に0なので、代わりにこれで判定すること):
  - 出力の最終行が `=== 調査完了: skip N 件(survey.sh vX.Y.Z) ===` になっているか確認する。
    この行が無ければ調査は途中で異常終了しており、それより前の出力も信用しないこと。
  - 本文中の ⏭ は「前提(git・python3・ファイル読み取りなど)が欠けて調べられなかった」を
    表す。N が 0 なら全項目を調べられたということ。
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "不明な引数: $1" >&2; usage >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
# skip: 「前提が欠けて調べられなかった」専用。survey.sh は判断ではなく事実の収集が
# 仕事なので「findings」ではなく「skip」という語で数える —— 0 なら「何も削れず
# 全部調べられた」ことがそのまま伝わる。記号は ⏭(check.sh / tidy.sh と共通)。
skips=0
skip() { printf '  ⏭ %s\n' "$*"; skips=$((skips+1)); }
# finish: 出力の最後に完走マーカーを出してから exit 0 する共通の出口。
# 出口を1関数に集約する理由は check.sh / tidy.sh と同じ(マーカーの出し忘れ防止)。
finish() {
  say ""
  say "=== 調査完了: skip ${skips} 件(survey.sh v0.11.0) ==="
  exit 0
}

# --- 前提: git -------------------------------------------------------------
# 旧実装は「git リポジトリではない」1行だけを ✗ で出していたが、これは
# 「git コマンド自体が無い」場合と「git はあるがこのディレクトリはリポジトリの外」
# 場合を同じ文言で潰していた —— 前者は環境の問題、後者は呼び出し場所の問題で
# 対処が違うので分ける。またこの1行以降の全節が `git ls-files` / `git log` 等に
# 依存しているため、ここが壊れているなら調査全体を諦めて finish する(check.sh の
# 「前提: git」節と同じ判断。理由もそちらを参照)。
if ! command -v git >/dev/null 2>&1; then
  skip "git コマンドが見つからない。この調査は git 依存のため実行できなかった(PATH を確認すること)"
  finish
fi
if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  skip "git リポジトリの外(または壊れたリポジトリ)。ハーネス導入判断のための調査を実行できなかった"
  finish
fi
root=$(git rev-parse --show-toplevel)
say "リポジトリ: $root"

# --- コード配置(--code-paths の判断材料) -------------------------------------
say ""
say "## コード配置(--code-paths の材料)"
# 追跡ファイルの拡張子分布から主言語を推定する。ディレクトリ名の慣習は言語で違うので、
# 「src/** で決め打ち」を避けるためにここで実物を見る。
git ls-files 2>/dev/null | sed -n 's/.*\.\([a-zA-Z0-9]\{1,6\}\)$/\1/p' | sort | uniq -c | sort -rn | head -6 | sed 's/^/  /'
say "  トップ階層のディレクトリ:"
git ls-files 2>/dev/null | awk -F/ 'NF>1{print $1}' | sort -u | head -12 | sed 's/^/    /'

# --- 検証コマンド(--check-cmd の判断材料) ------------------------------------
say ""
say "## 検証コマンドの候補(--check-cmd の材料。make は前提にしない)"
# python3 が無いと package.json の scripts を解析できない。旧実装は
# `python3 - <<PY 2>/dev/null || say "  package.json: 解析できず"` で、python3 が
# 無いケースと package.json が壊れた JSON なケースが同じ文言に潰れていた
# (このハーネスが問題提起そのものに挙げている実例と同型)。前者は ⏭、後者は
# 「解析できず」のまま残す(JSON 自体の異常はこの調査の対象外の情報なので note 相当)。
has_python3=1
command -v python3 >/dev/null 2>&1 || has_python3=0
if [ -f package.json ]; then
  if [ "$has_python3" -eq 0 ]; then
    skip "package.json はあるが python3 が無いため scripts を解析できなかった(手動で確認すること)"
  else
    python3 - <<'PY' 2>/dev/null || say "  package.json: 解析できず(JSON として不正な可能性)"
import json
s = json.load(open("package.json")).get("scripts", {})
for k in ("check", "test", "typecheck", "lint"):
    if k in s:
        print(f"  package.json scripts.{k}: {s[k]}")
PY
  fi
  [ -f bun.lock ] || [ -f bun.lockb ] && say "  → bun 系(bun run <script>)" || say "  → npm 系(npm run <script>)"
fi
[ -f Makefile ] && grep -E '^(check|test|verify):' Makefile 2>/dev/null | sed 's/^/  Makefile ターゲット: /'
[ -f package.json ] || [ -f Makefile ] || say "  (package.json も Makefile も無い — 検証コマンドは要相談)"

# --- docs/ の用途(公開サイトなら next-directions を置いてはいけない) ---------
say ""
say "## docs/ の用途"
if [ -d docs ]; then
  if ls docs/docs.json docs/mkdocs.yml docs/.vitepress docs/docusaurus.config.* 2>/dev/null | head -1 | grep -q .; then
    say "  ⚠️ docs/ は公開サイトのソースの可能性(内部メモが公開される)。--docs-dir で退避先を相談すること"
  else
    say "  docs/ あり(公開サイト設定は検出されず)"
  fi
else
  say "  docs/ なし(新規作成される)"
fi

# --- 既存ハーネスの状態(冪等な再実行か、初回導入か) --------------------------
say ""
say "## 既存ハーネスの状態"
nd=$(ls docs/next-directions.md 2>/dev/null || true)
if [ -n "$nd" ]; then
  if [ ! -r docs/next-directions.md ]; then
    # 読めないファイルに grep すると「マーカーが無い」と誤読される
    # (check.sh の CLAUDE.md 節と同型の壊れ方)。読めない、と正直に言う。
    skip "docs/next-directions.md の読み取り権限が無く検査できなかった"
  elif grep -q '^<!-- session-head-end' docs/next-directions.md; then
    # 頭のサイズは**文字と概算トークン**で出す(行はどの機構も使っていない代理指標。
    # 判断規則は docs/principles.md 規則8)。全体は行のままでよい —— 全文は注入されないので
    # ここで見たいのは「人が読み通せる長さか」だから。**単位は機構ごとに選ぶ。**
    _m=$(grep -n '^<!-- session-head-end' docs/next-directions.md | head -1 | cut -d: -f1)
    _h=$(sed -n "1,$((_m - 1))p" docs/next-directions.md)
    _c=$(printf '%s' "$_h" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' ')
    _a=$(printf '%s' "$_h" | LC_ALL=C tr -cd '\000-\177' | wc -c | tr -d ' ')
    say "  next-directions.md: あり(マーカーあり・頭 ${_c} 字 / ≒$(( (_a * ${HARNESS_TOK_ASCII_PCT:-35} + (_c - _a) * ${HARNESS_TOK_WIDE_PCT:-140}) / 100 )) tok(${HARNESS_TOKENIZER_LABEL:-Claude 4.7+} 換算) / 全 $(wc -l < docs/next-directions.md | tr -d ' ') 行)"
    unset _m _h _c _a
  else
    say "  ⚠️ next-directions.md: あるがマーカー無し(旧様式 — 上書きせずマイグレーションが要る)"
  fi
else
  say "  next-directions.md: なし(新規)"
fi
for f in .claude/hooks/session-start.sh .claude/rules/comments.md .githooks/pre-push CLAUDE.md AGENTS.md; do
  [ -e "$f" ] || [ -L "$f" ] && say "  $f: あり" || say "  $f: なし"
done
say "  core.hooksPath: $(git config core.hooksPath || echo '未設定')"
[ -d .codex ] && say "  .codex/: あり(--with-codex 推奨)" || say "  .codex/: なし"
# log.md は「大きく育ったリポジトリだけ」に入れる。小規模では git 履歴で足りるので、
# 作っても書かれないファイルが増えるだけ(判断材料としてコミット数を出す)。
if [ -e docs/log.md ]; then
  if [ -r docs/log.md ]; then
    say "  docs/log.md: あり($(wc -l < docs/log.md | tr -d ' ') 行)"
  else
    skip "docs/log.md の読み取り権限が無く検査できなかった"
  fi
else
  say "  docs/log.md: なし(コミット数 $(git rev-list --count HEAD 2>/dev/null || echo 0) — 長期プロジェクトなら --with-log を検討)"
fi
# 配布物の世代刻印。**2026-08-08 に2つのバグを直した(H-3 後半)。**
#
#  (1) 正規表現が `harness-template v[0-9.]*` で、`[0-9.]*` が**0文字にマッチする**。
#      その結果 `.claude/rules/harness.md` の散文
#      「どこが古いかは `grep -r "harness-template v"` で分かる」を拾い、
#      バージョン番号の無い `harness-template v` を「世代」として出していた。
#      **配布物を1つも持たないリポジトリで「導入済みに見える」**という、
#      検知器が黙って嘘をつくパターン。→ 数字を1桁以上必須にする。
#
#  (2) `... | tr '\n' ' ' || echo '(未導入)'` の `||` が**永久に発火しない**。
#      `||` はパイプライン全体の終了コード = 最後の `tr` のものを見るので、grep が
#      1件も見つけずに 1 を返しても `tr` は 0 を返す。**未導入のとき空文字が出るだけで
#      「未導入」とは一度も言えていなかった。** → 変数に取ってから空判定する。
#
# ⚠️ この2つは**同じ行に同居していた**。(1) が (2) を隠していた —— 散文が必ず1件
#    マッチするので空になることが無く、(2) のバグが表に出なかった。
#    **検知器のバグは互いを隠す**(原則4)。1つ直したらもう一度動かして確かめること。
gen=$(grep -rhos 'harness-template v[0-9][0-9.]*' .claude .githooks 2>/dev/null | sort -u | tr '\n' ' ')
gen=${gen% }
say "  配布物の世代: ${gen:-(未導入 — 刻印を持つ配布物が .claude/ にも .githooks/ にも無い)}"

# --- 現在地の材料(next-directions の {{CURRENT_STATE}} 用) --------------------
say ""
say "## 現在地の材料(next-directions に書く材料)"
say "  直近コミット:"
git log --oneline -5 2>/dev/null | sed 's/^/    /'
say "  未コミット: $(git status --porcelain 2>/dev/null | wc -l | tr -d ' ') ファイル"
git status --short 2>/dev/null | head -8 | sed 's/^/    /'
say "  ブランチ: $(git branch --show-current 2>/dev/null) / upstream: $(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || echo 'なし')"

finish
