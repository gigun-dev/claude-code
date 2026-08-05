#!/usr/bin/env bash
# harness-template v0.6.0 — 導入判断に必要な事実を集める(読み取り専用)。
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
set -uo pipefail

say() { printf '%s\n' "$*"; }

git rev-parse --show-toplevel >/dev/null 2>&1 || { say "✗ git リポジトリではない(ハーネス導入不可)"; exit 0; }
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
if [ -f package.json ]; then
  python3 - <<'PY' 2>/dev/null || say "  package.json: 解析できず"
import json
s = json.load(open("package.json")).get("scripts", {})
for k in ("check", "test", "typecheck", "lint"):
    if k in s:
        print(f"  package.json scripts.{k}: {s[k]}")
PY
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
  if grep -q '^<!-- session-head-end' docs/next-directions.md; then
    say "  next-directions.md: あり(マーカーあり・頭 $(( $(grep -n '^<!-- session-head-end' docs/next-directions.md | head -1 | cut -d: -f1) - 1 )) 行 / 全 $(wc -l < docs/next-directions.md) 行)"
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
  say "  docs/log.md: あり($(wc -l < docs/log.md | tr -d ' ') 行)"
else
  say "  docs/log.md: なし(コミット数 $(git rev-list --count HEAD 2>/dev/null || echo 0) — 長期プロジェクトなら --with-log を検討)"
fi
say "  配布物の世代: $(grep -rhos 'harness-template v[0-9.]*' .claude .githooks 2>/dev/null | sort -u | tr '\n' ' ' || echo '(未導入)')"

# --- 現在地の材料(next-directions の {{CURRENT_STATE}} 用) --------------------
say ""
say "## 現在地の材料(next-directions に書く材料)"
say "  直近コミット:"
git log --oneline -5 2>/dev/null | sed 's/^/    /'
say "  未コミット: $(git status --porcelain 2>/dev/null | wc -l | tr -d ' ') ファイル"
git status --short 2>/dev/null | head -8 | sed 's/^/    /'
say "  ブランチ: $(git branch --show-current 2>/dev/null) / upstream: $(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || echo 'なし')"

exit 0
