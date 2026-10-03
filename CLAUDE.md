# claude-code — gigun の Claude Code プラグイン集

<!-- ここに足すときの判定: その一文はエージェントの行動を変えるか(プラスにもマイナスにも)。
     変えないなら書かない —— 全行が毎セッションのコストで、サブエージェントにも継承される。
     技術スタックや概観は README、手順は skill、ファイル限定の制約は .claude/rules/ へ。
     却下の記録はここに置かない(docs/adr/ かコミットメッセージが置き場)。 -->

todo / adr / ios-skills / 各種 MCP をプラグインとして配布するモノレポ。

## 主要コマンド

- 検証: `bash scripts/verify.sh`。CI・pre-push からは呼ばれない。手で叩く
- `.claude-plugin/plugin.json` か `.claude-plugin/marketplace.json` を変えたら `python3 scripts/generate_manifests.py --write` で生成し直す(元はこの2つ。`.codex-plugin/plugin.json` は name/version/description/author が生成対象で、homepage・repository・keywords・mcpServers/skills の指す先・interface は引き続き手で編集する。`.agents/plugins/marketplace.json` は全体が生成物で手で編集しない)
- 次にやること: `plugins/todo/bin/todo ready`
- 既存の決定: `plugins/todo/bin/adr ls`

## 報告するとき

ユーザーの困りごとから、変更・検証結果・未完を説明する。未完は本人の判断が必要なものと、エージェントが進められるものを分ける。配布プラグインへの変更か、このrepoだけの変更かも伝える。

測定結果は、誤りなら検出できる対照ケースでも確かめる。

## 作業リズム

- **1コミット = 1論理変更。**
- **短命ブランチ = 着手順の1項目。** 依存を跨がせない(A が B を待つなら1本にしない)。
- **並行するなら worktree。** 同じ作業ツリーで2つ動かさない。
- **触ったプラグインの検証は手で叩く**(`bash scripts/verify.sh`。CI・pre-push は無い)。
- **他セッションの変更と分けてコミットし、依頼された push まで完了する。**

## 情報の書き分け

- **コード = How** / **テスト = What** / **コミットログ = Why** / **コメント = Why not**

## タスクと決定

Tasks live in todo.txt; use the todo skills.
決定は `docs/adr/`、知識は `docs/`、経緯はコミットメッセージに置く。
旧 `docs/<component>/next-directions.md` と `log.md` は移行前の参照記録。更新しない。
ios-skills と評価の作業では `.claude/rules/ios-skills.md` も読む。
