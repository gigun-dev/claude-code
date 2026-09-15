# worktree-sweep — サブエージェントが残した git worktree を掃除する

`bin/worktree-sweep` は git worktree を 3 分類する: 消せる / 人が決める / 触るな。
worktree の掃除は git の操作で、Claude でも Codex でも同じように要るため、
`.claude-plugin/plugin.json` と `.codex-plugin/plugin.json` を両方持つ CLI + skill
として作ってある(`telemetry` `todo` `pre-push` と同じ構え)。

## squash 判定

既定ブランチの祖先であることだけでは、`git merge --squash` で取り込まれたブランチを
「消せる」に分類できない(squash は新しい 1 コミットを作るので祖先関係が切れる)。

このスクリプトは、祖先でない場合に限り追加の機械判定を行う。分岐後にブランチが
触れたファイル(`merge-base(base, head)..head` の変更ファイル)に絞り、基準ブランチ
との diff が空かどうかを見る。空なら「そのブランチ固有の変更は基準側に既に含まれて
いる」と言えるため消せる扱いにする。比較材料が無い(分岐後にファイル変更が無い)、
または diff が残る場合は squash 済みかもしれないが機械には判断できないとして
人が決めるに残す —— 推測では消さない。

## 消し急ぎを防ぐ

`--apply` が worktree とブランチを消すのは、この判定で「消せる」と出た対象だけ。
この道具を経由せず `git worktree remove` / `git branch -D` を直接叩けば、この判定は
働かない。安全装置は道具を通ったときにだけ効く。

## 使い方

```bash
plugins/worktree-sweep/bin/worktree-sweep                      # カレントリポジトリを判定
plugins/worktree-sweep/bin/worktree-sweep --all                # ghq 配下で worktree を持つ全リポジトリ
plugins/worktree-sweep/bin/worktree-sweep --apply <repo>        # 判定どおりに削除
plugins/worktree-sweep/bin/worktree-sweep --apply --purge-ignored <repo>  # ignore 成果物ごと削除
```

`--force` は使わない。locked / prunable / detached には触らない。未コミット・未追跡が
あれば保持する。skill は `skills/sweep/SKILL.md`。

## テスト

```sh
bash plugins/worktree-sweep/tests/test_worktree_sweep.sh
```

squash 取り込み・非 squash・ignore 成果物・locked worktree の判定を、使い捨てリポジトリ
で確かめる。
