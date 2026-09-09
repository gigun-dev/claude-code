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

```!
"${CLAUDE_SKILL_DIR}/../../bin/todo" check || true
```

上が検査の結果だ。既定は診断までで、書くのは承認を得てからにする。ついでに直しておく、はしない。

指摘の読み方は次のとおり。`id:` が無い行は `add` 以外のコマンドが触れないので、`todo id` で配る。`id:` の重複はどちらを指しているか決まらない。存在しない id を指す `dep:` は、その行を永久に `ready` から外す。`dep:` の循環は輪の中の全員を永久に `ready` から外す。`key:value` の形式違反は、たとえば `see:https://…` のように value にコロンが二つ目に入ったもの。`x ` で始まる行が todo.txt にあると open として数え続ける。記法の定義は `../todo/SKILL.md` にあり、行が仕様上どう読まれるか分からないときだけ `../todo/references/todo-txt-format.md` を読む。

直し方は行を直接編集しても `todo replace` や `todo append` でもよく、求めるのは直したあとに `todo check` が通ることだけだ。`todo` が PATH に無ければ `${CLAUDE_SKILL_DIR}/../../bin/todo` を使う。

導入は承認を得てから、次の順で行う。`todo.txt` と `done.txt` が無ければ空で作り、`.gitignore` には入れない（タスクはリポジトリの資産で、個人の設定ではない）。`CLAUDE.md`（`AGENTS.md` があればそちらにも）へ `Tasks live in todo.txt; use the todo skills.` の一行だけ足す。書き方の規律は `todo:todo` が持っているので、ここに複製しない。リポジトリに検証コマンドがあれば、そこへ `todo check` を足すことを提案し、足すかは利用者が決める。

フックは置かず、現在地や経緯や log のファイルも作らない。形式は書き込みのたびに CLI 自身が見ており、`ls` と `ready` が毎回結果を出す。経緯はコミットメッセージに、知識は docs にある。
