#!/bin/sh
# =============================================================================
# plugins/todo のうち adr の分のテスト — 素の POSIX sh。bash に依存しない。
# =============================================================================
# 走らせ方: sh plugins/todo/tests/run.sh(実行口はそちら。ここは単独でも走る)
#
# 各テストは自分専用の一時ディレクトリをリポジトリ相当の作業場にする。
# ADR の置き場を**カレントディレクトリからの探索**で決めるコマンドなので、
# 呼び出しは必ず作業場へ cd したサブシェルから行う。
# =============================================================================

set -u

here=$(cd "$(dirname "$0")" && pwd)
ADRBIN="$here/../bin/adr"

pass=0
fail=0
workroot=$(mktemp -d "${TMPDIR:-/tmp}/adr-tests.XXXXXX") || exit 1
trap 'rm -rf "$workroot"' EXIT INT TERM

setup() {
	W="$workroot/$1"
	rm -rf "$W"
	mkdir -p "$W"
	unset ADR_DIR
}

t() { # t <name> <expected> <actual>
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf '✗ %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"
	fi
}

# 作業場から呼ぶ。ADR_DIR は環境から引き継ぐ(上書きテスト用)。
#
# ⚠️ `sh "$ADRBIN"` ではなく**実行ファイルとして直に呼ぶ**。前者は PATH 上の sh
# (このリポジトリでは Nix の新しい shell)で走ってしまい、shebang が指す
# /bin/sh —— macOS では bash 3.2 —— で一度も走らない。2026-09-10 に実際、
# `$( … )` の中の heredoc を bash 3.2 が誤解して構文エラーになるのに、テストは
# 39 件すべて緑だった。テストは配布物の入口をそのまま叩くこと。
adr() { (cd "$W" && "$ADRBIN" "$@"); }

# 1 件書く。write <相対パス> <中身...>
write() {
	p="$W/$1"
	shift
	mkdir -p "$(dirname "$p")"
	printf '%s\n' "$@" >"$p"
}

# ---------------------------------------------------------------------------
# ls — 番号順。日付順でも名前順でもない
# ---------------------------------------------------------------------------
setup ls_order
write docs/adr/0002-use-manual-sql.md '# Use manual SQL instead of an ORM' '' '2026-08-01 に決めた。ORM は N+1 を隠すため。'
write docs/adr/0010-adopt-a-monorepo.md '# Adopt a monorepo' '' 'Date: 2026-07-01' '' 'One repo.'
write docs/adr/0001-pick-postgres.md '# Pick Postgres' '' 'Date: 2026-09-10'
t "ls は番号順に出す(日付順ではない)" \
	"2026-09-10 0001-pick-postgres accepted Pick Postgres
2026-08-01 0002-use-manual-sql accepted Use manual SQL instead of an ORM
2026-07-01 0010-adopt-a-monorepo accepted Adopt a monorepo" \
	"$(adr ls)"
t "ls は 10 件を超えても文字列順でなく数値順(0010 は 0002 の後ろ)" \
	"0001-pick-postgres 0002-use-manual-sql 0010-adopt-a-monorepo" \
	"$(adr ls | awk '{ printf "%s%s", (NR > 1 ? " " : ""), $2 } END { print "" }')"

# ---------------------------------------------------------------------------
# ls — status の出どころ: Status: 行 / frontmatter / Superseded by / 既定
# ---------------------------------------------------------------------------
setup ls_status
write docs/adr/0001-a.md '# A' '' 'Date: 2026-01-01'
write docs/adr/0002-b.md '# B' '' 'Date: 2026-01-02' '' 'Status: proposed'
write docs/adr/0003-c.md '---' 'status: deprecated' '---' '' '# C' '' 'Date: 2026-01-03'
write docs/adr/0004-d.md 'Superseded by 0002-b' '' '# D' '' 'Date: 2026-01-04'
t "status の既定は accepted" "accepted" "$(adr ls | awk '$2 ~ /0001/ { print $3 }')"
t "Status: 行を読む" "proposed" "$(adr ls | awk '$2 ~ /0002/ { print $3 }')"
t "frontmatter の status を読む" "deprecated" "$(adr ls | awk '$2 ~ /0003/ { print $3 }')"
t "Superseded by があれば status は superseded" "superseded" "$(adr ls | awk '$2 ~ /0004/ { print $3 }')"

