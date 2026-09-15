#!/usr/bin/env bash
# =============================================================================
# plugins/agy-mcp/scripts/agy-run.sh — `agy` CLI を叩く唯一の直呼び経路
# =============================================================================
# 【このスクリプトが吸収するもの】(契約は skills/agy-cli-runtime/SKILL.md にも書く)
#   - `-p` の連結形式。`agy -p "..." --model X` は `-p` が `--model` を prompt
#     として食う(実測)。ここでは常に `-p=<text>` の `=` 連結を使う。
#   - 既定モデル。日本語の最終稿は gemini-3.8-flash-high。
#   - 返答冒頭の前置き剥がし。Gemini は「ご提示いただいた文章を…整えました」の
#     ような1〜2文を必ず先頭に付ける(実測)。プロンプト側で本文をマーカーで
#     挟ませ、マーカーの中身だけを抜き出す —— 前置きの文面そのものを
#     パターンマッチで狙う案は採らない(文面は言い回しが揺れる。マーカーは
#     位置で切るので言い回しに依存しない)。
#   - 長いプロンプト/長いファイル。ファイル経由で渡し、シェルのメタ文字と
#     改行を壊さない。
#   - ファイル入力のときは**その場で書き戻さない**。元ファイルと agy の案の
#     unified diff を返すだけにする。採用するかどうかは呼び出し元(エージェント
#     または人)が diff を見てから決める。
#
# 呼び出し元(agy-ja-writer / MCP ツール以外で agy を直接叩きたい場面)は、
# 生の `agy` 文字列を組まず、必ずこのスクリプトを経由すること
# (plugins/agy-mcp/skills/agy-cli-runtime/SKILL.md)。
# =============================================================================

set -euo pipefail

usage() {
	cat >&2 <<'USAGE'
Usage:
  agy-run.sh --file PATH [--instruction TEXT|--instruction-file PATH] [--model MODEL]
  agy-run.sh --prompt TEXT [--model MODEL]
  agy-run.sh --prompt-file PATH [--model MODEL]

--file モード(主):
  元ファイルを読み、instruction(省略時は日本語校正の既定指示)に従って
  agy に書き直させ、**元ファイルは変更せず** unified diff だけを標準出力へ出す。
  文字数(元/結果)を stderr に1行出す(事実照合・文字数照合は差分を見る側の仕事)。

--prompt / --prompt-file モード(従):
  短い断片やファイルに紐づかない相談用。前置きを剥がした本文だけを標準出力へ返す。

Options:
  --model MODEL              既定: gemini-3.8-flash-high
USAGE
	exit 1
}

# 日本語校正の既定指示。事実(数値・URL・固有名詞・項目数)を変えないことの
# 照合は呼び出し元(agy-ja-writer 等)の仕事 —— ここでは agy への指示に
# 「変えない」を含めるところまでが責務。
_DEFAULT_INSTRUCTION='次の文章を、意図や内容を変えずに、極めて自然かつ平易なビジネスユースの日本語へ校正すること。
普段の日本語では使わない言い回しや単語は避けること。難しい言葉を別の難しい言葉に置き換えるだけにしないこと。
数値・URL・固有名詞・項目数など事実に関わる部分は一切変えないこと。'

model="gemini-3.8-flash-high"
file=""
instruction=""
instruction_file=""
prompt=""
prompt_file=""

while [ $# -gt 0 ]; do
	case "$1" in
	--model)
		model="$2"
		shift 2
		;;
	--file)
		file="$2"
		shift 2
		;;
	--instruction)
		instruction="$2"
		shift 2
		;;
	--instruction-file)
		instruction_file="$2"
		shift 2
		;;
	--prompt)
		prompt="$2"
		shift 2
		;;
	--prompt-file)
		prompt_file="$2"
		shift 2
		;;
	-h | --help)
		usage
		;;
	*)
		echo "agy-run.sh: unknown argument: $1" >&2
		usage
		;;
	esac
