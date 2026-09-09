#!/bin/sh
# =============================================================================
# plugins/todo のテスト — 素の POSIX sh。sharness にも bash にも依存しない。
# =============================================================================
# 走らせ方: sh plugins/todo/tests/run.sh
#
# 各テストは自分専用の一時ディレクトリを TODO_DIR にする。日付は TODO_TODAY で、
# 採番は TODO_FAKE_IDS で固定する —— 実日付と乱数のままでは、期待値を書けない
# うえに「衝突したら引き直す」経路を一度も踏めない。
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
	unset TODO_FAKE_IDS
}

t() { # t <name> <expected> <actual>
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf '✗ %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"
	fi
}

todo() { sh "$TODOBIN" "$@"; }

# ---------------------------------------------------------------------------
# add: 作成日と乱数 id を付ける
# ---------------------------------------------------------------------------
setup add
todo add "first task +proj @ctx" >/dev/null
todo add "second task" >/dev/null
t "add が id: を 6 桁の小文字 16 進で付ける" "2" \
	"$(grep -c ' id:[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$' "$TODO_DIR/todo.txt")"
t "add が作成日を先頭に付ける" "2" "$(grep -c '^2026-09-09 ' "$TODO_DIR/todo.txt")"
t "add の 2 行が別々の id を取る" "2" \
	"$(sed 's/.* id://' "$TODO_DIR/todo.txt" | sort -u | wc -l | tr -d ' ')"

setup add_pri
export TODO_FAKE_IDS="aaa111"
t "add は優先度を先頭に、作成日をその後ろに置く" \
	"(A) 2026-09-09 urgent one id:aaa111" \
	"$(todo add "(A) urgent one")"
t "add は本文に id: を書かせない" "1" \
	"$(todo add "bogus id:9" >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
# add: 衝突したら引き直す。done.txt にある id も衝突とみなす
# ---------------------------------------------------------------------------
setup add_collide
export TODO_FAKE_IDS="aaa111 bbb222"
todo add "a" >/dev/null              # → aaa111
todo do aaa111 >/dev/null            # aaa111 は done.txt へ
export TODO_FAKE_IDS="aaa111 bbb222" # 1 回目は done.txt と衝突する
t "done.txt にある id を引いたら引き直す(完了済み id を再利用しない)" \
	"2026-09-09 b id:bbb222" "$(todo add "b")"

setup add_collide2
export TODO_FAKE_IDS="aaa111"
todo add "a" >/dev/null
export TODO_FAKE_IDS="aaa111 ccc333"
t "todo.txt にある id を引いたら引き直す" \
	"2026-09-09 b id:ccc333" "$(todo add "b")"

# ---------------------------------------------------------------------------
# do: x 完了日 作成日 本文 id:N の形で done.txt へ移し、todo.txt から消える
# ---------------------------------------------------------------------------
setup done
export TODO_FAKE_IDS="aaa111 bbb222"
todo add "(B) ship it +proj" >/dev/null
todo add "keep me" >/dev/null
todo do aaa111 >/dev/null
t "do は done.txt へ x <完了日> <作成日> <本文> id:N で書く" \
	"x 2026-09-09 2026-09-09 ship it +proj id:aaa111" \
	"$(cat "$TODO_DIR/done.txt")"
t "do した行は todo.txt から消える" \
	"2026-09-09 keep me id:bbb222" "$(cat "$TODO_DIR/todo.txt")"
t "二度目の do はエラーではなく何もしない(冪等)" "0" "$(todo do aaa111 >/dev/null 2>&1; echo $?)"
t "二度目の do は done.txt を増やさない" "1" "$(wc -l <"$TODO_DIR/done.txt" | tr -d ' ')"
t "do は存在しない id を 3 で拒む" "3" "$(todo do ffffff >/dev/null 2>&1; echo $?)"
t "start は完了済みの行を 1 で拒む" "1" "$(todo start aaa111 >/dev/null 2>&1; echo $?)"
t "ID は一意なら前方一致でよい" \
	"2026-09-09 keep me id:bbb222" "$(todo show bbb)"

setup prefix_ambiguous
export TODO_FAKE_IDS="ab1111 ab2222"
todo add "one" >/dev/null
todo add "two" >/dev/null
t "曖昧な前方一致は黙って選ばず 3 で落ちる" "3" "$(todo show ab >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
# start / stop: 進行中は @wip という context ひとつ
# ---------------------------------------------------------------------------
setup wip
export TODO_FAKE_IDS="aaa111 bbb222"
todo add "(A) working on it" >/dev/null
todo add "not started" >/dev/null
todo start aaa111 >/dev/null
t "start が @wip を足す" "(A) 2026-09-09 working on it id:aaa111 @wip" "$(todo show aaa111)"
todo start aaa111 >/dev/null
t "start は @wip を二重に足さない" "(A) 2026-09-09 working on it id:aaa111 @wip" "$(todo show aaa111)"
t "ls @wip で進行中だけ見える" "(A) 2026-09-09 working on it id:aaa111 @wip" "$(todo ls @wip)"
t "start は優先度を変えない" "A" \
	"$(todo show aaa111 | sed 's/^(\(.\)).*/\1/')"
