#!/usr/bin/env bash
# =============================================================================
# scripts/verify.sh — このリポジトリの「CI 相当の検証」を1本にまとめたもの
# =============================================================================
# 【なぜこの3つだけか】
#   harness の原則5「強制は最小、検知は最大。落とすのは CI 相当の検証だけ」
#   (docs/principles.md 判断規則 / .claude/rules/harness.md 参照)に従い、
#   pre-push で落とす検査は意図的に最小限へ絞っている。
#   このリポジトリの中身はほぼ Markdown・シェル・JSON で、コンパイルも
#   ユニットテストも存在しない。「壊れたものを事故で main へ push する」を
#   防ぐために必要十分な最小集合は次の3つになる:
#
#     1. シェル構文 — plugins/*/scripts/*.sh はそのまま配布物として
#        各リポジトリへコピーされる。構文エラーのまま push すると
#        配布先のフック・スクリプトがそのまま壊れる。
#     2. JSON 妥当性 — marketplace.json / plugin.json が壊れると
#        マーケットプレイス自体がロードできなくなる(影響範囲が最大)。
#     3. 正典の書式(nd-tasks.sh --lint) — docs/*/next-directions.md の
#        「着手順」節は /harness:status が機械的に読む唯一の節。
#        書式が壊れると読み取りが誤動作する。
#
#   これ以上テストやリンタを増やす方向へ育てないこと。
#   （原則2b: 散文とコードは別の物差しで採点する。コードは「散文を何行
#   消しているか」で採点する — ここに検査を足すなら、それが代替する
#   散文の説明がどこにあるかを先に説明できること。行数の多寡や
#   「あると安心」という理由だけでは足さない）。
#
# 【対象の列挙に git ls-files を使う理由】
#   find 等でファイルシステムを直接漁ると、未追跡の作業ファイルや
#   scratchpad まで検査対象に巻き込んでしまう。実際このリポジトリには
#   未追跡の scripts/sync_mcp_wrappers.py や .agents/ が存在し、これらの
#   構文都合で push が止まるのは理不尽な事故になる。
#   「push されるもの = git が追跡しているもの」を検査対象の定義にする。
#
# 【失敗の扱い: 3つとも走らせてから落ちる】
#   1つでも失敗したら非ゼロで終了するが、最初の失敗で打ち切らない
#   （set -e を使わない）。1回の実行で全種類の問題を出し切ることで、
#   「直して再実行」を3往復させないようにする。
# =============================================================================

set -u
# ⚠️ set -e はあえて使わない。3検査すべてを走らせてから落ちる設計なので、
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
echo "=== [1/3] シェル構文チェック (bash -n) ==="
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
echo "=== [2/3] JSON 妥当性チェック ==="
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
echo "=== [3/3] 正典の書式チェック (nd-tasks.sh --lint) ==="
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
# まとめ
# -----------------------------------------------------------------------
echo ""
if [ "$overall_failed" -ne 0 ]; then
	echo "✗ verify.sh: 検証に失敗した項目がある(上記参照)"
	exit 1
fi
echo "✓ verify.sh: すべての検証に合格した"
exit 0
