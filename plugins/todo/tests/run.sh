#!/bin/sh
# =============================================================================
# plugins/todo のテスト — 素の POSIX sh。sharness にも bash にも依存しない。
# =============================================================================
# 走らせ方: sh plugins/todo/tests/run.sh
#
# これが実行口。todo の分をここで走らせ、最後に tests/adr.sh を呼んで件数を
# 合算する(adr は作業場の作り方が違うので別ファイル。理由は末尾)。
#
# 各テストは自分専用の一時ディレクトリを TODO_DIR にする。日付だけは TODO_TODAY で
# 固定する —— 実日付のままだと「今日が変わると落ちる」テストになる。
# 採番は連番なので注入点は要らない: 空のディレクトリから始めれば id は 1, 2, 3…。
# =============================================================================

set -u

here=$(cd "$(dirname "$0")" && pwd)
TODOBIN="$here/../bin/todo"

pass=0
fail=0
workroot=$(mktemp -d "${TMPDIR:-/tmp}/todo-tests.XXXXXX") || exit 1
trap 'rm -rf "$workroot"' EXIT INT TERM

setup() {
	TODO_DIR="$workroot/$1"
	rm -rf "$TODO_DIR"
	mkdir -p "$TODO_DIR"
	export TODO_DIR
	export TODO_TODAY=2026-09-09
}

t() { # t <name> <expected> <actual>
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf '✗ %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"
	fi
}

todo() { "$TODOBIN" "$@"; }  # 実際の入口(shebang = macOS では bash 3.2)で走らせる

# ---------------------------------------------------------------------------
# add: 作成日と連番 id を付ける
# ---------------------------------------------------------------------------
setup add
t "add は 1 から採番する" "2026-09-09 first task +proj @ctx id:0001" \
	"$(todo add "first task +proj @ctx")"
t "add は次の行に 2 を配る" "2026-09-09 second task id:0002" \
	"$(todo add "second task")"

setup add_pri
t "add は優先度を先頭に、作成日をその後ろに置く" \
	"(A) 2026-09-09 urgent one id:0001" \
	"$(todo add "(A) urgent one")"
t "add は本文に id: を書かせない" "1" \
	"$(todo add "bogus id:9" >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
# add: 採番は todo.txt と done.txt の両方の max+1
# ---------------------------------------------------------------------------
setup add_number
todo add "a" >/dev/null   # id:0001
todo add "b" >/dev/null   # id:0002
todo do 2 >/dev/null      # 2 は done.txt へ
t "done.txt の id も max に数える(完了済み id を再利用しない)" \
	"2026-09-09 c id:0003" "$(todo add "c")"

setup add_number_empty
todo add "a" >/dev/null
todo do 1 >/dev/null
: >"$TODO_DIR/todo.txt"
t "todo.txt が空でも done.txt の max+1 になる" \
	"2026-09-09 b id:0002" "$(todo add "b")"

# ---------------------------------------------------------------------------
# do: x 完了日 作成日 本文 id:N の形で done.txt へ移し、todo.txt から消える
# ---------------------------------------------------------------------------
setup done
todo add "(B) ship it +proj" >/dev/null
todo add "keep me" >/dev/null
todo do 1 >/dev/null
t "do は done.txt へ x <完了日> <作成日> <本文> id:N で書く" \
	"x 2026-09-09 2026-09-09 ship it +proj id:0001" \
	"$(cat "$TODO_DIR/done.txt")"
t "do した行は todo.txt から消える" \
	"2026-09-09 keep me id:0002" "$(cat "$TODO_DIR/todo.txt")"
t "二度目の do はエラーではなく何もしない(冪等)" "0" "$(todo do 1 >/dev/null 2>&1; echo $?)"
t "二度目の do は done.txt を増やさない" "1" "$(wc -l <"$TODO_DIR/done.txt" | tr -d ' ')"
t "do は存在しない id を 3 で拒む" "3" "$(todo do 99 >/dev/null 2>&1; echo $?)"
t "start は完了済みの行を 1 で拒む" "1" "$(todo start 1 >/dev/null 2>&1; echo $?)"

# 前方一致は認めない —— 連番では 3 が 3 にも 30 にも当たる。
setup exact_id_only
todo add "one" >/dev/null    # id:0001
: >"$TODO_DIR/todo.txt"
printf '2026-09-09 thirty id:0030\n' >"$TODO_DIR/todo.txt"
t "ID は完全一致のみ(3 は 30 に当たらない)" "3" \
	"$(todo show 3 >/dev/null 2>&1; echo $?)"
