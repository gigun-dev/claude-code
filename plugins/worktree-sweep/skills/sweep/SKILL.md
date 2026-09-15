---
name: sweep
description: >-
  Clean up git worktrees a subagent left behind. Use when asked to sweep, clean up,
  or garbage-collect worktrees, or when finishing delegated work that used
  isolation: worktree.
metadata:
  version: "0.1.0"
---

# worktree-sweep

判定ロジックはこのスキルの配置場所にある `../../bin/worktree-sweep` が持つ。ここで
作り直さず、絶対パスに解決してそれを呼ぶこと。

## 手順

1. まず判定だけ実行して結果を見せる(引数はそのまま渡す。無ければカレントリポジトリ)。

   ```bash
   "<このスキルのディレクトリ>/../../bin/worktree-sweep" $ARGUMENTS
   ```

2. 出力は3分類: 「消せる」「人が決める」「触るな」。最後の合計行で件数と
   回収見込み容量を報告する。
   - 「人が決める」のうち ignore 成果物のみ残存のものは、内訳(ディレクトリ名とサイズ)
     を見せて、再生成できるものか(build 等)戻せないものか(ローカル DO/D1 の実体等)を
     利用者に判断してもらう。
   - 祖先ではないが squash 取り込みと同等と機械判定できたものは「消せる」に含まれる。
     判定できなかったものは「人が決める」に残り、理由(比較材料が無い/差分が残る)を出す。
3. 対象のエージェントが終了していることを確認する。利用者が承認したら削除する。
   - 通常の worktree だけ: `--apply`。
   - ignore 成果物ごと消してよいと判断されたものも含める: `--apply --purge-ignored`。

## 引数

- 無し: カレントリポジトリ
- `--all`: ghq 配下で worktree を持つ全リポジトリ
- パス: そのリポジトリだけ
- `--purge-ignored`: ignore 成果物のみ残る worktree も削除対象に含める(単独では判定のみ。
  `--apply` と併用して初めて消える)

## squash 判定

基準ブランチの祖先でなくても、`git merge --squash` で取り込まれていることがある。
このスキルは、分岐後にブランチが触れたファイルだけに絞り、基準ブランチと差分が
残っていないかを機械的に見る。差分が無ければ squash 取り込み済みと同等とみなして
消せる扱いにする。比較材料が無い、または差分が残る場合は推測せず人が決めるに残す。

## 消し急ぎを防ぐ

`--apply` はこの判定で「消せる」と出た対象しか消さない。この道具を経由せず
`git worktree remove` / `git branch -D` を直接叩くと、この判定は一切働かない ——
必ずこの道具を通すこと。

## 注意

- `--apply` は worktree のディレクトリとブランチを消す。未追跡・ignore 成果物、lock、
  未取込 commit、Git の判定失敗があれば保持する。unlocked の稼働中 agent は検出できず、
  判定直後の ignore ファイル生成とも競合するため、**停止済みの作業だけを対象にする**。
- `--force` は使わない。lock / prunable / detached には触らない。
- 「人が決める」が多いときは、掃除ではなく取り込みの問題。マージするか捨てるかを先に決める。
