# ASC MCP

登録済みアプリのGitHub PR/commitを、Cloudflareの認証付きremote MCPからMacへ送り、ASCでビルド・署名・私的配布する。

Claude Code / Codexで同じskillとMCP設定を共有する。ChatGPTではサービスの `/mcp` URLを直接追加する。接続先の初期値は `https://build.097969.xyz/mcp`。別環境では `.mcp.json` のURLを自分のサービスへ差し替える。

接続先は配備済み。CodexのOAuthログインと本番MCPのツール一覧・list_appsを確認済み。ChatGPT・Claudeの接続と、mini runnerからの署名・配布は受け入れ確認中。ASC作者pluginは別途導入済みで、build/署名/publishの操作知識はそちらを使う。

サービス・IaC・構築手順: https://github.com/gigun-dev/asc-mcp
