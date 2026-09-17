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
	"plugin.json 版数整合性チェック (.claude-plugin ⇔ .codex-plugin)"
	"marketplace.json プラグイン一覧整合性チェック (.claude-plugin ⇔ .agents)"
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
# plugin.json 版数整合性チェック — .claude-plugin ⇔ .codex-plugin
# -----------------------------------------------------------------------
# 【何を・なぜ比較するか】
#   1つのプラグインは plugins/<name>/.claude-plugin/plugin.json(Claude 向け)と
#   plugins/<name>/.codex-plugin/plugin.json(Codex 向け)の2枚のマニフェストを
#   同じ内容の別表現として持つ。version は「同じ世代を指しているか」を表す唯一の
#   フィールドなので、ここがズレると「どちらが最新か分からない配布物」が生まれる
#   —— 実際に plugins/harness で、片方だけ version を上げて push した状態が
#   本番の main に存在していた(2026-08-08 の敵対的検証で発覚)。
#
# 【"+" 以降(semver のビルドメタデータ)は比較しない】
#   .codex-plugin 側の一部プラグイン(例: xcode-mcp)は
#   "1.0.0+codex.20260805161201" のように、生成のたびに変わるタイムスタンプを
#   ビルドメタデータとして付与している。これは semver の定義上「世代」を表さない
#   (同じ 1.0.0 の再生成にすぎない)。ここを含めて文字列比較すると、世代が同じ
#   でも生成し直すたびに verify.sh が赤くなる —— 本当に見たいズレ(世代の違い)
#   ではなく、無関係な再生成のたびに誤検知する検査になってしまう。
#   だから比較対象は "+" より前(major.minor.patch 相当)だけに絞る。
#
# 【.codex-plugin を持たないプラグインを対象外にする理由】
#   Codex 未対応のプラグインが .claude-plugin だけを持つのは異常ではない
#   (このリポジトリは Claude 専用プラグインも配布している)。比較できるのは
#   両方が揃っているペアだけなので、片方しか無いものは黙って対象から外す。
#   ただし**ペアが1件も無い**のは別の話 —— このリポジトリには todo を含め
#   両方を持つプラグインが常に複数存在するため、0件は「対象が無いから合格」
#   ではなく「収集自体が壊れた疑い」として失敗扱いにする。
#
# 【対になる .codex-plugin/plugin.json の実在判定に `[ -f ]` ではなく git ls-files
#   を使う理由】(2026-08-08 実測して直した)
#   実際に手元の作業ツリーには、.claude-plugin/plugin.json は git 追跡されているのに
#   .codex-plugin/plugin.json が**追跡されていない**プラグインが複数ある
#   (例: chrome-devtools-mcp・dart-mcp 等。scripts/sync_mcp_wrappers.py が
#   ローカルで生成する未追跡の作業ファイルらしい — この生成物自体は本タスクの対象外)。
#   `[ -f "$xf" ]` はファイルシステムの実在だけを見るので、こうした未追跡ファイルも
#   拾って比較対象に混ぜてしまう。すると「push はされない、手元にしか無いファイルの
#   version が違う」だけで verify.sh が赤くなる —— このスクリプトの冒頭に書いた
#   「対象の列挙に git ls-files を使う理由」(push されるもの = git が追跡している
#   ものを検査対象の定義にする)にそのまま反する事故になる。だから対になる側も
#   git ls-files で追跡有無を判定し、未追跡なら「対象外(片方しか無い)」と同じ扱いで
#   黙って飛ばす。
echo ""
check_header
ver_failed=0
if ! command -v python3 >/dev/null 2>&1; then
	# python3 が無いのに黙って検査をスキップすると「検査した結果 OK」と区別が付かない。
	# 未検査を合格扱いにしない。
	echo "✗ python3 が見つからない — plugin.json の版数整合性を検査できない(未検査を合格扱いにしない)"
	ver_failed=1
