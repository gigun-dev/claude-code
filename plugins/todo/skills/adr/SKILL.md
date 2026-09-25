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
  version: "0.4.0"
---

このスキルのディレクトリから `../../bin/adr` の絶対パスを求め、対象リポジトリのルートで `ls` を実行する。以下の `adr` は、その同梱 CLI を引用符で囲んだ絶対パスで呼ぶことを指す。作業ディレクトリは対象リポジトリに保つ。

`ls` に並ぶのが、このリポジトリで**今も有効な**決定だ。置き場(`docs/adr/` など)は決定が下るたびに 1 件増えるのではなく、**現在有効な決定の集合**を映す —— 差し替えられた決定はファイルごと消えている(理由は後述)ので、そこに無いものは「決まっていない」であって「昔決めて今は違う」ではない。同じ索引は `todo ready` の先頭にも出るが、そこに出るのは題だけなので、触れる領域に当たるものがあればファイル本体を読む。提案がそのどれかに触れるなら、それに従うか、新しい ADR で覆すことを提案する。決まっていることを黙って別の道に変えるわけにはいかない。

ADR を書くのは、次の三つが全部そろうときだけ。覆すのに実質的な費用がかかる。文脈を知らない読み手がコードを見て「なぜこうした」と思う。本当に別の案があり、理由をもって片方を選んだ。一つでも欠けたら書かない。どれが欠けたかを言い、代わりにコミットメッセージを勧める。書かないと勧めるのは正常な結果で、この skill の出力の大半はそれになる。何が該当するか迷ったら `references/ADR-FORMAT.md` を読む(Nygard 2011 / ThoughtWorks Lightweight ADR / Azure の三つに沿っている。詳細はそちらに書いた)。

**書式は軽量**: `# 題`、`Date: YYYY-MM-DD`、`Implementation: done|pending`、任意で `Status: proposed`(書かなければ accepted 扱い)、そのあとに**文脈 → 決定 → 理由の順で 1 段落**、任意で `Rejected: <捨てた案> — <理由>` トレーラ。文字数の上限は無い —— 軽さは形で決まる。`##` 以上の見出し・箇条書き・番号付きリスト・表・コードフェンス・引用・複数段落は `adr check` が指摘する。それが要る内容なら、それは 1 つの決定ではない。

**書く前に、1 文で理由を言えるか試す。** 「〜なので〜にした」と 1 文で言えなければ、2 通りの可能性がある: (1) 実は 2 つ以上の決定が混ざっている —— 分けて別々の ADR に書く。(2) 決定ではなく経緯・作業ログの類 —— それは ADR ではなくコミットメッセージか measurements に書く(書かないと勧める)。**理由を削って 1 段落に収めない** —— 削ると、その決定が支えている前提ごと消える。段落が長くなるなら、それは分けるべき決定が 1 つのファイルに同居している合図として扱う。

書くときの材料は、会話に出た文脈・決定・理由・捨てた案に限る。会話に無いものを補って書くと、後のセッションがそれを事実として扱うので、無いものは埋めずに聞く。数値、行番号、日付が出ていたらそれを引く。決めたのが利用者なら「利用者の裁定」と書き、測定で決まったなら測定値を書く(measurements 側の詳細は参照するだけで、本文には引き写さない —— `[実測 ...]` のような角括弧参照そのものも本文に置かない。`adr check` が指摘する)。未決定の点があれば確認する。本文に日付を書けるのは `Date:` の 1 行だけ(経緯の日付は commit メッセージか measurements へ) —— ただし、MCP のようにプロトコルの版そのものを日付で識別する場合は、その値をバッククォートのコードスパン(`` `2026-07-28` ``)で囲めば指摘されない(識別子であって経緯ではないため)。

ファイルは `adr new "<題>" [<slug>]` で作る —— 採番・ファイル名・日付・`Implementation: pending` はこれが書く(題が非 ASCII を含むときは slug を渡す。動詞句の小文字ケバブにする)。出力されたパスに本文(文脈→決定→理由の 1 段落と、あれば `Rejected:`)を書き足す。実装済みの決定を後から記録するなら `Implementation:` を `done` に直す。書いたら `adr check` を通す。

**受理された ADR は、短くする(内容を削らず言い換えて縮める)ことと `Implementation:` の更新以外では編集しない。** 決定そのものが変わったら、このファイルを書き換えるのではなく新しい ADR を書き、`adr replace <古い> <新しい>` を実行する。これは新しい方に `Replaces: <古い番号>` を書き足し、**古いファイルを削除する**(git 管理下なら `git rm`)。手で `Superseded by` を足したり `deprecated` にしたりしない —— その語彙はもう無い(`adr check` が残骸を指摘する)。

**古いファイルを残さず消すのは意図的な選択。** エージェントは自分のコンテキストに載っている記述を「今も有効」として扱いやすい —— 新旧の矛盾する情報を同時に渡されたときにモデルがどちらを信じるかを調べた研究(ClashEval, 2024)や、Claude Code の memory ドキュメントが「相反する指示を残さない」と勧めているのも同じ理由による。決定が消えても記録は失われない: `git log -- docs/adr/NNNN-<slug>.md` が古い本文を持っている。部分的な差し替えなら、古い ADR に残る決定を新しい ADR に書き直すか、古い ADR 自体を短くしてから `adr replace` する —— **編集するか消すか、どちらかにする。差し替えた文面を置き場に残さない。**

決定によって生じる作業は ADR に書かない。todo の行にして `see:docs/adr/NNNN-....md` で根拠を示す。

書いた ADR が既存の todo の行に関わるなら、その行にも `todo replace ID "..."` で `see:docs/adr/NNNN-<slug>.md` を足す。ADR の本文から todo の id を参照するだけでは一方向で、次のセッションが読むのは `ready` の出力だけなので、そこから決定へ戻る経路が無い(逆に、ADR の本文に todo の id を書くことは `adr check` が指摘する —— 経路は todo → ADR の 1 方向で足りる)。
