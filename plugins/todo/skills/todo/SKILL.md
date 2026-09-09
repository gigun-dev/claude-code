---
name: todo
description: >-
  Use at the start of work in a repository to see which tasks are ready to start, and
  whenever a task is finished, started, split, or reworded — including when the user
  never says "todo". Tasks live in this repository's todo.txt and done.txt, driven by
  the `todo` CLI.
metadata:
  version: "0.1.0"
---

```!
"${CLAUDE_SKILL_DIR}/../../bin/todo" ready
```

上に並ぶのが、依存の解けた open な行、つまりいま着手できるものだ。並列に投げられるのもこの中から選ぶ。先頭に `✗` が出ていればファイルが壊れているので、一覧を読む前にそれを直す。

行の読み方は todo.txt の仕様のとおりで、`(A)` から `(Z)` が重要度（行頭のみ。進行中の意味は持たない）、その次が作成日、`+project` が束ね、`@context` がその作業に要る状況（`@device` `@user` `@unattended`）。このプラグインはそこに四つを足している。

| 記法 | 意味 |
|---|---|
| `@wip` | 進行中。`start` が付け、`stop` と `do` が外す。見るのは `ls @wip` |
| `dep:0001` | 依存。カンマ区切りで複数可。指す先が done.txt に入るまでその行は `ready` に出ない。存在しない id を指すと永久に出ないので、`check` がその行を名指しする |
| `see:docs/x.md` | 根拠の置き場。リポジトリ相対パスに限る。URL は value にコロンが二つ目に入るので形式違反になる |
| `id:0001` | `add` が付ける連番。4 桁ゼロ詰め、done.txt も数えた最大値に 1 を足す。タスクを指す唯一の手段で、行番号は編集とマージでずれるので使わない。指すときのゼロ詰めは省略できる（`todo do 12`）。手で足した行には `todo id` が配る |

`ls` と `ready` は重要度の順に並び、同じ重要度の中はファイルに書かれた順になる。行が仕様上どう読まれるか分からないときだけ `references/todo-txt-format.md`（上流の仕様そのまま）を読む。

```sh
todo ready              # 着手できるもの        todo ls @wip     # 手を付けているもの
todo ls +project        # その塊の残り          todo show <id>   # done も含めて 1 行
todo start <id>         # 着手した              todo stop <id>   # 未完のまま置いた
todo do <id>            # 検証まで終わった      todo add "<次の一手>"
todo replace <id> "…"   # 言い方・粒度を直す    todo pri <id> A / todo depri <id>
```

`todo --help` が正で、終了コードは 0 成功、1 引数や状態の誤り、2 形式違反、3 ID 不明。`todo` が PATH に無ければ `${CLAUDE_SKILL_DIR}/../../bin/todo` を使う。

todo.txt を更新するのは本線で、worktree で実装する側は結果を報告するだけにする。`do` を打てるのは検証した者で、根拠になるコミットと同時に打つ。それ以外のコマンドは、状態が変わったその瞬間に走らせる。コミットの区切りまで溜めない。

一行に書くのは、終わったと言える具体的な次の一手だけにする。終わりを言えないなら割る。学んだことや撤回や経緯は書かず、docs とコミットメッセージに回す。todo.txt が持つのはこれからやることだけで、行を直接編集してもよく、壊れていれば次の `ls` か `ready` が教える。
