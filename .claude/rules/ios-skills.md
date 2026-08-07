---
paths:
  - "plugins/ios-skills/**"
  - "evaluations/**"
  # 正典(docs/ios-skills/)を編集するときにも発火させる。ここが抜けていると、ND を書き換える
  # エージェントに書式の規約が届かない(harness 側と同じ是正。2026-08-06)。
  - "docs/ios-skills/**"
---

# ios-skills を触るときに読むもの

**現在地・次の作業は `docs/ios-skills/next-directions.md`(repo ルート相対)にある。
このディレクトリを編集する前に読むこと。** 作業の区切りごとに必ずそちらを更新する
(完了は打ち消し線+✅、状況変化は `> 日付 更新:` を積層。計画は消さない)。

**時系列の生記録は `docs/ios-skills/log.md`(追記専用アーカイブ)。** 書く条件6つ・読む条件4つ・
見出し規約・年次ローテは `plugins/harness/skills/doctor/assets/log.md` の先頭が**正**(複製しない)。
索引は自動生成 — 手で書かず `skills/tidy/scripts/log-index.sh` に書かせる
(旧書式の箇条書きからは 2026-08-07 に見出し書式へ移行済み。経緯は log.md の同日の項目)。

`evaluations/` は評価ハーネス専用の関心(rubric・case・runner・測定結果)。
継続コンテキスト(現在地・ログ)はここには置かない——評価とプラグイン改善は
別の関心なので、`docs/ios-skills/` 側にまとめる。

主旨は **ios-skills(`plugins/ios-skills/`)の改善**、特に iOS アプリ開発まわり。
`xcode-mcp` は公式バイナリ(`xcrun mcpbridge`)の薄いラッパーで、
私たちが開発しているものではないため対象外。

Codex からは `evaluations/AGENTS.md`
(このファイルへの symlink)経由で同じ pointer を読む。`plugins/` は配布物なので symlink を置かない。対応関係は `.codex/README.md`。
セッション開始時には SessionStart フックが軽量な pointer 一行を常時注入する
(`.claude/hooks/session-start.sh` / `.codex/hooks/session-start.sh`)。