todo stop aaa111 >/dev/null
t "stop が @wip を外す" "(A) 2026-09-09 working on it id:aaa111" "$(todo show aaa111)"
todo start aaa111 >/dev/null
todo do aaa111 >/dev/null
t "do は @wip を落としてから done.txt へ移す" \
	"x 2026-09-09 2026-09-09 working on it id:aaa111" "$(cat "$TODO_DIR/done.txt")"

# ---------------------------------------------------------------------------
# ready: dep の解決
# ---------------------------------------------------------------------------
setup ready
export TODO_FAKE_IDS="aaa111 bbb222 ccc333 ddd444 eee555"
todo add "base" >/dev/null
todo add "needs base dep:aaa111" >/dev/null
todo add "needs both dep:aaa111,bbb222" >/dev/null
todo add "free" >/dev/null
t "dep が未完了なら ready に出ない" \
	"2026-09-09 base id:aaa111
2026-09-09 free id:ddd444" \
	"$(todo ready)"

todo do aaa111 >/dev/null
t "dep が done になれば ready に出る" \
	"2026-09-09 needs base dep:aaa111 id:bbb222
2026-09-09 free id:ddd444" \
	"$(todo ready)"

todo do bbb222 >/dev/null
t "複数 dep はすべて done で初めて ready" \
	"2026-09-09 needs both dep:aaa111,bbb222 id:ccc333
2026-09-09 free id:ddd444" \
	"$(todo ready)"

# 宙吊り dep は書き込みの関門で止まるので、手で書いた行で確かめる。
setup ready_dangling
printf '2026-09-09 dangling id:aaa111 dep:zzzzzz\n2026-09-09 free id:bbb222\n' >"$TODO_DIR/todo.txt"
t "宙吊り dep の行は ready に出ない" "2026-09-09 free id:bbb222" \
	"$(todo ready 2>/dev/null | grep -v '^✗' | grep -v '^ ')"

# ---------------------------------------------------------------------------
# replace / prepend: id と作成日を保持する
# ---------------------------------------------------------------------------
setup replace
export TODO_FAKE_IDS="aaa111"
todo add "(C) old body +proj" >/dev/null
todo replace aaa111 "new body @ctx" >/dev/null
t "replace は id・作成日・優先度を保持する" \
	"(C) 2026-09-09 new body @ctx id:aaa111" "$(todo show aaa111)"
todo replace aaa111 "(A) reprioritised" >/dev/null
t "replace の本文が (A) で始まればそれを優先度に採る" \
	"(A) 2026-09-09 reprioritised id:aaa111" "$(todo show aaa111)"
todo prepend aaa111 "URGENT" >/dev/null
t "prepend は優先度と作成日の後ろに入れる" \
	"(A) 2026-09-09 URGENT reprioritised id:aaa111" "$(todo show aaa111)"

# ---------------------------------------------------------------------------
# pri / depri / append
# ---------------------------------------------------------------------------
setup pri
export TODO_FAKE_IDS="aaa111"
todo add "task" >/dev/null
todo pri aaa111 A >/dev/null
t "pri が優先度を付ける" "(A) 2026-09-09 task id:aaa111" "$(todo show aaa111)"
todo pri aaa111 C >/dev/null
t "pri が優先度を差し替える" "(C) 2026-09-09 task id:aaa111" "$(todo show aaa111)"
todo depri aaa111 >/dev/null
t "depri が優先度を外す" "2026-09-09 task id:aaa111" "$(todo show aaa111)"
todo append aaa111 "see:docs/x.md" >/dev/null
t "append が行末に足す" "2026-09-09 task id:aaa111 see:docs/x.md" "$(todo show aaa111)"
t "pri は A-Z 以外を拒む" "1" "$(todo pri aaa111 aa >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
# 書き込みの関門 — 違反を増やす操作は書かない
# ---------------------------------------------------------------------------
setup gate
export TODO_FAKE_IDS="aaa111"
todo add "task" >/dev/null
before=$(cat "$TODO_DIR/todo.txt")
t "宙吊り dep を作る add は 2 で拒まれる" "2" \
	"$(todo add "typo dep:zzzzzz" >/dev/null 2>&1; echo $?)"
t "拒まれた add は todo.txt を変えない" "$before" "$(cat "$TODO_DIR/todo.txt")"
t "URL を書く see: は key:value 違反として 2 で拒まれる" "2" \
	"$(todo append aaa111 "see:https://example.com" >/dev/null 2>&1; echo $?)"
t "拒まれた append は todo.txt を変えない" "$before" "$(cat "$TODO_DIR/todo.txt")"

# 既に壊れているファイルからでも CLI で直せる(違反が「増えなければ」通す)
setup gate_repair
printf '2026-09-09 hand written line without an id\n' >"$TODO_DIR/todo.txt"
export TODO_FAKE_IDS="aaa111"
t "既存の違反があっても、増やさない add は通る" "0" \
	"$(todo add "fine task" >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
