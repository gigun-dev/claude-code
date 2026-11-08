# cross-agent — 他社エージェント・モデルを使う skill

- `ask-other-agent`: Codex / Claude Code / Grok / Cursor に意見や作業を頼む。
- `review-loop`: 他社の強いモデルによるレビューの反復。
- `web-fetch`: `ax` / `tgrab` / grok 等による Web・SNS 取得。

必要な CLI(dotfiles 側で用意): codex, claude, grok, cursor-agent, ax, tgrab, nu。
exa 手順は bun と 1Password の `op` を使う。

## 出典

[ryoppippi/dotfiles](https://github.com/ryoppippi/dotfiles)(MIT)の
`agents/skills/{ask-other-agent,review-loop,web-fetch}` を原本のまま写している。
固定 commit は [`vendor/upstream-skills.json`](../../vendor/upstream-skills.json)。手で編集しない。