else
	claude_manifests=$(git ls-files 'plugins/*/.claude-plugin/plugin.json')
	if [ -z "$claude_manifests" ]; then
		echo "✗ 追跡対象の plugins/*/.claude-plugin/plugin.json が1件も見つからない(収集が壊れている可能性)"
		ver_failed=1
	else
		npairs=0
		while IFS= read -r cf; do
			# plugins/<name>/.claude-plugin/plugin.json → plugins/<name> を取り出し、
			# 対になる .codex-plugin/plugin.json を同じ階層で探す。
			plugin_dir=${cf%/.claude-plugin/plugin.json}
			xf="$plugin_dir/.codex-plugin/plugin.json"
			# git 追跡されていなければ対象外(理由は上のコメント「git ls-files を
			# 使う理由」)。`[ -f ]` ではなく `git ls-files --error-unmatch` で判定する。
			git ls-files --error-unmatch -- "$xf" >/dev/null 2>&1 || continue
			npairs=$((npairs + 1))
			# 両ファイルの version を読み、"+" より前だけを比較する(理由は上のコメント)。
			# 失敗(JSON 破損・version 欠如)は標準エラーへ出して非0で返す —— JSON が
			# 壊れていても黙って一致扱いにはしない。
			diff_out=$(python3 -c '
import json, sys

def base_version(path):
    with open(path, encoding="utf-8") as fp:
        v = json.load(fp)["version"]
    # semver のビルドメタデータ(+ 以降)は世代を表さない。
    return v.split("+", 1)[0]

a = base_version(sys.argv[1])
b = base_version(sys.argv[2])
if a != b:
    print(f"{a}\t{b}")
' "$cf" "$xf" 2>&1)
			rc=$?
			if [ "$rc" -ne 0 ]; then
				echo "✗ [ver]  $plugin_dir: version の読み取りに失敗した"
				echo "$diff_out" | sed 's/^/    /'
				ver_failed=1
			elif [ -n "$diff_out" ]; then
				claude_v=$(printf '%s' "$diff_out" | cut -f1)
				codex_v=$(printf '%s' "$diff_out" | cut -f2)
				echo "✗ [ver]  $plugin_dir: version が不一致(.claude-plugin=$claude_v / .codex-plugin=$codex_v)"
				ver_failed=1
			fi
		done <<<"$claude_manifests"
		if [ "$npairs" -eq 0 ]; then
			echo "✗ .claude-plugin と .codex-plugin を両方持つプラグインが1件も見つからない(収集が壊れている可能性)"
			ver_failed=1
		fi
	fi
fi
if [ "$ver_failed" -eq 0 ]; then
	echo "✓ plugin.json 版数整合性: 問題なし"
fi
[ "$ver_failed" -ne 0 ] && overall_failed=1

# -----------------------------------------------------------------------
# marketplace.json プラグイン一覧整合性チェック — .claude-plugin ⇔ .agents
# -----------------------------------------------------------------------
# 【何を・なぜ比較するか】
#   このリポジトリは同じ「配布するプラグインの集合」を2箇所に持つ:
#     - .claude-plugin/marketplace.json (Claude 向け。plugins[].source は文字列)
#     - .agents/plugins/marketplace.json (Codex 向け。plugins[].source は
#       policy/category を持つオブジェクト)
#   スキーマが違う(上の plugin.json 版数整合性チェックの .claude-plugin/.codex-plugin
#   と同じ二重管理の形)ので、比較できるのは plugins[].name の集合のみ ——
#   source や policy の値までは構造が違いすぎて機械的に突き合わせられない。
#   名前の集合さえ揃っていれば「両方のマーケットプレイスが同じプラグイン一覧を
#   配布している」という最低限の事実は保証できる。
#
#   JSON としてのパース可否だけを見る検査ではこの不一致を検出できない。片方の
#   marketplace.json にだけプラグインを1件足して他方を更新し忘れても、
#   両方とも文法的に正しい JSON のままだと素通りしてしまう。この検査が
#   埋めているのはその隙間。
#
# 【この検査を足す根拠 —— なぜ「起きてもいない不整合の先回り」ではないか】
#   plugin.json 版数整合性チェックで実際にズレた plugins/harness の version
#   不一致という実例が既に出ており、それが「同じプラグイン集合を指す複数
#   マニフェストを人手だけで同期している」という構造そのものに起因していた。
#   marketplace.json の2ファイルはその構造をそのまま持つ既知の危険域であり、
#   新種の不整合を先回りしているわけではない。
#
# 【両ファイルが git 追跡されていて初めて比較する。片方が無ければ「対象外」
#   ではなく「収集が壊れた疑い」として失敗させる理由】
#   plugin.json 版数整合性チェックでの .codex-plugin は「Codex 未対応の
#   プラグインが持たない」のが正常系なので、片方しか無いプラグインは黙って
#   対象外にしている。だがこの2ファイルは事情が違う —— どちらもリポジトリ全体で
#   1つしか無いはずのマーケットプレイス定義そのものであり、「一方だけ存在しない」
#   が起きてよい正常系が無い。もし片方が消えていたら、それはファイル移動・
#   リネーム等でこのスクリプトのパス指定が追随し損ねた可能性の方が高い。
#   「対象が無いから比較しない」を「合格」として扱うと、パス指定のミスを
#   そのまま見逃す最悪の壊れ方になる(検知器は黙って死ぬ前提で検証する)。
echo ""
check_header
mp_failed=0
claude_mp=".claude-plugin/marketplace.json"
codex_mp=".agents/plugins/marketplace.json"
if ! command -v python3 >/dev/null 2>&1; then
	# python3 が無ければ「検査していない」を「合格」に握りつぶさず、明示的に失敗させる。
	echo "✗ python3 が見つからない — marketplace.json のプラグイン一覧整合性を検査できない(未検査を合格扱いにしない)"
	mp_failed=1
else
	claude_tracked=1
	git ls-files --error-unmatch -- "$claude_mp" >/dev/null 2>&1 || claude_tracked=0
	codex_tracked=1
	git ls-files --error-unmatch -- "$codex_mp" >/dev/null 2>&1 || codex_tracked=0
	if [ "$claude_tracked" -eq 0 ] || [ "$codex_tracked" -eq 0 ]; then
		[ "$claude_tracked" -eq 0 ] && echo "✗ $claude_mp が git 追跡されていない(収集が壊れている可能性)"
		[ "$codex_tracked" -eq 0 ] && echo "✗ $codex_mp が git 追跡されていない(収集が壊れている可能性)"
		mp_failed=1
	else
		# python3 側は「読み取り自体の失敗(JSON 破損・plugins/name 欠如)」と
		# 「読み取れた上での差分」を区別する。前者は exit code を非0にして
		# 例外メッセージをそのまま流し、後者は TSV 1行を標準出力へ積んで
		# bash 側で判定する(plugin.json 版数整合性チェックの version 比較と同じ役割分担)。
		diff_out=$(python3 -c '
import json, sys

def names(path):
    with open(path, encoding="utf-8") as fp:
        data = json.load(fp)
    return set(p["name"] for p in data["plugins"])

claude_names = names(sys.argv[1])
codex_names = names(sys.argv[2])

# プラグイン名が0件は「一致しているから合格」ではなく、収集そのものが
# 壊れている疑いとして扱う(plugin.json 版数整合性チェックの npairs -eq 0 と同じパターン)。
if not claude_names or not codex_names:
    print(f"EMPTY\t{len(claude_names)}\t{len(codex_names)}")
else:
    only_claude = ",".join(sorted(claude_names - codex_names))
    only_codex = ",".join(sorted(codex_names - claude_names))
    if only_claude or only_codex:
        print(f"DIFF\t{only_claude}\t{only_codex}")
' "$claude_mp" "$codex_mp" 2>&1)
		rc=$?
		if [ "$rc" -ne 0 ]; then
			echo "✗ [mp]   marketplace.json の読み取りに失敗した"
			echo "$diff_out" | sed 's/^/    /'
			mp_failed=1
		elif [ -n "$diff_out" ]; then
			kind=$(printf '%s' "$diff_out" | cut -f1)
			if [ "$kind" = "EMPTY" ]; then
				claude_count=$(printf '%s' "$diff_out" | cut -f2)
				codex_count=$(printf '%s' "$diff_out" | cut -f3)
				echo "✗ [mp]   プラグイン名が0件($claude_mp=${claude_count}件 / $codex_mp=${codex_count}件) — 収集が壊れている可能性"
				mp_failed=1
			else
				only_claude=$(printf '%s' "$diff_out" | cut -f2)
				only_codex=$(printf '%s' "$diff_out" | cut -f3)
				echo "✗ [mp]   $claude_mp と $codex_mp のプラグイン名の集合が不一致"
				[ -n "$only_claude" ] && echo "    $claude_mp にしか無い: $only_claude"
				[ -n "$only_codex" ] && echo "    $codex_mp にしか無い: $only_codex"
				mp_failed=1
			fi
		fi
	fi
fi
if [ "$mp_failed" -eq 0 ]; then
	echo "✓ marketplace.json プラグイン一覧整合性: 問題なし"
fi
[ "$mp_failed" -ne 0 ] && overall_failed=1

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
