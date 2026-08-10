#!/usr/bin/env bash
# =============================================================================
# plugins/agy-mcp/scripts/smoke.sh — agy-mcp が本当に動くかを実物で確かめる
# =============================================================================
# 【何を検証するか / なぜこの2本なのか】
#   (1) 正常系: server.py --selftest を既定モデルで1回走らせ、出力に
#       「## 出典」節と http を含む本文が返ることを確認する。
#       —— agy が呼べて、JSON が読めて、グラウンディング検索が実際に行われ、
#       出典要求のプロンプトが効いている、までを一気通貫で見る。
#   (2) 異常系: agy が PATH に無い状態で --selftest を走らせ、**非0で落ち、
#       かつメッセージに `agy` を含む**ことを確認する。
#
#   (2) を必ず入れること。正常系だけのスモークは「検知器が死んでも気づけない」
#   (harness 原則4)。この MCP サーバは「status:SUCCESS なのに response が空」
#   のような黙った失敗を捕まえるための fail-closed 判定を何段も積んでいるが、
#   その判定自体が壊れて素通しになったとき、正常系のテストは何も言わない。
#   「失敗すべきときに失敗するか」を測る検査が要る。
#
# 【なぜ MCP クライアントを立てずに --selftest を叩くのか】
#   MCP クライアントを起動して JSON-RPC を喋らせると、検証したい対象
#   (agy の呼び出しと fail-closed 判定)以外の可動部が一気に増える。
#   --selftest は同じ _search() 実装を MCP を経由せず呼ぶ口なので、
#   スモークの失敗が「agy 側の問題」なのか「MCP 配線の問題」なのかを
#   混ぜずに切り分けられる。
#   (MCP としての起動確認は別途 uv run --script server.py を直接立てて行う。
#    そちらは stdio で常駐するのでスモークの自動判定には向かない。)
#
# 【所要時間】
#   正常系は agy の実呼び出しを含むので 10〜40 秒かかる(実測 8〜30 秒 + uv の起動)。
#   異常系は agy を呼ばないので即座に終わる。
# =============================================================================

set -euo pipefail

# スクリプトの位置からプラグイン root を割り出す。どこから呼ばれても
# 同じファイルを見るようにする(pre-push や CI から相対パスで呼ばれても壊れないように)。
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
plugin_root=$(cd -- "$script_dir/.." && pwd)
server="$plugin_root/server.py"

if [ ! -f "$server" ]; then
	# 「対象が無いので検査しない」を成功にしない(verify.sh と同じ規律)。
	echo "✗ server.py が見つからない: $server"
	exit 1
fi

# 【uv を絶対パスで解決しておく理由】
#   異常系では PATH を潰して実行するので、そのとき `uv` という名前では
#   もう解決できない。先に絶対パスを取っておき、PATH に依存せず起動する。
#   —— 潰したいのは「agy が見つからないこと」であって「何も起動できないこと」
#   ではない。PATH ごと潰したまま `uv` と書くと、uv が見つからないという
#   別の理由で非0になり、検査したかった fail-closed 判定に到達しないまま
#   「合格」に見えてしまう(検知器を検証しているつもりで何も検証していない状態)。
if ! uv_bin=$(command -v uv); then
	echo "✗ uv が PATH にない — server.py は uv run --script で起動する前提"
	exit 1
fi

# 正常系の質問。「検索しないと答えられない/答えが URL 付きで出る」ものを選ぶ。
# 内部知識だけで答えられる質問(例: 1+1)にすると、グラウンディングが働かなくても
# 通ってしまい、この検査の意味が消える。
query="Astral の uv の最新リリース版はいくつか。"

echo "=== [1/2] 正常系: --selftest が出典付きの本文を返すか ==="
echo "    query: $query"
if ! out=$("$uv_bin" run --script "$server" --selftest "$query"); then
	echo "✗ --selftest が非0で終了した(正常系)"
	exit 1
fi
echo "--- 出力 ---"
echo "$out"
echo "------------"

ok=1
# grep -F: 「## 出典」を正規表現ではなく固定文字列として探す(# は正規表現の
# メタ文字ではないが、意図を固定文字列比較だと明示しておく)。
if ! printf '%s' "$out" | grep -qF '## 出典'; then
	echo "✗ 出力に「## 出典」節が無い — 出典要求のプロンプトが効いていない可能性"
	ok=0
fi
if ! printf '%s' "$out" | grep -q 'http'; then
	echo "✗ 出力に URL(http)が含まれない — グラウンディング検索が行われていない可能性"
	ok=0
fi
if [ "$ok" -ne 1 ]; then
	exit 1
fi
echo "✓ 正常系: 出典付きの本文が返った"

echo ""
echo "=== [2/2] 異常系: agy が PATH に無いとき fail-closed するか ==="
# PATH=/nonexistent にすると shutil.which("agy") が None になる。
# uv は絶対パスで起動するので、PATH が空でも uv 自体は動く(実測済み)。
if err=$(env PATH=/nonexistent "$uv_bin" run --script "$server" --selftest "$query" 2>&1); then
	rc=0
else
	rc=$?
fi
echo "--- 出力(rc=$rc) ---"
echo "$err"
echo "--------------------"

if [ "$rc" -eq 0 ]; then
	# ここが 0 で返るということは、agy を呼べないのに成功を名乗ったということ。
	# fail-closed が壊れている、この検査で最も見つけたい状態。
	echo "✗ agy が PATH に無いのに rc=0 で終了した — fail-closed が壊れている"
	exit 1
fi
if ! printf '%s' "$err" | grep -q 'agy'; then
	# 非0ではあるが理由が分からない、も不合格にする。「落ちた」だけで
	# 何が足りないのか書いていない失敗は、利用者がそのまま直せない。
	echo "✗ 非0で終了したが、メッセージに 'agy' が含まれない — 失敗の理由が伝わっていない"
	exit 1
fi
echo "✓ 異常系: agy が無いとき非0で、理由を名指しして落ちた"

echo ""
echo "✓ smoke.sh: すべて合格"
