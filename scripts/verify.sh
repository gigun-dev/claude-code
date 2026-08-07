#!/usr/bin/env bash
# =============================================================================
# scripts/verify.sh — このリポジトリの「CI 相当の検証」を1本にまとめたもの
# =============================================================================
# 【なぜこの4つだけか】
#   harness の原則5「強制は最小、検知は最大。落とすのは CI 相当の検証だけ」
#   (docs/principles.md 判断規則 / .claude/rules/harness.md 参照)に従い、
#   pre-push で落とす検査は意図的に最小限へ絞っている。
#   このリポジトリの中身はほぼ Markdown・シェル・JSON で、コンパイルも
#   ユニットテストも存在しない。「壊れたものを事故で main へ push する」を
#   防ぐために必要十分な最小集合は次の4つになる:
#
#     1. シェル構文 — plugins/*/scripts/*.sh はそのまま配布物として
#        各リポジトリへコピーされる。構文エラーのまま push すると
#        配布先のフック・スクリプトがそのまま壊れる。
#     2. JSON 妥当性 — marketplace.json / plugin.json が壊れると
#        マーケットプレイス自体がロードできなくなる(影響範囲が最大)。
#     3. 正典の書式(nd-tasks.sh --lint) — docs/*/next-directions.md の
#        「着手順」節は /harness:status が機械的に読む唯一の節。
#        書式が壊れると読み取りが誤動作する。
#     4. plugin.json の版数整合性(.claude-plugin ⇔ .codex-plugin) —
#        2026-08-08 の敵対的検証で実際にズレていたのを発見した
#        (plugins/harness: .claude-plugin は 0.15.0、.codex-plugin だけ
#        0.14.0 のまま。同じプラグインの同じ世代を指す2つのマニフェストの
#        片方だけを上げる操作が過去に起きた実例)。1つ2つに片方だけ手で
#        直しても、次に version を上げる誰か(モデルでも人でも)が
#        もう一方を上げ忘れる経路は塞がっていない。「揃える」だけでは
#        同じ壊れ方が再発するので、再発防止を機械へ足す。
#
#   これ以上テストやリンタを増やす方向へ育てないこと。
#   （原則2b: 散文とコードは別の物差しで採点する。コードは「散文を何行
#   消しているか」で採点する — ここに検査を足すなら、それが代替する
#   散文の説明がどこにあるかを先に説明できること。行数の多寡や
#   「あると安心」という理由だけでは足さない。上の4番目は「あると安心」
#   ではなく「実際にズレた事実がある」ことを根拠に足した唯一の例外
#   —— 起きてもいない不整合を投機で先回りして検査に足すことは、
#   この4番目を足した後も引き続き禁止(docs/principles.md 規則2)。
#   新しいマニフェストの組(例: 将来別のアダプタが増える)が実際に
#   ズレるまでは、それ用の検査を先回りで足さないこと）。
#
# 【対象の列挙に git ls-files を使う理由】
#   find 等でファイルシステムを直接漁ると、未追跡の作業ファイルや
#   scratchpad まで検査対象に巻き込んでしまう。実際このリポジトリには
#   未追跡の scripts/sync_mcp_wrappers.py や .agents/ が存在し、これらの
#   構文都合で push が止まるのは理不尽な事故になる。
#   「push されるもの = git が追跡しているもの」を検査対象の定義にする。
#
# 【失敗の扱い: 4つとも走らせてから落ちる】
#   1つでも失敗したら非ゼロで終了するが、最初の失敗で打ち切らない
#   （set -e を使わない)。1回の実行で全種類の問題を出し切ることで、
#   「直して再実行」を4往復させないようにする。
# =============================================================================

set -u
# ⚠️ set -e はあえて使わない。4検査すべてを走らせてから落ちる設計なので、
#    個別コマンドの失敗で即座にスクリプト全体が終了されると困る。
#    各検査は自分で exit code を拾って overall_failed に積み、
#    最後にまとめて判定する。

