# iOS ツール移行前の環境確認

2026-11-09 に SSH とローカル CLI で確認したスナップショット。推奨構成の決定ではない。

| 環境 | 確認結果 |
|---|---|
| MBPM4Pro | Darwin arm64、Xcode 27.2 (27B52)。`xcrun xcodeproj --help` と `xcrun agent plugin path --plugin-format claude/codex` が成功 |
| mini | Intel x86_64、macOS 15.8.2、Xcode 26.3 (17C529)。mcpbridge は存在するが agent と xcodeproj は見つからない。iOS 26.3 runtime がある。確認時は booted Simulator なし、Xcode プロセスあり、Simulator アプリのプロセスなし。console user は gigun |
| mini-vm | Linux x86_64、NixOS 26.11。xcrun / Xcode は見つからない。SSH と Tailscale は存在 |

初回は mini-vm → mini の SSH が tailnet policy により拒否された。その後、本人の指示で dotfiles のポリシーを更新し、mini-vm を tag:dev、mini を tag:dev + tag:storage に移行した。両ノードの鍵期限を無効化し、mini-vm → mini と mini → mini-vm の gigun による相互実行を確認済み。ポリシーの正本と判断は dotfiles の docs/tailnet.md / ADR 0015 にある。

## 更新方針への影響

- Xcode 27.2 の機能を全環境の必須条件にしない。実行先のツール能力を確認して経路を選ぶ。
- mini の mcpbridge はバイナリの存在のみ確認。MCP 接続、公開ツール、DeviceInteraction session は未検証。27.2 のツールと同一と扱わない。
- mini-vm は主開発環境、mini は macOS 実行環境。相互 SSH は確認済みだが、MCP のリモート接続と各ツールの動作は別途実走する。同じ gigun へのアクセスがあることを build/sign/publish の資格情報分離の前提に含める。
- CLI build、GUI 操作、Simulator 実行、USB 実機アクセス、ブラウザへの映像配信を別々に検証する。Xcode プロセスや runtime の存在だけで成功と判定しない。
- mini の OS/Xcode 更新可否、GUI session への操作権限、Simulator の起動・描画性能、署名・実機接続、remote MCP の到達性、serve-sim の接続先と port forwarding は未確認。

## 残る検証

iOS のビルド、Simulator 起動、実機操作は行っていない。ネットワーク設定は後続の dotfiles 作業で移行・検証した。Apple 公式 plugin への移行と自作 skill の routing 更新は、これらの実走確認を経てから確定する。
