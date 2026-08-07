<!-- harness-template v0.1.0 (配布元: gigun-dev/claude-code plugins/harness) -->
# {{PROJECT_NAME}}

<!-- ここに足すときの判定: その一文はエージェントの行動を変えるか(プラスにもマイナスにも)。
     変えないなら書かない —— 全行が毎セッションのコスト。技術スタック/アーキテクチャ概観は
     README、手順は skill、ファイル限定の制約は .claude/rules/ へ。予算80行。 -->

{{ONE_LINE_DESCRIPTION}}

## 主要コマンド

- 検証: `{{CHECK_CMD}}`
- 実行: `{{RUN_CMD}}`
- デプロイ: `{{DEPLOY_CMD}}`

## デフォルトと異なる規約

<!-- 「知らないと間違った場所にファイルを作る」類だけ。無ければ「特になし」と書く。 -->
- {{NON_DEFAULT_CONVENTIONS}}

## 情報の書き分け方針

- **コード = How** / **テスト = What** / **コミットログ = Why** / **コメント = Why not**。
- **コメントはコードと同量レベルでベッタベタに書く。** 詳細は `.claude/rules/comments.md`
  (コード編集時に自動ロード)。

## 現在地・次の作業(セッション引き継ぎ)

- 正典は **`docs/next-directions.md`** — SessionStart フック(`.claude/settings.json`)が
  頭(`session-head-end` マーカーまで)を自動注入する。作業の区切りごとに必ず更新
  (完了は打ち消し線+✅、変化は `> **YYYY-MM-DD 更新:**` を積層。計画は消さない)。

- 詳細・技術スタック・アーキテクチャは `README.md` を参照。
