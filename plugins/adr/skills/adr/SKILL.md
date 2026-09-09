---
name: adr
description: >-
  Use the moment a decision that is hard to reverse gets made: when the user rules on
  something, when a measurement refutes an approach, when someone asks "why is it done
  this way", and before you propose a change in an area that may already be decided.
  Read this repository's existing ADRs first, then offer to record the new one. Fire
  even when nobody says "ADR".
metadata:
  version: "0.1.0"
---

```!
"${CLAUDE_SKILL_DIR}/../../bin/adr" ls
```

上に並ぶのが、このリポジトリで既に決まっていることだ。提案がそのどれかに触れるなら、それに従うか、新しい ADR で覆すことを提案する。決まっていることを黙って別の道に変えるわけにはいかない。

ADR を書くのは、次の三つが全部そろうときだけ。覆すのに実質的な費用がかかる。文脈を知らない読み手がコードを見て「なぜこうした」と思う。本当に別の案があり、理由をもって片方を選んだ。一つでも欠けたら書かない。どれが欠けたかを言い、代わりにコミットメッセージを勧める。理由は本文に、捨てた案は `Rejected:` トレーラに書く。書かないと勧めるのは正常な結果で、この skill の出力の大半はそれになる。何が該当するか迷ったら `references/ADR-FORMAT.md` を読む。

書くときの材料は、会話に出た文脈・決定・理由・捨てた案に限る。会話に無いものを補って書くと、後のセッションがそれを事実として扱うので、無いものは埋めずに聞く。数値、行番号、日付が出ていたらそれを引く。決めたのが利用者なら「利用者の裁定」と書き、測定が決めたなら測定値を書く。一気に書き上げて見せるのではなく、題、本文の順に一つずつ合意してから書く。

形は題と 1〜3 文。文脈、決定、理由をその順に 1 段落で書く。Status、Considered Options、Consequences は、それが無いと読み手が困るときだけ足す。ファイルは `docs/adr/NNNN-<動詞句>.md`。番号は 4 桁で、`adr ls` の最大値に 1 を足す。ディレクトリは最初の 1 件を書くときに作る。題の直下に `Date: YYYY-MM-DD` を 1 行置く。書いたら `adr check` を通す。

受理された ADR は編集しない。覆すときは新しいファイルに書き、その中で古い番号を名指しする。古い方に加えてよいのは先頭の 1 行 `Superseded by NNNN` だけ。

決定が仕事を生むなら、その仕事は ADR に書かない。todo の行にして `see:docs/adr/NNNN-....md` で根拠を指す。
