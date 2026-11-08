# worktree — git-wt で git worktree を扱う

worktree の作成・切り替え・削除・PR の checkout を、`git wt`(k1LoW/git-wt)と
`git wtpr`(PR を worktree で開く)に統一する skill。Claude Code・Codex・agy で
同じ `skills/worktree/SKILL.md` を読む。

## 前提

`git-wt` と `git-wtpr` が PATH にあること。このリポジトリは導入しない
(dotfiles 側で PATH に入れる)。

## 出典

[ryoppippi/dotfiles](https://github.com/ryoppippi/dotfiles)(MIT)の
`agents/skills/worktree/SKILL.md` を元にしている。あわせて同リポジトリの
`agents/shared/git.md`(linked worktree にいるならそこに留まる)と
`agents/shared/delegate-work.md`(isolated worktree の subagent には
1 コマンド 1 呼び出しと `git -C` を指示する)の該当箇所を skill 本文に取り込んだ。

## 旧版からの変更

0.2.0 までの `bin/integrate`・`bin/sweep`・`lib/`・`tests/`・`skills/integrate`・
`skills/sweep` は削除した。squash 取り込みの検査や一括掃除は持たない。
削除は `git wt -d` に任せ、強制削除はユーザーが求めたときだけ行う。
