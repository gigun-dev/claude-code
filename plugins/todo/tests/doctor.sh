#!/bin/sh
# =============================================================================
# plugins/todo のうち doctor の分のテスト — 素の POSIX sh。bash に依存しない。
# =============================================================================
# 走らせ方: sh plugins/todo/tests/run.sh(実行口はそちら。ここは単独でも走る)
#
# doctor は「カレントディレクトリからの探索」でリポジトリを見る(adr と同じ)ので、
# 呼び出しは作業場へ cd したサブシェルから行う。
# =============================================================================

set -u

here=$(cd "$(dirname "$0")" && pwd)
DOCTORBIN="$here/../bin/doctor"

pass=0
fail=0
workroot=$(mktemp -d "${TMPDIR:-/tmp}/doctor-tests.XXXXXX") || exit 1
trap 'rm -rf "$workroot"' EXIT INT TERM

setup() {
	W="$workroot/$1"
	rm -rf "$W"
	mkdir -p "$W"
}

t() { # t <name> <expected> <actual>
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf '✗ %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"
	fi
}

# 配布物の入口(shebang = macOS では bash 3.2)をそのまま叩く。adr.sh と同じ理由で
# `sh "$DOCTORBIN"` ではなく実行ファイルとして直に呼ぶ。
doctor() { (cd "$W" && "$DOCTORBIN" "$@"); }

write() { # write <相対パス> <行...>
	p="$W/$1"
	shift
	mkdir -p "$(dirname "$p")"
	printf '%s\n' "$@" >"$p"
}

# ---------------------------------------------------------------------------
# docs/adr が無い / あっても指示が指していない
# ---------------------------------------------------------------------------
setup no_adr_dir
write CLAUDE.md 'ここはただの説明。'
out=$(doctor check 2>&1)
rc=$?
t "docs/adr が無ければ 2 で指摘する" "2" "$rc"
t "docs/adr が無い旨を出す" "1" "$(printf '%s\n' "$out" | grep -c '決定の置き場(docs/adr など)が無い')"

setup adr_dir_unpointed
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10'
write CLAUDE.md '決定の置き場についてはここには何も書いていない。'
out=$(doctor check 2>&1)
rc=$?
t "docs/adr はあるが指示が指していなければ 2 で指摘する" "2" "$rc"
t "指していない旨を出す" "1" \
	"$(printf '%s\n' "$out" | grep -c '決定の置き場(docs/adr)はあるが.*指していない')"

setup adr_dir_pointed
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10'
write CLAUDE.md '決定は docs/adr/ に書く。'
t "docs/adr を指示が指していれば指摘しない" "0" "$(doctor check >/dev/null 2>&1; echo $?)"

setup adr_dir_pointed_agents
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10'
write AGENTS.md '決定は docs/adr/ に書く。'
t "AGENTS.md 側の紐付けでも通る" "0" "$(doctor check >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
# 正典として名指しされたファイルが実在しない
# ---------------------------------------------------------------------------
setup canon_missing
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10'
write CLAUDE.md '決定は docs/adr/ に書く。' 'このリポジトリの正典は `docs/spec.md` にある。'
out=$(doctor check 2>&1)
rc=$?
t "存在しない正典ファイルを 2 で指摘する" "2" "$rc"
t "指摘は名指ししたパスと行を出す" "1" \
	"$(printf '%s\n' "$out" | grep -c '指示が正典として名指ししているファイルが無い: docs/spec.md')"
t "行番号も出す" "1" "$(printf '%s\n' "$out" | grep -c 'CLAUDE.md:2')"

setup canon_exists
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10'
write docs/spec.md '中身'
write CLAUDE.md '決定は docs/adr/ に書く。' '正典は `docs/spec.md`。'
t "正典ファイルが実在すれば指摘しない" "0" "$(doctor check >/dev/null 2>&1; echo $?)"

setup canon_keyword_absent
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10'
write CLAUDE.md '決定は docs/adr/ に書く(この行が紐付け)。' '詳しくは `docs/notes.md` を参照(存在しない)。'
t "「正典」という語が無ければ、無いファイルへの言及でも指摘しない(誤検知回避)" "0" \
	"$(doctor check >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
# フック — 存在しないパス / 存在するが未登録
# ---------------------------------------------------------------------------
setup hook_missing
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10'
write CLAUDE.md '決定は docs/adr/ に書く。' 'フックは `.claude/hooks/session-start.sh` を使う。'
out=$(doctor check 2>&1)
rc=$?
t "存在しないフックのパスを 2 で指摘する" "2" "$rc"
t "指摘はパスと行を出す" "1" \
	"$(printf '%s\n' "$out" | grep -c '指示が前提にしているフックのパスが無い: .claude/hooks/session-start.sh')"

