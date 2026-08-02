---
paths:
  - "plugins/ios-skills/**"
  - "evaluations/**"
---

# ios-skills を触るときに読むもの

**現在地・次の作業は `docs/ios-skills/next-directions.md`(repo ルート相対)にある。
このディレクトリを編集する前に読むこと。** 作業の区切りごとに必ずそちらを更新する
(完了は打ち消し線+✅、状況変化は `> 日付 更新:` を積層。計画は消さない)。

**時系列の生記録は `docs/ios-skills/log.md`(追記専用アーカイブ)。** 作業の区切りごとに
末尾へ追記する。通常は全文ロードしない — 経緯を掘るときだけ読む。

`evaluations/` は評価ハーネス専用の関心(rubric・case・runner・測定結果)。
継続コンテキスト(現在地・ログ)はここには置かない——評価とプラグイン改善は
別の関心なので、`docs/ios-skills/` 側にまとめる。

主旨は **ios-skills(`plugins/ios-skills/`)の改善**、特に iOS アプリ開発まわり。
`xcode-mcp` は公式バイナリ(`xcrun mcpbridge`)の薄いラッパーで、
私たちが開発しているものではないため対象外。

Codex からは `plugins/ios-skills/AGENTS.md` / `evaluations/AGENTS.md`
(このファイルへの symlink)経由で同じ pointer を読む。対応関係は `.codex/README.md`。
セッション開始時には SessionStart フックが軽量な pointer 一行を常時注入する
(`.claude/hooks/session-start.sh` / `.codex/hooks/session-start.sh`)。
