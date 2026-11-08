# t3 — T3 Code の子タスク委譲と quota 確認

- `t3-delegate`: `t3-code` MCP サーバーの `delegate_task` で別プロバイダ・モデルを子スレッドとして動かす。
- `t3-limits`: 各プロバイダの quota 残量を確認する。`t3-limits` CLI と `t3` CLI が PATH に必要。
- `.mcp.json`: T3 Code の MCP サーバー(`http://127.0.0.1:3773/mcp`)。

## 出典

[ryoppippi/dotfiles](https://github.com/ryoppippi/dotfiles) の `agents/skills/t3-delegate` と
[ryoppippi/t3-limits](https://github.com/ryoppippi/t3-limits) の `skills/t3-limits`(いずれも MIT)を
原本のまま写している。固定 commit は
[`vendor/upstream-skills.json`](../../vendor/upstream-skills.json)。手で編集しない。