setup hook_unregistered
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10'
mkdir -p "$W/.claude/hooks"
: >"$W/.claude/hooks/session-start.sh"
write CLAUDE.md '決定は docs/adr/ に書く。' 'フックは `.claude/hooks/session-start.sh` を使う。'
out=$(doctor check 2>&1)
rc=$?
t "スクリプトはあるが設定に登録が無ければ 2 で指摘する" "2" "$rc"
t "未登録の指摘を出す" "1" \
	"$(printf '%s\n' "$out" | grep -c '指示が前提にしているフックが設定に登録されていない: .claude/hooks/session-start.sh')"

setup hook_registered_claude
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10'
mkdir -p "$W/.claude/hooks"
: >"$W/.claude/hooks/session-start.sh"
write .claude/settings.json '{"hooks": {"SessionStart": ".claude/hooks/session-start.sh"}}'
write CLAUDE.md '決定は docs/adr/ に書く。' 'フックは `.claude/hooks/session-start.sh` を使う。'
t "設定に登録があれば指摘しない" "0" "$(doctor check >/dev/null 2>&1; echo $?)"

setup hook_registered_githooks
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10'
(cd "$W" && git init -q && git config core.hooksPath .githooks)
mkdir -p "$W/.githooks"
: >"$W/.githooks/pre-push"
write CLAUDE.md '決定は docs/adr/ に書く。' 'pre-push は `.githooks/pre-push` にある。'
t "core.hooksPath が指すディレクトリなら登録されている扱い" "0" "$(doctor check >/dev/null 2>&1; echo $?)"

setup hook_unregistered_githooks
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10'
(cd "$W" && git init -q)
mkdir -p "$W/.githooks"
: >"$W/.githooks/pre-push"
write CLAUDE.md '決定は docs/adr/ に書く。' 'pre-push は `.githooks/pre-push` にある。'
out=$(doctor check 2>&1)
t "core.hooksPath が設定されていなければ .githooks は未登録扱い" "1" \
	"$(printf '%s\n' "$out" | grep -c '指示が前提にしているフックが設定に登録されていない: .githooks/pre-push')"

# ---------------------------------------------------------------------------
# 誤検知しない — 何も問題が無いリポジトリ
# ---------------------------------------------------------------------------
setup clean_repo
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10'
write todo.txt '2026-09-10 sample task id:0001'
(cd "$W" && git init -q && git config core.hooksPath .githooks)
mkdir -p "$W/.githooks" "$W/.claude/hooks" "$W/.codex/hooks"
: >"$W/.githooks/pre-push"
: >"$W/.claude/hooks/session-start.sh"
: >"$W/.codex/hooks/session-start.sh"
write .claude/settings.json '{"hooks": {"SessionStart": ".claude/hooks/session-start.sh"}}'
write .codex/config.toml 'hooks = [".codex/hooks/session-start.sh"]'
write CLAUDE.md \
	'決定は docs/adr/ に書く(正典は docs/adr/、コードの中身の話ではない)。' \
	'正典は `docs/adr/` の決定と `todo.txt` のタスクの 2 つ。' \
	'pre-push は `.githooks/pre-push`、セッション開始は `.claude/hooks/session-start.sh` と `.codex/hooks/session-start.sh`。' \
	'詳しい経緯は `docs/notes.md`(まだ無くても触れない話題)。'
out=$(doctor check 2>&1)
rc=$?
t "健全なリポジトリでは 0 で返る" "0" "$rc"
t "健全なリポジトリでは check: 問題なし を出す" "check: 問題なし" "$out"

# ---------------------------------------------------------------------------
# 導入は行わない — check は読むだけで何も書かない
# ---------------------------------------------------------------------------
setup readonly_check
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10'
write CLAUDE.md '決定の置き場についてはここには何も書いていない。'
before=$(cd "$W" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
	printf '%s %s\n' "$f" "$(wc -c <"$f" | tr -d ' ')"
done)
doctor check >/dev/null 2>&1
after=$(cd "$W" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
	printf '%s %s\n' "$f" "$(wc -c <"$f" | tr -d ' ')"
done)
t "check はファイルを 1 つも書かない(一覧とサイズが変わらない)" "$before" "$after"

# ---------------------------------------------------------------------------
# --help は正
# ---------------------------------------------------------------------------
setup help
t "--help は 0 で返る" "0" "$(doctor --help >/dev/null 2>&1; echo $?)"
t "引数なしは usage を stderr に出して 2" "2" "$(doctor >/dev/null 2>&1; echo $?)"
t "知らないコマンドは 2" "2" "$(doctor nope >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
# 素の /bin/sh — macOS ではこれが bash 3.2 で、新しい shell が通す書き方を落とす
# ---------------------------------------------------------------------------
setup binsh
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10'
write CLAUDE.md '決定は docs/adr/ に書く。'
if [ -x /bin/sh ]; then
	t "/bin/sh で読める(構文エラーが無い)" "0" \
		"$( (cd "$W" && /bin/sh "$DOCTORBIN" --help >/dev/null 2>&1); echo $?)"
	t "/bin/sh でも check が走る" "check: 問題なし" \
		"$(cd "$W" && /bin/sh "$DOCTORBIN" check 2>&1)"
else
	printf 'skip: /bin/sh が無い\n'
fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
