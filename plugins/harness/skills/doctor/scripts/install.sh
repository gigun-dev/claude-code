#!/usr/bin/env bash
# harness-template v0.15.0 — ハーネス導入の機械的な部分をすべて実行する。
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
  # 着手順はチェックリスト形式(/harness:status が読む唯一の機械可読な節)。ID の接頭辞だけは
  # 人が決めるしかないので TODO に出す —— テンプレートの `X-` のままだと、どのプロジェクトの
  # 項目かが --all の横断一覧で判別できなくなる。
  TODO+=("$ND の着手順の ID 接頭辞 'X-' をプロジェクトの略号へ変える(例: caldav なら 'CD-1')。書式は節の先頭コメント参照。確認は /harness:status --lint")
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
# ⚠️ **素の cp ではなく、予算を展開して置く。**値の正典は plugins/harness/budgets.sh の
#    1箇所だけで、配布物はそれを**展開済みの形で**受け取る(コンパイルと同じ)。
#    こうすると (a) 配布先に実行時依存が生まれず (b) 値が複製されず
#    (c) ドリフトが構造的に起きない —— 検知器すら要らない(原則7 / 原則3)。
#    2026-08-08 まで素の cp で、同じ値が2箇所にあり、隣に「一致していること」という
#    散文の規律が置かれていた。単位の読み違いが5箇所へ伝播したのはそれが原因。
# shellcheck source=/dev/null
. "$(cd "$(dirname "$0")/../../.." && pwd)/budgets.sh"
sed -e "s|{{DOCS_DIR}}|$DOCS_DIR|g" \
    -e "s/{{CATALOG_MAX_LINES}}/$CATALOG_MAX_LINES/g" \
    -e "s/{{UPDATE_BLOCK_MAX}}/$UPDATE_BLOCK_MAX/g" \
    -e "s/{{HEAD_WARN_CHARS}}/$HEAD_WARN_CHARS/g" \
    -e "s/{{HEAD_HARD_CHARS}}/$HEAD_HARD_CHARS/g" \
    "$ASSETS/session-start.sh" > .claude/hooks/session-start.sh
# 展開漏れは**その場で落とす**。未展開のまま配ると、配布先で毎セッション黙って死ぬ。
# ⚠️ 検出は `{{NAME}}` の完全な形で行う。素の `{{` を探すと、テンプレ側にある
#    「未展開を検知する fail-loud ガード」自身(`case "$X" in *'{{'*)`)を拾って
#    **展開に成功しているのに失敗と言う**(2026-08-08 に実際に誤検知した)。
#    検知器が、別の検知器の存在そのものに反応した形。
if grep -qE '\{\{[A-Z_]+\}\}' .claude/hooks/session-start.sh; then
  echo "✗ session-start.sh のプレースホルダが展開しきれていません:" >&2
  grep -oE '\{\{[A-Z_]+\}\}' .claude/hooks/session-start.sh | sort -u | sed 's/^/    /' >&2
  echo "  budgets.sh に対応する変数を足してください。" >&2
  exit 1
fi
chmod +x .claude/hooks/session-start.sh
DID+=(".claude/hooks/session-start.sh: 配置(既存があれば最新版へ更新)")