t "完全一致なら引ける" "2026-09-09 thirty id:0030" "$(todo show 30)"

# ---------------------------------------------------------------------------
# start / stop: 進行中は @wip という context ひとつ
# ---------------------------------------------------------------------------
setup wip
todo add "(A) working on it" >/dev/null
todo add "not started" >/dev/null
todo start 1 >/dev/null
t "start が @wip を足す" "(A) 2026-09-09 working on it id:0001 @wip" "$(todo show 1)"
todo start 1 >/dev/null
t "start は @wip を二重に足さない" "(A) 2026-09-09 working on it id:0001 @wip" "$(todo show 1)"
t "ls @wip で進行中だけ見える" "(A) 2026-09-09 working on it id:0001 @wip" "$(todo ls @wip)"
t "start は優先度を変えない" "A" \
	"$(todo show 1 | sed 's/^(\(.\)).*/\1/')"
todo stop 1 >/dev/null
t "stop が @wip を外す" "(A) 2026-09-09 working on it id:0001" "$(todo show 1)"
todo start 1 >/dev/null
todo do 1 >/dev/null
t "do は @wip を落としてから done.txt へ移す" \
	"x 2026-09-09 2026-09-09 working on it id:0001" "$(cat "$TODO_DIR/done.txt")"

# ---------------------------------------------------------------------------
# ready: dep の解決
# ---------------------------------------------------------------------------
setup ready
todo add "base" >/dev/null
todo add "needs base dep:0001" >/dev/null
todo add "needs both dep:0001,0002" >/dev/null
todo add "free" >/dev/null
t "dep が未完了なら ready に出ない" \
	"2026-09-09 base id:0001
2026-09-09 free id:0004" \
	"$(todo ready)"

todo do 1 >/dev/null
t "dep が done になれば ready に出る" \
	"2026-09-09 needs base dep:0001 id:0002
2026-09-09 free id:0004" \
	"$(todo ready)"

todo do 2 >/dev/null
t "複数 dep はすべて done で初めて ready" \
	"2026-09-09 needs both dep:0001,0002 id:0003
2026-09-09 free id:0004" \
	"$(todo ready)"

# 宙吊り dep は書き込みの関門で止まるので、手で書いた行で確かめる。
setup ready_dangling
printf '2026-09-09 dangling id:0001 dep:0099\n2026-09-09 free id:0002\n' >"$TODO_DIR/todo.txt"
t "宙吊り dep の行は ready に出ない" "2026-09-09 free id:0002" \
	"$(todo ready 2>/dev/null | grep -v '^✗' | grep -v '^ ')"

# ---------------------------------------------------------------------------
# replace / prepend: id と作成日を保持する
# ---------------------------------------------------------------------------
setup replace
todo add "(C) old body +proj" >/dev/null
todo replace 1 "new body @ctx" >/dev/null
t "replace は id・作成日・優先度を保持する" \
	"(C) 2026-09-09 new body @ctx id:0001" "$(todo show 1)"
todo replace 1 "(A) reprioritised" >/dev/null
t "replace の本文が (A) で始まればそれを優先度に採る" \
	"(A) 2026-09-09 reprioritised id:0001" "$(todo show 1)"
todo prepend 1 "URGENT" >/dev/null
t "prepend は優先度と作成日の後ろに入れる" \
	"(A) 2026-09-09 URGENT reprioritised id:0001" "$(todo show 1)"

# ---------------------------------------------------------------------------
# pri / depri / append
# ---------------------------------------------------------------------------
setup pri
todo add "task" >/dev/null
todo pri 1 A >/dev/null
t "pri が優先度を付ける" "(A) 2026-09-09 task id:0001" "$(todo show 1)"
todo pri 1 C >/dev/null
t "pri が優先度を差し替える" "(C) 2026-09-09 task id:0001" "$(todo show 1)"
todo depri 1 >/dev/null
t "depri が優先度を外す" "2026-09-09 task id:0001" "$(todo show 1)"
todo append 1 "see:docs/x.md" >/dev/null
t "append が行末に足す" "2026-09-09 task id:0001 see:docs/x.md" "$(todo show 1)"
t "pri は A-Z 以外を拒む" "1" "$(todo pri 1 aa >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
# 書き込みの関門 — 違反を増やす操作は書かない
# ---------------------------------------------------------------------------
setup gate
todo add "task" >/dev/null
before=$(cat "$TODO_DIR/todo.txt")
t "宙吊り dep を作る add は 2 で拒まれる" "2" \
	"$(todo add "typo dep:0099" >/dev/null 2>&1; echo $?)"
