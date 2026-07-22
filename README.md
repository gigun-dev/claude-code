# claude-code

gigun の Claude Code プラグイン・マーケットプレイス。

## 使い方

```bash
claude plugin marketplace add gigun-dev/claude-code
claude plugin enable <plugin>@gigun
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
| `vercel-mcp` | Vercel (http) | デプロイ・プロジェクト管理 |
| `figmate-mcp` | `figmate-mcp` | agent2figmaデザイン(要 figmate グローバルインストール) |
| `markitdown-mcp` | `uvx markitdown-mcp` | ファイル→Markdown変換 |

Supabase など公式マーケットプレイスに既にMCP内包プラグインがあるものは重複させず、`claude-plugins-official` 側を使う方針。
