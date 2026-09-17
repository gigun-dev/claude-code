#!/usr/bin/env bash
# 手で叩く検証。CI と pre-push からは呼ばれない。全項目を実行してから失敗を返す。
# git ls-files で追跡対象を列挙し、未追跡の作業ファイルを混ぜない。

set -u
# ⚠️ set -e はあえて使わない。全検査を走らせてから落ちる設計なので、
#    個別コマンドの失敗で即座にスクリプト全体が終了されると困る。
#    各検査は自分で exit code を拾って overall_failed に積み、
#    最後にまとめて判定する。

# git ls-files はカレントディレクトリからの相対パスで結果を返す。
# リポジトリ直下で実行される想定だが、サブディレクトリから呼ばれても
# 壊れないよう、リポジトリ直下に固定する。
repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$repo_root" ]; then
	echo "✗ ここは git リポジトリ内ではない(git rev-parse --show-toplevel が失敗)"
	exit 1
fi
cd "$repo_root" || exit 1

overall_failed=0

# 検査の名前と順序をここ1箇所だけに持つ。[n/N] は手で書かず、この一覧から
# 数える(check_header)。検査を足す・消すときはこの一覧と対応する呼び出し
# 箇所だけを直せばよく、他の項目の番号は自動で追随する —— 以前は検査を
# 1つ消すたびに残り8箇所の番号を手で書き換える羽目になっていた
# (番号そのものは情報を持たない。進捗は節の名前と最後の合否で分かる)。
# bash 3.2(macOS の /bin/bash)には連想配列(declare -A)が無いので、
# 素朴な添字配列と、呼ばれた回数を数えるだけのカウンタで済ませる。
CHECK_NAMES=(
	"生成マニフェストの整合性チェック (scripts/generate_manifests.py --check)"
	"agy-mcp パース回帰テスト (--selftest-parse)"
	"ADR の形式チェック"
	"todo プラグインのテスト (tests/run.sh)"
	"pre-push プラグインの実 push テスト"
	"telemetry のローカル集計・クエリ回帰テスト"
	"worktree プラグインのテスト (sweep / integrate)"
)
check_total=${#CHECK_NAMES[@]}
check_n=0
check_header() {
	check_n=$((check_n + 1))
	# 検査を足して CHECK_NAMES に名前を足し忘れると、空の名前で
	# [10/9] のような見出しを出して黙って進んでしまう。検知器が黙って
	# 死ぬのを許さない(このファイルが python3 の不在で失敗するのと同じ理由)。
	if [ "$check_n" -gt "$check_total" ]; then
		echo "✗ 検査が CHECK_NAMES の件数($check_total)より多い —— 一覧に名前を足し忘れている"
		overall_failed=1
		echo "=== [$check_n/$check_total] (名前なし) ==="
		return
	fi
	echo "=== [$check_n/$check_total] ${CHECK_NAMES[$((check_n - 1))]} ==="
}

# 逆に、一覧に名前だけ足して呼び出しを足し忘れると最後の項目が走らない。
# 全項目を走らせたあとで件数を突き合わせる(末尾の合否判定の直前で呼ぶ)。
check_count_matches() {
	if [ "$check_n" -ne "$check_total" ]; then
		echo ""
		echo "✗ 走った検査は $check_n 件だが CHECK_NAMES は $check_total 件 —— 呼び出しか一覧のどちらかが欠けている"
		overall_failed=1
	fi
}

# -----------------------------------------------------------------------
# 生成マニフェストの整合性チェック
# -----------------------------------------------------------------------
# 【何を・なぜ比較するか】
#   同じ「配布するプラグインの集合」と「プラグインごとの版数」は、以前は
#   2箇所に手で書かれていた:
#     - plugins/<name>/.claude-plugin/plugin.json の version と
#       plugins/<name>/.codex-plugin/plugin.json の version(同じ世代を
#       指しているか。片方だけ version を上げて push した状態が実際に本番の
#       main に存在していた —— 2026-08-08 の敵対的検証で発覚)
#     - .claude-plugin/marketplace.json(Claude 向け)と
#       .agents/plugins/marketplace.json(Codex 向け)のプラグイン一覧
#   いまはこの2つを scripts/generate_manifests.py が
#   .claude-plugin/plugin.json と .claude-plugin/marketplace.json を元に
#   生成する(手順は CLAUDE.md)。この検査は「生成し直した結果が、いま
#   git に積んである生成物と一致するか」を見る —— 生成を実行し忘れたまま
#   push したときに気付く手段はこれしかない。
echo ""
check_header
if ! command -v python3 >/dev/null 2>&1; then
	# python3 が無いのに黙って検査をスキップすると「検査した結果 OK」と区別が付かない。
	# 未検査を合格扱いにしない。
	echo "✗ python3 が見つからない — 生成マニフェストの整合性を検査できない(未検査を合格扱いにしない)"
	overall_failed=1
elif gen_out=$(python3 scripts/generate_manifests.py --check 2>&1); then
	echo "✓ 生成マニフェストの整合性: 問題なし"
else
	echo "✗ 生成マニフェストが実態とずれている — scripts/generate_manifests.py --write で生成し直すこと"
	printf '%s\n' "$gen_out" | sed 's/^/    /'
	overall_failed=1
fi
# -----------------------------------------------------------------------
# agy-mcp のパース回帰テスト(agy を呼ばない部分だけ)
# -----------------------------------------------------------------------
# 【なぜ smoke.sh 全体ではなく、この一部だけを呼ぶのか】
#   smoke.sh には性質の違う2種類が同居している:
#     [1] --selftest-parse … agy を呼ばない・決定論的・1秒。ここで呼ぶ対象
#     [2][3][4]            … 実 agy を叩く。80〜100秒・課金枠を要る・
#                            トークン更新のタイミングで落ちる(2026-08-10 に実際に落ちた)
#   混ざっているせいで、**決定論的で安いほうまで自動実行できていなかった**
#   (smoke.sh はどこからも呼ばれておらず、人が思い出したときだけ走っていた)。
#   ここで呼ぶのは決定論的な検証だけという線引きに照らすと [1] は入れるべきで、
#   [2][3][4] は入れてはいけない —— ネットワークと課金枠に依存する検査をここに
#   混ぜると「落ちても気にしない」に転んで、検証そのものが形骸化する。
#
# 【なぜ uv が無いときに「スキップ」しないのか】
#   未検査を合格扱いにしない。
#   agy-mcp が存在するのに検査できないなら、それは合格ではなく「検査できていない」。
echo ""
check_header
agy_failed=0
agy_server="plugins/agy-mcp/server.py"
if ! git ls-files --error-unmatch -- "$agy_server" >/dev/null 2>&1; then
	# プラグインごと存在しない配布先もあるので、追跡されていなければ検査対象なし。
	echo "- $agy_server が無いので検査しない(このリポジトリに agy-mcp は入っていない)"
else
	if ! command -v uv >/dev/null 2>&1; then
		echo "✗ uv が見つからない — agy-mcp のパース回帰テストを実行できない(未検査を合格扱いにしない)"
		agy_failed=1
	else
		if agy_out=$(uv run --script "$agy_server" --selftest-parse 2>&1); then
			echo "✓ agy-mcp パース回帰テスト: 問題なし"
		else
			echo "✗ agy-mcp のパース回帰テストが失敗した"
			echo "$agy_out" | tail -20 | sed 's/^/    /'
			agy_failed=1
		fi
	fi
fi
[ "$agy_failed" -ne 0 ] && overall_failed=1

# ADR の単体テストに加え、リポジトリ自身の決定を検査する。
echo ""
check_header
if [ ! -d docs/adr ]; then
    echo "✗ docs/adr が見つからない"
    overall_failed=1
elif plugins/todo/bin/adr check; then
    echo "✓ ADR: 問題なし"
else
    overall_failed=1
fi

# -----------------------------------------------------------------------
# todo プラグインのテスト
# -----------------------------------------------------------------------
# 【なぜ関門に入れるのか】
#   ヘッダの「これ以上テストやリンタを増やすな」は**投機的な検査**の禁止であって、
#   配布物が自分で持っているテストを走らせないことの推奨ではない。
#   plugins/todo/tests/run.sh は決定論的(日付は TODO_TODAY で固定。採番は連番なので
#   空のディレクトリから始めれば決まる)・ネットワーク不要・1秒未満
#   = agy-mcp の --selftest-parse と同じ性質。
#   にもかかわらず、足した時点ではどこからも呼ばれておらず、人が思い出したときだけ
#   走る状態だった —— --selftest-parse を足したときと同じ理由でここへ入れる。
#
#   ⚠️ **ここに入れてよいのはこの性質のテストだけ。** ネットワーク・課金枠・実機に
#   依存するテストを関門にすると「落ちても気にしない」に転んで、関門ごと死ぬ。
echo ""
check_header
todo_failed=0
todo_tests="plugins/todo/tests/run.sh"
if ! git ls-files --error-unmatch -- "$todo_tests" >/dev/null 2>&1; then
	echo "- $todo_tests が無いので検査しない(このリポジトリに todo プラグインは入っていない)"
else
	if todo_out=$(sh "$todo_tests" 2>&1); then
		echo "✓ todo プラグイン: $(printf '%s\n' "$todo_out" | tail -1)"
	else
		echo "✗ todo プラグインのテストが失敗した"
		printf '%s\n' "$todo_out" | tail -30 | sed 's/^/    /'
		todo_failed=1
	fi
fi
[ "$todo_failed" -ne 0 ] && overall_failed=1

# -----------------------------------------------------------------------
# pre-push プラグインの実 push テスト
# -----------------------------------------------------------------------
# ローカルの bare リポジトリで、配布する Git フックの実際の成否を検証する。
echo ""
check_header
if prepush_out=$(python3 plugins/pre-push/tests/test_pre_push.py 2>&1); then
    printf '%s\n' "$prepush_out" | tail -4
else
    printf '%s\n' "$prepush_out"
    overall_failed=1
fi

# Local fixtures cover period boundaries, usage accounting, and query output.
echo ""
check_header
if [ ! -d plugins/telemetry/tests ]; then
    echo "✗ telemetry tests are missing"
    overall_failed=1
elif telemetry_out=$(python3 -m unittest discover -s plugins/telemetry/tests -p 'test*.py' 2>&1); then
    if printf '%s\n' "$telemetry_out" | grep -q 'Ran 0 tests'; then
        echo "✗ telemetry test discovery found no tests"
        overall_failed=1
    else
        printf '%s\n' "$telemetry_out" | tail -4
    fi
else
    printf '%s\n' "$telemetry_out"
    overall_failed=1
fi

# 使い捨てリポジトリで squash 判定・消し急ぎ防止・locked の据え置き・
# integrate の merge/finish と競合時の停止を実機確認する。
echo ""
check_header
if worktree_out=$(bash plugins/worktree/tests/run.sh 2>&1); then
    printf '%s\n' "$worktree_out" | tail -2
else
    printf '%s\n' "$worktree_out"
    overall_failed=1
fi

# -----------------------------------------------------------------------
# まとめ
# -----------------------------------------------------------------------
check_count_matches
echo ""
if [ "$overall_failed" -ne 0 ]; then
	echo "✗ verify.sh: 検証に失敗した項目がある(上記参照)"
	exit 1
fi
echo "✓ verify.sh: すべての検証に合格した"
exit 0