# settings.json への SessionStart 登録。既存の設定を壊さないよう Python で厳密にマージし、
# 同じコマンドのエントリが既にあれば「追加」はしない(冪等)。
#
# ⚠️ matcher 文字列は「追加しない」だけでは冪外(冪等ではあるが古いままになる)。H-7
#   (docs/harness/next-directions.md): 公式に確認できたのは startup|resume|clear の3つ、
#   compact は実測で発火。--resume/--continue では「resume が matcher に無いと頭注入が
#   一度も走らない」ことが分かっている(assets/codex-hooks.json には既に resume が入って
#   おり、Claude 側だけの取りこぼしだった)。**fork は有効性が未確認なので足さない**
#   (投機で足すと、確認できていない前提を配布物に埋め込むことになる)。
#
#   旧実装は「同じコマンドのエントリがあれば何もしない」だったため、matcher の定数だけ
#   直しても**既に導入済みのリポジトリには新版が届かない**(install.sh は「冪等だから
#   新版の配布にも同じコマンドを使う」設計 — README・harness.md 参照)。これは
#   session-start.sh 本体を毎回上書きしているのと非対称で、放置すると settings.json だけ
#   世代が固定されたまま取り残される。そこで今回、同一コマンドのエントリを見つけたら
#   matcher が期待値と一致しているかも見て、違っていれば書き換える形にした。
#
#   「ユーザーが意図的に別の matcher にしている可能性」は認識している(例: fork を
#   独自に足している等)。それでも上書きする判断にしたのは、(a) install.sh は
#   SessionStart フックのように毎セッション自動実行されるものではなく、人(エージェント)
#   が明示的に叩く破壊的スクリプトであり実行前に内容を読める、(b) 書き換えたことを
#   DID に必ず出す(黙って上書きしない)、の2点で担保できると判断したため。
#   代替案として「一致しなければ TODO で警告するだけに留める」も検討したが、
#   それだと matcher 直し忘れが `paths:` 不一致と同じ「サイレント無効化」のまま
#   配布先に残り続ける — 今回直したい本題そのものなので採らなかった。
SS_STATUS=$(python3 - "$PWD/.claude/settings.json" <<'PY'
import json, os, sys
path = sys.argv[1]
cmd = 'bash "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/session-start.sh"'
matcher = "startup|resume|clear|compact"   # H-7。fork は有効性未確認のため含めない
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

# 同じコマンドを持つ既存エントリを探す(無ければ target は None のまま = 新規追加)。
target = None
for entry in hooks:
    if any(h.get("command") == cmd for h in entry.get("hooks", [])):
        target = entry
        break

if target is None:
    hooks.append({"matcher": matcher, "hooks": [{"type": "command", "command": cmd}]})
    status = "ADDED"
elif target.get("matcher") != matcher:
    old = target.get("matcher")
    target["matcher"] = matcher
    status = f"UPDATED\t{old}\t{matcher}"
else:
    status = "UNCHANGED"

with open(path, "w") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")

# bash 側が DID の文言を作れるよう、タブ区切りの1行だけを標準出力へ返す。
print(status)
PY
)
case "$SS_STATUS" in
  ADDED)
    DID+=(".claude/settings.json: SessionStart を追加(matcher=startup|resume|clear|compact)") ;;
  UPDATED$'\t'*)
    # "UPDATED\t旧matcher\t新matcher" を分解して、DID に旧→新を明示する(黙って
    # 書き換えない —— このリポジトリは「何をしたか」を必ず報告する規約のため)。
    IFS=$'\t' read -r _ ss_old ss_new <<<"$SS_STATUS"
    DID+=(".claude/settings.json: SessionStart の matcher を更新した($ss_old → $ss_new)") ;;
  UNCHANGED)
    DID+=(".claude/settings.json: SessionStart は既存 — matcher 一致のため変更なし") ;;
  *)
    echo "✗ .claude/settings.json の SessionStart マージで想定外の応答: $SS_STATUS" >&2
    exit 1 ;;
esac

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
    # .githooks/pre-push 自体は session-start.sh と同じ「完全にこちらが生成する管理下ファイル」
    # なので、常に最新版へ上書きする(既存の comments.md / AGENTS.md のような「ユーザーが書き足す
    # 文書」の skip-if-exists とは性質が違う)。core.hooksPath が別の値を指していても、
    # このファイル自体を置くこと自体は git から参照されないので無害 — 危険なのは
    # 次の core.hooksPath の書き換えだけ、という前提でここは常に上書きする。
    python3 - "$ASSETS/pre-push" .githooks/pre-push "$CHECK_CMD" <<'PY'
