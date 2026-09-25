#!/bin/sh
# =============================================================================
# plugins/todo のうち adr の分のテスト — 素の POSIX sh。bash に依存しない。
# =============================================================================
# 走らせ方: sh plugins/todo/tests/run.sh(実行口はそちら。ここは単独でも走る)
#
# 各テストは自分専用の一時ディレクトリをリポジトリ相当の作業場にする。
# ADR の置き場を**カレントディレクトリからの探索**で決めるコマンドなので、
# 呼び出しは必ず作業場へ cd したサブシェルから行う。
#
# 書式は 2026-09-25 に、実測(9 リポジトリ 249 件の ADR)を踏まえて軽量 ADR
# として再定義した(正は skills/adr/references/ADR-FORMAT.md)。テストが書く
# ファイルはその書式(Date: / Implementation: / 任意の Status: / 本文 1〜3
# 段落(文脈・決定・理由)/ `Accepting:` 最低 1 行 / 任意の Rejected:(理由
# 必須)・Revisit:・Replaces:)に合わせる。
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
	# new が書く日付を固定する —— 実日付のままだと日を跨いだ実行で落ちる。
	ADR_TODAY=2026-09-10
	export ADR_TODAY
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

# 書式に沿った 1 件を書く(check を通る最小形。Accepting: を含む)。
# adrfile <相対パス> <題> <Implementation: done|pending>
adrfile() {
	write "$1" "# $2" '' "Date: 2026-09-10" "Implementation: $3" '' \
		"文脈があって、決定して、理由がある。" '' "Accepting: 受け入れた代償"
}

# ---------------------------------------------------------------------------
# ls — 番号順。日付順でも名前順でもない
# ---------------------------------------------------------------------------
setup ls_order
write docs/adr/0002-use-manual-sql.md '# Use manual SQL instead of an ORM' '' 'Date: 2026-08-01' 'Implementation: done' '' 'ORM は N+1 を隠すため、手で書く。'
write docs/adr/0010-adopt-a-monorepo.md '# Adopt a monorepo' '' 'Date: 2026-07-01' 'Implementation: done' '' 'One repo.'
write docs/adr/0001-pick-postgres.md '# Pick Postgres' '' 'Date: 2026-09-10' 'Implementation: pending'
t "ls は番号順に出す(日付順ではない)" \
	"2026-09-10 0001-pick-postgres accepted Pick Postgres
2026-08-01 0002-use-manual-sql accepted Use manual SQL instead of an ORM
2026-07-01 0010-adopt-a-monorepo accepted Adopt a monorepo" \
	"$(adr ls)"
t "ls は 10 件を超えても文字列順でなく数値順(0010 は 0002 の後ろ)" \
	"0001-pick-postgres 0002-use-manual-sql 0010-adopt-a-monorepo" \
	"$(adr ls | awk '{ printf "%s%s", (NR > 1 ? " " : ""), $2 } END { print "" }')"

# 2026-09-25 実測: 0528 のような 8/9 を含む番号は sh の printf 組み込みが
# 8 進として誤読して `printf: 0528: invalid number` になっていた。
setup ls_octal
write docs/adr/0528-eighth.md '# Eighth' '' 'Date: 2026-09-10' 'Implementation: pending'
out=$(adr ls 2>&1)
rc=$?
t "8/9 を含む番号でも ls は落ちない" "0" "$rc"
t "invalid number を出さない" "0" "$(printf '%s\n' "$out" | grep -c 'invalid number')"
t "0528 はそのまま出る" "2026-09-10 0528-eighth accepted Eighth" "$out"

# ---------------------------------------------------------------------------
# ls — status の出どころ: Status: 行 / 既定
# ---------------------------------------------------------------------------
setup ls_status
write docs/adr/0001-a.md '# A' '' 'Date: 2026-01-01' 'Implementation: pending'
write docs/adr/0002-b.md '# B' '' 'Date: 2026-01-02' 'Implementation: pending' 'Status: proposed'
t "status の既定は accepted" "accepted" "$(adr ls | awk '$2 ~ /0001/ { print $3 }')"
t "Status: 行を読む" "proposed" "$(adr ls | awk '$2 ~ /0002/ { print $3 }')"

