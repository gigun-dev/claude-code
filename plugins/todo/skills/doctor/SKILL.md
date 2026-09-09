---
name: doctor
description: >-
  Use when asked to set up or check how a repository keeps tasks and decisions, or when
  todo.txt or docs/adr is missing, the agent instructions (CLAUDE.md / AGENTS.md) do not
  point at either, or `todo check` / `adr check` report violations that need explaining.
  Diagnoses by default; installs the files and instruction pointers when requested.
metadata:
  version: "0.2.0"
---

このスキルのディレクトリから `../../bin/todo`・`../../bin/adr`・`../../bin/doctor` を絶対パスに解決し、対象リポジトリのルートで `todo check`・`adr ls`・`adr check`・`doctor check` を実行する。以下の `todo` `adr` `doctor` は、それぞれの同梱 CLI を引用符で囲んだ絶対パスで呼ぶことを指す。作業ディレクトリは対象リポジトリに保つ。

検査結果とファイルの実在を確認する。ファイルが無い場合も `check` は成功するので、成功だけで導入済みと判断しない。既定は診断まで。導入が依頼されていれば、その範囲のファイル作成と指示更新は進める。

## todo.txt の指摘の読み方

`id:` が無い行は `add` 以外のコマンドが触れないので、`todo id` で配る。`id:` の重複はどちらを指しているか決まらない。存在しない id を指す `dep:` は、その行を永久に `ready` から外す。`dep:` の循環は輪の中の全員を永久に `ready` から外す。`key:value` の形式違反は、たとえば `see:https://…` のように value にコロンが二つ目に入ったもの。`x ` で始まる行が todo.txt にあると open として数え続ける。記法の定義は `../todo/SKILL.md` にあり、行が仕様上どう読まれるか分からないときだけ `../todo/references/todo-txt-format.md` を読む。直し方は行を直接編集しても `todo replace` や `todo append` でもよく、求めるのは直したあとに `todo check` が通ることだけだ。

## docs/adr の指摘の読み方

`adr check` はファイル名・番号の重複・題・日付・`Superseded by` の指す先・`Status:` の語彙を見る。書式は `../adr/references/ADR-FORMAT.md` が正。直し方はファイルを編集するだけで、受理済み ADR は編集しない(差し替えは新しい番号で書き、先頭に `Superseded by <slug>` を足す)。

## 指示と実体の食い違い(`doctor check`)

`doctor check` は `CLAUDE.md` / `AGENTS.md` を読み、次の 2 つだけを見る。

- 決定の置き場(`docs/adr` など)が無い、またはあっても指示がどこも指していない。
- 指示と実体の矛盾。特定の過去の仕組みを名指しせず、一般的な形で検出する: (a) 指示が「正典」という語とともに名指ししたファイルが実在しない、(b) 指示が挙げるフックのパス(`.claude/hooks/` `.codex/hooks/` `.githooks/` `.git/hooks/` の配下)が実在しない、または設定(`core.hooksPath` / `.claude/settings.json` / `.codex/config.toml`・`.codex/hooks.json`)に登録されていない。

**todo.txt の指し忘れはここでは見ない**(`todo check` 側の診断と役割が重なるので重複させない)。

対象は極めて狭く絞ってある —— 誤検知を避けるため、`doctor check` は「正典」という語が無い行の参照や、上記 4 つのフック用ディレクトリに当たらないパスは何も言わない。それでも拾いきれない・判断が割れる指摘は残る(例: フックが別の目的で意図的に外されている、指示が文書を単に参照しているだけで正典とは言っていない)。そうした場合は `doctor check` の指摘を鵜呑みにせず、確信が持てなければ利用者に「確認したほうがよい点」として伝えるに留め、断定して直さない。**直し方はこのスキルが決めない** —— 何が正しいかはリポジトリごとに違うので、矛盾している 2 か所をパスと行で示すところまでにする。

## 導入

導入を依頼された場合は、次の順で行う。

`todo.txt` と `done.txt` が無ければ空で作り、`.gitignore` には入れない(タスクはリポジトリの資産で、個人の設定ではない)。`docs/adr/` は、最初の 1 件を書くときに作る(空のディレクトリだけを先に作らない — `../adr/SKILL.md` の規律どおり、書く材料が無いのに雛形を作らない)。

対象が使う `CLAUDE.md` / `AGENTS.md` へ、無い方だけ一行足す: `Tasks live in todo.txt; use the todo skills.`(todo.txt 用)と `Decisions live in docs/adr/; use the adr skill.`(docs/adr 用)。既存ファイルが両方あれば両方を更新し、同じ実体への symlink なら一度だけ。どちらも無ければ、利用中のホストが読む方を作る。書き方の規律は `../todo/SKILL.md` と `../adr/SKILL.md` が持つので、ここに複製しない。

リポジトリに検証コマンドがあれば、そこへ `todo check` と `adr check` を足すことを提案し、足すかは利用者が決める。

フックは置かず、現在地や経緯や log のファイルも作らない。形式は書き込みのたびに CLI 自身が見ており、`ls` と `ready` が毎回結果を出す。経緯はコミットメッセージに、知識は docs にある。
