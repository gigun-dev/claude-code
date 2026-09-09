# harness から todo・ADR への移行

2026-09-10 の利用者の指示により、harness を廃止して todo・adr に切り替える。
タスクは `todo.txt` / `done.txt`、決定は `docs/adr/`、知識は docs、経緯はコミットメッセージに置く。
フックを配布しない判断は [ADR 0002](../adr/0002-ship-no-hooks-in-todo-and-adr.md) を参照する。

## このリポジトリでの変更

- Claude / Codex 両方の marketplace から harness を除き、`plugins/harness/` を撤去。
- SessionStart の設定・スクリプトと、旧文書の更新を催促する pre-commit を撤去。
- `CLAUDE.md`（`AGENTS.md` と共有）の入口を todo・ADR に変更。
- `scripts/verify.sh` の旧文書・ログ索引の検査を、実際の todo・ADR の検査へ置換。
- main の push 時に CI と同じ検証を呼ぶ `.githooks/pre-push` は、このリポジトリの検証として維持。
- 旧 `next-directions.md` / `log.md` は参照記録として保存。本文中の旧更新指示は現行の運用に適用しない。

評価用の共通実行器（`evaluations/` で「harness」と呼んでいるもの）は別の仕組みであり、継続する。
他リポジトリのファイル・設定は変更していない。Codex には todo / adr 0.1.1 を導入し、Claude 側の既存 0.1.0 も 0.1.1 に更新した。
両ホストの harness インストール登録を削除した。各リポジトリのコピー済みフックは別途移行する。
対象候補と各プロジェクトへの依頼文は [migration-targets.md](migration-targets.md)。
移行は各プロジェクトのセッションで実施する。今回限りの手順はプラグインに同梱しない。

## 旧タスクの対応

移行日は元の作成日ではないため、todo.txt の日付には取り込んだ日を使う。
過去の測定や詳細な完了条件は旧文書に保存し、`see:` で参照する。

| 旧 ID | todo ID / 扱い |
| --- | --- |
| IOS-7 | 0001 |
| IOS-8 | 0002 |
| IOS-1 | 0003 |
| IOS-2 | 0004 |
| IOS-6 | 0005。望む結果を成功条件にせず、比較結果を記録する |
| IOS-4 | 0006。判断を得ることを次の一手とする。履歴は書き換えない |
| IOS-5 | 0007。未定義だった対応と完了条件を決める |
| IOS-3 / IOS-9 | 旧完了記録を保存。再実行や新しい検証済み主張はしない |
| IOS-10 | 中止。廃止する文書更新の仕組みの追試なので、新タスクにはしない |
| H-2, H-7, H-4, H-5, H-6, H-11, H-9, H-13, H-14, H-15, H-22, H-24, H-25, H-26, H-29, H-32, H-34, H-35, H-36, H-37 | harness の開発・展開計画として中止。未修正の問題を修正済みとは扱わない。旧本文と履歴は保存 |

`done.txt` は空で開始する。中止した項目や過去の未再検証の項目を、新たに完了した仕事として登録しない。
旧文書の裁定待ち・危険・詳細は参照記録に残している。取り込んだタスクの着手時に現況を確認する。

## 導入済みプロジェクトの切り替え

harness はフックを各リポジトリへコピーしていたため、プラグインのアンインストールだけでは消えない。
各プロジェクトで以下を確認して移行する。共有設定に別用途のフックがある場合は、その設定を保持する。

1. 利用するホストで `todo@gigun` を導入する(adr は todo プラグインに同梱)。README を参照。
2. 旧着手順の未完了項目を読み、具体的な次の一手を todo に取り込む。旧 ID と新 ID の対応を残し、依存関係も移す。
3. 旧決定は保存し、必要なものを ADR の基準に沿って取り込む。経緯やログ全体を ADR として複製しない。
4. CLAUDE.md / AGENTS.md の旧指示を todo・ADR の入口に置き換える。
5. SessionStart / pre-commit / pre-push / rules / `.codex/` を実物で確認し、harness 専用部分を外す。
   CI 相当の検証を呼ぶ既存 pre-push は独立して維持できる。`core.hooksPath` を一括解除すると他のフックも止まるので、残すフックを先に確認する。
6. リポジトリの検証処理から `nd-tasks.sh` / `log-index.sh` の呼び出しを外し、todo / ADR の形式を検査する。
7. `todo check` / `adr check` と既存検証を実行し、旧専用スクリプトへの実行参照がないことを確認して、harness をアンインストールする。
   新規セッションで todo・ADR が利用でき、旧フックの出力がないことを確認する。

旧ソースは移行前コミット `5afd4864910c8b709b5d65789bdf4f2f1726799b` に残っている。
例: `git show 5afd4864910c8b709b5d65789bdf4f2f1726799b:plugins/harness/skills/doctor/scripts/install.sh`。
過去の記録に出てくる削除済みの `plugins/harness/` や rules のパスも、このコミットで参照できる。

## この変更の検証

- `bash scripts/verify.sh`: `✓ verify.sh: すべての検証に合格した`。
  追加・削除を反映した一時 Git index を使い、利用者の staging 状態は変更していない。
  todo は `81 passed, 0 failed`、adr は `42 passed, 0 failed`。
- 不正な `dep:9999` と日付なし ADR は、それぞれ `check` が終了コード 2 で検出。
- pre-push は一時プロジェクトの検証失敗で main の更新を終了コード 1 で阻止。
  検証成功、feature の更新、ブランチ削除は終了コード 0。
- 旧タスクは harness 20 ID / ios-skills 10 ID を移行対応表と照合済み。
- Codex CLI 0.153.4 の app-server `skills/list` で `todo:todo` / `todo:doctor` / `adr:adr` が有効、読み込みエラー 0。
- Claude Code 2.1.263 の `plugin details` で todo の2スキル、adr の1スキルを認識。
  両方とも hooks / MCP / agents は 0。manifest の strict 検査は errors / warnings とも空。
- インストール先の CLI を配布元と別の一時ディレクトリから実行。
  Claude 固有変数を渡さず、todo の追加・依存解決・完了と、adr の一覧・検査を確認。
- スキル本文の読み込み・CLI の実行と、モデルが実際の依頼で適切にスキルを選ぶことは別。
  新規のモデル会話での自動選択や、他リポジトリの移行完了は今回検証していない。

共通化の方針は [ADR 0003](../adr/0003-share-skills-and-cli-between-hosts.md)。
Codex のスキルの段階的読み込みと配置パスの仕様は
[公式の Build skills](https://learn.chatgpt.com/codex/build-skills)、
インストールした CLI を別フォルダから検証する考え方は
[公式の Create a CLI Codex can use](https://learn.chatgpt.com/use-cases/agent-friendly-clis) を確認した。
