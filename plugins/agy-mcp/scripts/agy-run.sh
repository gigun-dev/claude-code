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
#   - ファイル入力のときはその場で書き戻さない契約。ただし agy 自身の設定
#     (~/.gemini/antigravity-cli/settings.json の agentMode: accept-edits /
#     toolPermission: always-proceed)は承認なしでファイル書き込みツールを
#     実行できるため、prompt に元ファイルの絶対パスを書くと agy がその場で
#     元ファイルを直接書き換えた(実測: 呼び出し前後で md5 が変化)。ここでは
#     prompt にファイル名(basename)だけを渡して絶対パスを書かず、agy の
#     CWD を呼び出しごとの空ディレクトリへ隔離し、さらに呼び出し後に
#     元ファイルの内容を退避分と照合して変わっていれば書き戻す。渡し方を
#     絞ったうえで、それでも破れた場合に検査で戻す二重の構え。
#
# 呼び出し元(agy-ja-writer / MCP ツール以外で agy を直接叩きたい場面)は、
# 生の `agy` 文字列を組まず、必ずこのスクリプトを経由すること
# (plugins/agy-mcp/skills/agy-cli-runtime/SKILL.md)。
#
# 【なぜ agy 本体の skill 機構(skills.json / .agents/)を使わないのか】
#   一度検討して戻した。~/.gemini/antigravity-cli/builtin/skills/
#   agy-customizations/SKILL.md の Progressive Disclosure の節にある通り、
#   skill として登録しても本文が実際に読まれるかはモデルの判断に委ねられる
#   (「name と description だけが注入され、本文はモデルが要ると判断した
#   ときだけ読まれる」)。ここでの用途(1回きりの推敲に規範を強制する)は
#   賭けにできない。本文をこちらから prompt に確実に含めてしまう
#   `--rules` / `--skill`(内部は同じ経路)の形を採る。
# =============================================================================

set -euo pipefail

# 生成した一時パス(ディレクトリ・ファイル)をここへ積み、EXIT 時にまとめて消す。
# agy を呼ぶたびに CWD 隔離用の空ディレクトリを1つ作るので、trap は複数パス
# 前提で書く(1パスだけを消す前提の trap だと隔離ディレクトリが残り続ける)。
_tmp_paths=()
_cleanup_tmp_paths() {
	local p
	for p in "${_tmp_paths[@]}"; do
		rm -rf -- "$p"
	done
}
trap _cleanup_tmp_paths EXIT

