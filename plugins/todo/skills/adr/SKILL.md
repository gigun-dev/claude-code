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
  version: "0.3.0"
---

このスキルのディレクトリから `../../bin/adr` を絶対パスに解決し、対象リポジトリのルートで `ls` を実行する。以下の `adr` は、その同梱 CLI を引用符で囲んだ絶対パスで呼ぶことを指す。作業ディレクトリは対象リポジトリに保つ。

`ls` に並ぶのが、このリポジトリで既に決まっていることだ。同じ索引は `todo ready` の先頭にも出るが、そこに出るのは題だけなので、触れる領域に当たるものがあればファイル本体を読む。提案がそのどれかに触れるなら、それに従うか、新しい ADR で覆すことを提案する。決まっていることを黙って別の道に変えるわけにはいかない。

ADR を書くのは、次の三つが全部そろうときだけ。覆すのに実質的な費用がかかる。文脈を知らない読み手がコードを見て「なぜこうした」と思う。本当に別の案があり、理由をもって片方を選んだ。一つでも欠けたら書かない。どれが欠けたかを言い、代わりにコミットメッセージを勧める。理由は本文に、捨てた案は `Rejected:` トレーラに書く。書かないと勧めるのは正常な結果で、この skill の出力の大半はそれになる。何が該当するか迷ったら `references/ADR-FORMAT.md` を読む。

書くときの材料は、会話に出た文脈・決定・理由・捨てた案に限る。会話に無いものを補って書くと、後のセッションがそれを事実として扱うので、無いものは埋めずに聞く。数値、行番号、日付が出ていたらそれを引く。決めたのが利用者なら「利用者の裁定」と書き、測定が決めたなら測定値を書く。未決定の点があれば確認する。既に利用者が決めた内容や明示的に依頼した記録は、その範囲で書く。

形は題と 1〜3 文。文脈、決定、理由をその順に 1 段落で書く。Status、Considered Options、Consequences は、それが無いと読み手が困るときだけ足す。ファイルは `adr new "<題>" [<slug>]` で作る —— 採番もファイル名も日付もこれが書く(題が非 ASCII を含むときは slug を渡す。動詞句の小文字ケバブにする)。出力されたパスに本文を書き足す。書いたら `adr check` を通す。

受理された ADR は編集しない。覆すときは新しいファイルに書き、その中で古い番号を名指しする。古い方には `adr supersede <古い> <新しい>` で先頭の 1 行を足す。手で書かない。

決定が仕事を生むなら、その仕事は ADR に書かない。todo の行にして `see:docs/adr/NNNN-....md` で根拠を指す。

書いた ADR が既存の todo の行に関わるなら、その行にも `todo replace ID "..."` で `see:docs/adr/NNNN-<slug>.md` を足す。ADR の本文から todo の id を名指しするだけでは片方向で、次のセッションが読むのは `ready` の出力だけなので、そこから決定へ戻る経路が無い。
