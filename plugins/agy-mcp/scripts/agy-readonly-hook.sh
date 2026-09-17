#!/bin/sh
# plugins/agy-mcp/scripts/agy-readonly-hook.sh
#
# agy(Antigravity CLI)の PreToolUse フック本体。
# 環境変数 AGY_RUN_READONLY が 1 のときだけ、書き込み系ツールの実行を deny する。
# 1 でないとき(対話で agy を普通に使うとき)は allow を返して素通りさせる。
#
# 設定は常設・実効は呼び出しごと、という形にするための口。
# 設定側は ~/.gemini/config/hooks.json 1 枚で、中身はこのファイルの絶対パスを指す。
#
# 呼ばれ方(2026-09-17 に agy 1.2.1 で実測):
#   - 標準入力に JSON が渡る。toolCall.name に write_to_file などが入る。
#   - 標準出力へ JSON を返す。decision は allow / deny / ask / force_ask。
#   - 空の JSON オブジェクト {} を返すと deny 扱いになる。素通しさせたいときも
#     decision を省略せず、明示的に allow を書くこと。
#   - 作業ディレクトリは hooks.json の置き場所(~/.gemini/config)になる。
#     相対パスを前提にしないこと。
#   - agy を起動した親プロセスの環境変数はそのままこのスクリプトに届く。
#
# どのツールに当てるかは hooks.json の matcher が決める。ここでツール名は見ない。
#
# AGY_READONLY_HOOK_LOG にファイルパスを入れておくと、判定の記録をそこへ追記する。
# 常用するものではなく、動作を確かめるときだけ使う。

set -u

payload=$(cat)

if [ "${AGY_RUN_READONLY-}" = "1" ]; then
	decision='deny'
	out='{"decision":"deny","reason":"AGY_RUN_READONLY=1 が立っているため、この呼び出しではファイルへの書き込みを受け付けない。読み取り系のツールで進めること。"}'
else
	decision='allow'
	out='{"decision":"allow"}'
fi

if [ -n "${AGY_READONLY_HOOK_LOG-}" ]; then
	{
		printf '%s decision=%s AGY_RUN_READONLY=[%s]\n' \
			"$(date '+%Y-%m-%dT%H:%M:%S')" "$decision" "${AGY_RUN_READONLY-<unset>}"
		printf '  payload=%s\n' "$payload"
	} >>"$AGY_READONLY_HOOK_LOG" 2>/dev/null || true
fi

printf '%s' "$out"
