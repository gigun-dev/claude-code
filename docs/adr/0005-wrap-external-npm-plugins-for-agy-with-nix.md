# agy には外部 npm plugin をこのリポジトリの flake で包んで配る

Date: 2026-11-13
Implementation: pending

外部 plugin は marketplace 経由で Claude Code と Codex に入るが、agy には入らない。agy は `~/.gemini/config/plugins.json` が指すディレクトリから `.antigravity-plugin/` を持つ plugin だけを読み、REA の npm パッケージ（`rea-agents`）はそれを持たないためである。上流の `rea setup` は agy にも登録できるが、`~/.gemini/config/` へ直接書き込み、実行した場所の起動パスと Ghidra のパスを焼き込む。版を進める手段も setup の再実行しかない。さらに agy 1.5.5 は、スラッシュコマンドで呼んだ skill の本文を先頭 24,000 バイトで切り、上限を変える設定を持たない。REA 6.9.0 の本文は 43,053 バイトある。

npm で配布される外部 plugin の agy 版は、このリポジトリの flake が作る（`nix/agy-external-plugins.nix`、overlay は `agy-external-plugins`）。上流の tarball を `nix/npm-sources.json` の版と SRI ハッシュで取得し、`scripts/agy_wrap_plugin.py` が agy の manifest と `mcp_config.json` を足す。上限を超える SKILL.md は、`## ` の節を大きい順に `references/` へ移して上限内に収める。移した節の見出しと冒頭の段落は本文に残し、移した先を読むよう指示を置く。文言は書き換えない。収まらないときやリンクが壊れるときは、ビルドを失敗させる。MCP は consumer の PATH ではなく、パッケージが指定する node の絶対パスで起動する。ビルドの最後にその node でサーバーを起動し、tools/list が返ることを確かめる。`nix/npm-sources.json` は marketplace の npm の版を動かす週次の更新が同じコミットで書き、`--check` が両者のずれを検出する。Ghidra や JDK など consumer の環境に属する値は、`mcpEnv` で consumer（dotfiles）が渡す。形は ryoppippi/claude-code-overlay に揃えた。版ごとの sources ファイルを更新スクリプトが書き、パッケージはそれを読むだけにする。

Accepting: agy に入る skill は上流の配布物そのものではない（節の位置が変わり、案内文が加わる）
Accepting: このリポジトリが flake になり、flake.lock の nixpkgs の更新を持つ
Accepting: 上流が節の構成を変えると、分割が失敗してビルドが止まることがある
Rejected: `rea setup` で agy に登録する — Nix の外に状態が残り、版と Ghidra のパスが実行時の環境で決まるため
Rejected: dotfiles 内の package にする — 版とハッシュの更新が marketplace の固定と別々に進むため
Rejected: skill を分割せずに使う — 後半の指示が届くかどうかが、モデルが切れ目に気づいて読み直すかに左右されるため
Rejected: 起動に PATH の node を使う — consumer の nixpkgs の node が REA の要求する版を満たさないことがあり、launcher が起動を拒むため
Revisit: agy が skill 本文の上限を外すか設定可能にしたとき、または上流が本文を上限内に収めたとき
