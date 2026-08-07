# Claude Code / Codex 共有ハーネス

Claude Code 側を正典にし、同じ内容を表現できる Codex surface は symlink で共有する。

| Codex | 正典 | 方式 |
| --- | --- | --- |
| `AGENTS.md` | `CLAUDE.md` | symlink |
| `.agents/skills/*` | `.claude/skills/*` | symlink |
| `.codex/hooks/session-start.sh` | `.claude/hooks/session-start.sh` | symlink |

`.codex/hooks.json` と `.codex/config.toml` は設定形式が異なるため、薄い Codex 専用 adapter として
管理する。

## コンテキストの正典

1. `AGENTS.md` / `CLAUDE.md`: 常時必要な不変条件。
2. `docs/next-directions.md`: 最新の現在地と次の作業。最初の `session-head-end` までだけを hook 注入。
3. project skills: トリガー時だけ必要な長い手順。
4. `docs/log.md`(あれば): 時系列アーカイブ。通常は全文ロードしない。

Claude project memory や session JSONL / tool results は機械依存・一時的で秘密を含み得るため
symlink しない。恒久化すべき知識だけを上記の instructions / docs / skills へ昇格する。

## 保守

- 共通 instruction、skill、rules、hook script は **Claude 側の正典だけを編集する**。
- Claude settings / plugin / MCP を変えた場合、Codex adapter にも同じ意図を反映する。
- `.claude/settings.local.json` の permission allowlist は個人環境なので Codex へ移植しない。
