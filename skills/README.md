# skills — plugin で包まずに配る skill

skill だけでできたものは plugin にせず、dotfiles の agent-skills-nix がこのディレクトリを
読んで Claude Code・Codex・agy へ直接置く(ADR 0006)。ここに置くのは、このリポジトリが
正本を持つものだけ。pre-push はリポジトリの CI と重なるので廃止した。上流がある skill は dotfiles 側で上流を直接固定して読む。

| skill | 正本 | 備考 |
|---|---|---|
| [`japanese-tech-writing`](japanese-tech-writing/SKILL.md) | k16shikano 氏の [gist](https://gist.github.com/k16shikano/fd287c3133457c4fd8f5601d34aa817d)(raw revision `8f2d57610a73efc97d743c9b0b0ecb1002e09fa4`)の逐語の複製 | Unlicense。ローカルで編集しない。更新は上流から取り直して丸ごと入れ替える |