# ---------------------------------------------------------------------------
# check — 健全なら 0
# ---------------------------------------------------------------------------
setup check_ok
adrfile docs/adr/0001-pick-postgres.md "Pick Postgres" done
adrfile docs/adr/0002-use-sqlite.md "Use SQLite for the CLI" pending
write docs/adr/0003-status.md '# Something' '' 'Date: 2026-09-12' 'Implementation: pending' 'Status: proposed' '' '文脈があって、決定して、理由がある。' '' 'Accepting: 受け入れた代償'
out=$(adr check 2>&1)
rc=$?
t "健全なファイルで check は 0" "0" "$rc"
t "健全なら件数を出す" "check: 問題なし (3 件)" "$out"

# ---------------------------------------------------------------------------
# check — 指摘ひとつずつ
# ---------------------------------------------------------------------------
setup check_name
write docs/adr/pick-postgres.md '# Pick Postgres' '' 'Date: 2026-09-10' 'Implementation: pending'
write docs/adr/0002-Pick_Redis.md '# Pick Redis' '' 'Date: 2026-09-10' 'Implementation: pending'
write docs/adr/003-short.md '# Short' '' 'Date: 2026-09-10' 'Implementation: pending'
out=$(adr check 2>&1)
rc=$?
t "check はファイル名の違反を 2 で指摘する" "2" "$rc"
t "番号無し・大文字/下線・3 桁の 3 件を名指しする" "3" \
	"$(printf '%s\n' "$out" | grep -c 'ファイル名が NNNN-')"

setup check_dupnum
write docs/adr/0001-first.md '# First' '' 'Date: 2026-09-10' 'Implementation: pending'
write docs/adr/0001-second.md '# Second' '' 'Date: 2026-09-11' 'Implementation: pending'
out=$(adr check 2>&1)
rc=$?
t "check は番号の重複を 2 で指摘する" "2" "$rc"
t "重複は両方のファイルを名指しする" "2" \
	"$(printf '%s\n' "$out" | grep -c '番号 0001 を 2 つ以上')"
t "重複しても check はファイルを改名しない" "0001-first.md 0001-second.md" \
	"$(ls "$W/docs/adr" | tr '\n' ' ' | sed 's/ $//')"

setup check_notitle
write docs/adr/0001-no-title.md 'Date: 2026-09-10' 'Implementation: pending' '' '題が無い。'
out=$(adr check 2>&1)
rc=$?
t "check は題の無いファイルを 2 で指摘する" "2" "$rc"
t "題のメッセージ" "1" "$(printf '%s\n' "$out" | grep -c "題(1 行目の '# ...')が無い")"

setup check_nodate
write docs/adr/0001-no-date.md '# No date' '' 'Implementation: pending' '' '日付がどこにも無い。'
out=$(adr check 2>&1)
rc=$?
t "check は日付の無いファイルを 2 で指摘する" "2" "$rc"
t "日付が無いメッセージ" "1" "$(printf '%s\n' "$out" | grep -c '日付が無い')"

setup check_baddate
write docs/adr/0001-bad-date.md '# Bad date' '' 'Date: 2026/09/10' 'Implementation: pending'
out=$(adr check 2>&1)
rc=$?
t "check は YYYY-MM-DD でない日付を 2 で指摘する" "2" "$rc"
t "日付の形のメッセージ" "1" \
	"$(printf '%s\n' "$out" | grep -c "日付 '2026/09/10' が YYYY-MM-DD でない")"

setup check_baddate_range
write docs/adr/0001-bad-month.md '# Bad month' '' 'Date: 2026-13-45' 'Implementation: pending'
t "13 月 45 日は日付として通さない" "2" "$(adr check >/dev/null 2>&1; echo $?)"

setup check_datefield_only
write docs/adr/0001-body-date.md '# Body date' '' 'Implementation: pending' '' '2026-09-10 に決めた。書き出しの日付はもう読まない。'
out=$(adr check 2>&1)
rc=$?
t "本文の書き出しの日付はもう Date: として読まない(無いと指摘される)" "2" "$rc"
t "日付が無いと指摘する" "1" "$(printf '%s\n' "$out" | grep -c '日付が無い')"

# ---------------------------------------------------------------------------
# check — Implementation:
# ---------------------------------------------------------------------------
setup check_impl_missing
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' '' '文脈があって、決定して、理由がある。'
out=$(adr check 2>&1)
rc=$?
t "Implementation: が無ければ 2 で指摘する" "2" "$rc"
t "指摘のメッセージ" "1" "$(printf '%s\n' "$out" | grep -c 'Implementation: が無い')"

