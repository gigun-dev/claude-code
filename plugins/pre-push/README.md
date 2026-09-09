# pre-push — push 前の検証を導入・点検する

Git の pre-push に、そのリポジトリの CI と共通の検証コマンドを接続する。
スキル1つと薄い雛形を配布する。導入後の実行は Git と各リポジトリの検証処理で完結する。

```sh
codex plugin add pre-push@gigun
claude plugin install pre-push@gigun
```

インストール後、対象プロジェクトで「pre-push に CI と同じ検証を入れて」または
「pre-push が実際に検証失敗を止めるか確認して」と依頼する。

- スキルと雛形は Codex / Claude Code 共通。ホスト別の登録定義だけを分ける。
- 既存のフック管理に合わせて導入する。インストールだけで Git 設定は書き換えない。
- 検証コマンド・対象ブランチ・フック本体は各リポジトリが管理する。
- プラグインを外してもコピー済みの Git フックは動く。更新も各リポジトリで差分を確認して行う。

[スキル](skills/pre-push/SKILL.md)が導入・点検の手順、
[雛形](skills/pre-push/assets/pre-push)が新規導入時の出発点。
雛形は main の更新時に、現在の作業ツリーで `./scripts/verify.sh` を実行する。
Git フックの実行依存は POSIX sh と、接続した検証処理の実行環境だけ。
アプリ側の hooks.json・MCP・常駐処理は持たない。

仕様は [Git の pre-push](https://git-scm.com/docs/githooks#_pre_push) を参照。

## 検証

```sh
python3 plugins/pre-push/tests/test_pre_push.py
bash scripts/verify.sh
```

雛形を一時リポジトリへコピーし、ローカルの bare リポジトリへの実際の push を試す。
検証失敗時のリモート参照、ブランチの選択・削除・複数 ref、linked worktree からの実行を確認する。
ネットワークやモデル呼び出しは不要。テストだけ Python 3 と Git を使う。