# git ls-files はカレントディレクトリからの相対パスで結果を返す。
# pre-push はリポジトリ直下で実行される想定だが、手動実行で万一
# サブディレクトリから呼ばれても壊れないよう、リポジトリ直下に固定する。
repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$repo_root" ]; then
	echo "✗ ここは git リポジトリ内ではない(git rev-parse --show-toplevel が失敗)"
	exit 1
fi
cd "$repo_root" || exit 1

overall_failed=0

# -----------------------------------------------------------------------
# (1) シェル構文チェック — 追跡対象の *.sh すべてに bash -n
# -----------------------------------------------------------------------
echo "=== [1/4] シェル構文チェック (bash -n) ==="
sh_failed=0
sh_files=$(git ls-files '*.sh')
if [ -z "$sh_files" ]; then
	# 0件は「対象が無いので合格」ではなく「収集自体が壊れた疑い」として扱う。
	# このリポジトリには plugins/harness/skills/status/scripts/nd-tasks.sh 等、
	# 追跡対象の *.sh が常に複数存在するため、0件は git ls-files や
	# 実行ディレクトリの取り違えを疑うべき異常値。
	# 「検査できなかった」と「合格した」を混同しないために失敗扱いにする。
	echo "✗ 追跡対象の *.sh が1件も見つからない(git ls-files '*.sh' が空) — 収集が壊れている可能性"
	sh_failed=1
else
	while IFS= read -r f; do
		err=$(bash -n "$f" 2>&1)
		rc=$?
		if [ "$rc" -ne 0 ]; then
			echo "✗ [sh]   $f"
			echo "$err" | sed 's/^/    /'
			sh_failed=1
		fi
	done <<<"$sh_files"
fi
if [ "$sh_failed" -eq 0 ]; then
	echo "✓ シェル構文: 問題なし"
fi
[ "$sh_failed" -ne 0 ] && overall_failed=1

# -----------------------------------------------------------------------
# (2) JSON 妥当性チェック — 追跡対象の *.json すべてをパース
# -----------------------------------------------------------------------
echo ""
echo "=== [2/4] JSON 妥当性チェック ==="
json_failed=0
if ! command -v python3 >/dev/null 2>&1; then
	# python3 が無い環境で「JSON チェックを黙ってスキップし、結果として
	# verify.sh 全体が rc=0 で成功扱いになる」のを最も避けたい。
	# 「検査できなかった」と「検査して合格した」は意味が違うのに、
	# 前者を後者として握りつぶす検知器は最悪の壊れ方をする
	# （.claude/rules/harness.md 原則4「検知器は黙って死ぬ前提で検証する」）。
	# だから python3 が無い場合は明示的に失敗させる。
	#
	# ボツ案（Why not）: 「python3 が無ければ JSON チェックをスキップして
	# 警告だけ出す」という案もあり得たが、警告は pre-push の rc には
	# 反映されないため、CI 相当の検証としては機能しない。ここでの目的は
	# 「JSON が壊れたまま main へ push される」を止めることなので、
	# 検査できない = 安全と言い切れない = 落とす、を選んだ。
	echo "✗ python3 が見つからない — JSON 妥当性を検査できない(未検査を合格扱いにしない)"
	json_failed=1