setup check_impl_bad
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: maybe'
out=$(adr check 2>&1)
rc=$?
t "Implementation: が done|pending 以外なら 2 で指摘する" "2" "$rc"
t "語彙のメッセージ" "1" "$(printf '%s\n' "$out" | grep -c "Implementation: 'maybe' は語彙外")"

setup check_impl_ok
adrfile docs/adr/0001-a.md "A" done
adrfile docs/adr/0002-b.md "B" pending
t "done|pending は両方通る" "0" "$(adr check >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
# check — Status: の語彙(deprecated / superseded はもう無い)
# ---------------------------------------------------------------------------
setup check_status_vocab
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: pending' 'Status: おわり'
out=$(adr check 2>&1)
rc=$?
t "check は語彙外の Status: を 2 で指摘する" "2" "$rc"
t "語彙のメッセージ" "1" "$(printf '%s\n' "$out" | grep -c 'は語彙外')"

setup check_status_deprecated
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: pending' 'Status: deprecated'
t "Status: deprecated はもう語彙に無いので指摘される" "2" "$(adr check >/dev/null 2>&1; echo $?)"

setup check_status_superseded
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: pending' 'Status: superseded'
t "Status: superseded はもう語彙に無いので指摘される" "2" "$(adr check >/dev/null 2>&1; echo $?)"

setup check_status_vocab_ok
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: pending' 'Status: proposed' '' 'Accepting: X'
write docs/adr/0002-b.md '# B' '' 'Date: 2026-09-11' 'Implementation: done' 'Status: accepted' '' 'Accepting: X'
t "proposed と accepted は通る" "0" "$(adr check >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
# check — Superseded by の残骸
# ---------------------------------------------------------------------------
setup check_superseded_leftover
write docs/adr/0001-old.md 'Superseded by 0002-new' '' '# Old' '' 'Date: 2026-09-10' 'Implementation: done'
out=$(adr check 2>&1)
rc=$?
t "'Superseded by' の残骸は 2 で指摘する" "2" "$rc"
t "残骸のメッセージ" "1" \
	"$(printf '%s\n' "$out" | grep -c "'Superseded by' はもう使わない語彙")"

# ---------------------------------------------------------------------------
# check — Accepting: と Rejected: の理由(2026-09-25 実測を踏まえて追加。
# Zimmermann の Free Lunch Coupon / Fairy Tale を機械的に締め出す)
# ---------------------------------------------------------------------------
setup check_accepting_missing
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: pending' '' '本文。'
out=$(adr check 2>&1)
t "Accepting: が無ければ 2 で指摘する" "2" "$(adr check >/dev/null 2>&1; echo $?)"
t "指摘のメッセージ" "1" "$(printf '%s\n' "$out" | grep -c 'Accepting: が無い')"

setup check_accepting_present
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: pending' '' '本文。' '' 'Accepting: 受け入れた代償'
t "Accepting: が 1 行あれば通る" "0" "$(adr check >/dev/null 2>&1; echo $?)"

setup check_rejected_noreason
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: pending' '' '本文。' '' 'Accepting: X' 'Rejected: 案 A(区切りが無い)'
out=$(adr check 2>&1)
t "Rejected: に理由(空白+emダッシュ+空白)が無ければ 2 で指摘する" "2" "$(adr check >/dev/null 2>&1; echo $?)"
t "指摘のメッセージ" "1" "$(printf '%s\n' "$out" | grep -c 'Rejected: に理由が無い')"

setup check_rejected_withreason
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: pending' '' '本文。' '' 'Accepting: X' 'Rejected: 案 A — 理由'
t "Rejected: に理由があれば通る" "0" "$(adr check >/dev/null 2>&1; echo $?)"

setup check_accepting_not_counted_as_paragraph
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: pending' '' '段落 1。' '' '段落 2。' '' '段落 3。' '' 'Accepting: X' 'Rejected: Y — Z' 'Revisit: 条件'
t "Accepting/Rejected/Revisit は段落に数えない(本文 3 段落のまま通る)" "0" \
	"$(adr check >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
# check — 構造(見出し・箇条書き・表・コードフェンス・引用・4 段落以上)
# ---------------------------------------------------------------------------
setup check_heading
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: pending' '' '## 見出し' '' '本文。'
out=$(adr check 2>&1)
t "## 見出しは 2 で指摘する" "2" "$(adr check >/dev/null 2>&1; echo $?)"
t "見出しのメッセージ" "1" "$(printf '%s\n' "$out" | grep -c '見出し(## 以上)は使えない')"

