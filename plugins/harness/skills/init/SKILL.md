---
name: init
description: gigun 標準のプロジェクトハーネス(docs/next-directions.md セッション引き継ぎ正典 + SessionStart 頭注入フック + パススコープ付きコメント方針 rules + pre-push 品質ゲート + CLAUDE.md/AGENTS.md 配線)を現在のリポジトリに導入する。「ハーネスを導入して」「/harness:init」で発火。
---

# harness:init — プロジェクトハーネスの導入

このスキルは、caldav / swift-mcp-app で実証済みのセッション引き継ぎハーネスを
対象リポジトリにスキャフォールドする。

## 設計原則(なぜこの形か)

- **すべて対象リポジトリへコピーする。** 導入後はこのプラグインへのランタイム依存が無い。
  目的は Claude Code のメモリー機構への依存を減らすこと — メモリーはプロジェクトスコープで
  git 外・マシン依存・他エージェント不可視。リポジトリ内ファイルなら git 管理で履歴が残り、
  remote 実行や別マシンでも同じ文脈が立ち上がり、明示的に管理できる。
- **エージェント可視性は2層で正直に扱う。** md ファイルの実体はどのエージェントからも
  読める。ただし自動ロード(頭注入フック・rules のパススコープ)はエージェント実装依存 —
  Claude Code はネイティブ、Codex は `.codex/` アダプタ + symlink で**同じフックスクリプトを
  共有できる**(caldav で実証済み。手順6)。他のエージェントには AGENTS.md 経由で正典への
  ポインタを見せる。
- **セッション開始時の注入は「頭」だけ。** 全文注入は毎セッション高コストなアンチパターン。
  行頭の `<!-- session-head-end` マーカーで境界を固定。**マーカーが無いときは全文注入に
  フォールバックせず警告して止まる**(fail-closed — 敵対的検証 2026-08-05 の補強)。
- **運用契約は検知器で支える。** 「必ず更新する」は宣言だけでは腐る。フックが
  カタログ肥大化・頭の肥大化・現在地の日付 vs 最終コミット日の乖離を機械計測して警告する。
  閾値は「棚卸し後に下げ直す」方向のみ調整可(上げて警告を消すのは禁止)。
- **コメント方針はパススコープ付き rules。** 常時ロードせず、コード編集時のみロードする。
  一次資料は `references/comment-culture-source.md`(このスキル内)を参照。

## 前提と注意

- 対象リポジトリのルートで実行。git リポジトリであること。
- **個人リポジトリ前提。** チーム共有リポに入れる場合は、`.claude/settings.json` + フック .sh の
  コミットは「clone した全員のセッション開始時に実行されるコード」になることを認識する
  (settings.json のコマンド文字列を変えずに PR で .sh の中身だけ差し替え可能)。
- **assets の実体はこの SKILL.md と同じディレクトリ配下**(`.../plugins/harness/skills/init/assets/`)。
  cwd は対象リポジトリなので、コピー元は絶対パスで解決すること。

## 手順

### 1. 現状調査

- **言語とコード配置**を確認(rules の `paths:` glob に使う。**言語が違うと glob がマッチせず
  silent に無効化される** — assets/comments-rule.md の警告コメント参照)。
- **docs/ の用途**を確認。GitHub Pages / VitePress / Docusaurus 等の公開サイトソースなら、
  next-directions.md(内部の意思決定・ボツ案を含む)が公開されてしまう。配置先を
  ユーザーと相談して変え、フックの `doc=` パスも合わせて変更する。
- **モノレポ/起動ルート**: フックは「claude を起動したディレクトリ」基準で動く。普段
  サブディレクトリから起動する運用なら、そのディレクトリを起点に配置する(ルートに置くと
  無言で不活性化し、検知手段が無い)。
- 既存の `CLAUDE.md` / `.claude/settings.json` / `AGENTS.md` / `.codex/` の有無を確認。
- README・直近コミット・会話の文脈から「現在地」と「次にやること」を把握する。
- 既に `docs/next-directions.md` がある場合(旧様式): 上書きせず、既存内容をカタログ部へ
  移設し、頭とマーカーを新設する形でマイグレーションする。**マーカー新設を忘れると
  フックは警告モードになる**(fail-closed なので気づける)。

### 2. docs/next-directions.md の作成

`assets/next-directions.md` をコピーし、プレースホルダを埋める:

- `{{DATE}}`: 今日の日付 / `{{CURRENT_STATE}}`: 現在地 / `{{NEXT_STEPS}}`: 次の一手 /
  `{{CATALOG}}`: 将来の方向性(無ければ「(まだ無い)」)
