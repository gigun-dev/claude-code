# skill だけのものは plugin にせず dotfiles の agent-skills-nix で配る

Date: 2026-11-13
Implementation: pending

gigun marketplace は、skill だけでできたものも plugin として配っていた。上流があるものは外部参照(ADR 0004)かベンダー複製のどちらかで、その違いがホストへの届き方を変えた。外部参照は Claude では `claude plugin update`、Codex では `plugin add` のやり直しをしないと版が上がらず、agy には `gitNames` に足したものしか届かない。ベンダー複製は 3 ホストに届くが、版を進める方針が外部参照と食い違った。

skill だけでできたものは plugin で包まず、dotfiles の agent-skills-nix が `flake.lock` に固定した版を各ホストが読む場所へ置く。上流があるものは dotfiles が上流を直接固定し、このリポジトリには複製しない。このリポジトリが正本を持つものは `skills/` に置き、dotfiles が gigun-plugins input から読む。commands・MCP・`bin/`・agents など skill 以外を持つものは plugin に残す。

置く場所は、使い捨て skill で実測したホストの読み込み先に合わせる。Claude は `~/.claude/skills`、Codex は `~/.agents/skills`、agy CLI は `~/.gemini/skills` だけを読む。Codex は SKILL.md 単体の symlink を読まないので、`~/.agents/skills` だけは skill のディレクトリごとに link する。

Accepting: nix の無い環境(Nix を外す途中の mini の macOS を含む)には skill が届かない。必要になれば別の配り方を足す
Accepting: plugin の名前空間が無くなり、ホストに同じ名前の skill が並んでもホストは片方に絞らない。名前の重複は agent-skills-nix の評価で止める
Accepting: GUI の plugin 一覧から個別にオン・オフできない。要・不要は dotfiles の選択で決める
Accepting: 上流の版は dotfiles の lock 更新の PR で進み、marketplace の外部 plugin とは更新の流れが別になる
Rejected: 外部参照をやめてすべてベンダー複製で揃える — 複製の追従と差分管理をこのリポジトリが抱え続けるため
Rejected: すべて外部参照で揃える — 上流が plugin 定義を持たない skill(ryoppippi/dotfiles など)は参照できないため
Rejected: agy の gitNames に外部 Git plugin を足し続ける — Claude と Codex の更新の問題が残るため
