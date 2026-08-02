#!/usr/bin/env bash
# SessionStart フック: ios-skills の継続コンテキストへの pointer を常時注入する。
#
# 設計意図(2026-08-02):
#   caldav の docs/next-directions.md は「頭(現在地)」を毎セッション全文注入する。
#   これは caldav が単一プロダクトのリポジトリで、どのセッションもその現在地を
#   知りたがる前提があるから成立する。
#
#   この repo(claude-code)は複数の独立したプラグインの寄せ集め(marketplace)で、
#   ios-skills はその一つに過ぎない。全文注入すると、ios-skills と無関係な
#   セッション(他プラグインの作業)にまで毎回コストを強制する。
#
#   そのため注入は軽量な pointer 一行だけに絞る。実際に ios-skills を触るときは
#   .claude/rules/ios-skills.md(path-scoped rule)がより強く思い出させる —— この
#   フックは「セッションを開いた瞬間に気づく」予防型、rule は「触ったら気づく」
#   反応型で、役割を分けている。
set -euo pipefail

doc="${CLAUDE_PROJECT_DIR:-.}/docs/ios-skills/next-directions.md"
[ -f "$doc" ] || exit 0  # 正典が無ければ無言で終了(フックはセッションを止めない)

echo '=== ios-skills を開発するなら: 現在地は docs/ios-skills/next-directions.md、時系列の記録は docs/ios-skills/log.md ==='
