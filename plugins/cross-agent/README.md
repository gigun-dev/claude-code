# cross-agent — 他社エージェント・モデルを使う skill

- `ask-other-agent`: Codex / Claude Code / Grok / Cursor に意見や作業を頼む。
- `review-loop`: 他社の強いモデルによるレビューの反復。

必要な CLI(dotfiles 側で用意): codex, claude, grok, cursor-agent, nu。

上流の `web-fetch` は写していない。skill のディレクトリに `ax` / `tgrab` の実体を
置く agent-skills-nix の配り方が前提で(`./ax` と呼ぶ)、plugin では動かないため。
`ask-other-agent` の X 検索の手順はこれを参照する。

## 出典

[ryoppippi/dotfiles](https://github.com/ryoppippi/dotfiles)(MIT)の
`agents/skills/{ask-other-agent,review-loop}` を原本のまま写している。
固定 commit は [`vendor/upstream-skills.json`](../../vendor/upstream-skills.json)。手で編集しない。