setup check_bullet
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: pending' '' '- 箇条書き' '' '本文。'
out=$(adr check 2>&1)
t "箇条書きは 2 で指摘する" "2" "$(adr check >/dev/null 2>&1; echo $?)"
t "箇条書きのメッセージ" "1" "$(printf '%s\n' "$out" | grep -c '箇条書きは使えない')"

setup check_numlist
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: pending' '' '1. 番号付き' '' '本文。'
out=$(adr check 2>&1)
t "番号付きリストは 2 で指摘する" "2" "$(adr check >/dev/null 2>&1; echo $?)"
t "番号付きリストのメッセージ" "1" "$(printf '%s\n' "$out" | grep -c '番号付きリストは使えない')"

setup check_table
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: pending' '' '| a | b |' '' '本文。'
out=$(adr check 2>&1)
t "表は 2 で指摘する" "2" "$(adr check >/dev/null 2>&1; echo $?)"
t "表のメッセージ" "1" "$(printf '%s\n' "$out" | grep -c '表(|)は使えない')"

setup check_fence
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: pending' '' '```' 'code' '```' '' '本文。'
out=$(adr check 2>&1)
t "コードフェンスは 2 で指摘する" "2" "$(adr check >/dev/null 2>&1; echo $?)"
t "コードフェンスのメッセージ" "2" "$(printf '%s\n' "$out" | grep -c 'コードフェンスは使えない')"

setup check_quote
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: pending' '' '> 引用' '' '本文。'
out=$(adr check 2>&1)
t "引用は 2 で指摘する" "2" "$(adr check >/dev/null 2>&1; echo $?)"
t "引用のメッセージ" "1" "$(printf '%s\n' "$out" | grep -c '引用(>)は使えない')"

setup check_two_paragraphs_ok
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: pending' '' '文脈段落。' '' '決定段落。' '' 'Accepting: X'
t "本文 2 段落(文脈・決定)は通る" "0" "$(adr check >/dev/null 2>&1; echo $?)"

setup check_three_paragraphs_ok
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: pending' '' '文脈段落。' '' '決定段落。' '' '帰結段落。' '' 'Accepting: X'
t "本文 3 段落(文脈・決定・帰結)まで通る" "0" "$(adr check >/dev/null 2>&1; echo $?)"

setup check_four_paragraphs
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: pending' '' '1 段落目。' '' '2 段落目。' '' '3 段落目。' '' '4 段落目。' '' 'Accepting: X'
out=$(adr check 2>&1)
t "本文が 4 段落以上なら 2 で指摘する" "2" "$(adr check >/dev/null 2>&1; echo $?)"
t "4 段落以上のメッセージ" "1" "$(printf '%s\n' "$out" | grep -c '本文の段落が 4 つ以上ある')"

setup check_structure_ok
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: pending' '' '1 段落だけの本文。' '' 'Accepting: X' 'Rejected: X — Y'
t "1 段落 + Accepting + Rejected: は構造検査を通る" "0" "$(adr check >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
# check — 内容([実測 / [検査: / id: / Date: 行以外の日付)
# ---------------------------------------------------------------------------
setup check_content_sokutei
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: pending' '' '本文 [実測 2026-09-10] を引く。'
out=$(adr check 2>&1)
t "[実測 は 2 で指摘する" "2" "$(adr check >/dev/null 2>&1; echo $?)"
t "[実測 のメッセージ" "1" "$(printf '%s\n' "$out" | grep -c "'\[実測' は本文に置かない")"

setup check_content_kensa
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: pending' '' '本文 [検査: foo.sh] を引く。'
out=$(adr check 2>&1)
t "[検査: は 2 で指摘する" "2" "$(adr check >/dev/null 2>&1; echo $?)"
t "[検査: のメッセージ" "1" "$(printf '%s\n' "$out" | grep -c "'\[検査:' はテスト名の参照")"

setup check_content_id
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: pending' '' 'todo の id:0042 を引く。'
out=$(adr check 2>&1)
t "id: 参照は 2 で指摘する" "2" "$(adr check >/dev/null 2>&1; echo $?)"
t "id: のメッセージ" "1" "$(printf '%s\n' "$out" | grep -c 'todo の id: 参照は本文に置かない')"

