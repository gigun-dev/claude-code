---
name: doctor
description: このリポジトリの Claude Code 設定がベストプラクティスを守れているか検査する。CLAUDE.md の肥大化・rules の paths 未設定/不一致(silent 無効化)・個人設定の混入・ハーネスの配線漏れ・skill の description 不足を指摘する。「設定を点検して」「ベスプラ守れてる?」「/harness:doctor」で発火。
---

# harness:doctor — 設定の健全性検査

```!
bash "${CLAUDE_SKILL_DIR}/scripts/check.sh"
```

上の検査結果を読んで、指摘があれば直す。**すべての指摘に従う必要はない** — このリポジトリの
事情で意図的に外している場合は、その理由を CLAUDE.md か next-directions に書き残すこと
(次のセッションが同じ指摘を蒸し返さないため)。

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

## 判定基準そのものを疑うとき

**最終検証: 2026-08-05。180日を超えていたら、まず一次情報で基準を確認し直してから使うこと**
(検査項目や閾値は Claude Code 側の仕様変更で陳腐化する)。

1. ベストプラクティス記事をライブ取得する(要約や記憶で判定しない):
   https://claude.com/blog/steering-claude-code-skills-hooks-rules-subagents-and-more
2. 仕様の確認が要る項目だけ公式ドキュメントに接地する: https://code.claude.com/docs/
   — hooks / memory(rules・CLAUDE.md)/ plugins / skills。
   2026-08-05 の敵対的検証では、深刻度「高」の誤指摘を原文引用で棄却した実績がある。
3. 変わっていたら `scripts/check.sh` の閾値・検査項目と、この節の日付を更新する。
4. 前回の状態は `references/audit-2026-08-05.md`(記事要旨の表・当時の監査結果)。
   ライブ版との差分が「何が変わったか」。

## 関連(役割分担)

- **`/harness:init`** — 指摘された配線漏れを直す(冪等)。
- **`/cclens:doctor`** — 設定の静的検査ではなく**実際の使われ方**の実測
  (失敗の癖・未使用設定・常時コスト)。両方見ると「設定は正しいが使い方が悪い」が分かる。
- **`/telemetry:review`** — Langfuse のトレースからツール別の時間と失敗を見る。
- 大きな設計変更を入れる前は**敵対的検証**をかける。方法は
  `references/adversarial-verification.md`(観点分割・fresh context・偽陽性前提の裁定)。

## 監査履歴

- **2026-08-05(初回)**: caldav / swift-mcp-app は模範解。乖離4変種のコメント方針を正典化、
  harness:init を新設し store-redirect へ初適用。cclens 実測(edit-precondition 344件・
  path-not-found 137件・cd 25%)からグローバル CLAUDE.md を新設。敵対的検証で
  フェイルオープン等を修正。詳細: `references/audit-2026-08-05.md`。
  テレメトリ方針は `references/telemetry-2026-08-05.md`。
