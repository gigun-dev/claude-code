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
t "new が書くのは題と日付の 2 行だけ(本文は書かない)" "# Pick Postgres

Date: 2026-09-10" "$(cat "$W/docs/adr/0001-pick-postgres.md")"
t "new が書いたファイルは check を通る" "check: 問題なし (1 件)" "$(adr check)"

setup new_first_stderr
t "置き場を作ったことは stderr に言う(stdout はパスだけ)" "1" \
	"$(adr new "Pick Postgres" 2>&1 >/dev/null | grep -c 'docs/adr を作った')"

setup new_number
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-01'
write docs/adr/0007-b.md '# B' '' 'Date: 2026-09-02'
t "採番は最大値 + 1(欠番は埋めない)" "docs/adr/0008-adopt-a-monorepo.md" \
	"$(adr new "Adopt a monorepo")"

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
write docs/adr/0001-first.md '# First' '' 'Date: 2026-09-01'
write docs/adr/0001-second.md '# Second' '' 'Date: 2026-09-02'
out=$(adr new "Next one" 2>&1)
rc=$?
t "同じ番号のファイルがあれば new は 1 で拒む" "1" "$rc"
t "拒否は check を見ろと言う" "1" "$(printf '%s\n' "$out" | grep -c 'adr check')"
t "拒まれた new はファイルを増やさない" "2" \
	"$(ls "$W/docs/adr" | wc -l | tr -d ' ')"

setup new_badname
write docs/adr/notes.md '# Notes' '' 'Date: 2026-09-01'
t "NNNN-<slug>.md でない名前があれば new は 1 で拒む" "1" \
	"$(adr new "Next one" >/dev/null 2>&1; echo $?)"
t "拒まれた new はファイルを増やさない" "1" "$(ls "$W/docs/adr" | wc -l | tr -d ' ')"

setup new_adrdir
write records/0003-a.md '# A' '' 'Date: 2026-09-01'
export ADR_DIR=records
t "ADR_DIR があればそこに採る" "records/0004-b.md" "$(adr new "B")"
export ADR_DIR=nosuchdir
t "ADR_DIR が実在しなければ作らずに 1 で落ちる" "1" \
	"$(adr new "C" >/dev/null 2>&1; echo $?)"
unset ADR_DIR

# ---------------------------------------------------------------------------
# supersede — 受理済み ADR に許された唯一の編集。両方そろって初めて書く
# ---------------------------------------------------------------------------
setup supersede_ok
write docs/adr/0001-old.md '# Old' '' 'Date: 2026-09-01' '' '本文はそのまま残ること。'
write docs/adr/0002-new.md '# New' '' 'Date: 2026-09-02'
t "supersede は書き換えたファイルのパスを出す" "docs/adr/0001-old.md" "$(adr supersede 1 2)"
t "先頭に 1 行足すだけで、元の中身は 1 バイトも変わらない" "Superseded by 0002-new

# Old

Date: 2026-09-01

本文はそのまま残ること。" "$(cat "$W/docs/adr/0001-old.md")"
t "supersede の後も check は通る" "check: 問題なし (2 件)" "$(adr check)"
t "ls の status が superseded になる" "superseded" \
	"$(adr ls | awk '$2 ~ /0001/ { print $3 }')"
t "新しい方は触らない" "# New

Date: 2026-09-02" "$(cat "$W/docs/adr/0002-new.md")"

setup supersede_ref
write docs/adr/0001-old.md '# Old' '' 'Date: 2026-09-01'
write docs/adr/0002-new.md '# New' '' 'Date: 2026-09-02'
t "slug でも指せる" "docs/adr/0001-old.md" "$(adr supersede 0001-old 0002-new)"

setup supersede_twice
write docs/adr/0001-old.md 'Superseded by 0002-new' '' '# Old' '' 'Date: 2026-09-01'
write docs/adr/0002-new.md '# New' '' 'Date: 2026-09-02'
write docs/adr/0003-newer.md '# Newer' '' 'Date: 2026-09-03'
before=$(cat "$W/docs/adr/0001-old.md")
out=$(adr supersede 1 3 2>&1)
rc=$?
t "既に Superseded by を持つ ADR は 1 で拒む" "1" "$rc"
t "拒否は既に指している先を名指しする" "1" \
	"$(printf '%s\n' "$out" | grep -c "既に 'Superseded by 0002-new' を持っている")"
t "拒まれた supersede は古い方を変えない" "$before" "$(cat "$W/docs/adr/0001-old.md")"

setup supersede_missing
write docs/adr/0001-old.md '# Old' '' 'Date: 2026-09-01'
before=$(cat "$W/docs/adr/0001-old.md")
out=$(adr supersede 1 0099-nonexistent 2>&1)
rc=$?
t "指す先が実在しなければ 1 で拒む" "1" "$rc"
t "拒否は先に new しろと言う" "1" "$(printf '%s\n' "$out" | grep -c 'adr new で作ること')"
t "拒まれた supersede は古い方に何も書かない" "$before" "$(cat "$W/docs/adr/0001-old.md")"
t "古い方が実在しなければ 1 で拒む" "1" \
	"$(adr supersede 0099 1 >/dev/null 2>&1; echo $?)"
t "自分自身では差し替えられない" "1" "$(adr supersede 1 1 >/dev/null 2>&1; echo $?)"

setup supersede_ambiguous
write docs/adr/0001-a.md '# A' '' 'Date: 2026-09-01'
write docs/adr/0001-b.md '# B' '' 'Date: 2026-09-02'
write docs/adr/0002-new.md '# New' '' 'Date: 2026-09-03'
t "番号が重複していれば、どちらか決められないので 1 で拒む" "1" \
	"$(adr supersede 1 2 >/dev/null 2>&1; echo $?)"

# 書式どおりに見えないファイルには、どこに足すかを推測せずに触らない
# (frontmatter の前に足すと frontmatter ごと壊れる)。
setup supersede_shape
write docs/adr/0001-frontmatter.md '---' 'status: accepted' '---' '' '# Old' '' 'Date: 2026-09-01'
write docs/adr/0002-new.md '# New' '' 'Date: 2026-09-02'
before=$(cat "$W/docs/adr/0001-frontmatter.md")
out=$(adr supersede 1 2 2>&1)
rc=$?
t "先頭行が題でなければ 1 で拒む" "1" "$rc"
t "拒否は推測しないと言う" "1" "$(printf '%s\n' "$out" | grep -c '推測せずに拒む')"
t "拒まれた supersede はファイルを変えない" "$before" "$(cat "$W/docs/adr/0001-frontmatter.md")"

setup supersede_notitle
write docs/adr/0001-old.md '# Old' '' 'Date: 2026-09-01'
write docs/adr/0002-no-title.md 'Date: 2026-09-02' '' '題が無い。'
before=$(cat "$W/docs/adr/0001-old.md")
t "題の無い ADR は指す先にできない" "1" "$(adr supersede 1 2 >/dev/null 2>&1; echo $?)"
t "そのとき古い方は変えない" "$before" "$(cat "$W/docs/adr/0001-old.md")"

setup supersede_usage
write docs/adr/0001-old.md '# Old' '' 'Date: 2026-09-01'
t "引数が 2 つでなければ 1" "1" "$(adr supersede 1 >/dev/null 2>&1; echo $?)"
t "ADR ディレクトリが無ければ supersede は 1" "1" \
	"$(cd "$workroot" && "$ADRBIN" supersede 1 2 >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