setup check_content_date
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: pending' '' '2026-09-01 に気づいたことを書く。'
out=$(adr check 2>&1)
t "Date: 行以外の日付は 2 で指摘する" "2" "$(adr check >/dev/null 2>&1; echo $?)"
t "日付のメッセージ" "1" "$(printf '%s\n' "$out" | grep -c "'Date:' 行以外に日付がある")"

# 2026-09-25 実測: MCP はプロトコルの版を日付そのもので識別する。経緯の日付
# ではなく値なので、コードスパンに入れれば指摘しない(見出しは skill にも書く)。
setup check_content_date_codespan
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: pending' '' 'MCP の `2026-07-28` 版を前提にする。' '' 'Accepting: X'
t "コードスパンの中の日付は指摘しない" "0" "$(adr check >/dev/null 2>&1; echo $?)"

setup check_content_date_outside_codespan
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: pending' '' 'コードスパンの外 2026-07-28 は指摘する。'
t "コードスパンの外の日付は今までどおり指摘する" "2" "$(adr check >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
# ディレクトリの探索順
# ---------------------------------------------------------------------------
setup dir_decisions
write docs/decisions/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: pending'
t "docs/adr が無ければ docs/decisions を見る" \
	"2026-09-10 0001-a accepted A" "$(adr ls)"

setup dir_priority
write docs/adr/0001-in-adr.md '# In adr' '' 'Date: 2026-09-10' 'Implementation: pending'
write docs/decisions/0001-in-decisions.md '# In decisions' '' 'Date: 2026-09-10' 'Implementation: pending'
write adr/0001-in-top.md '# In top' '' 'Date: 2026-09-10' 'Implementation: pending'
t "探索順は docs/adr が先" "2026-09-10 0001-in-adr accepted In adr" "$(adr ls)"

setup dir_top_adr
write adr/0001-in-top.md '# In top' '' 'Date: 2026-09-10' 'Implementation: pending'
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
write docs/adr/0001-ignored.md '# Ignored' '' 'Date: 2026-09-10' 'Implementation: pending'
write records/0001-picked.md '# Picked' '' 'Date: 2026-09-11' 'Implementation: pending' '' '本文。' '' 'Accepting: X'
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
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: pending' '' '本文。' '' 'Accepting: X'
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
# 探索順の実装は 1 箇所だけ
# ---------------------------------------------------------------------------
# bin/adr と bin/todo が別々に探索を持つと、片方だけ直されて `adr ls` と
# `todo ready` の索引が別の場所を見るようになる。表に出るのは「決定を守らせる
# ための索引が、実際の決定と違う」という一番まずい形なので、実装が 1 本である
# ことをテストで固定する(コメントで頼まない)。
setup single_source
lib="$here/../lib/adr-dir.sh"
t "探索順のリテラルを持つファイルは lib の 1 つだけ" "1" \
	"$(grep -l 'docs/adr docs/decisions' "$lib" "$ADRBIN" "$here/../bin/todo" | wc -l | tr -d ' ')"
t "候補一覧の定義も 1 つだけ" "1" \
	"$(grep -h '^ADR_DIR_CANDIDATES=' "$lib" "$ADRBIN" "$here/../bin/todo" | wc -l | tr -d ' ')"
t "bin/adr は lib を読み込む" "1" \
	"$(grep -c '\. "\$ADRLIB"' "$ADRBIN" | tr -d ' ')"
t "bin/todo も同じ lib を読み込む" "1" \
	"$(grep -c '\. "\$ADRLIB"' "$here/../bin/todo" | tr -d ' ')"

# ---------------------------------------------------------------------------
# new — 採番と、採番できないときの拒否
# ---------------------------------------------------------------------------
setup new_first
t "置き場が無ければ docs/adr を作って 0001 を採る" "docs/adr/0001-pick-postgres.md" \
	"$(adr new "Pick Postgres" 2>/dev/null)"
t "new が書くのは題・日付・Implementation: pending の 3 行だけ(決定の本文は書かない)" "# Pick Postgres

Date: 2026-09-10
Implementation: pending" "$(cat "$W/docs/adr/0001-pick-postgres.md")"
out=$(adr check 2>&1)
t "new が書いた直後は Accepting: が無いので check を通らない(本文と一緒に書き手が足す)" "2" \
	"$(adr check >/dev/null 2>&1; echo $?)"
