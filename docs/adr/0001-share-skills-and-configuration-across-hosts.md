# Claude Code・Codex・Antigravity でスキル本文と設定を共有する

Date: 2026-09-10
Implementation: done

リポジトリ名は claude-code だが、利用者は同じプラグインを Claude Code、Codex、Antigravity (AGY) の 3 つすべてのホストで透過的に使うことを求めている。

スキル本文（SKILL.md）は共有し、各ホスト固有の登録形式（.claude-plugin/、.codex-plugin/、.antigravity-plugin/、mcp_config.json）はマニフェスト生成スクリプトが自動生成する。共通本文はホスト固有の自動実行記法や環境変数に頼らず、スキルの配置場所から同梱 CLI や設定を解決する。

Accepting: 各ホスト固有の便利機能・独自フック機構には頼らない
Rejected: 各エージェントごとに別リポジトリや別スキル本文を用意する — 二重管理と乖離を防ぐため