t "拒まれた add は todo.txt を変えない" "$before" "$(cat "$TODO_DIR/todo.txt")"
t "URL を書く see: は key:value 違反として 2 で拒まれる" "2" \
	"$(todo append 1 "see:https://example.com" >/dev/null 2>&1; echo $?)"
t "拒まれた append は todo.txt を変えない" "$before" "$(cat "$TODO_DIR/todo.txt")"

# 既に壊れているファイルからでも CLI で直せる(違反が「増えなければ」通す)
setup gate_repair
printf '2026-09-09 hand written line without an id\n' >"$TODO_DIR/todo.txt"
t "既存の違反があっても、増やさない add は通る" "0" \
	"$(todo add "fine task" >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
# ls / listproj / listcon
# ---------------------------------------------------------------------------
setup ls
todo add "alpha +web @home" >/dev/null
todo add "(A) beta +web" >/dev/null
todo add "gamma +cli @work" >/dev/null
t "ls は優先度順に出す" \
	"(A) 2026-09-09 beta +web id:0002
2026-09-09 alpha +web @home id:0001
2026-09-09 gamma +cli @work id:0003" \
	"$(todo ls)"
t "ls の TERM は AND" "2026-09-09 alpha +web @home id:0001" "$(todo ls +web @home)"
t "ls の -TERM は除外" \
	"(A) 2026-09-09 beta +web id:0002
2026-09-09 gamma +cli @work id:0003" \
	"$(todo ls -@home)"
t "listproj" "+cli
+web" "$(todo listproj)"
t "listcon" "@home
@work" "$(todo listcon)"

# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------
setup check_ok
todo add "a" >/dev/null
todo add "b dep:0001" >/dev/null
todo do 1 >/dev/null
t "check は健全なファイルで 0 を返す" "0" "$(todo check >/dev/null 2>&1; echo $?)"

setup check_noid
printf '2026-09-09 hand written line\n' >"$TODO_DIR/todo.txt"
out=$(todo check 2>&1); rc=$?
t "check は id 無しを 2 で指摘する" "2" "$rc"
t "check の id 無しメッセージ" "1" "$(printf '%s\n' "$out" | grep -c 'id: が無い')"
t "ls は一覧の前に検査結果を出す" "1" \
	"$(todo ls 2>&1 | grep -c 'id: が無い')"
t "ls 自体は成功で返る(壊れを理由に一覧を隠さない)" "0" \
	"$(todo ls >/dev/null 2>&1; echo $?)"

# 作成日は仕様上「任意」。手で書いた行を追い返す理由が仕様に無いので違反にしない。
setup check_nodate
printf 'no creation date id:0001\n' >"$TODO_DIR/todo.txt"
t "作成日が無くても check は通る(仕様上 任意)" "0" \
	"$(todo check >/dev/null 2>&1; echo $?)"

setup check_donedate
printf 'x なんとか id:0001\n' >"$TODO_DIR/done.txt"
t "完了日は必須なので、無ければ check が落ちる" "2" \
	"$(todo check >/dev/null 2>&1; echo $?)"

setup check_dup
printf '2026-09-09 one id:0001\n2026-09-09 two id:0001\n' >"$TODO_DIR/todo.txt"
out=$(todo check 2>&1); rc=$?
t "check は id 重複を検出する" "2" "$rc"
t "check の重複メッセージ" "1" \
	"$(printf '%s\n' "$out" | grep -c 'id:0001 は id:0001 .* と同じ番号を指している')"

# ゼロ詰めの有無は「書き方」の違いで、同じ番号。数値として突き合わせる。
setup zero_padding
printf '2026-09-09 twelve id:0012\n' >"$TODO_DIR/todo.txt"
t "ゼロ詰めを省いた ID で引ける" "2026-09-09 twelve id:0012" "$(todo show 12)"
t "ゼロ詰めのままでも引ける" "2026-09-09 twelve id:0012" "$(todo show 0012)"
todo do 12 >/dev/null
t "ゼロ詰めを省いた ID で do できる" \
	"x 2026-09-09 2026-09-09 twelve id:0012" "$(cat "$TODO_DIR/done.txt")"
