# claude-code

gigun の Claude Code / Codex プラグイン・マーケットプレイス。

skill / plugin / MCP の回帰評価とClaude/Codex共通runnerは
[`evaluations/README.md`](evaluations/README.md)を入口とする。

## 使い方

### Claude Code

```bash
claude plugin marketplace add gigun-dev/claude-code
claude plugin enable <plugin>@gigun
```

### Codex

Codex ネイティブのカタログ定義は [`.agents/plugins/marketplace.json`](.agents/plugins/marketplace.json) にあります。Claude Code 互換の [`.claude-plugin/marketplace.json`](.claude-plugin/marketplace.json) も維持しています。
MCP定義の正典は各pluginルートの `.mcp.json` とする。例外は、公式が直接設定を案内する製品MCPとCodexデスクトップ内部機能だけである。
Claude用 `.claude-plugin/plugin.json` は正典から生成するadapterであり、変更後は `python3 scripts/sync_mcp_wrappers.py --check` を通す。修正が必要な場合だけ `--write` を実行する。

```bash
# マーケットプレイス登録は初回のみ
codex plugin marketplace add gigun-dev/claude-code
codex plugin add <plugin>@gigun
```

## Claude Code / Codex 共通の構成

| 内容 | 置き場 | 扱い |
| --- | --- | --- |
| スキル本文・参照資料 | `plugins/<name>/skills/` | 両ホストで同じファイルを読む |
| 実行する CLI | `plugins/<name>/bin/` | スキルの配置場所から解決し、対象リポジトリで実行する |
| Claude 向け登録 | `.claude-plugin/plugin.json` | Claude 固有の定義 |
| Codex 向け登録 | `.codex-plugin/plugin.json` | Codex 固有の定義 |
| MCP 接続定義 | `plugins/<name>/.mcp.json` | 共通の正典。Claude 側の定義は生成して照合する |

共通スキルはホスト固有の環境変数・自動コマンド展開・PATH 注入を前提にしない。
ホスト別のスキル本文や CLI を複製せず、登録形式の差だけを各 manifest に置く。
導入時の指示ファイルは対象が使う `AGENTS.md` / `CLAUDE.md` に合わせる。
todo・adr の実行依存は POSIX sh と awk。harness やホスト専用ランタイムには依存しない。

## 外部MCPラッパー

既存の外部MCPを配布・有効化するための薄いパッケージです。実装本体は持たず、manifestと `.mcp.json` のみを正典とします。
プラグインの enable/disable でMCPサーバーが一括起動・停止されます。

| プラグイン | MCPサーバー | 用途 |
|---|---|---|
| `xcode-mcp` | `xcrun mcpbridge` | Xcode / iOS開発 |
| `next-devtools-mcp` | `next-devtools-mcp` | Next.js開発 |
| `chrome-devtools-mcp` | `chrome-devtools-mcp` | ブラウザ操作・Web検証 |
| `deepwiki-mcp` | DeepWiki (http) | GitHubリポジトリのドキュメントQ&A |
| `dart-mcp` | `dart mcp-server` | Dart / Flutter開発(PATHに dart が必要) |
| `tableplus-mcp` | TablePlus | データベースGUI連携 |
| `figmate-mcp` | `figmate-mcp` | agent2figmaデザイン(要 figmate グローバルインストール) |
| `markitdown-mcp` | `uvx markitdown-mcp` | ファイル→Markdown変換 |

Context7はClaude/Codexともに `context7@claude-plugins-official` を使う。OpenAI Developer Docs MCPは[公式の直接設定](https://developers.openai.com/learn/docs-mcp)を使う。開発中のTDR MCPは将来ChatGPT pluginとして扱い、このmarketplaceには含めない。

## 自前MCP実装

MCPサーバーのコード・テスト・配布方法までこのリポジトリで保守するものを置く区分です。現在は該当なしです。Gemini MCPの代替候補であるAntigravity CLI（agy）のPython MCP化を着手する場合は、この区分に追加します。

## スキルプラグイン

| プラグイン | スキル | 用途 |
|---|---|---|
| `todo` | todo, adr, doctor | todo.txt でタスクと依存関係を、docs/adr/ で決定を管理 |
| `pre-push` | pre-push | Git の push 前検証の導入・点検 |
| `telemetry` | review | Langfuse のトレースから自分のセッションを実測し、設定改善に回す |
| `ios-skills` | ios-app-icon, ios-simulator, ios-device-build, appstoreconnect-upload | `.icon`生成・Simulator操作・実機build・App Store Connect upload |
| `japanese-tech-writing` | japanese-tech-writing | 日本語の技術文書・書籍原稿を書く / 推敲するときの文章規範(上流のgistから逐語でvendor、Unlicense) |

Supabase・Vercel など公式マーケットプレイスに既にMCP内包プラグインがあるものは重複させず、`claude-plugins-official` 側を使う方針。

### harness から todo・ADR へ移行

harness の配布を終了し、タスク管理と決定の記録は [todo](plugins/todo/README.md)
プラグインに切り替えました(adr は 2026-09-10 に todo へ統合)。
経緯はコミットメッセージ、知識は docs に置きます。
このリポジトリのタスクは `todo.txt`、決定は `docs/adr/` にあります。

導入済みのプロジェクトにはコピー済みのフックが残るため、プラグインを外すだけでは移行できません。
[移行手順と旧タスクの対応](docs/harness/migration.md)を参照してください。

### telemetry — 自分の使い方を実測する

`/telemetry:review` は Langfuse のトレースからツール別の時間・失敗・サブエージェントを集計する。
セッションで**実際にどう使われたか**を確認します。
作った直後に自分のフックのバグを2つ暴いた(サブエージェント span の duration が 0、型名が空)。