usage() {
	cat >&2 <<'USAGE'
Usage:
  agy-run.sh --file PATH [--instruction TEXT|--instruction-file PATH] [--rules PATH ...] [--skill NAME ...] [--model MODEL]
  agy-run.sh --prompt TEXT [--rules PATH ...] [--skill NAME ...] [--model MODEL]
  agy-run.sh --prompt-file PATH [--rules PATH ...] [--skill NAME ...] [--model MODEL]

--file モード(主):
  元ファイルを読み、instruction(省略時は日本語校正の既定指示)に従って
  agy に書き直させ、元ファイルは変更せず unified diff だけを標準出力へ出す。
  文字数(元/結果)を stderr に1行出す(事実照合・文字数照合は差分を見る側の仕事)。

--prompt / --prompt-file モード(従):
  短い断片やファイルに紐づかない相談用。前置きを剥がした本文だけを標準出力へ返す。

Options:
  --model MODEL              既定: gemini-3.8-flash-high
  --rules PATH                固定の文章規範ファイルを instruction / prompt の後ろに
                               連結する。複数回指定でき、指定順に連結する
                               (--skill で引いたファイルとも同じ列に混ざる)。
                               instruction(タスク固有の指示)と両立させるための口
                               ——依頼者が個別に却下した語の一覧など、配布物の
                               skill には無い断片もここで渡せる。
  --skill NAME                 このリポジトリの plugins/*/skills/NAME/SKILL.md を
                               名前だけで引き当て、--rules と同じ経路(prompt への
                               連結)へ流す。複数回指定できる。呼び出し側は
                               プラグイン名を知らなくてよい。
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
rules_files=()
skill_names=()

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
	--rules)
		rules_files+=("$2")
		shift 2
		;;
	--skill)
		skill_names+=("$2")
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

# --skill は名前から実ファイルを引き当て、--rules と同じ列(rules_files)へ
# 積む。ここで解決を終わらせ、以降の連結処理を1本にする(同じ文字列が
# 2通りの経路で入ると、片方だけ直す事故が起きる)。
if [ "${#skill_names[@]}" -gt 0 ]; then
	script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
	# plugins/agy-mcp/scripts から3つ上がこのリポジトリの root
	# (plugins/agy-mcp/scripts → plugins/agy-mcp → plugins → root)。
	repo_root=$(cd -- "$script_dir/../../.." && pwd)

	for skill_name in "${skill_names[@]}"; do
		hit=""
		for candidate in "$repo_root"/plugins/*/skills/"$skill_name"/SKILL.md; do
			[ -f "$candidate" ] || continue
			if [ -n "$hit" ]; then
				echo "agy-run.sh: skill '$skill_name' が複数の plugin に見つかった(あいまい): $hit / $candidate" >&2
				exit 1
			fi
			hit="$candidate"
		done
		if [ -z "$hit" ]; then
			echo "agy-run.sh: skill が見つからない: $skill_name (plugins/*/skills/$skill_name/SKILL.md を探した)" >&2
			exit 1
		fi
		rules_files+=("$hit")
	done
fi

# --rules / --skill は指定順に連結する。全文を渡す(要点への圧縮はしない)。理由:
# 規範文書(例: japanese-tech-writing の SKILL.md)は「AI っぽい表現」「翻訳調の
# 比喩」などを個別の禁止語ではなく判定手順(字義どおりの動作を想像できるか→
# 主体と対象を具体語で言い直せるか)で定めていることが多い。要点だけを抜くと
# 判定手順が失われ、抜き出した禁止語リストだけが残って結局「別の難しい言葉への
# 置換」を誘発する(このリポジトリが既に踏んだ失敗のパターン)。渡すファイルは
# 数百行程度の想定で、1回の書き直し呼び出しあたりのトークン費用は無視できる
# 規模であり、費用を理由に要約しない。
rules_text=""
if [ "${#rules_files[@]}" -gt 0 ]; then
	for _rf in "${rules_files[@]}"; do
		[ -f "$_rf" ] || {
			echo "agy-run.sh: rules file not found: $_rf" >&2
			exit 1
		}
		if [ -n "$rules_text" ]; then
			rules_text="${rules_text}

$(cat -- "$_rf")"
		else
			rules_text="$(cat -- "$_rf")"
		fi
	done
fi

# マーカーは衝突しにくい固定文字列にする。本文に元々この文字列が含まれることは
# 通常ないが、絶対に無いとは言えないので前提として書いておく(その場合は抽出がずれる)。
_begin_marker="=====AGY_RUN_BODY_BEGIN====="
_end_marker="=====AGY_RUN_BODY_END====="

# `agy` を1回呼び、前置きを剥がした本文だけを標準出力へ書く。
# 失敗(マーカーが見当たらない等)は非0で返し、生応答を stderr に残す。
#
# agy は自分の CWD を ls して回り、prompt 本文に書かれた絶対パスまで勝手に
# 開く(実測)。呼び出しごとに空の一時ディレクトリを作り、そこへ cd してから
# agy を起動することで、呼び出し元のリポジトリ全体(および CWD 配下の
# .agents/skills 等)を見えなくする。
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

	local isolated_cwd
	isolated_cwd=$(mktemp -d)
	_tmp_paths+=("$isolated_cwd")

	local raw
	raw=$(cd -- "$isolated_cwd" && agy -p="${wrapped}" --model "${model}" --disable-slash-commands)

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
	if [ -n "$rules_text" ]; then
		instruction="$instruction

$rules_text"
	fi

	original_content=$(cat -- "$file")
	# 絶対パスは書かない。ファイル名(拡張子)まではモデルへの推敲の手がかりに
	# なるので渡すが、agy が到達できる形の手がかり(ディレクトリ構造)は渡さない。
	body_prompt="$instruction

対象ファイル名: $(basename -- "$file")

--- 本文 ---
${original_content}"

	tmp_out=$(mktemp)
	_tmp_paths+=("$tmp_out")
	_call_agy "$body_prompt" >"$tmp_out"
	printf '\n' >>"$tmp_out"

	# 上の対策(絶対パスを渡さない・CWD を隔離する)で塞いだつもりでも、agy が
	# 別経路(例えば元々開いていたファイルディスクリプタ)で元ファイルへ到達し
	# うる以上、最後に実物を照合して契約を保つ。変わっていたら退避してあった
	# 内容へ戻し、その事実(異常)を stderr に警告する。
	current_content=$(cat -- "$file")
	if [ "$current_content" != "$original_content" ]; then
		printf '%s' "$original_content" >"$file"
		echo "agy-run.sh: 警告 — agy が呼び出し中に元ファイル ${file} を書き換えた(本来 --file モードは元ファイルを変更しない契約)。退避しておいた元の内容へ書き戻した。書き換わったこと自体が異常であり、原因(prompt へのパス漏れや agy 側の設定変化)を調べること。" >&2
	fi

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

if [ -n "$rules_text" ]; then
	prompt="$prompt

$rules_text"
fi

_call_agy "$prompt"
printf '\n'
