---
name: todo
description: >-
  Use at the start of work in a repository to see which tasks are ready to start, and
  whenever a task is finished, started, split, or reworded — including when the user
  never says "todo". Tasks live in this repository's todo.txt and done.txt, driven by
  the `todo` CLI. Also on '/todo:todo'.
metadata:
  version: "0.1.0"
---

```!
todo ready
```

# todo:todo

上は `dep:` が解けている open 行 = **いま着手できる / 並列に投げられる**もの。
先に `✗` が出ていたらファイルが壊れている。一覧より先にそれを直す。

## 語彙

| 記法 | 意味 |
|---|---|
| `(A)`..`(Z)` | 重要度。**先頭のみ。進行中を表さない** |
| `+project` | 束ね。行にはその次の一手だけを書く |
| `@context` | 要る状況（`@device` `@user` `@unattended`) |
| `@wip` | 進行中。`start` が付け、`stop` と `do` が外す |
| `dep:a3f9c1` | 依存。指す先が done に入るまで `ready` に出ない |
| `see:docs/x.md` | 根拠の置き場。**リポジトリ相対パス**（URL は形式違反） |
| `id:7b2e04` | `add` が採番。タスクを指す唯一の手段。一意なら前方一致でよい |

行が曖昧なとき、`check` の指摘が分からないときは
**`references/format.md` を読む**。

## コマンド

```sh
todo ready              # 着手できるもの        todo ls @wip     # 手を付けているもの
todo ls +project        # その塊の残り          todo show <id>   # done も含めて 1 行
todo start <id>         # 着手した              todo stop <id>   # 未完のまま置いた
todo do <id>            # 検証まで終わった      todo add "<次の一手>"
todo replace <id> "…"   # 言い方・粒度を直す    todo pri <id> A / todo depri <id>
```

`todo --help` が正。終了コード: 0 成功 / 1 引数・状態 / 2 形式違反 / 3 ID 不明。

## 規律

- **走らせるのは状態が変わったその瞬間。** コミットの区切りではない。
  ただし `do` は、根拠になるコミットと同時に。
- 1 行 = **「終わったと言える具体的な次の一手」**。終わりを言えないなら割る。
- **学んだこと・撤回・経緯を書かない。** docs とコミットメッセージへ。
  todo.txt が持つのは「これからやること」だけ。
- 行を直接編集してもよい。次の `ls` / `ready` が壊れていれば教える。
