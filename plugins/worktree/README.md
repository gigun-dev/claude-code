# worktree — サブエージェントが使った git worktree を扱う

worktree の扱いは git の操作で、Claude でも Codex でも同じように要るため、
`.claude-plugin/plugin.json` と `.codex-plugin/plugin.json` を両方持つ CLI + skill
として作ってある(`telemetry` `todo` `pre-push` と同じ構え)。判定・squash 検査の
共有ロジックは `lib/common.sh`。

2 つの道具がある。**`integrate` が主経路、`sweep` は integrate を経ずに残った分を
拾う網。**

## integrate — 取り込みの主経路 (`bin/integrate`, `skills/integrate/`)

```bash
plugins/worktree/bin/integrate merge <worktree-path>   # squash-merge。競合は自動解決せず止める
git -C <root> commit -m "..."                           # コミットは呼び出し元が書く
plugins/worktree/bin/integrate finish <worktree-path>   # コミットの成立を確認してから片付け
```

`finish` は「分岐後にブランチが触ったファイルが基準ブランチの現在の HEAD と差分なしか」
を機械的に確かめ(sweep と同じ squash 判定)、確かめられて初めて worktree とブランチ
(`-D`)を消す。確かめられなければ何も消さず理由を言う。**順序を守れと書くのではなく、
守られたことを道具が確かめる**——2026-09-15 に、親が merge・コミット・片付けを 1 コマンドに
まとめてコミット失敗のまま worktree とブランチを消した事故を受けて、この確認を必須にした。

## sweep — 取りこぼしの網 (`bin/sweep`, `skills/sweep/`)

git worktree を 3 分類する: 消せる / 人が決める / 触るな。

```bash
plugins/worktree/bin/sweep                              # カレントリポジトリを判定
plugins/worktree/bin/sweep --all                         # ghq 配下で worktree を持つ全リポジトリ
plugins/worktree/bin/sweep --apply <repo>                 # 判定どおりに削除
plugins/worktree/bin/sweep --apply --purge-ignored <repo> # ignore 成果物ごと削除
```

### squash 判定と限界

既定ブランチの祖先であることだけでは、`git merge --squash` で取り込まれたブランチを
「消せる」に分類できない(squash は祖先関係を切る)。祖先でない場合に限り、分岐後に
ブランチが触れたファイルに絞って基準ブランチと diff が空かどうかを見る。空なら
「分岐後の変更は基準側に既に含まれている」と言えるため消せる扱いにする。比較材料が
無い、または diff が残る場合は squash 済みかもしれないが機械には判断できないとして
人が決めるに残す —— 推測では消さない。

**限界**: この判定は「未取込」と「基準側が独立に同じファイルを進めた」を区別できない。
活発なリポジトリでは基準側が先に進むだけで「人が決める」に落ちやすい(実測: cf-fireboard
で取り込み済みブランチが分岐点の古さだけで「人が決める」に落ちた)。判定の欠陥ではなく、
推測しない設計の裏返し。**integrate を主経路にすれば、取り込み直後にその場で片付けるので
分岐点が古くならず、この限界に当たりにくい。**

### 消し急ぎを防ぐ

`--apply` が worktree とブランチを消すのは、この判定で「消せる」と出た対象だけ。
この道具を経由せず `git worktree remove` / `git branch -D` を直接叩けば、この判定は
働かない。安全装置は道具を通ったときにだけ効く。

ブランチの削除は根拠によって強制の有無を変える: 祖先判定で消せたものは `branch -d`
(git 自身の merged 判定に乗る)、squash 判定で消せたものは `branch -D`(内容の一致を
機械で確かめているので git の merged フラグを待たない)。どちらで消したかは出力に書く。

`--force` は使わない従来の設計(worktree remove 自体、および祖先判定での branch 削除)
は維持している。locked / prunable / detached には触らない。未コミット・未追跡が
あれば保持する。

## テスト

```sh
bash plugins/worktree/tests/test_sweep.sh
bash plugins/worktree/tests/test_integrate.sh
```

squash 取り込み・非 squash・ignore 成果物・locked worktree・integrate の
merge/finish・競合時の停止・未コミットでの finish 拒否を、使い捨てリポジトリで確かめる。
