---
name: init
description: >-
  I invoke this when this repository has no session-handoff harness and context will
  be lost between sessions, or when its harness files are from an older generation and
  need refreshing. Installs a canonical docs/next-directions.md, a SessionStart hook
  that injects only its head, path-scoped comment rules, a pre-push quality gate, and
  AGENTS.md/Codex wiring. Idempotent — the same command distributes new versions.
  Also on '/harness:init'.
---

# harness:init — プロジェクトハーネスの導入

## Operating Posture

あなたは配布物を置く作業者ではなく、**何を配るかを決める判断者**。機械的な作業は全部
`install.sh` が行う。残るのは判断だけ — コード配置の特定、検証コマンドの選定、現在地の文章化。

失敗モードは2つ。**前者の方が重い**:

1. **置いたが効いていない状態で「導入完了」と報告する。** `paths:` が言語に合わない・
   `session-head-end` が無い・`core.hooksPath` 未設定 —— **どれもエラーを出さずに死ぬ**ので、
   効いていると信じたまま誰も気づかない(前2つは実際に起きた)。手順4の検証を飛ばさない。
2. **現在地を捏造する。** コードも差分も読まずに next-directions を埋めると正典が嘘になる。
   材料が無ければ「材料が無い」と書く。

**配らないという結論は成功。** `--with-log` を付けない・`--skip-prepush` にする・チーム共有
リポなら導入を見送る —— どれも正しい実行で、全部入りが正解ではない。

## スクリプト

- `scripts/survey.sh` — **読み取り専用**。`!` 記法でこのスキル読み込み時に自動実行され、
  判断に要る事実(言語・検証コマンド候補・既存ハーネスの状態・現在地の材料)が下に出ている。
- `scripts/install.sh` — **破壊的**なので `!` には置かない。判断結果を引数で渡して明示的に呼ぶ。
  冪等なので、導入済みリポジトリへ新版を配るのにも同じコマンドを使う。

## 配布物の前提(判断に効く事実)

- **すべて対象リポジトリへコピーする。** 導入後はこのプラグインへのランタイム依存が無い。
  恒久情報はメモリー機構ではなくリポジトリ内ファイルへ置く(メモリーは git 外・マシン依存・
  他エージェント不可視)。
- **Codex は `.codex/` アダプタで同じフックスクリプトを共有できる**(`--with-codex`)。
- **注入は「頭」だけ。マーカーが無いときは全文注入にフォールバックせず警告して止まる**
  (fail-closed)。
- **運用契約は検知器で支える。** フックがカタログ肥大化・頭の肥大化・現在地の日付 vs
  最終コミット日の乖離を機械計測して警告する。
- **pre-push はローカルで止める。make は前提にしない**(あれば使うだけ)。

## 現状調査(このスキル読み込み時に自動実行済み)

```!
bash "${CLAUDE_SKILL_DIR}/scripts/survey.sh"
```

## 手順

### 1. 判断

上の調査結果を読んで、次を決める:

- **コード配置**: rules の `paths:` に渡す glob。調査結果の拡張子分布とトップ階層ディレクトリ
  から決める。TypeScript なら `src/**,test/**,migrations/**`、Swift なら `Sources/**,Tests/**`。
- **検証コマンド**: pre-push で走らせるもの。**CI と同じ内容にする**(手元で通って CI で
  落ちるなら関門の意味がない)。省略時は調査結果と同じ検出ロジックで自動選択される。
  重い工程(ネットワークや認証を要する deploy dry-run 等)を含むなら、push のたびに
  待たされてよいかユーザーに確認する。
- **docs/ の退避要否**: 調査結果が公開サイトの可能性を警告していたら、`--docs-dir` で変える
  (next-directions には内部の意思決定・ボツ案が入るので公開されると困る)。
- **log.md の要否**: 長期・大規模プロジェクトなら `--with-log`。小規模では git 履歴で足りるので
  作らない(書かれないファイルが増えるだけ)。
- **Codex 併用**: 調査結果に `.codex/` があるか、ユーザーが Codex も使うなら `--with-codex`。
- **起動ルート**: フックは claude を起動したディレクトリ基準。モノレポでサブディレクトリから
  起動する運用なら、そこを起点に実行する(ルートに置くと無言で不活性化する)。

