---
name: adr
description: >-
  Read this repository's recorded decisions before touching an area that may already be
  decided, and record new hard-to-reverse ones. Use it at the start of work in a
  repository, before proposing or implementing a change to a protocol, a default, a
  build flag, a file format or a layout, when someone asks why it is done this way, when
  a measurement refutes an approach, and when the user settles a trade-off. Fire even
  when nobody says "ADR" or "decision".
metadata:
  version: "0.5.0"
---

このスキルのディレクトリから `../../bin/adr` の絶対パスを求め、対象リポジトリのルートで `ls` を実行する。以下の `adr` は、その同梱 CLI を引用符で囲んだ絶対パスで呼ぶことを指す。作業ディレクトリは対象リポジトリに保つ。

`ls` に並ぶのが、このリポジトリで**今も有効な**決定だ(差し替えられた決定はファイルごと消える。理由は後述)。同じ索引は `todo ready` の先頭にも題だけ出るので、触れる領域があればファイル本体を読む。提案が既存の決定に触れるなら、それに従うか新しい ADR で覆すことを提案する —— 黙って別の道に変えない。

ADR を書くのは、覆すのに実質的な費用がかかる・文脈を知らない読み手が「なぜこうした」と思う・本当に別の案があり理由をもって選んだ、の三つが全部そろうときだけ。欠けたら書かない理由を言い、コミットメッセージを勧める(出力の大半はそれになる)。迷ったら `references/ADR-FORMAT.md`(Nygard 2011 / ThoughtWorks Lightweight ADR / Azure に沿う。書式・語彙・検査の詳細は全てそちら)。

**書く前に、1 文で理由を言えるか試す。** 言えなければ、複数の決定が混ざっているので分けて別々の ADR に書くか、決定ではなく経緯なのでコミットメッセージか measurements に書く。**同じ関門を文ごとにも掛ける**: 各文がその 1 つの決定についてか確認し、覆すのが安いサブ決定(実装の詳細)を書いた文は実装コードのコメントかコミットメッセージへ移す。全文がそれで消えるなら ADR ごと消し、理由はコードコメントへ。決定の理由そのものは削らない —— 削ると、それを支える前提ごと消える。

書くときの材料は会話に出た文脈・決定・理由・捨てた案に限る —— 補って書かない(後のセッションが事実として扱う)。未決定なら確認する。日付・測定値・todo id・見出しや箇条書きは本文に混ぜない(`adr check` が指摘する。詳細は `references/ADR-FORMAT.md`)。

ファイルは `adr new "<題>" [<slug>]` で作る —— 採番・ファイル名・日付・`Implementation: pending` はこれが書く(題が非 ASCII を含むときは slug を渡す)。出力されたパスに本文(文脈→決定→帰結、最大 3 段落)を書き足し、`adr check` を通す。書いたら `adr stats` も走らせ、上位(文字数・段落数が突出したもの)を split の候補として扱う —— 軽さが安定するまでは折に触れて見る。

**受理された ADR は、短くすることと `Implementation:` の更新以外では編集しない。** 決定が変わったら `adr replace <古い> <新しい>` で新しい ADR を書く。これは新しい方に `Replaces: <古い番号>` を足し、**古いファイルを削除する**(git 管理下なら `git rm`。記録は git の履歴に残る)。`Superseded by` や `deprecated` を手で足さない —— エージェントはコンテキストの記述を「今も有効」として扱いやすいため(ClashEval 2024)、deprecated のまま残さず置き場から消す。部分的な差し替えなら、古い ADR に残る決定を新しい ADR に書き直すか古い ADR 自体を短くしてから `adr replace` する —— 編集するか消すか、差し替えた文面を置き場に残さない。

決定によって生じる作業は ADR に書かず、todo の行にして `see:docs/adr/NNNN-....md` で根拠を示す。既存の todo の行に関わる ADR を書いたら、その行にも `todo replace ID "..."` で同じ参照を足す —— ADR から todo id への逆向きの参照は `adr check` が指摘する(経路は todo → ADR の 1 方向で足りる)。
