#!/usr/bin/env bash
# harness-template v0.5.0 — ハーネス導入の機械的な部分をすべて実行する。
#
# 設計意図(2026-08-05):
#   SKILL.md の散文手順を LLM に解釈させると、実行のたびに揺れる(手順の読み飛ばし・
#   chmod 忘れ・settings.json の壊し方が毎回違う)。**決定論的にできる部分は全部ここに置く。**
#   エージェントに残す仕事は「判断」だけ — コード配置の特定、検証コマンドの選定、
#   現在地の文章化。判断結果は引数として渡させ、作業自体はこのスクリプトが行う。
#
#   冪等。2回目以降は既存を壊さず差分だけ埋める(既に導入済みのリポジトリに
#   新しいテンプレート版を配るのにも使える)。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ASSETS="$SCRIPT_DIR/../assets"   # assets はこのスクリプトからの相対で解決する
                                 # (cwd は対象リポジトリなので相対パスでは見つからない)

CODE_PATHS=""      # rules の paths: に入れる glob(カンマ区切り)
CHECK_CMD=""       # pre-push で走らせる検証コマンド(未指定なら自動検出)
DOCS_DIR="docs"    # next-directions.md の置き場(docs/ が公開サイトのリポでは変える)
WITH_CODEX=0
SKIP_PREPUSH=0
WITH_LOG=0        # docs/log.md(追記専用アーカイブ)。小規模では git 履歴で足りるので既定 off

usage() {
  cat <<'EOF'
使い方: install.sh --code-paths "<glob,glob,...>" [options]

  --code-paths <globs>  必須。コメント方針 rules を自動ロードさせるパス(カンマ区切り)。
                        例: "src/**,test/**,migrations/**" / "Sources/**,Tests/**"
                        ⚠️ 言語に合っていないと一度もマッチせず silent に無効化される。
  --check-cmd <cmd>     pre-push で走らせる検証コマンド。省略時は package.json /
                        Makefile から自動検出する(make 依存は強制しない)。
  --docs-dir <dir>      next-directions.md の置き場(既定: docs)。
  --with-codex          .codex/ アダプタも配線する(Codex を併用するリポジトリ)。
  --with-log            docs/log.md(時系列の追記専用アーカイブ)も作る。長期・大規模向け。
                        小規模では git 履歴で足りるので、作っても書かれないファイルが増えるだけ。
  --skip-prepush        pre-push フックを入れない。
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --code-paths) CODE_PATHS="${2:-}"; shift 2 ;;
    --check-cmd) CHECK_CMD="${2:-}"; shift 2 ;;
    --docs-dir) DOCS_DIR="${2:-}"; shift 2 ;;
    --with-codex) WITH_CODEX=1; shift ;;
    --with-log) WITH_LOG=1; shift ;;
    --skip-prepush) SKIP_PREPUSH=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "不明な引数: $1" >&2; usage >&2; exit 2 ;;
  esac
done

git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "✗ git リポジトリではありません" >&2; exit 1; }
[ -n "$CODE_PATHS" ] || { echo "✗ --code-paths は必須です(言語に合った glob を渡すこと)" >&2; usage >&2; exit 2; }

TODO=()   # エージェントに残る「判断が要る作業」を集めて最後に出す
DID=()

# --- 1. next-directions.md(正典) --------------------------------------------
mkdir -p "$DOCS_DIR"
ND="$DOCS_DIR/next-directions.md"
if [ -e "$ND" ]; then
  # 既存を絶対に上書きしない(引き継ぎの正典を消すのは最悪の事故)。
  if grep -q '^<!-- session-head-end' "$ND"; then
    DID+=("$ND: 既存(マーカーあり)— 変更なし")
  else
    TODO+=("$ND に旧様式の内容がある。頭(現在地・着手順)を新設し、既存本文はカタログ部へ移し、行頭に '<!-- session-head-end -->' を入れる(無いとフックは警告モードのまま)")
  fi
else
  sed "s/{{DATE}}/$(date +%Y-%m-%d)/g" "$ASSETS/next-directions.md" > "$ND"
  DID+=("$ND: テンプレートから作成")
  TODO+=("$ND の {{CURRENT_STATE}} / {{NEXT_STEPS}} / {{CATALOG}} を、README・直近コミット・会話の文脈から埋める")
fi

# --- 1b. log.md(追記専用アーカイブ・任意) -----------------------------------
if [ "$WITH_LOG" -eq 1 ]; then
  LOG="$DOCS_DIR/log.md"
  if [ -e "$LOG" ]; then
    DID+=("$LOG: 既存 — 変更なし")
  else
    sed "s/{{DATE}}/$(date +%Y-%m-%d)/g" "$ASSETS/log.md" > "$LOG"
    DID+=("$LOG: 作成(時系列の追記専用アーカイブ)")
  fi