t "その指摘は Accepting: を名指しする" "1" "$(printf '%s\n' "$out" | grep -c 'Accepting: が無い')"
printf '\n本文。\n\nAccepting: 受け入れた代償\n' >>"$W/docs/adr/0001-pick-postgres.md"
t "本文と Accepting: を足せば check を通る" "check: 問題なし (1 件)" "$(adr check)"

setup new_first_stderr
t "置き場を作ったことは stderr に言う(stdout はパスだけ)" "1" \
	"$(adr new "Pick Postgres" 2>&1 >/dev/null | grep -c 'docs/adr を作った')"

setup new_number
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-01' 'Implementation: pending'
write docs/adr/0007-b.md '# B' '' 'Date: 2026-09-02' 'Implementation: pending'
t "採番は最大値 + 1(欠番は埋めない)" "docs/adr/0008-adopt-a-monorepo.md" \
	"$(adr new "Adopt a monorepo")"

setup new_number_replaces
write docs/adr/0002-b.md '# B' '' 'Date: 2026-09-02' 'Implementation: pending' '' '本文。' '' 'Replaces: 0009'
t "採番はファイル名だけでなく Replaces: が名指しする番号も見る(削除済みの番号を再利用しない)" \
	"docs/adr/0010-adopt-a-monorepo.md" "$(adr new "Adopt a monorepo")"

setup new_slug
t "slug は小文字にして a-z0-9 以外を - に畳む" "docs/adr/0001-use-manual-sql-not-an-orm.md" \
	"$(adr new "Use manual SQL: NOT an ORM!" 2>/dev/null)"
t "先頭と末尾の - は落ちる" "docs/adr/0002-trim-me.md" "$(adr new "  (trim me)  ")"

# 題は日本語で、slug は手で書いた英語 —— それが実際の書かれ方。ASCII の断片
# だけを拾うと、改名できない slug が残る。
setup new_nonascii
out=$(adr new "探索は TLS 1.3、送信フローは 1.2 に分ける" 2>&1)
rc=$?
t "非 ASCII の題からは slug を作らず 1 で拒む" "1" "$rc"
t "拒否は slug を渡せと言う" "1" "$(printf '%s\n' "$out" | grep -c 'slug を渡すこと')"
t "拒まれた new は置き場すら作らない" "1" \
	"$(test -d "$W/docs/adr"; echo $?)"
t "slug を渡せば日本語の題で書ける" "docs/adr/0001-split-tls-version-by-role.md" \
	"$(adr new "探索は TLS 1.3、送信フローは 1.2 に分ける" split-tls-version-by-role 2>/dev/null)"
t "題は本文にそのまま入る" "# 探索は TLS 1.3、送信フローは 1.2 に分ける" \
	"$(head -1 "$W/docs/adr/0001-split-tls-version-by-role.md")"

setup new_badslug
t "渡された slug が小文字ケバブでなければ 1 で拒む" "1" \
	"$(adr new "A title" Bad_Slug >/dev/null 2>&1; echo $?)"
t "空の題は 1 で拒む" "1" "$(adr new "" >/dev/null 2>&1; echo $?)"
t "題に # を付けたら 1 で拒む(見出しは new が書く)" "1" \
	"$(adr new "# A title" >/dev/null 2>&1; echo $?)"

# 採番の当てにできない状態では書かない。判定は check と同じもの。
setup new_dupnum
write docs/adr/0001-first.md '# First' '' 'Date: 2026-09-01' 'Implementation: pending'
write docs/adr/0001-second.md '# Second' '' 'Date: 2026-09-02' 'Implementation: pending'
out=$(adr new "Next one" 2>&1)
rc=$?
t "同じ番号のファイルがあれば new は 1 で拒む" "1" "$rc"
t "拒否は check を見ろと言う" "1" "$(printf '%s\n' "$out" | grep -c 'adr check')"
t "拒まれた new はファイルを増やさない" "2" \
	"$(ls "$W/docs/adr" | wc -l | tr -d ' ')"

setup new_badname
write docs/adr/notes.md '# Notes' '' 'Date: 2026-09-01' 'Implementation: pending'
t "NNNN-<slug>.md でない名前があれば new は 1 で拒む" "1" \
	"$(adr new "Next one" >/dev/null 2>&1; echo $?)"
t "拒まれた new はファイルを増やさない" "1" "$(ls "$W/docs/adr" | wc -l | tr -d ' ')"

