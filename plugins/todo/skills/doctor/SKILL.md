---
name: doctor
description: >-
  Use when asked to set up or check task tracking in a repository, or when there is no
  todo.txt yet, the agent instructions do not point at it, or `todo check` reports
  violations that need explaining. Diagnoses by default; creates files and edits
  CLAUDE.md / AGENTS.md only after the user approves.
metadata:
  version: "0.1.0"
---

<!-- `|| true` は必須。`!` はスキルを読んだだけで無条件に走るので、ここに置けるのは
     必ず成功するコマンドだけ。`check` は違反があると 2 で返る。 -->

```!
"${CLAUDE_SKILL_DIR}/../../bin/todo" check || true
```

# todo:doctor

**既定は診断だけ。書くのは承認を得てから。**「ついでに直しておきました」をしない。

## 検査（上の出力）

| 違反 | 何が起きるか |
|---|---|
| `id:` が無い | `add` 以外のコマンドがその行を触れない。**`todo id` で付ける** |
| `id:` の重複 | どちらを指しているか決まらない |
| 宙吊り `dep:` | その行は永久に `ready` に出ない |
| 循環 `dep:` | 輪の中の全員が永久に `ready` に出ない |
| `key:value` の形式違反 | 例: `see:https://…` は value にコロンが 2 つ目 |
| `x ` 始まりが todo.txt にある | open として数え続ける |

`id:` `dep:` `see:` `@wip` の定義は `../todo/SKILL.md` の「語彙」。
**行が仕様上どう読まれるか分からないときだけ** `../todo/references/todo-txt-format.md`
（上流の仕様そのまま）を読む。

直し方は行を直接編集するか `todo replace` / `todo append`。**どちらでもよい** ——
要求するのは、直したあとに `todo check` が通ることだけ。
`todo` が PATH に無ければ `${CLAUDE_SKILL_DIR}/../../bin/todo`。

## 導入（承認を得てから）

1. `todo.txt` と `done.txt` が無ければ空で作る。`.gitignore` に入れない ——
   **タスクはリポジトリの資産で、個人の設定ではない。**
2. `CLAUDE.md`（`AGENTS.md` があればそちらにも）へ 1 行だけ:
   `Tasks live in todo.txt; use the todo skills.`
   書き方の規律は `todo:todo` が持っている。複製すると必ずずれる。
3. リポジトリの検証コマンド（`scripts/verify.sh` / `tools/test.sh` 等）があるなら、
   そこへ `todo check` を足すことを**提案する**。足すかは利用者が決める。

## しないこと

- **フックを置かない。** 呼ばれる保証の無い場所に検査を置くと、検査が黙って死ぬ。
  形式は書き込みのたびに CLI 自身が見ており、`ls` と `ready` が毎回結果を出す。
- **現在地・経緯・log のファイルを作らない。** 経緯はコミットメッセージ、知識は docs。