fi

# --- 2. SessionStart フック ---------------------------------------------------
mkdir -p .claude/hooks
cp "$ASSETS/session-start.sh" .claude/hooks/session-start.sh
chmod +x .claude/hooks/session-start.sh
DID+=(".claude/hooks/session-start.sh: 配置(既存があれば最新版へ更新)")

# settings.json への SessionStart 登録。既存の設定を壊さないよう Python で厳密にマージし、
# 同じコマンドのエントリが既にあれば追加しない(冪等)。
python3 - "$PWD/.claude/settings.json" <<'PY'
import json, os, sys
path = sys.argv[1]
cmd = 'bash "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/session-start.sh"'
data = {}
if os.path.exists(path):
    with open(path) as f:
        try:
            data = json.load(f)
        except json.JSONDecodeError:
            print("✗ .claude/settings.json が壊れています。手で直してから再実行してください", file=sys.stderr)
            sys.exit(1)
data.setdefault("$schema", "https://json.schemastore.org/claude-code-settings.json")
hooks = data.setdefault("hooks", {}).setdefault("SessionStart", [])
if not any(h.get("command") == cmd for entry in hooks for h in entry.get("hooks", [])):
    hooks.append({"matcher": "startup|clear|compact",
                  "hooks": [{"type": "command", "command": cmd}]})
with open(path, "w") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
DID+=(".claude/settings.json: SessionStart を冪等マージ")

# --- 3. コメント方針 rules ----------------------------------------------------
mkdir -p .claude/rules
if [ -e .claude/rules/comments.md ]; then
  DID+=(".claude/rules/comments.md: 既存 — 変更なし")
else
  # カンマ区切りの glob を YAML のリスト項目へ展開する。
  paths_yaml=$(printf '%s' "$CODE_PATHS" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed 's|^|  - "|;s|$|"|')
  python3 - "$ASSETS/comments-rule.md" .claude/rules/comments.md "$paths_yaml" <<'PY'
import sys
src, dst, paths = sys.argv[1], sys.argv[2], sys.argv[3]
body = open(src).read().replace('  - "{{CODE_PATHS}}"', paths)
open(dst, "w").write(body)
PY
  DID+=(".claude/rules/comments.md: 配置(paths を反映)")
  TODO+=(".claude/rules/comments.md の {{REPO_SPECIFIC_HOTSPOTS}} を、このリポジトリで経緯コメントが特に効く場所に置き換える(外部 API の非公式な叩き方・ドメインの癖・チューニング値など)")
fi

# --- 4. pre-push フック -------------------------------------------------------
if [ "$SKIP_PREPUSH" -eq 0 ]; then
  # 検証コマンドの自動検出。**make は「あれば使う」だけで前提にしない** —
  # Makefile を持たないリポジトリの方が多く、make を強制するとハーネスが入らなくなる。
  if [ -z "$CHECK_CMD" ]; then
    if [ -f package.json ] && python3 -c "import json,sys; sys.exit(0 if 'check' in json.load(open('package.json')).get('scripts',{}) else 1)" 2>/dev/null; then
      if [ -f bun.lock ] || [ -f bun.lockb ]; then CHECK_CMD="bun run check"; else CHECK_CMD="npm run check"; fi
    elif [ -f Makefile ] && grep -qE '^check:' Makefile; then
      CHECK_CMD="make check"
    elif [ -f package.json ] && python3 -c "import json,sys; sys.exit(0 if 'test' in json.load(open('package.json')).get('scripts',{}) else 1)" 2>/dev/null; then
      if [ -f bun.lock ] || [ -f bun.lockb ]; then CHECK_CMD="bun test"; else CHECK_CMD="npm test"; fi
    fi
  fi

  if [ -z "$CHECK_CMD" ]; then
    TODO+=("検証コマンドを自動検出できなかったため pre-push は未導入。--check-cmd を指定して再実行するか、CI と同じ検証を用意する")
  else
    mkdir -p .githooks
    python3 - "$ASSETS/pre-push" .githooks/pre-push "$CHECK_CMD" <<'PY'
import sys
src, dst, cmd = sys.argv[1], sys.argv[2], sys.argv[3]
open(dst, "w").write(open(src).read().replace("{{CHECK_COMMAND}}", cmd))
PY
    chmod +x .githooks/pre-push
    git config core.hooksPath .githooks
    DID+=(".githooks/pre-push: 配置(検証= $CHECK_CMD)+ core.hooksPath を配線")
    # 既に README に書いてあるなら催促しない(再実行のたびに済んだ TODO が出ると、
    # 出力全体が「読み飛ばしてよいもの」に見えてしまう)。
    if ! grep -rqs 'core.hooksPath' README.md Makefile package.json 2>/dev/null; then
      TODO+=("README に 'git config core.hooksPath .githooks' を書く(.git/config に入るため git 管理されず、clone ごとに1回必要)")
    fi
  fi