t "採番は数値で見るので次は 13" "2026-09-09 next id:0013" "$(todo add "next")"

setup zero_padding_dep
printf '2026-09-09 base id:0012\n2026-09-09 needs it dep:12 id:0013\n' >"$TODO_DIR/todo.txt"
t "dep:12 は id:0012 に届く(未完なので ready に出ない)" "2026-09-09 base id:0012" \
	"$(todo ready 2>/dev/null)"
todo do 12 >/dev/null
t "dep:12 は id:0012 が done になれば解決する" "2026-09-09 needs it dep:12 id:0013" \
	"$(todo ready 2>/dev/null)"

setup zero_padding_dup
printf '2026-09-09 one id:0012\n2026-09-09 two id:12\n' >"$TODO_DIR/todo.txt"
out=$(todo check 2>&1); rc=$?
t "id:0012 と id:12 は同じ番号なので重複" "2" "$rc"
t "重複の指摘は両方の書き方を見せる" "1" \
	"$(printf '%s\n' "$out" | grep -c 'id:12 は id:0012 .* と同じ番号を指している')"
t "どちらを指すか決まらないので操作は 3 で落ちる" "3" \
	"$(todo show 12 >/dev/null 2>&1; echo $?)"

setup check_dup_across
printf '2026-09-09 one id:0001\n' >"$TODO_DIR/todo.txt"
printf 'x 2026-09-09 2026-09-08 old id:0001\n' >"$TODO_DIR/done.txt"
t "check は todo.txt と done.txt を跨いだ id 重複も検出する" "2" \
	"$(todo check >/dev/null 2>&1; echo $?)"

setup check_dangling
printf '2026-09-09 one id:0001 dep:0099\n' >"$TODO_DIR/todo.txt"
out=$(todo check 2>&1); rc=$?
t "check は宙吊り dep を検出する" "2" "$rc"
t "check の宙吊りメッセージ" "1" \
	"$(printf '%s\n' "$out" | grep -c 'dep:0099 が todo.txt にも done.txt にも無い')"

setup check_cycle
printf '2026-09-09 one id:0001 dep:0002\n2026-09-09 two id:0002 dep:0003\n2026-09-09 three id:0003 dep:0001\n' >"$TODO_DIR/todo.txt"
out=$(todo check 2>&1); rc=$?
t "check は循環 dep を検出する" "2" "$rc"
t "check の循環メッセージは循環している 3 件を名指しする" "3" \
	"$(printf '%s\n' "$out" | grep -c 'dep が循環している')"

setup check_selfdep
printf '2026-09-09 one id:0001 dep:0001\n' >"$TODO_DIR/todo.txt"
t "check は自己依存を検出する" "2" "$(todo check >/dev/null 2>&1; echo $?)"

setup check_misplaced
printf 'x 2026-09-09 done in the wrong file id:0001\n' >"$TODO_DIR/todo.txt"
t "check は todo.txt の完了行を検出する" "2" "$(todo check >/dev/null 2>&1; echo $?)"

setup check_keyvalue
printf '2026-09-09 one id:0001 see:https://example.com\n' >"$TODO_DIR/todo.txt"
out=$(todo check 2>&1); rc=$?
t "check は value にコロンを含む key:value を拒む" "2" "$rc"
t "check の key:value メッセージ" "1" \
	"$(printf '%s\n' "$out" | grep -c 'key:value の形式違反')"

setup check_keyvalue_ok
printf '2026-09-09 one id:0001 see:docs/x.md due:2026-09-30\n' >"$TODO_DIR/todo.txt"
t "リポジトリ相対パスの see: は通る" "0" "$(todo check >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
# id — 手で足した行を CLI の操作対象へ引き上げる
# ---------------------------------------------------------------------------
setup idcmd
printf '2026-09-09 hand written one\nhand written two\n2026-09-09 already has one id:0001\n' >"$TODO_DIR/todo.txt"
out=$(todo id)
t "id は id: の無い行だけに配る" \
	"2026-09-09 hand written one id:0002
hand written two id:0003" "$out"
t "id は既に id: を持つ行を触らない" \
	"2026-09-09 already has one id:0001" "$(todo show 1)"