done

if ! command -v agy >/dev/null 2>&1; then
	echo "agy-run.sh: agy が PATH にない" >&2
	exit 1
fi

# マーカーは衝突しにくい固定文字列にする。本文に元々この文字列が含まれることは
# 通常ないが、絶対に無いとは言えないので前提として書いておく(その場合は抽出がずれる)。
_begin_marker="=====AGY_RUN_BODY_BEGIN====="
_end_marker="=====AGY_RUN_BODY_END====="

# `agy` を1回呼び、前置きを剥がした本文だけを標準出力へ書く。
# 失敗(マーカーが見当たらない等)は非0で返し、生応答を stderr に残す。
_call_agy() {
	local body_prompt="$1"
	local wrapped
	wrapped="$(
		cat <<EOF
${body_prompt}

---
出力形式についての指示(この指示自体への言及・前置きの文は一切書かないこと):
前置きも後書きも書かず、本文だけを次の2行のマーカーで挟んで返すこと。
マーカーの外には1文字も書かないこと。

${_begin_marker}
(ここに本文)
${_end_marker}
EOF
	)"

	local raw
	raw=$(agy -p="${wrapped}" --model "${model}" --disable-slash-commands)

	local body
	body=$(printf '%s\n' "$raw" | awk -v b="$_begin_marker" -v e="$_end_marker" '
		$0 ~ b { flag = 1; next }
		$0 ~ e { flag = 0 }
		flag { if (NF || started) { print; started = 1 } }
	')

	if [ -z "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
		echo "agy-run.sh: 応答からマーカーで囲まれた本文を抽出できなかった" >&2
		echo "--- agy の生応答 ---" >&2
		echo "$raw" >&2
		echo "--------------------" >&2
		return 1
	fi
	printf '%s' "$body"
}

if [ -n "$file" ]; then
	if [ ! -f "$file" ]; then
		echo "agy-run.sh: file not found: $file" >&2
		exit 1
	fi
	if [ -n "$instruction_file" ]; then
		[ -f "$instruction_file" ] || {
			echo "agy-run.sh: instruction file not found: $instruction_file" >&2
			exit 1
		}
		instruction=$(cat -- "$instruction_file")
	fi
	[ -n "$instruction" ] || instruction="$_DEFAULT_INSTRUCTION"

	original_content=$(cat -- "$file")
	body_prompt="$instruction

対象ファイル: ${file}

--- 本文 ---
${original_content}"

	tmp_out=$(mktemp)
	trap 'rm -f "$tmp_out"' EXIT
	_call_agy "$body_prompt" >"$tmp_out"
	printf '\n' >>"$tmp_out"

	orig_chars=$(printf '%s' "$original_content" | wc -m | tr -d ' ')
	new_chars=$(wc -m <"$tmp_out" | tr -d ' ')
	echo "agy-run.sh: 元 ${orig_chars} 文字 / 結果 ${new_chars} 文字(差 $((new_chars - orig_chars)))" >&2

	# diff は 0(差分なし)/1(差分あり)のどちらでも正常系。2以上だけ異常。
	set +e
	diff -u --label "a/${file}" --label "b/${file}(agy案)" "$file" "$tmp_out"
	diff_rc=$?
	set -e
	if [ "$diff_rc" -ge 2 ]; then
		echo "agy-run.sh: diff の実行自体が失敗した (rc=${diff_rc})" >&2
		exit "$diff_rc"
	fi
	exit 0
fi

if [ -n "$prompt_file" ]; then
	[ -f "$prompt_file" ] || {
		echo "agy-run.sh: prompt file not found: $prompt_file" >&2
		exit 1
	}
	prompt=$(cat -- "$prompt_file")
elif [ -z "$prompt" ]; then
	echo "agy-run.sh: --file か --prompt か --prompt-file のいずれかが必須" >&2
	usage
fi

_call_agy "$prompt"
printf '\n'