- 更新ブロックの正書式は `> **YYYY-MM-DD 更新:** ...`(太字)。フックの計測は太字省略にも
  寛容だが、教える書式は太字で統一する。

### 3. SessionStart フックの配線

- `assets/session-start.sh` を `.claude/hooks/session-start.sh` へコピーし `chmod +x`。
- `.claude/settings.json` に以下をマージする。**冪等に**: 既に同じコマンドの SessionStart
  エントリがあれば追加しない。既存の hooks / enabledPlugins / $schema は壊さない。

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|clear|compact",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/session-start.sh\""
          }
        ]
      }
    ]
  }
}
```

- matcher に `resume` / `fork` が無いのは意図的(会話履歴ごと復元され、過去の注入が
  transcript に残っているため再注入は重複)。ただし復元後にフックの鮮度警告は走らないので、
  長期間空いた resume では ND を手で読み直すこと。

### 4. コメント方針 rules の配置

`assets/comments-rule.md` を `.claude/rules/comments.md` へコピーし:

- `{{CODE_PATHS}}`: 実際のコード配置に置換(テスト・スクリプト・マイグレーション等、
  コメントを書く場所をすべて含める)
- `{{REPO_SPECIFIC_HOTSPOTS}}`: このリポジトリで経緯コメントが特に効く場所。リポジトリを
  読んで下書きし、自信が無ければユーザーに確認する。
- 既にコメント方針が CLAUDE.md にインラインで書かれている場合: rules へ移設し、CLAUDE.md
  には要旨1〜2行 + rules への参照を残す(この要旨が AGENTS.md 経由で他エージェントにも
  見える最低限の伝達になる)。リポ固有の「特に効く場所」は必ず保存する。

### 5. CLAUDE.md の整備

- 無ければ最小構成で作成(200行以下厳守): プロジェクト一行説明 / 主要コマンド /
  アーキテクチャ要点 / 以下の定型2節。あれば定型2節の有無を確認して追記。

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

### 6. pre-push フックの配線

壊れたコードが main に乗るのを止める最後の関門(main への push で自動 deploy される
構成なら本番を守る関門)。**サーバー側の branch protection は個人開発では admin が
bypass できるので実効的でない** — ローカルで止めるのが効く。

- `assets/pre-push` を `.githooks/pre-push` へコピーし `chmod +x`。
- `{{CHECK_COMMAND}}` をこのリポジトリの検証コマンドに置換する
  (例: `make check` / `bun run check` / `npm test`。**CI と同じ内容にする** —
  手元で通って CI で落ちるなら関門の意味がない)。
  ネットワークや認証を要する重い工程(deploy dry-run 等)が含まれる場合は、
  push のたびに待たされてよいかユーザーに確認する。
- 配線: `git config core.hooksPath .githooks` を実行する。
  **これは .git/config に入るため git 管理されず、clone ごとに1回必要**。
  Makefile や package.json のセットアップスクリプトに含め、README にも書いておく。
- 検証: `git push --dry-run` ではフックは走らない。実際の push か、
  `echo "refs/heads/main <sha> refs/heads/main <sha>" | .githooks/pre-push` で確認する。

### 7. 他エージェントへの配線

- **AGENTS.md**: 無ければ `AGENTS.md -> CLAUDE.md` の symlink を作成(caldav /
  swift-mcp-app の確立パターン)。実ファイルの AGENTS.md が既にあれば統合を相談。
- **Codex を併用するリポジトリなら** `.codex/` アダプタを配線(正典は caldav の
  `.codex/README.md`。方式: Claude 側を正典に、Codex surface は symlink 共有):
  - `assets/codex-hooks.json` を `.codex/hooks.json` へコピー
  - `.codex/hooks/session-start.sh -> ../../.claude/hooks/session-start.sh` の symlink
  - `.codex/config.toml` に `[features]\nhooks = true` を確保
  - 必要なら path 別 `AGENTS.md` symlink で rules も共有

### 8. 検証

- **普段 claude を起動するディレクトリで** `bash .claude/hooks/session-start.sh` を実行し、
  頭(マーカーまで)だけが出力されることを確認。
- マーカー行を一時的に消して警告モード(fail-closed)になることも確認して戻す。
- 大規模・長期プロジェクトなら `docs/log.md`(追記専用アーカイブ)の新設も提案。
  小規模なら git 履歴で足りるので作らない。
- 注意: 導入後にビルトイン `/init` を実行すると CLAUDE.md が定型2節を持たない形で
  上書きされうる。実行してしまった場合は手順5の2節を復元すること。

### 9. 報告

作成・変更したファイルの一覧と、next-directions.md に書いた現在地の要約をユーザーに示す。
コミットはユーザーの指示があってから。