fi

# --- 5. AGENTS.md(他エージェント向けの入口) ----------------------------------
if [ -e AGENTS.md ] || [ -L AGENTS.md ]; then
  DID+=("AGENTS.md: 既存 — 変更なし")
elif [ -e CLAUDE.md ]; then
  ln -s CLAUDE.md AGENTS.md
  DID+=("AGENTS.md -> CLAUDE.md の symlink を作成")
else
  TODO+=("CLAUDE.md が無いため AGENTS.md を作れなかった。CLAUDE.md 作成後に 'ln -s CLAUDE.md AGENTS.md'")
fi

# --- 6. Codex アダプタ --------------------------------------------------------
if [ "$WITH_CODEX" -eq 1 ]; then
  mkdir -p .codex/hooks
  cp "$ASSETS/codex-hooks.json" .codex/hooks.json
  [ -L .codex/hooks/session-start.sh ] || ln -sf ../../.claude/hooks/session-start.sh .codex/hooks/session-start.sh
  if [ -f .codex/config.toml ] && grep -q 'hooks = true' .codex/config.toml; then :; else
    printf '\n[features]\nhooks = true\n' >> .codex/config.toml
  fi
  # 保守規約(Claude 側が正典・symlink で共有)を書き残す。これが無いと、次に触る人が
  # Codex 側を直接編集して正典が2つに割れる。
  [ -e .codex/README.md ] || cp "$ASSETS/codex-README.md" .codex/README.md
  # project skills があれば Codex からも同じ実体を見せる(.agents/skills/* -> .claude/skills/*)。
  if [ -d .claude/skills ]; then
    mkdir -p .agents/skills
    for s in .claude/skills/*/; do
      [ -d "$s" ] || continue
      n=$(basename "$s")
      [ -e ".agents/skills/$n" ] || ln -s "../../.claude/skills/$n" ".agents/skills/$n"
    done
    DID+=(".agents/skills/: .claude/skills/* への symlink を作成")
  fi
  DID+=(".codex/: hooks.json + session-start.sh symlink + config.toml + README を配線")
fi

# --- 6b. .gitignore(個人環境ファイルの流出防止) ------------------------------
# settings.local.json は permission allowlist などマシン固有の設定で、コミットすると
# 他人・他マシンへ個人環境が漏れる。plans も一時作業物。**実害があるので必ず入れる。**
for entry in ".claude/settings.local.json" ".claude/plans/"; do
  if ! grep -qxF "$entry" .gitignore 2>/dev/null; then
    if ! grep -q "claude local settings" .gitignore 2>/dev/null; then
      printf '\n# claude local settings(個人環境の設定。プロジェクト共有の設定は .claude/settings.json に置く)\n' >> .gitignore
    fi
    printf '%s\n' "$entry" >> .gitignore
    DID+=(".gitignore: $entry を追加")
  fi
done
# 既に追跡されてしまっている場合は gitignore が効かないので、明示的に知らせる。
if git ls-files --error-unmatch .claude/settings.local.json >/dev/null 2>&1; then
  TODO+=("⚠️ .claude/settings.local.json が既に git 追跡されている(個人環境の permission が共有される)。'git rm --cached .claude/settings.local.json' で追跡を外すこと")
fi

# --- 7. CLAUDE.md の定型節(存在チェックのみ。本文はエージェントが書く) --------
if [ ! -e CLAUDE.md ]; then
  TODO+=("CLAUDE.md を作成する(200行以下。プロジェクト一行説明 / 主要コマンド / アーキテクチャ要点 / 情報の書き分け方針 / 現在地・次の作業の2定型節)")
elif ! grep -q 'next-directions' CLAUDE.md; then
  TODO+=("CLAUDE.md に定型2節(情報の書き分け方針 / 現在地・次の作業=docs/next-directions.md が正典)を追記する")
fi

# --- 結果 ---------------------------------------------------------------------
echo "=== 実行した機械的作業 ==="
for d in "${DID[@]}"; do echo "  ✓ $d"; done
echo
if [ ${#TODO[@]} -gt 0 ]; then
  echo "=== 残りの作業(判断が要るのでエージェントが行う) ==="
  for t in "${TODO[@]}"; do echo "  □ $t"; done
  echo
fi
echo "=== 検証 ==="
echo "  bash .claude/hooks/session-start.sh    # 頭だけが出るか"
[ -x .githooks/pre-push ] && echo "  echo \"refs/heads/main \$(git rev-parse HEAD) refs/heads/main \$(git rev-parse HEAD)\" | .githooks/pre-push    # 検証が走るか"
exit 0