import sys
src, dst, cmd = sys.argv[1], sys.argv[2], sys.argv[3]
open(dst, "w").write(open(src).read().replace("{{CHECK_COMMAND}}", cmd))
PY
    chmod +x .githooks/pre-push

    # core.hooksPath は無条件に書き換えない(H-1: 既に別の値が設定されているリポジトリで
    # 黙って上書きすると、既存のフック一式が丸ごと無効化される。これは騒がしく失敗する
    # 他の不具合と違って気づかれずに壊れるので、最優先で塞ぐ)。
    # まず既存値を読み、3パターンに分岐する。
    #   - 未設定                → 従来どおり .githooks を設定(挙動変更なし)。
    #   - 既に ".githooks"      → 何もしない。同じ値を再設定しても実害は無いが、
    #                              「変更なし」であることが DID から分かるようにする。
    #   - 既に別の値            → 絶対に上書きしない。TODO で警告し、pre-push の配線は
    #                              人(エージェント)の判断に委ねる。
    existing_hooks_path=$(git config --get core.hooksPath 2>/dev/null || true)
    if [ -z "$existing_hooks_path" ]; then
      git config core.hooksPath .githooks
      DID+=(".githooks/pre-push: 配置(検証= $CHECK_CMD)+ core.hooksPath を配線")
    elif [ "$existing_hooks_path" = ".githooks" ]; then
      DID+=(".githooks/pre-push: 配置(検証= $CHECK_CMD)。core.hooksPath は既に .githooks — 変更なし")
    else
      DID+=(".githooks/pre-push: 配置(検証= $CHECK_CMD)。core.hooksPath は '$existing_hooks_path' のまま — 上書きせず")
      TODO+=("⚠️ core.hooksPath が既に '$existing_hooks_path' に設定されている(このハーネスが設定したものではない)。上書きすると既存のフック一式が黙って無効化されるため、このスクリプトは core.hooksPath を変更しなかった。'.githooks/pre-push' は生成済みなので、'$existing_hooks_path/pre-push' に手で配置するか、既存の仕組み(例: $existing_hooks_path 配下のディスパッチャ)へ組み込むこと")
    fi

    # 既に README に書いてあるなら催促しない(再実行のたびに済んだ TODO が出ると、
    # 出力全体が「読み飛ばしてよいもの」に見えてしまう)。
    # core.hooksPath が別の値のまま(上記の else 分岐)なら、'.githooks' を勧める文言は
    # 実態と食い違うので出さない — その場合は上の ⚠️ TODO が既に対応を促している。
    if [ -z "$existing_hooks_path" ] || [ "$existing_hooks_path" = ".githooks" ]; then
      if ! grep -rqs 'core.hooksPath' README.md Makefile package.json 2>/dev/null; then
        TODO+=("README に 'git config core.hooksPath .githooks' を書く(.git/config に入るため git 管理されず、clone ごとに1回必要)")
      fi
    fi
  fi
fi

# --- 5. CLAUDE.md ---------------------------------------------------------------
# 課題(2026-08-05 実測): ハーネスが配る他のファイルは全部テンプレートを持つのに、CLAUDE.md
# だけ「無ければ TODO で促すだけ」で本文をエージェント任せにしていた。結果、配布先8リポジトリで
# 別々に育った(store-redirect 23行 〜 dotfiles 169行、見出し構成は7通り)。刻印(先頭コメントの
# バージョン文字列)も無いので、どのリポジトリがどの世代か機械的に見分けられなかった。
#
# skip-if-exists(3番の comments.md と同じクラス): CLAUDE.md は「ユーザー(エージェント)が
# 書き足していく文書」であり、session-start.sh や pre-push のような「常に最新版へ差し替えて
# よい管理下ファイル」ではない。既にあるなら1バイトも変更しない —— 中身は人によって最初から
# テンプレとは違う書き方で育っている可能性があり、無条件上書きは執筆済みの文書を破壊する事故に
# なる。無ければテンプレを置き、プレースホルダを埋める判断だけ TODO としてエージェントに残す。
#
# ★ このセクションを AGENTS.md(次の6番)より前に置いた理由:
#   AGENTS.md 節は「CLAUDE.md があれば symlink を作る」ことで Codex 等の入口を用意する。
#   元の実装は AGENTS.md(旧5番)→ CLAUDE.md(旧7番、TODO を出すだけ)の順だったため、
#   CLAUDE.md が存在しない初回導入では AGENTS.md 節を通過する時点でまだ CLAUDE.md が無く、
#   symlink が作られないまま TODO で止まっていた(このリポジトリのルートに実際に AGENTS.md が
#   存在しない、という形で顕在化していた)。CLAUDE.md にテンプレができた今、順序を入れ替えて
#   ここで先に確定させれば、後続の AGENTS.md 節は初回導入でも必ず symlink を作れる。
#   (代替案: AGENTS.md 節を後ろへ動かす手もあったが、通し番号の付け替え範囲が大きくなるだけで
#   本質は同じなので、より小さい差分で済む「CLAUDE.md を前に出す」を採った。)
if [ -e CLAUDE.md ]; then
  DID+=("CLAUDE.md: 既存 — 変更なし")
  # 中身は書かないが、定型2節(情報の書き分け方針 / 現在地・次の作業)が無ければ追記を促す。
  # これは新規テンプレートでは自動的に満たされるが、旧来ユーザーが手書きした CLAUDE.md では
  # 欠けていることがあるための互換チェック。
  if ! grep -q 'next-directions' CLAUDE.md; then
    TODO+=("CLAUDE.md に定型2節(情報の書き分け方針 / 現在地・次の作業=docs/next-directions.md が正典)を追記する")
  fi
