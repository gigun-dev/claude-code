# t3 — T3 Code の子タスク委譲

T3 Code が各スレッドへ注入する `t3-code` MCP サーバーの `delegate_task` で、
別のプロバイダ・モデルを子スレッドとして動かす skill(`t3-delegate`)。
T3 Code の外では使わない。

## 出典

[ryoppippi/dotfiles](https://github.com/ryoppippi/dotfiles)(MIT)の
`agents/skills/t3-delegate/SKILL.md` を元にしている。上流にあった特定プロバイダの
quota 方針は外した。残量確認は `t3-limits` skill が入っていれば使う。
`t3-limits` は上流に plugin 定義が無く、この marketplace には載せていない
(手で導入する)。
