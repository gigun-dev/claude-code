---
paths:
  - "plugins/ios-skills/**"
  - "evaluations/**"
  - "docs/ios-skills/**"
---

# ios-skills を触るときに読むもの

次の作業は `todo.txt` の `+ios-skills`、決定は `docs/adr/` にある。
旧 ID と詳細の対応は `docs/harness/migration.md` を参照する。
`docs/ios-skills/next-directions.md` と `log.md` は過去の測定・判断を調べる参照記録で、更新しない。

`evaluations/` は評価の手順・入力・実行器・測定結果を置く。
評価を変更するときは `evaluations/README.md` を読む。
対象は `plugins/ios-skills/` の改善で、外部製品を接続するだけの `xcode-mcp` は対象外。

Codex では `evaluations/AGENTS.md` がこのファイルへの symlink。
配布物の `plugins/` にリポジトリ外を指す symlink を置かない。
