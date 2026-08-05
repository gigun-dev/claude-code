#!/usr/bin/env bash
# SessionStart フック: 各コンポーネントの継続コンテキストへの pointer を常時注入する。
#
# 設計意図(2026-08-02、2026-08-05 に複数コンポーネント対応へ一般化):
#   caldav の docs/next-directions.md は「頭(現在地)」を毎セッション注入する。
#   これは caldav が単一プロダクトのリポジトリで、どのセッションもその現在地を
#   知りたがる前提があるから成立する。
#
#   この repo(claude-code)は複数の独立したプラグインの寄せ集め(marketplace)で、
#   ios-skills も harness もその一つに過ぎない。全文注入すると、無関係な
#   セッション(他プラグインの作業)にまで毎回コストを強制する。
#
#   そのため注入は軽量な pointer 一行だけに絞る。実際にそのプラグインを触るときは
#   .claude/rules/<plugin>.md(path-scoped rule)がより強く思い出させる —— この
#   フックは「セッションを開いた瞬間に気づく」予防型、rule は「触ったら気づく」
#   反応型で、役割を分けている。
#
#   注: harness プラグインが配る session-start.sh(頭を注入する版)とは別物。
#   あちらは単一プロダクト向けで、この repo には合わない。テンプレート側へ
#   「pointer モード」を取り込む案は docs/harness/next-directions.md の着手順2にある。
set -euo pipefail

docs_dir="${CLAUDE_PROJECT_DIR:-.}/docs"
[ -d "$docs_dir" ] || exit 0

# docs/<component>/next-directions.md を持つコンポーネントすべてに pointer を出す。
# ハードコードしないのは、プラグインが増えるたびにこのフックを直す運用が続かないため。
for nd in "$docs_dir"/*/next-directions.md; do
  [ -f "$nd" ] || continue
  component=$(basename "$(dirname "$nd")")
  # 変数展開は必ずブレースで囲う。直後が日本語だと "$line、" のように多バイト文字まで
  # 変数名の一部として解釈され unbound variable で落ちる(2026-08-05 に実際に踏んだ)。
  line="=== ${component} を開発するなら: 現在地は docs/${component}/next-directions.md"
  [ -f "$docs_dir/$component/log.md" ] && line="${line}、時系列の記録は docs/${component}/log.md"
  echo "${line} ==="
done
