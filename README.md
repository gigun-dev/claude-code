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

```bash
# マーケットプレイス登録は初回のみ
codex plugin marketplace add gigun-dev/claude-code
codex plugin add <plugin>@gigun
```

## プラグイン

MCPサーバーを1つずつプラグインとして内包しています。プラグインの enable/disable でMCPサーバーが一括起動・停止されます。

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

## スキルプラグイン

| プラグイン | スキル | 用途 |
|---|---|---|
| `ios-skills` | ios-app-icon, ios-simulator, ios-device-build, appstoreconnect-upload | `.icon`生成・Simulator操作・実機build・App Store Connect upload |
| `workers-fetch` | workers-fetch | workers-fetch CLIでのWorkers検証 |

Supabase・Vercel など公式マーケットプレイスに既にMCP内包プラグインがあるものは重複させず、`claude-plugins-official` 側を使う方針。
