# Claude Code / Codex の共有設定

| Codex | 正典 | 方式 |
| --- | --- | --- |
| `AGENTS.md` | `CLAUDE.md` | symlink |
| `evaluations/AGENTS.md` | `.claude/rules/ios-skills.md` | symlink |

タスクは `todo.txt`、決定は `docs/adr/`、評価手順は `evaluations/README.md` を読む。
プラグインは `.agents/plugins/marketplace.json` で配布する。
SessionStart フックは使用しない。harness からの移行は `docs/harness/migration.md` を参照する。

配布物の `plugins/` 配下には、リポジトリ内部の運用ファイルへの symlink を置かない。
インストール先でリンク切れになるため。エージェント定義は `.codex/agents/` に置く。
