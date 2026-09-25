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

**書く前に、1 文で理由を言えるか試す。** 言えなければ、複数の決定が混ざっているので分けるか、経緯ならコミットメッセージか measurements へ。本文は文脈→決定→理由の短い段落を最大 3 つ、目安 120〜200 語(check は数えない。実測: 9 リポジトリ 249 件の ADR で、最も軽い部類の中央値ですら約 160 語だった)。**`Accepting: <受け入れた代償>` を最低 1 行**(costs 抜きの案だけを書かない)、`Rejected: <案> — <理由>` は理由必須。書きすぎ(関係ない背景や手順まで書く Mega-ADR)にも、削りすぎ(costs や理由を削って前提ごと消す)にも寄らない —— 同じ判断は文ごとにも掛け、覆すのが安いサブ決定を書いた文は実装コードのそばのコメントかコミットメッセージへ移す。

書く材料は会話に出た文脈・決定・理由・捨てた案に限る —— 補って書かない(後のセッションが事実として扱う)。未決定なら確認する。日付・測定値・todo id・見出しや箇条書きは本文に混ぜない(`adr check` が指摘。詳細は `references/ADR-FORMAT.md`)。

ファイルは `adr new "<題>" [<slug>]` で作る —— 採番・ファイル名・日付・`Implementation: pending` はこれが書く(題が非 ASCII を含むときは slug を渡す)。出力されたパスに本文と `Accepting:` を書き足し、`adr check` を通す。書いたら `adr stats` も走らせ、上位(語数・文数・最長文が突出したもの)を split の候補として扱う —— 軽さが安定するまでは折に触れて見る。

**受理された ADR は、短くすることと `Implementation:` の更新以外では編集しない。** 決定が変わったら `adr replace <古い> <新しい>` で新しい ADR を書く —— 新しい方に `Replaces: <古い番号>` を足し、**古いファイルを削除する**(git 管理下なら `git rm`。記録は git の履歴に残る)。`Superseded by` や `deprecated` を手で足さない —— エージェントはコンテキストの記述を「今も有効」として扱いやすいため(ClashEval 2024)。部分的な差し替えは、古い ADR の残りを新しい方に書き直すか古い ADR を短くしてから `adr replace` する —— 編集するか消すか、差し替えた文面を残さない。

決定によって生じる作業は ADR に書かず、todo の行にして `see:docs/adr/NNNN-....md` で根拠を示す。既存の todo の行に関わる ADR を書いたら、その行にも `todo replace ID "..."` で同じ参照を足す —— ADR から todo id への逆向きの参照は `adr check` が指摘する(経路は todo → ADR の 1 方向で足りる)。
