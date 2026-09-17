---
name: integrate
description: >-
  Integrate a subagent's finished git worktree: squash-merge, let the caller write
  and make the commit, then clean up only after the commit is verified. Use when a
  worktree's work is done and ready to land — the primary path, not sweep.
metadata:
  version: "0.1.0"
---

# worktree:integrate

`isolation: worktree` で終わった子を取り込む主経路。実体は
`../../bin/integrate`(絶対パスに解決して呼ぶこと)。2 段階に分かれていて、
間に必ずコミットが要る。

```bash
"<このスキルのディレクトリ>/../../bin/integrate" merge <worktree-path>
```

基準ブランチへ squash-merge する。**競合が残れば自動解決せず、そこで止めて報告する。**
競合ファイルの一覧を読み、対象の worktree で解決すること。

競合が無ければ index に変更が入った状態で終わる。**コミットはここではしない**
—— メッセージは呼び出し元(あなた)が書き、`git commit` すること。

```bash
git -C <root> commit -m "..."
"<このスキルのディレクトリ>/../../bin/integrate" finish <worktree-path>
```

コミット後に `finish` を呼ぶ。**取り込みのコミットが実際に成立しているかを
機械的に確かめてから**(sweep と同じ squash 判定を、コミット後の基準ブランチに
対して実行する)、確かめられた場合だけ worktree とブランチ(`-D`)を消す。
確かめられなければ何も消さず理由を出力する —— コミット忘れや競合が残ったままの
コミットはここで止まる。

**順序を手で守る必要は無い**: `merge` → commit → `finish` を 1 コマンドにまとめて
後段を前段の成否に繋げなくても、`finish` 自身が取り込みの成立を検査するので
未成立のまま消えることは無い。