setup new_adrdir
write records/0003-a.md '# A' '' 'Date: 2026-09-01' 'Implementation: pending'
export ADR_DIR=records
t "ADR_DIR があればそこに採る" "records/0004-b.md" "$(adr new "B")"
export ADR_DIR=nosuchdir
t "ADR_DIR が実在しなければ作らずに 1 で落ちる" "1" \
	"$(adr new "C" >/dev/null 2>&1; echo $?)"
unset ADR_DIR

# ---------------------------------------------------------------------------
# replace — 新しい方に Replaces: を足し、古い方を削除する(旧 supersede)
# ---------------------------------------------------------------------------
setup replace_ok
adrfile docs/adr/0001-old.md "Old" done
adrfile docs/adr/0002-new.md "New" pending
t "replace は新しい方のパスを出す" "docs/adr/0002-new.md" "$(adr replace 1 2)"
t "新しい方に Replaces: <古い番号> が付く" "1" \
	"$(grep -c '^Replaces: 0001$' "$W/docs/adr/0002-new.md")"
t "古い方のファイルは消える" "1" "$(test -e "$W/docs/adr/0001-old.md"; echo $?)"
t "replace の後も check は通る" "check: 問題なし (1 件)" "$(adr check)"
t "ls には古い方が出ない(置き場は今も有効な決定だけ)" "1" "$(adr ls | wc -l | tr -d ' ')"

setup replace_ref
adrfile docs/adr/0001-old.md "Old" done
adrfile docs/adr/0002-new.md "New" pending
t "slug でも指せる" "docs/adr/0002-new.md" "$(adr replace 0001-old 0002-new)"

setup replace_twice
adrfile docs/adr/0001-old.md "Old" done
adrfile docs/adr/0002-mid.md "Mid" done
adrfile docs/adr/0003-new.md "New" pending
adr replace 1 3 >/dev/null
adr replace 2 3 >/dev/null
t "複数回 replace すると Replaces: にカンマで並ぶ(冪等に追記)" "1" \
	"$(grep -c '^Replaces: 0001,0002$' "$W/docs/adr/0003-new.md")"
t "同じ古い番号をもう一度 replace しても増えない" "1" \
	"$(adr replace 1 3 >/dev/null 2>&1; grep -c '^Replaces: 0001,0002$' "$W/docs/adr/0003-new.md")"
t "両方消えて新しい方だけ残る" "1" "$(adr ls | wc -l | tr -d ' ')"

setup replace_number_reuse
adrfile docs/adr/0001-old.md "Old" done
adrfile docs/adr/0002-new.md "New" pending
adr replace 1 2 >/dev/null
t "削除済みの番号 0001 は new で再利用されない" "docs/adr/0003-third.md" \
	"$(adr new "Third")"

setup replace_missing_new
adrfile docs/adr/0001-old.md "Old" done
out=$(adr replace 1 0099-nonexistent 2>&1)
rc=$?
t "新しい方が無ければ 1 で拒む" "1" "$rc"
t "拒否は先に new しろと言う" "1" "$(printf '%s\n' "$out" | grep -c 'adr new で作ること')"
t "拒まれた replace は古い方を消さない" "0" "$(test -e "$W/docs/adr/0001-old.md"; echo $?)"

setup replace_missing_old
adrfile docs/adr/0002-new.md "New" pending
t "古い方が実在しなければ 1 で拒む" "1" \
	"$(adr replace 0099 2 >/dev/null 2>&1; echo $?)"

setup replace_self
adrfile docs/adr/0001-a.md "A" pending
t "自分自身では差し替えられない" "1" "$(adr replace 1 1 >/dev/null 2>&1; echo $?)"

setup replace_ambiguous
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-01' 'Implementation: pending'
write docs/adr/0001-b.md '# B' '' 'Date: 2026-09-02' 'Implementation: pending'
adrfile docs/adr/0002-new.md "New" pending
t "番号が重複していれば、どちらか決められないので 1 で拒む" "1" \
	"$(adr replace 1 2 >/dev/null 2>&1; echo $?)"

setup replace_notitle
adrfile docs/adr/0001-old.md "Old" done
write docs/adr/0002-no-title.md 'Date: 2026-09-02' 'Implementation: pending' '' '題が無い。'
t "題の無い ADR は指す先にできない" "1" "$(adr replace 1 2 >/dev/null 2>&1; echo $?)"
t "拒まれたら古い方は消えない" "0" "$(test -e "$W/docs/adr/0001-old.md"; echo $?)"

