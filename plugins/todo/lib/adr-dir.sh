# =============================================================================
# adr-dir.sh — ADR の置き場を決める。bin/adr と bin/todo が共有する
# =============================================================================
# この解決を 2 箇所に書くと、片方だけ直されてずれる(`todo ready` が索引に出す
# 決定と、`adr ls` が一覧する決定が食い違う、という形で表に出る)。1 箇所に置き、
# 両方の CLI が `.` で読み込む。テストが「実装は 1 箇所」を固定している。
#
# POSIX sh のみ。関数と変数を定義するだけで、読み込んだだけでは何も起きない
# —— 呼び出し側の set -u / trap / 終了コードに触れない。
# =============================================================================

# 探索順。ADR_DIR が無いとき、この順で最初に見つかったものを使う。
ADR_DIR_CANDIDATES='docs/adr docs/decisions adr decisions'

# adr_resolve_dir の戻り値。「まだ 1 件も無い」は誤りではないので、誤りと別の
# 値で返す —— adr_resolve_dir はコマンド置換の中で呼ばれ、1 だと呼び出し側の
# 「引数・状態の誤り」と区別できなくなる。
ADR_EX_NODIR=9  # どこにも ADR ディレクトリが無い
ADR_EX_BADDIR=8 # ADR_DIR が指す先が無い(明示された場所が無いのは誤り)

# base と候補をつなぐ。base が "." のときは "./" を付けない —— 診断文と
# `ready` の見出しにそのまま出る文字列なので、"docs/adr" のままにする。
adr_join_dir() { # adr_join_dir <base> <候補>
	case $1 in
	.) printf '%s' "$2" ;;
	*/) printf '%s%s' "$1" "$2" ;;
	*) printf '%s/%s' "$1" "$2" ;;
	esac
}

# ADR ディレクトリを決めて stdout に出す。
#
# base は「リポジトリのルートに当たる場所」。bin/adr は "." (カレント
# ディレクトリ)、bin/todo は "$TODO_DIR" を渡す —— todo にとってのリポジトリは
# todo.txt が置いてあるところで、そこから離れた場所の決定を索引に出しても
# 対応が付かない。
#
# ADR_DIR があればそれだけを見る(明示された場所が無いのは誤りなので、黙って
# 別の場所へ落ちない)。相対パスなら base からの相対と読む。
adr_resolve_dir() { # adr_resolve_dir [base]
	_adr_base=${1:-.}
	if [ -n "${ADR_DIR:-}" ]; then
		case $ADR_DIR in
		/*) _adr_d=$ADR_DIR ;;
		*) _adr_d=$(adr_join_dir "$_adr_base" "$ADR_DIR") ;;
		esac
		[ -d "$_adr_d" ] || return "$ADR_EX_BADDIR"
		printf '%s' "$_adr_d"
		return 0
	fi
	for _adr_c in $ADR_DIR_CANDIDATES; do
		_adr_d=$(adr_join_dir "$_adr_base" "$_adr_c")
		if [ -d "$_adr_d" ]; then
			printf '%s' "$_adr_d"
			return 0
		fi
	done
	return "$ADR_EX_NODIR"
}