t "id を配れば check が通る" "0" "$(todo check >/dev/null 2>&1; echo $?)"
t "二度目の id は何もしない(冪等)" "0" "$(todo id >/dev/null 2>&1; echo $?)"
t "二度目の id は行を変えない" "3" "$(wc -l <"$TODO_DIR/todo.txt" | tr -d ' ')"

# 1 回の実行で複数配るとき、書き込む前の同一実行内で同じ id を 2 回配らないこと。
setup idcmd_unique
printf 'a\nb\nc\n' >"$TODO_DIR/todo.txt"
todo id >/dev/null
t "id は 1 回の実行でも重複しない id を配る" "3" \
	"$(sed 's/.* id://' "$TODO_DIR/todo.txt" | sort -u | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
# 形式互換: 生成した todo.txt を todo.txt-cli の todo.sh が読めるか
# ---------------------------------------------------------------------------
# 「自分の書式検査が通る」は自作自演なので、独立した実装に読ませて確かめる。
# todo.sh が無い環境ではこのテストだけ skip する(CI に外部依存を持ち込まない)。
todosh=${TODO_SH:-/Users/gigun/ghq/github.com/todotxt/todo.txt-cli/todo.sh}
if [ -x "$todosh" ]; then
	setup compat
	todo add "beta +web" >/dev/null
	todo add "(A) alpha +web @home dep:0001 see:docs/x.md" >/dev/null
	todo add "gamma" >/dev/null
	todo start 2 >/dev/null
	todo do 3 >/dev/null
	cfg="$TODO_DIR/todo.cfg"
	{
		printf 'export TODO_DIR="%s"\n' "$TODO_DIR"
		printf 'export TODO_FILE="$TODO_DIR/todo.txt"\n'
		printf 'export DONE_FILE="$TODO_DIR/done.txt"\n'
		printf 'export REPORT_FILE="$TODO_DIR/report.txt"\n'
	} >"$cfg"
	shown=$("$todosh" -d "$cfg" -p ls 2>&1)
	t "todo.sh が open 行を全部読める" "2" "$(printf '%s\n' "$shown" | grep -c 'id:')"
	t "todo.sh が優先度を認識する" "1" \
		"$(printf '%s\n' "$shown" | grep -c '(A) 2026-09-09 alpha')"
	t "todo.sh が @wip を context として認識する" "1" \
		"$("$todosh" -d "$cfg" -p listcon 2>&1 | grep -c '^@wip$')"
	t "todo.sh が +project を認識する" "1" \
		"$("$todosh" -d "$cfg" -p listproj 2>&1 | grep -c '^+web$')"
	t "todo.sh が done.txt を読める" "1" \
		"$("$todosh" -d "$cfg" -p listfile done.txt 2>&1 | grep -c 'gamma id:0003')"
else
	printf 'skip: 互換テスト — todo.sh が無い (%s)\n' "$todosh"
fi

# ---------------------------------------------------------------------------
# adr の分 — 実行口はこのファイル 1 つに保つ
# ---------------------------------------------------------------------------
# ファイルが 2 つに分かれているのは作業場の作り方が違うから: todo は TODO_DIR を
# 渡すが、adr は**カレントディレクトリからの探索**で ADR の置き場を決めるので、
# cd したサブシェルから呼ぶ必要がある。実行口まで 2 つにすると、関門
# (scripts/verify.sh)が片方だけを呼んでいても気づけない —— ここから呼んで
# 件数を合算する。
adr_out=$(sh "$here/adr.sh" 2>&1)
adr_rc=$?
# 最後の "N passed, M failed" 以外(= 失敗の詳細と skip)はそのまま見せる。
printf '%s\n' "$adr_out" | sed '$d' | sed '/^$/d'
adr_pass=$(printf '%s\n' "$adr_out" | tail -1 | awk '{ print $1 + 0 }')
adr_fail=$(printf '%s\n' "$adr_out" | tail -1 | awk '{ print $3 + 0 }')
if [ "$adr_rc" -ne 0 ] && [ "$adr_fail" -eq 0 ]; then
	# 集計行が読めない = adr.sh 自体が落ちた。0 件で通したことにしない。
	printf '✗ adr.sh が %d で終わった(集計行が読めない)\n' "$adr_rc"
	adr_fail=1
fi
pass=$((pass + adr_pass))
fail=$((fail + adr_fail))

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed (todo + adr)\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
