# Claude Code と Codex でスキル本文と CLI を共有する

Date: 2026-09-10
Implementation: done

利用者は同じプラグインを Claude Code と Codex の両方で使うことを求めている。スキル本文と同梱 CLI は共有し、登録形式の違いは各ホストの manifest に置く。共通本文はホスト固有の自動実行記法や PATH 注入を前提にせず、配置場所から CLI を解決する。