# ---------------------------------------------------------------------------
# check — 健全なら 0
# ---------------------------------------------------------------------------
setup check_ok
write docs/adr/0001-pick-postgres.md '# Pick Postgres' '' '2026-09-10 に決めた。1 文で足りる。'
write docs/adr/0002-supersede-it.md '# Use SQLite for the CLI' '' 'Date: 2026-09-11' '' 'Supersedes 0001.'
write docs/adr/0003-status.md '# Something' '' 'Date: 2026-09-12' 'Status: proposed'
out=$(adr check 2>&1)
rc=$?
t "健全なファイルで check は 0" "0" "$rc"
t "健全なら件数を出す" "check: 問題なし (3 件)" "$out"

# ---------------------------------------------------------------------------
# check — 指摘ひとつずつ
# ---------------------------------------------------------------------------
setup check_name
write docs/adr/pick-postgres.md '# Pick Postgres' '' 'Date: 2026-09-10'
write docs/adr/0002-Pick_Redis.md '# Pick Redis' '' 'Date: 2026-09-10'
write docs/adr/003-short.md '# Short' '' 'Date: 2026-09-10'
out=$(adr check 2>&1)
rc=$?
t "check はファイル名の違反を 2 で指摘する" "2" "$rc"
t "番号無し・大文字/下線・3 桁の 3 件を名指しする" "3" \
	"$(printf '%s\n' "$out" | grep -c 'ファイル名が NNNN-')"

setup check_dupnum
write docs/adr/0001-first.md '# First' '' 'Date: 2026-09-10'
write docs/adr/0001-second.md '# Second' '' 'Date: 2026-09-11'
out=$(adr check 2>&1)
rc=$?
t "check は番号の重複を 2 で指摘する" "2" "$rc"
t "重複は両方のファイルを名指しする" "2" \
	"$(printf '%s\n' "$out" | grep -c '番号 0001 を 2 つ以上')"
t "重複しても check はファイルを改名しない" "0001-first.md 0001-second.md" \
	"$(ls "$W/docs/adr" | tr '\n' ' ' | sed 's/ $//')"

setup check_notitle
write docs/adr/0001-no-title.md 'Date: 2026-09-10' '' '題が無い。'
out=$(adr check 2>&1)
rc=$?
t "check は題の無いファイルを 2 で指摘する" "2" "$rc"
t "題のメッセージ" "1" "$(printf '%s\n' "$out" | grep -c "題(1 行目の '# ...')が無い")"

setup check_nodate
write docs/adr/0001-no-date.md '# No date' '' '日付がどこにも無い。'
out=$(adr check 2>&1)
rc=$?
t "check は日付の無いファイルを 2 で指摘する" "2" "$rc"
t "日付が無いメッセージ" "1" "$(printf '%s\n' "$out" | grep -c '日付が無い')"

setup check_baddate
write docs/adr/0001-bad-date.md '# Bad date' '' 'Date: 2026/09/10'
out=$(adr check 2>&1)
rc=$?
t "check は YYYY-MM-DD でない日付を 2 で指摘する" "2" "$rc"
t "日付の形のメッセージ" "1" \
	"$(printf '%s\n' "$out" | grep -c "日付 '2026/09/10' が YYYY-MM-DD でない")"

setup check_baddate_range
write docs/adr/0001-bad-month.md '# Bad month' '' 'Date: 2026-13-45'
t "13 月 45 日は日付として通さない" "2" "$(adr check >/dev/null 2>&1; echo $?)"

setup check_dangling
write docs/adr/0001-old.md 'Superseded by 0009-nonexistent' '' '# Old' '' 'Date: 2026-09-10'
out=$(adr check 2>&1)
rc=$?
t "check は宙吊りの Superseded by を 2 で指摘する" "2" "$rc"
t "宙吊りのメッセージ" "1" \
	"$(printf '%s\n' "$out" | grep -c "'Superseded by 0009-nonexistent' の指す先が docs/adr に無い")"