else
  cp "$ASSETS/CLAUDE.md" CLAUDE.md
  DID+=("CLAUDE.md: テンプレートから作成")
  # 「何を書かないか」の根拠は、テンプレート本体ではなくこの TODO に置く。理由: テンプレ内の
  # HTML コメントは埋め終わった後も**配布先で毎セッション読まれ続ける**のに、埋める作業が
  # 終わればエージェントの行動を1つも変えない = 純粋なコンテキストコストになる。埋めるときにだけ
  # 要る情報なので、埋めるときにだけ出るここに置くのが正しい(テンプレ側には1行の判定基準だけ残した)。
  TODO+=("CLAUDE.md の {{PROJECT_NAME}} / {{ONE_LINE_DESCRIPTION}} / {{CHECK_CMD}} / {{RUN_CMD}} / {{DEPLOY_CMD}} / {{NON_DEFAULT_CONVENTIONS}} を、README・package.json・直近コミットから埋める。判定は「その一文はエージェントの行動を変えるか」の一点。**書かないもの**: 技術スタック一覧(package.json 等で分かる)/ アーキテクチャ概観・ディレクトリツリー(ETH の A/B 実測 arXiv:2602.11988 —— 成果に効かずコストだけ +20%。README へ)/ コメント方針の中身(.claude/rules/comments.md と複製になりドリフトする。ポインタ1行のみ)/ 手順(skill へ)/「毎回必ず〜する」(hook へ)。80行以内を維持")
fi

# --- 6. AGENTS.md(他エージェント向けの入口) ----------------------------------
# 上の5番で CLAUDE.md は既存 or 新規作成のどちらかで必ず存在する状態になっているため、
# 通常はこの if 分岐が常に真になる。elif 以下は CLAUDE.md 作成に失敗した場合の防御的な分岐として
# 残す(set -euo pipefail 下では cp 失敗時点でスクリプト自体が止まるので、実運用では到達しない
# はずだが、削って silent な前提にするより残すコストの方が低い)。
if [ -e AGENTS.md ] || [ -L AGENTS.md ]; then
  DID+=("AGENTS.md: 既存 — 変更なし")
elif [ -e CLAUDE.md ]; then
  ln -s CLAUDE.md AGENTS.md
  DID+=("AGENTS.md -> CLAUDE.md の symlink を作成")
else
  TODO+=("CLAUDE.md が無いため AGENTS.md を作れなかった。CLAUDE.md 作成後に 'ln -s CLAUDE.md AGENTS.md'")
fi

# --- 7. Codex アダプタ --------------------------------------------------------
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

# --- 7b. .gitignore(個人環境ファイルの流出防止) ------------------------------
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

# CLAUDE.md のテンプレート配置・skip-if-exists 判定は上の5番へ統合済み
# (旧: ここに「存在チェックのみで本文はエージェント任せ」の節があったが、課題そのものだった
# ので廃止した。詳細は5番のコメント参照)。

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