else
	json_files=$(git ls-files '*.json')
	if [ -z "$json_files" ]; then
		# こちらも (1) と同様、0件は収集が壊れている疑いとして失敗させる。
		# .claude-plugin/marketplace.json など、追跡対象の JSON は常に存在する。
		echo "✗ 追跡対象の *.json が1件も見つからない(git ls-files '*.json' が空) — 収集が壊れている可能性"
		json_failed=1
	else
		while IFS= read -r f; do
			err=$(python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as fp:
    json.load(fp)
' "$f" 2>&1)
			rc=$?
			if [ "$rc" -ne 0 ]; then
				echo "✗ [json] $f"
				echo "$err" | sed 's/^/    /'
				json_failed=1
			fi
		done <<<"$json_files"
	fi
fi
if [ "$json_failed" -eq 0 ]; then
	echo "✓ JSON 妥当性: 問題なし"
fi
[ "$json_failed" -ne 0 ] && overall_failed=1

# -----------------------------------------------------------------------
# (3) 正典の書式チェック — docs/*/next-directions.md の「着手順」節
# -----------------------------------------------------------------------
echo ""
echo "=== [3/4] 正典の書式チェック (nd-tasks.sh --lint) ==="
lint_script="plugins/harness/skills/status/scripts/nd-tasks.sh"
lint_failed=0
if [ ! -f "$lint_script" ]; then
	# こちらも「対象が無いから合格」にしない。このリポジトリは harness
	# プラグイン自身の配布元なので nd-tasks.sh は常に存在するはず。
	echo "✗ $lint_script が見つからない — harness プラグインの配置が壊れている可能性"
	lint_failed=1
else
	if ! bash "$lint_script" --lint; then
		lint_failed=1
	fi
fi
[ "$lint_failed" -ne 0 ] && overall_failed=1

# -----------------------------------------------------------------------
# (4) plugin.json 版数整合性チェック — .claude-plugin ⇔ .codex-plugin
# -----------------------------------------------------------------------
# 【何を・なぜ比較するか】
#   1つのプラグインは plugins/<name>/.claude-plugin/plugin.json(Claude 向け)と
#   plugins/<name>/.codex-plugin/plugin.json(Codex 向け)の2枚のマニフェストを
#   同じ内容の別表現として持つ。version は「同じ世代を指しているか」を表す唯一の
#   フィールドなので、ここがズレると「どちらが最新か分からない配布物」が生まれる
#   —— 実際に plugins/harness で、片方だけ version を上げて push した状態が
#   本番の main に存在していた(2026-08-08 の敵対的検証で発覚。上のヘッダコメント
#   「4. plugin.json の版数整合性」を参照)。
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
#   ただし**ペアが1件も無い**のは別の話 —— このリポジトリには harness を含め
#   両方を持つプラグインが常に複数存在するため、0件は (1)(2) と同様「対象が
#   無いから合格」ではなく「収集自体が壊れた疑い」として失敗扱いにする。
#
# 【対になる .codex-plugin/plugin.json の実在判定に `[ -f ]` ではなく git ls-files
#   を使う理由】(2026-08-08 実測して直した)
#   実際に手元の作業ツリーには、.claude-plugin/plugin.json は git 追跡されているのに
#   .codex-plugin/plugin.json が**追跡されていない**プラグインが複数ある
#   (例: chrome-devtools-mcp・dart-mcp 等。scripts/sync_mcp_wrappers.py が
#   ローカルで生成する未追跡の作業ファイルらしい — この生成物自体は本タスクの対象外)。
#   `[ -f "$xf" ]` はファイルシステムの実在だけを見るので、こうした未追跡ファイルも
#   拾って比較対象に混ぜてしまう。すると「push はされない、手元にしか無いファイルの
#   version が違う」だけで pre-push が赤くなる —— このスクリプトの冒頭に書いた
#   「対象の列挙に git ls-files を使う理由」(push されるもの = git が追跡している
#   ものを検査対象の定義にする)にそのまま反する事故になる。だから対になる側も
#   git ls-files で追跡有無を判定し、未追跡なら「対象外(片方しか無い)」と同じ扱いで
#   黙って飛ばす。
echo ""
echo "=== [4/4] plugin.json 版数整合性チェック (.claude-plugin ⇔ .codex-plugin) ==="
ver_failed=0
if ! command -v python3 >/dev/null 2>&1; then
	# (2) の JSON 妥当性チェックと同じ理由(原則4「検知器は黙って死ぬ前提で検証する」)。
	# python3 が無いのに黙って検査をスキップすると「検査した結果 OK」と区別が付かない。
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
			# 失敗(JSON 破損・version 欠如)は (2) と同じく標準エラーへ出して非0で返す
			# —— こちらは (2) の JSON 妥当性チェックが既に拾うはずの壊れ方だが、
			# 万一 (2) をすり抜けた場合でも黙って一致扱いにはしない。
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
# まとめ
# -----------------------------------------------------------------------
echo ""
if [ "$overall_failed" -ne 0 ]; then
	echo "✗ verify.sh: 検証に失敗した項目がある(上記参照)"
	exit 1
fi
echo "✓ verify.sh: すべての検証に合格した"
exit 0
