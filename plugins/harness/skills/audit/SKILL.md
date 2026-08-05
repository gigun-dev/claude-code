---
name: audit
description: Claude Code ハーネス(ユーザースコープ + プロジェクトスコープの設定ファイル類)の健全性監査。公式ベストプラクティスのライブ照合 + cclens 実測 + 機構選択の判定枠組みで改善提案する。「ハーネスを見直したい」「設定の監査」「/harness:audit」で発火。
---

# harness:audit — ハーネス健全性監査

**最終検証: 2026-08-05。この日から180日を超えていたら、本節の枠組み自体を手順1の
一次情報で再検証し、この日付を更新してから使うこと**(内容の主張には賞味期限がある。
手順の構造は腐りにくいが、事実の主張は腐る)。

## 原則

- **このファイルの要約や学習済み知識で判定しない。** 事実の根拠は毎回、手順1で
  ライブ取得した一次情報に置く(caldav の rfc-primary-sources と同じ原文主義)。
- **感想ではなく実測で語る。** 設定の無駄・失敗の癖は cclens の数字で示す。
- **結論は日付付きで記録する。** 監査結果は「当時の状態」として残し、次回との差分を見る。

## いつ実行するか

新プロジェクトへのハーネス展開前 / Claude Code の大型アップデート後 /
cclens doctor が新しいパターンを出したとき / 概ね四半期ごと。

## 手順

### 1. 一次情報のライブ取得

- ベストプラクティス記事(機構の使い分け):
  https://claude.com/blog/steering-claude-code-skills-hooks-rules-subagents-and-more
  (日本語版: /ja/blog/ 同スラッグ)
- 公式ドキュメント(仕様の確認が必要になった項目だけ): https://code.claude.com/docs/
  — hooks / memory(rules・CLAUDE.md) / plugins / skills。仕様適合の判定は必ずここに接地する
  (2026-08-05 の敵対的検証で「深刻度:高」の誤指摘を原文引用で棄却した実績)。
- 前回監査時のスナップショットは references/ にある。ライブ版との差分が「何が変わったか」。

### 2. 現状調査

- ユーザースコープ: `~/.claude/` の CLAUDE.md・settings.json・agents/・commands/・
  hooks/・skills/(実体が dotfiles への symlink なら dotfiles 側が正)。
- プロジェクトスコープ: 対象リポジトリの CLAUDE.md(行数と内容の性質)・`.claude/`
  (settings/rules/skills/hooks)・AGENTS.md/.codex 配線・docs/next-directions.md の鮮度。
- 横断比較: 同じ内容(コメント方針等)が複数リポで乖離していないか。git log -S で系譜を追える。

### 3. 実測(cclens)

```sh
DB="${XDG_CACHE_HOME:-$HOME/.cache}/cclens/cclens.db"; mkdir -p "$(dirname "$DB")"
cclens doctor --db "$DB"            # 一画面ヘルスチェック
cclens failures --scope global --db "$DB"   # 横断的な失敗の癖
cclens waste --scope project:<slug> --db "$DB"  # プロジェクト別の未使用設定
```

### 4. 判定枠組み(機構の選択)

ライブ取得した記事を正としつつ、2026-08-05 時点の要旨:

- 毎回必ず実行すべき自動処理 → **Hook**(CLAUDE.md の「毎回Xせよ」指示は守られない)
- 手順的ワークフロー → **Skill**(中間結果が邪魔なら **Subagent**)
- 常時必要な制約 → **CLAUDE.md**(ルート・200行以下) / ファイル限定なら **paths 付き rules**
- 個人嗜好・全プロジェクト共通 → ユーザースコープ(~/.claude、dotfiles 管理)
- 恒久情報はメモリーに置かない(git 外・マシン依存・他エージェント不可視)

### 5. 変更の展開

- 大きな設計変更は**敵対的検証**をかけてから展開する: 観点を分けた3体(実行系を実際に
  壊す / 公式仕様へ接地 / 設計レッドチーム)・fresh context(作成経緯を渡さない)・
  指摘は偽陽性前提で裁定(判定基準と方法の出典は references/adversarial-verification.md)。
- 複数リポへの配布物は harness-template のバージョン刻印を上げ、配布先の世代を grep で追う。

### 6. 記録

監査結果の要約(1〜3行)を下の監査履歴に追記し、大きな発見は references/ に日付付きで残す。

## 監査履歴

- **2026-08-05(初回)**: caldav/swift-mcp-app は模範解。乖離4変種のコメント方針を正典化、
  harness:init を新設し store-redirect へ初適用。cclens 実測(edit-precondition 344件・
  path-not-found 137件・cd 25%)からグローバル CLAUDE.md を新設。敵対的検証で
  フェイルオープン等を修正(v0.2.0)。詳細: references/audit-2026-08-05.md
