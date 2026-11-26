# 配布する拡張はこの flake で版を固定してビルドし、home-manager で各ホストの読む場所へ置く

Date: 2026-11-25
Implementation: pending

REA は Claude Code・Codex・agy に別々の経路で届き、版も node も解析エンジンの環境もホストごとに違った。marketplace から入る写しはホストの導入時刻と PATH で中身が決まり、Codex は MCP の環境変数も消す。

このリポジトリが配る拡張は、この flake が固定した版から 1 回だけビルドし、consumer の home-manager module がその出力を各ホストの読む場所へ置く。版と実行環境を、ホストではなくこのリポジトリの固定で決めるためである。中身は Agent Plugins 1.0 に従い、ホスト別の manifest を並べて生成する。MCP はどのホストからも、固定した node と consumer が渡す環境を持つ同じ実行ファイルで起動する。

Accepting: Nix の無いホストには何も届かない
Accepting: Claude への配置は skills ディレクトリの plugin 読み込みに頼る。Desktop では確かめていない
Accepting: 上流の新しい版は、週次の自動更新に加えて consumer の lock 更新を待って届く
Rejected: marketplace で配り、ホストごとに環境だけ渡す — 写しと node がホストごとに分かれ、版のずれが残るため
Rejected: `rea setup` で各ホストに登録する — Nix の外に状態が残り、パスが実行時の環境で決まるため

Replaces: 0004,0005,0006
