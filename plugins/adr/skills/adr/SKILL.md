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

# adr:adr

上は既に決まっていること。**答えがあるならそれに従う。**覆すなら supersede を
提案する —— 黙って別の道を選ばない。

## 三重関門(正は `references/ADR-FORMAT.md`)

1. **覆すのが高い** 2. **文脈が無いと驚く** 3. **本物の取引の結果**

**三つ揃わなければ ADR にしない。**落ちたら**どの関門で落ちたかを言って勧退する**
—— 正常な出力であって失敗ではない。代わりに勧めるのはコミットメッセージ:
理由は本文へ、捨てた案は `Rejected: <案> —— <理由>` のトレーラへ。
該当するか迷ったときだけ `references/ADR-FORMAT.md` を読む。

## 書くとき

- 下書きは**会話に出た文脈・決定・理由・捨てた案だけ**で組む。**創作しない。**
  数値・行・日付が出ていれば引用する。無い欄は埋めずに訊く。
- **節ごとに利用者と合意してから書く。**書き上げてから見せない。
- 利用者が決めたことは「**利用者の裁定**」と明記する。測定が決めたなら測定値を引く。
- 形は**題 + 1〜3 文**。Status / Considered Options / Consequences は値打ちが
  あるときだけ。ほとんどの ADR には要らない。

## ファイル

`docs/adr/NNNN-<動詞句の slug>.md`。番号は 4 桁、`adr ls` の最大値 + 1。
ディレクトリは最初の 1 件で作る。題の次に日付 `YYYY-MM-DD`(書き出しの文の中か
`Date:` の 1 行。**どちらかに決めて揃える**)。

**受理済みの ADR は編集しない。**差し替えは新しいファイルに書き、その中で古い方を
名指しする。古い方に許される編集は先頭行 `Superseded by <slug>` だけ。
書いたら `adr check` を通す。

## 決定が仕事を生んだら

その仕事は **todo の 1 行**にする —— `see:docs/adr/<slug>.md` で根拠を指す。
ADR に「これからやること」を書かない。
