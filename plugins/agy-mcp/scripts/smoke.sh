#!/usr/bin/env bash
# =============================================================================
# plugins/agy-mcp/scripts/smoke.sh — agy-mcp が本当に動くかを実物で確かめる
# =============================================================================
# 【何を検証するか / なぜこの4本なのか】
#   (1) 外を叩かない回帰テスト: server.py --selftest-parse。**agy を1度も呼ばない**。
#       実測で踏んだ2つの壊れ方(response に生の制御文字が混ざる / JSON 行の前に
#       別の行が出る)を固定文字列で再現し、パースが通ることを確かめる。
#       併せて会話 ID の検証・**権限拒否の検知**・媒体パスと区間指定の検証も見る。
#       外を叩かないので一瞬で終わり、ネットワークやモデルの気分に左右されない。
#   (2) 正常系 + 会話継続: server.py --selftest-followup を1回走らせ、
#       (a) 1回目の出力に「## 出典」節と http を含む本文が返る
#       (b) 来歴行に cid= が出る
#       (c) 追撃(2回目)が同じ cid の会話として通る
#       を確認する。—— agy が呼べて、JSON が読めて、グラウンディング検索が実際に
#       行われ、出典要求のプロンプトが効き、会話が継続できる、までを一気通貫で見る。
#   (3) 異常系: agy が PATH に無い状態で --selftest を走らせ、**非0で落ち、
#       かつメッセージに `agy` を含む**ことを確認する。
#   (4) 媒体(agy_look): scripts/fixtures/ の画像と動画を1回で見せ、
#       **こちらが焼き込んだコード3つ**が返ることを確認する。
#       画像 `QZ7M-4419` / 動画 0〜5秒 `VX3K-8827`・5〜10秒 `NP5R-1163`。
#       ここを「それらしい説明が返ったか」で判定しないのが肝心 —— モデルは
#       ファイル名だけでもっともらしい話を作れる(fixtures/README.md 参照)。
#
#   (3) を必ず入れること。正常系だけのスモークは「検知器が死んでも気づけない」
#   (harness 原則4)。この MCP サーバは「status:SUCCESS なのに response が空」
#   のような黙った失敗を捕まえるための fail-closed 判定を何段も積んでいるが、
#   その判定自体が壊れて素通しになったとき、正常系のテストは何も言わない。
#   「失敗すべきときに失敗するか」を測る検査が要る。
#   同じ理由で (1) にも異常系(読めない stdout を失敗させるか)を入れてある。
#
# 【(4) に YouTube を入れない理由】
#   ネットワークと外部サービス(YouTube の仕様変更・yt-dlp の版・動画の削除)に
#   依存する検査を常用の検査経路へ入れると、落ちるようになった日に
#   「またあれか」で無視されるか、コメントアウトされて**検知器ごと死ぬ**
#   (R-43 で出典 URL の HTTP 実在確認を却下したのと同じ理由)。
#   agy_youtube は落としたファイルを agy_look と同じ経路へ流すだけなので、
#   中核は (4) で覆えている。YouTube 経路の実地確認は手で行う。
#   ⚠️ (2) が既にネットワークに依存しているのは事実だが、あれが依存しているのは
#   「agy が動くこと」そのもの ——  それが落ちたらこのプラグインは無価値なので、
#   検査が落ちるのは正しい。YouTube はそうではない(agy_look は生きたまま
#   YouTube 側の都合だけで赤くなる)。依存の質が違う。
#
# 【(2) を「正常系」と「追撃」の2本に分けなかった理由】
#   分けると agy の実呼び出しが 1 + 2 = 3回になり、待ち時間がほぼ倍になる。
#   --selftest-followup は内部で 1回目に通常の検索を行うので、正常系の検査対象
#   (出典付きの本文が返るか)はその 1回目の出力にそのまま含まれている。
#   同じものを2度測るために30秒余分に待つ理由が無い。
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
#   (2) は agy の実呼び出しを2回含むので 40〜120 秒かかる(実測 1回 8〜40 秒 +
#   uv の起動)。(4) は実呼び出し1回で 10〜30 秒。
#   (1) と (3) は agy を呼ばないので即座に終わる。
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

# 追撃の質問。**指示語だけで、単体では意味をなさない**ものにするのが肝心
# —— 「uv とは何か」のように単体で答えられる質問にすると、会話が継続されて
# いなくても答えが返ってしまい、継続の検査にならない。
followup="それは何のソフトウェアか。1行で。"

echo "=== [1/4] 外を叩かない回帰テスト (agy を呼ばない) ==="
if ! parse_out=$("$uv_bin" run --script "$server" --selftest-parse 2>&1); then
	echo "$parse_out"
	echo "✗ --selftest-parse が非0で終了した — agy の出力を読む部分が壊れている"
	exit 1
fi
echo "$parse_out"
echo "✓ JSON パース: すべての回帰ケースに合格"

echo ""
echo "=== [2/4] 正常系 + 会話継続: --selftest-followup ==="
echo "    query   : $query"
echo "    followup: $followup"
if ! out=$("$uv_bin" run --script "$server" --selftest-followup "$query" "$followup"); then
	# 失敗時も stdout を捨てない。2回目(追撃)で落ちた場合、1回目の本文と
	# 来歴行はここに入っている —— それを見ないと「1回目から駄目だったのか、
	# 継続だけが駄目だったのか」の切り分けができない
	# (失敗の理由そのものは stderr 側に出るので、端末には既に表示されている)。
	echo "--- 出力(途中まで) ---"
	echo "$out"
	echo "----------------------"
	echo "✗ --selftest-followup が非0で終了した(正常系)"
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

