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
| `harness` | init, doctor, tidy, next | セッション引き継ぎハーネスの導入・点検・片付け・着手順の一覧 |
| `telemetry` | review | Langfuse のトレースから自分のセッションを実測し、設定改善に回す |
| `ios-skills` | ios-app-icon, ios-simulator, ios-device-build, appstoreconnect-upload | `.icon`生成・Simulator操作・実機build・App Store Connect upload |
| `workers-fetch` | workers-fetch | workers-fetch CLIでのWorkers検証 |

Supabase・Vercel など公式マーケットプレイスに既にMCP内包プラグインがあるものは重複させず、`claude-plugins-official` 側を使う方針。

### harness — セッションの引き継ぎを腐らせない

エージェントのセッションは前回を覚えていない。harness は「現在地と次の作業」の正典を
リポジトリ内のファイル(`docs/next-directions.md`)に置き、セッション開始時に**その頭だけ**を
自動注入する。そのうえで、正典が腐ったことを機械が検知する。

**なぜ書式ではなく仕組みなのか。** 同じ形式の引き継ぎ文書を複数のリポジトリで運用していて、
caldav と swift-mcp-app では機能していたのに、cf-asc-dashbord のものは1ヶ月放置で腐っていた。
差は書式ではなく、**更新ルールが明文化されていたか**と**腐敗を機械が検知していたか**だった。
テンプレート化したのは書式ではなく、後者を含む一式。

配布物は caldav / swift-mcp-app で実証済みの形が原型で、導入後は対象リポジトリ内で完結する
(このプラグインへのランタイム依存が無い)。Codex は `.codex/` アダプタで**同じフック
スクリプトを共有する**。pre-push をサーバー側の branch protection に頼らずローカルで止めて
いるのは、個人開発では admin が bypass できて実効的でないから。

| スキル | 何をするか |
|---|---|
| `/harness:doctor` | 一式(正典テンプレ・SessionStart 頭注入フック・パススコープ付き rules・pre-push ゲート・AGENTS.md/Codex 配線)を対象リポジトリへ導入する。冪等なので新版の配布にも同じコマンドを使う |
| `/harness:doctor` | 設定がベストプラクティスを守れているかの静的検査。CLAUDE.md の肥大化、rules の `paths` 不一致(**エラーを出さずに無効化される**)、配線漏れを指摘する |
| `/harness:tidy` | セッションを畳む。正典の更新・コミット・push・log への追記と索引の再生成まで片付ける |
| `/harness:status` | 正典の「着手順」節をリポジトリ横断で一覧化。注入される頭のバイト数(10KB 超で無言に切り詰められる)も出す |

**設計原則(盆栽の7原則)はここには載せない。**圧縮版が
[`.claude/rules/harness.md`](.claude/rules/harness.md)(`plugins/harness/**` を触ると自動で届く)、
全文と根拠が [`docs/harness/next-directions.md`](docs/harness/next-directions.md) のカタログ部にある。
3箇所目を作ると必ずドリフトする(原則7)。

**個人リポジトリ前提。** チーム共有リポでは `.claude/settings.json` + フック `.sh` のコミットが
「clone した全員のセッション開始時に実行されるコード」になる。

### telemetry — 自分の使い方を実測する

`/telemetry:review` は Langfuse のトレースからツール別の時間・失敗・サブエージェントを集計する。
`/harness:doctor` が「設定が正しいか」を静的に見るのに対し、こちらは**実際にどう使われたか**。
作った直後に自分のフックのバグを2つ暴いた(サブエージェント span の duration が 0、型名が空)。