setup check_superseded_ok
write docs/adr/0001-old.md 'Superseded by 0002-new' '' '# Old' '' 'Date: 2026-09-10'
write docs/adr/0002-new.md '# New' '' 'Date: 2026-09-11' '' 'Supersedes 0001-old.'
t "指す先が実在すれば Superseded by は通る" "0" "$(adr check >/dev/null 2>&1; echo $?)"

setup check_status_vocab
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Status: おわり'
out=$(adr check 2>&1)
rc=$?
t "check は語彙外の Status: を 2 で指摘する" "2" "$rc"
t "語彙のメッセージ" "1" "$(printf '%s\n' "$out" | grep -c 'は語彙外')"

setup check_status_vocab_ok
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Status: superseded'
write docs/adr/0002-b.md '---' 'status: proposed' '---' '# B' '' 'Date: 2026-09-11'
t "語彙内の Status: は通る(frontmatter も)" "0" "$(adr check >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
# ディレクトリの探索順
# ---------------------------------------------------------------------------
setup dir_decisions
write docs/decisions/0001-a.md '# A' '' 'Date: 2026-09-10'
t "docs/adr が無ければ docs/decisions を見る" \
	"2026-09-10 0001-a accepted A" "$(adr ls)"

setup dir_priority
write docs/adr/0001-in-adr.md '# In adr' '' 'Date: 2026-09-10'
write docs/decisions/0001-in-decisions.md '# In decisions' '' 'Date: 2026-09-10'
write adr/0001-in-top.md '# In top' '' 'Date: 2026-09-10'
t "探索順は docs/adr が先" "2026-09-10 0001-in-adr accepted In adr" "$(adr ls)"

setup dir_top_adr
write adr/0001-in-top.md '# In top' '' 'Date: 2026-09-10'
t "docs/ が無ければ直下の adr/ を見る" \
	"2026-09-10 0001-in-top accepted In top" "$(adr ls)"

setup dir_none
t "ADR ディレクトリが無ければ ls は何も出さず 0" "" "$(adr ls 2>/dev/null)"
t "ADR ディレクトリが無くても ls は 0 で返る" "0" "$(adr ls >/dev/null 2>&1; echo $?)"
t "無いことは stderr に言う" "1" "$(adr ls 2>&1 >/dev/null | grep -c 'ADR ディレクトリが無い')"
t "ADR ディレクトリが無ければ check も 0" "0" "$(adr check >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
# ADR_DIR の上書き
# ---------------------------------------------------------------------------
setup adrdir_override
write docs/adr/0001-ignored.md '# Ignored' '' 'Date: 2026-09-10'
write records/0001-picked.md '# Picked' '' 'Date: 2026-09-11'
export ADR_DIR=records
t "ADR_DIR は探索より優先する" "2026-09-11 0001-picked accepted Picked" "$(adr ls)"
t "ADR_DIR の中身を check する" "check: 問題なし (1 件)" "$(adr check)"
export ADR_DIR=nosuchdir
t "ADR_DIR が実在しなければ 1 で落ちる(黙って別の場所へ落ちない)" "1" \
	"$(adr ls >/dev/null 2>&1; echo $?)"
unset ADR_DIR

# ---------------------------------------------------------------------------
# --help は正
# ---------------------------------------------------------------------------
setup help
t "--help は 0 で返る" "0" "$(adr --help >/dev/null 2>&1; echo $?)"
t "引数なしは usage を stderr に出して 2" "2" "$(adr >/dev/null 2>&1; echo $?)"
t "知らないコマンドは 2" "2" "$(adr nope >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
# 素の /bin/sh — macOS ではこれが bash 3.2 で、新しい shell が通す書き方を落とす
# ---------------------------------------------------------------------------
setup binsh
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10'
if [ -x /bin/sh ]; then
	t "/bin/sh で読める(構文エラーが無い)" "0" \
		"$( (cd "$W" && /bin/sh "$ADRBIN" --help >/dev/null 2>&1); echo $?)"
	t "/bin/sh でも check が走る" "check: 問題なし (1 件)" \
		"$(cd "$W" && /bin/sh "$ADRBIN" check 2>&1)"
	t "/bin/sh でも ls が走る" "2026-09-10 0001-a accepted A" \
		"$(cd "$W" && /bin/sh "$ADRBIN" ls 2>&1)"
else
	printf 'skip: /bin/sh が無い\n'
fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
