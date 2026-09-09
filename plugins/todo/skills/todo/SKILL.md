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

# todo:todo

上は `dep:` が解けている open 行 = **いま着手できる / 並列に投げられる**もの。
先に `✗` が出ていたらファイルが壊れている。一覧より先にそれを直す。

## 語彙

上 4 つは todo.txt 仕様のもの。下 4 つは**このプラグインの拡張**（仕様の
`key:value` と `@context` の範囲内。定義はここが正）。

| 記法 | 意味 |
|---|---|
| `(A)`..`(Z)` | 重要度。**先頭のみ。進行中を表さない** |
| `2026-09-10` | 作成日。任意（`add` は必ず付ける）。優先度があればその後ろ |
| `+project` | 束ね。行にはその次の一手だけを書く |
| `@context` | 要る状況（`@device` `@user` `@unattended`） |
| `@wip` | 進行中。`start` が付け、`stop` と `do` が外す。見るのは `ls @wip` |
| `dep:a3f9c1` | 依存。カンマ区切りで複数可。**指す先が done.txt に入るまで `ready` に出ない**（宙吊りの id を指す行は永久に出ない。`check` が名指しする） |
| `see:docs/x.md` | 根拠の置き場。**リポジトリ相対パス** —— URL は value にコロンが 2 つ目に入るので形式違反 |
| `id:7b2e04` | `add` が採番する 6 桁の小文字 16 進。**タスクを指す唯一の手段**（行番号は編集とマージでずれる）。連番にしないのは並行ブランチで採番が衝突するから。一意なら前方一致でよい。手で足した行には `todo id` が配る |

`ls` と `ready` の並びは **優先度（`(A)` が先、無しは最後）→ ファイル内の出現順**。
id は乱数なので id 順に意味は無い。

**行が仕様上どう読まれるか分からないときだけ** `references/todo-txt-format.md`
（上流の仕様そのまま）を読む。

## コマンド

```sh
todo ready              # 着手できるもの        todo ls @wip     # 手を付けているもの
todo ls +project        # その塊の残り          todo show <id>   # done も含めて 1 行
todo start <id>         # 着手した              todo stop <id>   # 未完のまま置いた
todo do <id>            # 検証まで終わった      todo add "<次の一手>"
todo replace <id> "…"   # 言い方・粒度を直す    todo pri <id> A / todo depri <id>
```

`todo --help` が正。終了コード: 0 成功 / 1 引数・状態 / 2 形式違反 / 3 ID 不明。
`todo` が PATH に無ければ `${CLAUDE_SKILL_DIR}/../../bin/todo`。

## 規律

- **走らせるのは状態が変わったその瞬間。** コミットの区切りではない。
  ただし `do` は、根拠になるコミットと同時に。
- 1 行 = **「終わったと言える具体的な次の一手」**。終わりを言えないなら割る。
- **学んだこと・撤回・経緯を書かない。** docs とコミットメッセージへ。
  todo.txt が持つのは「これからやること」だけ。
- 行を直接編集してもよい。次の `ls` / `ready` が壊れていれば教える。
