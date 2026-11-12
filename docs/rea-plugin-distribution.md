# REA plugin配布の確認

REA（morluto/rea）は npm パッケージ `rea-agents` を Claude Code・Codex 共通の plugin 配布物にしている。共通marketplaceには npm source（バージョン指定なし）で登録した。方針は ADR 0003。

## 6.8.0 で登録を見送った理由

- 2026-11-10時点の最新 `rea-agents@6.8.0` の tarball（2,398 entry）には `skills/reverse-engineer-anything/SKILL.md` はあったが、`.claude-plugin/`、`.codex-plugin/`、`scripts/plugin-mcp-launcher.mjs` が無かった。
- 上流Gitには plugin 定義と launcher があるが、`dist/` と配布用 `skills/` は追跡外で、未ビルドの clean checkout では launcher が runtime missing で失敗する。Git source では起動できない。
- 上流 `docs/getting-started/installation.md` は、plugin定義を含む最初の npm release 以降で plugin を使えると書いていた。

## 6.9.0 で確認したこと（2026-11-12）

- `rea-agents@6.9.0`（2026-11-12公開、10,585 entry）に `.claude-plugin/plugin.json`・`.codex-plugin/plugin.json`・`.codex-plugin/mcp.json`・`scripts/plugin-mcp-launcher.mjs`・`dist/`・`skills/reverse-engineer-anything/` が揃い、両 manifest と launcher 引数のバージョンは 6.9.0 で一致する。
- 上流の両 marketplace（`.claude-plugin/marketplace.json`、`.agents/plugins/marketplace.json`）は npm source `rea-agents@6.9.0` を指す。
- 展開した tarball で `node scripts/plugin-mcp-launcher.mjs 6.9.0` に MCP の initialize と tools/list を送ると、serverInfo `rea 6.9.0`、255 tools が返った。対照として引数を 6.8.0 にすると、launcher はバージョン不一致のエラーで exit 1 になった。
- 一時的な設定ディレクトリ（`CLAUDE_CONFIG_DIR` / `CODEX_HOME`）に、npm source をバージョン指定なしで書いた marketplace を追加して導入した。
  - Claude Code 2.1.322: `claude plugin install` で 6.9.0 が入り、`claude mcp list` で `plugin:rea:rea` が Connected。
  - Codex 0.167.1: `codex plugin add` で 6.9.0 が入った。`codex mcp list` は接続を確かめないため、Codex と同じくインストール先を cwd にして相対パスの launcher を起動し、initialize と tools/list（255 tools）を確認した。

確認していないのは、普段の設定へのインストールと、実際のエージェントセッションから REA の tool を呼ぶことである。

## 運用

REA plugin が MCP と skill を所有するため、同じ host へ `rea setup` や別の MCP 定義を重ねない。更新は plugin 更新機構に委ね、解析エンジンと Node/Java の環境は dotfiles 側で管理する。plugin 自体は Ghidra をインストールせず、CLI の `rea` を PATH へ追加するものでもない。launcher は PATH 上の `node` を使う。

## 上流の根拠

- [installation and plugin distribution](https://github.com/morluto/rea/blob/main/docs/getting-started/installation.md)
- [Claude plugin manifest](https://github.com/morluto/rea/blob/main/.claude-plugin/plugin.json)
- [Claude marketplace](https://github.com/morluto/rea/blob/main/.claude-plugin/marketplace.json)
- [Codex marketplace](https://github.com/morluto/rea/blob/main/.agents/plugins/marketplace.json)
- [launcher](https://github.com/morluto/rea/blob/main/scripts/plugin-mcp-launcher.mjs)
