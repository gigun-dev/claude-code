---
name: doctor
description: >-
  I invoke this when I need to know whether this repository's Claude Code setup is
  sound before relying on it — I am about to trust CLAUDE.md or a path-scoped rule to
  be reaching me, I suspect a rule is silently not firing, or the user asks how the
  setup is doing. Reports bloated CLAUDE.md, rules whose `paths:` match nothing (they
  fail silently), personal settings leaking into version control, missing
  session-handoff wiring, and skills whose descriptions are too thin to trigger.
  Read-only. Also on '/harness:doctor'.
---

# harness:doctor — 設定の健全性検査

```!
bash "${CLAUDE_SKILL_DIR}/scripts/check.sh"
```

## Operating Posture

あなたは**検査官であって、修理工でも弁護人でもない**。既定は厳しい側 —— 各指摘は
「直す」か「棄却して理由を書き残す」かの二択で、**素通りという第3の選択肢は無い**。

失敗モードは2つ。**前者の方が重い**:

1. **緩和を既定にしてしまう。** 「このリポジトリの事情で意図的に外している」を理由を書かずに
   使うと、次のセッションが同じ指摘を発見して同じ判断をやり直す。**検査そのものが無意味になる。**
   棄却したら理由を CLAUDE.md か next-directions に残すこと(蒸し返しを止めるのはこの記録だけ)。
2. **誤検知に従って、正しい設定を壊す。** `check.sh` は実際に外れたことがある(2026-08-05、
   可能表現を禁止指示として誤検知)。**指摘は裁定するものであって、従うものではない。**
   おかしいと思ったら下の起票へ回す。**検査は当たらないことがある前提で使う。**

**全部棄却して1行も直さずに終わる実行は成功。** 逆に、指摘を作るために設定をいじるのは失敗。

上の検査結果を読んで、指摘を1件ずつ裁定する。

## 指摘の読み方(なぜそれが問題か)

- **CLAUDE.md が長い** — 全行が毎セッションのコストで、長いほど指示の見落としが増える。
  手順は skill(呼ばれたときだけロード)、ファイル限定の制約は paths 付き rules へ。
- **「毎回/必ず〜する」がある** — 指示は守られないことがある。決定論的に実行したいなら Hook。
- **「絶対に〜するな」がある** — 長いセッションで破綻しうる。permissions / PreToolUse hook で
  サーバー側から止める方が確実。
- **rules に paths が無い** — 常時ロードになり、無関係な作業でもコストを払う。
- **rules の paths がマッチしない** — ⚠️ **最も危険**。エラーにならず silent に無効化されるので、
  「自動ロードされている」と思い込んだまま一度も効かない状態が続く
  (swift-mcp-app で 2026-07-22 に実際に起きた)。
- **settings.local.json が追跡されている** — 個人環境の permission が共有される。
- **core.hooksPath 未設定** — `.githooks/pre-push` があっても**動いていない**。
  `.git/config` に入る設定なので git 管理されず、clone ごとに1回必要。
- **正典の日付より新しいコミットがある** — 引き継ぎドキュメントの更新漏れ。
- **skill の description が短い** — 自動トリガーされない。「何をするか」だけでなく
  「いつ使うか」を書く。

配線漏れ(ハーネス・gitignore・pre-push)は **`/harness:init` の再実行**で直る(冪等)。
CLAUDE.md の構成や rules の paths は判断が要るので手で直す。

## 検査そのものがおかしいとき(誤検知・見落とし)

**その場で起票する。** 直す場所は配布元(`gigun-dev/claude-code`)だが、気づくのは配布先で
作業している最中なので、跨いで記録できないと「あとで直す」が失われる:

```sh
"${CLAUDE_SKILL_DIR}/scripts/report.sh" --title "<一行要約>" --note "<誤検知した文面や期待>"
```

既定は**下書きの表示だけ**。内容をユーザーに見せて合意してから `--create` を付けて実行する
(外向きの操作を黙って実行しない)。発生リポジトリ・配布物の世代・そのときの doctor 出力は
自動で本文に入るので、再現材料が揃った状態で残る。

## 判定基準そのものを疑うとき

**最終検証: 2026-08-05。180日を超えていたら、まず一次情報で基準を確認し直してから使うこと**
(検査項目や閾値は Claude Code 側の仕様変更で陳腐化する)。

1. ベストプラクティス記事をライブ取得する(要約や記憶で判定しない):
   https://claude.com/blog/steering-claude-code-skills-hooks-rules-subagents-and-more
2. 仕様の確認が要る項目だけ公式ドキュメントに接地する: https://code.claude.com/docs/
   — hooks / memory(rules・CLAUDE.md)/ plugins / skills。
3. 変わっていたら `scripts/check.sh` の閾値・検査項目と、この節の日付を更新する。
4. 前回の状態は `references/audit-2026-08-05.md`(記事要旨の表・当時の監査結果)。
   ライブ版との差分が「何が変わったか」。テレメトリ方針は `references/telemetry-2026-08-05.md`。

## 関連(役割分担)

- **`/harness:init`** — 指摘された配線漏れを直す(冪等)。
- **`/harness:tidy`** — セッションを畳む。正典の更新・log 追記・未コミット作業の始末まで。
- **`/harness:next`** — 「着手順」を読んで次にやることを一覧する(読み取り専用)。
- **`/cclens:doctor`** — 静的検査ではなく**実際の使われ方**の実測(失敗の癖・未使用設定・常時コスト)。
- **`/telemetry:review`** — Langfuse のトレースからツール別の時間と失敗を見る。
- 大きな設計変更を入れる前は**敵対的検証**をかける。方法は
  `references/adversarial-verification.md`(観点分割・fresh context・偽陽性前提の裁定)。