# ls / listproj / listcon
# ---------------------------------------------------------------------------
setup ls
export TODO_FAKE_IDS="aaa111 bbb222 ccc333"
todo add "alpha +web @home" >/dev/null
todo add "(A) beta +web" >/dev/null
todo add "gamma +cli @work" >/dev/null
t "ls は優先度順に出す" \
	"(A) 2026-09-09 beta +web id:bbb222
2026-09-09 alpha +web @home id:aaa111
2026-09-09 gamma +cli @work id:ccc333" \
	"$(todo ls)"
t "ls の TERM は AND" "2026-09-09 alpha +web @home id:aaa111" "$(todo ls +web @home)"
t "ls の -TERM は除外" \
	"(A) 2026-09-09 beta +web id:bbb222
2026-09-09 gamma +cli @work id:ccc333" \
	"$(todo ls -@home)"
t "listproj" "+cli
+web" "$(todo listproj)"
t "listcon" "@home
@work" "$(todo listcon)"

# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------
setup check_ok
export TODO_FAKE_IDS="aaa111 bbb222"
todo add "a" >/dev/null
todo add "b dep:aaa111" >/dev/null
todo do aaa111 >/dev/null
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

setup check_dup
printf '2026-09-09 one id:aaa111\n2026-09-09 two id:aaa111\n' >"$TODO_DIR/todo.txt"
out=$(todo check 2>&1); rc=$?
t "check は id 重複を検出する" "2" "$rc"
t "check の重複メッセージ" "1" "$(printf '%s\n' "$out" | grep -c 'id:aaa111 が重複')"

setup check_dup_across
printf '2026-09-09 one id:aaa111\n' >"$TODO_DIR/todo.txt"
printf 'x 2026-09-09 2026-09-08 old id:aaa111\n' >"$TODO_DIR/done.txt"
t "check は todo.txt と done.txt を跨いだ id 重複も検出する" "2" \
	"$(todo check >/dev/null 2>&1; echo $?)"

setup check_dangling
printf '2026-09-09 one id:aaa111 dep:zzzzzz\n' >"$TODO_DIR/todo.txt"
out=$(todo check 2>&1); rc=$?
t "check は宙吊り dep を検出する" "2" "$rc"
t "check の宙吊りメッセージ" "1" \
	"$(printf '%s\n' "$out" | grep -c 'dep:zzzzzz が todo.txt にも done.txt にも無い')"

setup check_cycle
printf '2026-09-09 one id:aaa111 dep:bbb222\n2026-09-09 two id:bbb222 dep:ccc333\n2026-09-09 three id:ccc333 dep:aaa111\n' >"$TODO_DIR/todo.txt"
out=$(todo check 2>&1); rc=$?
t "check は循環 dep を検出する" "2" "$rc"
t "check の循環メッセージは循環している 3 件を名指しする" "3" \
	"$(printf '%s\n' "$out" | grep -c 'dep が循環している')"

setup check_selfdep
printf '2026-09-09 one id:aaa111 dep:aaa111\n' >"$TODO_DIR/todo.txt"
t "check は自己依存を検出する" "2" "$(todo check >/dev/null 2>&1; echo $?)"

setup check_misplaced
printf 'x 2026-09-09 done in the wrong file id:aaa111\n' >"$TODO_DIR/todo.txt"
t "check は todo.txt の完了行を検出する" "2" "$(todo check >/dev/null 2>&1; echo $?)"

setup check_keyvalue
printf '2026-09-09 one id:aaa111 see:https://example.com\n' >"$TODO_DIR/todo.txt"
out=$(todo check 2>&1); rc=$?
t "check は value にコロンを含む key:value を拒む" "2" "$rc"
t "check の key:value メッセージ" "1" \
	"$(printf '%s\n' "$out" | grep -c 'key:value の形式違反')"

setup check_keyvalue_ok
printf '2026-09-09 one id:aaa111 see:docs/x.md due:2026-09-30\n' >"$TODO_DIR/todo.txt"
t "リポジトリ相対パスの see: は通る" "0" "$(todo check >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
# 形式互換: 生成した todo.txt を todo.txt-cli の todo.sh が読めるか
# ---------------------------------------------------------------------------
# 「自分の書式検査が通る」は自作自演なので、独立した実装に読ませて確かめる。
# todo.sh が無い環境ではこのテストだけ skip する(CI に外部依存を持ち込まない)。
todosh=${TODO_SH:-/Users/gigun/ghq/github.com/todotxt/todo.txt-cli/todo.sh}
if [ -x "$todosh" ]; then
	setup compat
	export TODO_FAKE_IDS="aaa111 bbb222 ccc333"
	todo add "beta +web" >/dev/null
	todo add "(A) alpha +web @home dep:aaa111 see:docs/x.md" >/dev/null
	todo add "gamma" >/dev/null
	todo start bbb222 >/dev/null
	todo do ccc333 >/dev/null
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
		"$("$todosh" -d "$cfg" -p listfile done.txt 2>&1 | grep -c 'gamma id:ccc333')"
else
	printf 'skip: 互換テスト — todo.sh が無い (%s)\n' "$todosh"
fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