setup replace_usage
adrfile docs/adr/0001-old.md "Old" done
t "引数が 2 つでなければ 1" "1" "$(adr replace 1 >/dev/null 2>&1; echo $?)"
t "ADR ディレクトリが無ければ replace は 1" "1" \
	"$(cd "$workroot" && "$ADRBIN" replace 1 2 >/dev/null 2>&1; echo $?)"

setup replace_git
git -C "$W" init -q
git -C "$W" config user.email t@t.example
git -C "$W" config user.name t
adrfile docs/adr/0001-old.md "Old" done
adrfile docs/adr/0002-new.md "New" pending
(cd "$W" && git add -A && git commit -qm init)
adr replace 1 2 >/dev/null
t "git 管理下なら git rm で消す(index にも反映される)" "D  docs/adr/0001-old.md" \
	"$(cd "$W" && git status --short docs/adr/0001-old.md)"

setup supersede_alias
adrfile docs/adr/0001-old.md "Old" done
adrfile docs/adr/0002-new.md "New" pending
t "supersede は replace の別名として動く" "docs/adr/0002-new.md" "$(adr supersede 1 2)"
t "古い方は消える" "1" "$(test -e "$W/docs/adr/0001-old.md"; echo $?)"

# ---------------------------------------------------------------------------
# stats — 報告のみ(ゲートではない)。文字数の多い順、末尾に合計。
# 2026-09-25 に文数・最長文の文字数を足し、同日さらに語数(wc -w 相当)を
# 足した(段落数だけでは「短い段落を最大 3 つ、120〜200 語」という目標からの
# 逸脱に気づけないため)。
# ---------------------------------------------------------------------------
setup stats_basic
write docs/adr/0001-short.md '# S' '' 'Date: 2026-09-10' 'Implementation: pending' '' '短い。'
write docs/adr/0002-long.md '# L' '' 'Date: 2026-09-10' 'Implementation: pending' '' '長い文脈の段落がここに入る。' '' '長い決定の段落がここに入る。'
out=$(adr stats)
rc=$?
t "stats は常に 0 で返る(ゲートではない)" "0" "$rc"
t "stats は文字数の多い順(長い方が先)" "1" \
	"$(printf '%s\n' "$out" | head -1 | grep -c '0002-long.md')"
t "stats は末尾に合計と件数を出す" "1" \
	"$(printf '%s\n' "$out" | tail -1 | grep -c '^計 [0-9]* 文字 / 2 件$')"
t "stats は段落数も出す(0002 は 2 段落)" "1" \
	"$(printf '%s\n' "$out" | grep -c '2 段落  2 文(最長 14 文字)  docs/adr/0002-long.md')"
t "stats は 1 文だけのファイルの文数・最長文も出す" "1" \
	"$(printf '%s\n' "$out" | grep -c '1 段落  1 文(最長 3 文字)  docs/adr/0001-short.md')"

# 語数はファイル全体(wc -m と同じ数え方)。題やフィールド行の語も数える ——
# 字数との一貫性を優先した(字数も本文だけでなくファイル全体を数えている)。
setup stats_wordcount
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: pending' '' 'one two three four five'
out=$(adr stats)
t "stats は語数(wc -w 相当。ファイル全体)を文字数の次に出す" "1" \
	"$(printf '%s\n' "$out" | grep -c '文字  11 語  1 段落')"

setup stats_sentence_split
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' 'Implementation: pending' '' '一文目。二文目は少し長め。三文目。'
out=$(adr stats)
t "1 段落の中でも句点ごとに文を数える(3 文)" "1" \
	"$(printf '%s\n' "$out" | grep -c '1 段落  3 文')"
t "最長は「二文目は少し長め。」" "1" \
	"$(printf '%s\n' "$out" | grep -c '最長 9 文字')"

setup stats_none
t "ADR ディレクトリが無ければ stats は何も出さず 0" "" "$(adr stats 2>/dev/null)"
t "ADR ディレクトリが無くても stats は 0 で返る" "0" "$(adr stats >/dev/null 2>&1; echo $?)"

setup stats_even_when_check_fails
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-10' '' '本文。'
t "check が指摘を出す状態でも stats は 0 で返る(ゲートではない)" "0" \
	"$(adr stats >/dev/null 2>&1; echo $?)"

setup stats_usage
t "stats は引数を取らない" "1" "$(adr stats extra >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