### 2. スクリプト実行

```sh
"${CLAUDE_SKILL_DIR}/scripts/install.sh" --code-paths "src/**,test/**" \
  [--check-cmd "bun run check"] [--docs-dir docs] [--with-log] [--with-codex] [--skip-prepush]
```

スクリプトが「実行した機械的作業」と「残りの作業」を出力する。

### 3. 残りの作業(スクリプトが出した □ を埋める)

スクリプトの出力が正。以下は各項目の説明:

- **next-directions.md の `{{CURRENT_STATE}}` / `{{NEXT_STEPS}}` / `{{CATALOG}}`** —
  手順1で集めた材料から書く。現在地は「未コミットの実装がある」「裁定待ちの判断がある」など
  次のセッションが知らないと困ることを具体的に。捏造しない。
- **rules の `{{REPO_SPECIFIC_HOTSPOTS}}`** — このリポジトリで経緯コメントが特に効く場所
  (外部 API の非公式な叩き方、ドメインの癖、チューニング値など)。リポジトリを読んで書く。
- **CLAUDE.md** — 無ければ `install.sh` がテンプレートから作る。残るのは
  `{{PROJECT_NAME}}` などのプレースホルダを埋める判断だけで、**80行以内**を維持する
  (何を書かないか — 技術スタック一覧・アーキテクチャ概観など — はスクリプトが出す TODO 行が正)。
  既存の CLAUDE.md は1バイトも触らないので、定型2節が無い場合はここで追記する:

```markdown
## 情報の書き分け方針

- **コード = How** / **テスト = What** / **コミットログ = Why** / **コメント = Why not**。
- **コメントはコードと同量レベルでベッタベタに書く。** 詳細は `.claude/rules/comments.md`
  (コード編集時に自動ロード)。

## 現在地・次の作業(セッション引き継ぎ)

- 正典は **`docs/next-directions.md`** — SessionStart フック(`.claude/settings.json`)が
  頭(`session-head-end` マーカーまで)を自動注入する。作業の区切りごとに必ず更新
  (完了は打ち消し線+✅、変化は `> **YYYY-MM-DD 更新:**` を積層。計画は消さない)。
```

- **README に `git config core.hooksPath .githooks`** — `.git/config` に入るため git 管理
  されず、**clone ごとに1回必要**。
- **既存 next-directions.md が旧様式の場合** — 上書きせず、既存本文をカタログ部へ移し、
  頭(現在地・着手順)を新設し、行頭に `<!-- session-head-end -->` を入れる。

### 4. 検証

- `bash .claude/hooks/session-start.sh` — 頭(マーカーまで)だけが出ること。
- マーカー行を一時的に消して警告モード(fail-closed)になるのも確認して戻す。
- pre-push: `echo "refs/heads/main $(git rev-parse HEAD) refs/heads/main $(git rev-parse HEAD)" | .githooks/pre-push`
  で検証が走ること(`git push --dry-run` ではフックは走らない)。

### 5. 報告

作成・変更したファイルと、next-directions.md に書いた現在地の要約をユーザーに示す。
**コミットはユーザーの指示があってから。**

## 注意

- **個人リポジトリ前提。** チーム共有リポでは `.claude/settings.json` + フック .sh のコミットが
  「clone した全員のセッション開始時に実行されるコード」になる(settings.json のコマンド文字列を
  変えずに PR で .sh の中身だけ差し替えられる)。導入前にユーザーへ確認すること。
- **配布物のバージョン刻印は「そのファイルの内容が最後に変わった版」**。ファイルごとに
  異なるのは正常で、揃えてはいけない(揃えると配布先で世代差分を検出できなくなる)。
  配布先の世代確認は `grep -r "harness-template v" <repo>`。
- 導入後にビルトイン `/init` を実行すると CLAUDE.md が定型2節を持たない形で上書きされうる。
  実行してしまった場合は手順3の2節を復元する。

## 関連(導入したら次にここへ)

- **`/harness:doctor`** — 置いたものが本当に効いているかの静的検査(配線漏れ・silent 無効化)。
- **`/harness:next`** — 「着手順」を読んで次にやることを一覧する(読み取り専用)。
- **`/harness:tidy`** — セッションを畳む。正典の更新・log 追記・未コミット作業の始末まで。
