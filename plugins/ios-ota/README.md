# iOS OTA (`ios-ota`)

`ota-deploy`（ローカルビルド・Cloudflare R2配布）と `asc-mcp`（リモートMCPビルド・ASC CLI操作）を統合したプラグイン。

- **ローカルCLIビルド & 自動プロビジョニング**: `ota.conf` 不要で対象リポジトリの `project.yml` / `.xcodeproj` を自動検出し、Explicit App ID・Capability（Push Notifications、App Groups等）・Ad Hoc プロファイルの自動発行から Ad Hoc 署名・R2 配布までを一気通貫で実行する（`uv run python3 scripts/ios_ota.py --repo /path/to/repo`）。
- **リモートMCPビルド**: 登録済みアプリの GitHub PR / commit を Cloudflare の認証付き remote MCP（`list_apps`、`build_app`、`get_build`）から Mac runner へ送り、ビルド・署名・私的配布する。
- **ASC CLI Code Mode**: `asc_search` と `asc_execute` により、App Store Connect CLI のサブコマンド検索とガードレール付き実行計画生成を提供する。

Claude Code / Codex / Antigravity で同じ skill と MCP 設定を共有する。接続先の初期値は `https://build.097969.xyz/mcp`。

サービス・CLI・IaC・構築手順: `/Users/gigun/ghq/github.com/gigun-dev/asc-mcp`（`ios-ota` リポジトリ）