# 【cid の検査は「サーバの自己申告」を信じず、こちらで数え直す】
#   server.py 側にも「要求した cid と返ってきた cid が違えば失敗」という検査が
#   あるが、それは検査対象のコード自身が下した判定。ここでは出力に現れた
#   cid= の値を独立に拾って突き合わせる(原則4: 検知器は第二の計測で検証する)。
#   継続に失敗すると agy は**別の cid で新規会話を始めて平然と答える**ので、
#   2つの cid が一致することが「同じ会話に積まれた」ことの証拠になる。
#   ⚠️ `|| true` を付けてあるのは set -o pipefail 対策。cid が1つも見つからない
#   ケース(= まさに検知したい失敗)で grep が非0を返し、判定に入る前に
#   スクリプトごと落ちてしまうと、「✗ cid が見つからない」という診断が
#   出力されないまま終わる。落とすのは自分で判定してからにする。
cids=$(printf '%s' "$out" | grep -o 'cid=[^ ]*$' | sed 's/^cid=//' || true)
cid_count=$(printf '%s' "$cids" | grep -c . || true)
if [ "$cid_count" -ne 2 ]; then
	echo "✗ 来歴行の cid= が2つ見つからない(${cid_count}個) — 会話 ID が出力されていない"
	ok=0
else
	cid_first=$(printf '%s\n' "$cids" | sed -n '1p')
	cid_second=$(printf '%s\n' "$cids" | sed -n '2p')
	if [ "$cid_first" != "$cid_second" ]; then
		echo "✗ 1回目と2回目の cid が違う($cid_first / $cid_second) — 追撃が新規会話になっている"
		ok=0
	else
		echo "    cid(両方一致): $cid_first"
	fi
	if [ "$cid_first" = "(取得できず)" ]; then
		# 「取得できず」同士が一致しても継続できたことにはならない。
		echo "✗ cid が「(取得できず)」 — agy が conversation_id を返していない"
		ok=0
	fi
fi

if [ "$ok" -ne 1 ]; then
	exit 1
fi
echo "✓ 正常系: 出典付きの本文が返り、同じ会話 ID で追撃が通った"

echo ""
echo "=== [3/4] 異常系: agy が PATH に無いとき fail-closed するか ==="
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
echo "=== [4/4] 媒体: 画像と動画を実際に見せて、焼き込んだコードが返るか ==="
# 【なぜ画像と動画を1回の呼び出しでまとめて渡すのか】
#   agy の実呼び出しを2回から1回に減らせるだけでなく、**複数ファイルを一度に
#   渡す経路**(agy_look の売りの1つ)そのものの検査を兼ねられる。
#   別々に呼ぶと待ち時間が倍になり、複数渡しは未検査のまま残る。
still="$plugin_root/scripts/fixtures/still.png"
clip="$plugin_root/scripts/fixtures/clip.mp4"
for f in "$still" "$clip"; do
	if [ ! -f "$f" ]; then
		# 「材料が無いので検査しない」を成功にしない。ここを skip にすると、
		# fixtures を消した瞬間に媒体の検査が黙って消える(検知器が死ぬ形)。
		echo "✗ 検証材料が見つからない: $f"
		exit 1
	fi
done

media_prompt="それぞれのファイルに写っているコードを、動画については表示されている時間帯とともにすべて挙げよ。"
if ! media_out=$("$uv_bin" run --script "$server" --selftest-look "$media_prompt" "$still" "$clip"); then
	echo "--- 出力(途中まで) ---"
	echo "$media_out"
	echo "----------------------"
	echo "✗ --selftest-look が非0で終了した — 媒体を見せる経路が壊れている"
	echo "  (権限不足なら、失敗メッセージに settings.json の直し方が書いてあるはず)"
	exit 1
fi
echo "--- 出力 ---"
echo "$media_out"
echo "------------"

media_ok=1
# 【期待するのは「それらしい説明」ではなく、焼き込んだ文字列そのもの】
#   説明文の一致で判定すると、モデルがファイル名から作文しただけの回答でも
#   通ってしまう(原則4: それらしい出力は 0件より危険)。
#   コードは合成媒体の画素にしか存在しないので、これが返る = 本当に見ている。
#   grep -F: ランダムな英数字コードを正規表現として解釈させない。
for code in QZ7M-4419 VX3K-8827 NP5R-1163; do
	if ! printf '%s' "$media_out" | grep -qF "$code"; then
		echo "✗ 出力にコード $code が無い — 媒体を実際には読めていない可能性"
		media_ok=0
	fi
done
# 動画の2つのコードは**時間帯が違う**。片方しか出ないなら、静止画1枚として
# 見ている(時間軸を持って読んでいない)疑いがあるので、上の3件が揃うことを要求する。
if [ "$media_ok" -ne 1 ]; then
	echo "  期待: 画像 QZ7M-4419 / 動画 0〜5秒 VX3K-8827・5〜10秒 NP5R-1163"
	echo "  (材料の説明は plugins/agy-mcp/scripts/fixtures/README.md)"
	exit 1
fi
echo "✓ 媒体: 画像1件・動画2件(時間帯違い)のコードをすべて正しく読めた"

echo ""
echo "✓ smoke.sh: すべて合格"
