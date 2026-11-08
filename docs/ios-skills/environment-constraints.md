# iOS ツール移行前の環境確認

2026-11-09 に SSH とローカル CLI で確認したスナップショット。実装と実走結果を含む。

| 環境 | 確認結果 |
|---|---|
| MBPM4Pro | Darwin arm64、Xcode 27.2 (27B52)。`xcrun xcodeproj --help` と `xcrun agent plugin path --plugin-format claude/codex` が成功 |
| mini | Intel x86_64、macOS 15.8.2、Xcode 26.3 (17C529)。mcpbridge は存在するが agent と xcodeproj は見つからない。iOS 26.3 runtime がある。確認時は booted Simulator なし、Xcode プロセスあり、Simulator アプリのプロセスなし。console user は gigun |
| mini-vm | Linux x86_64、NixOS 26.11。xcrun / Xcode は見つからない。SSH と Tailscale は存在 |

初回は mini-vm → mini の SSH が tailnet policy により拒否された。その後、本人の指示で dotfiles のポリシーを更新し、mini-vm を tag:dev、mini を tag:dev + tag:storage に移行した。両ノードの鍵期限を無効化し、mini-vm → mini と mini → mini-vm の gigun による相互実行を確認済み。ポリシーの正本と判断は dotfiles の docs/tailnet.md / ADR 0015 にある。

## 更新方針への影響

- Xcode 27.2 の機能を全環境の必須条件にしない。実行先のツール能力を確認して経路を選ぶ。
- mini の mcpbridge は存在するが、実際の起動はAppSandboxの未解決symbolで失敗した。Apple MCPを前提にせず、動作確認済みのCLIを使う。
- mini-vm は主開発環境、mini は macOS 実行環境。相互 SSH は確認済みだが、MCP のリモート接続と各ツールの動作は別途実走する。同じ gigun へのアクセスがあることを build/sign/publish の資格情報分離の前提に含める。
- CLI build、GUI 操作、Simulator 実行、USB 実機アクセス、ブラウザへの映像配信を別々に検証する。Xcode プロセスや runtime の存在だけで成功と判定しない。
- mini の Simulator bootとscreenshotは確認済み。OS/Xcode更新可否、GUI操作、描画性能、署名・実機接続、serve-simの映像配信は未確認。

## 残る検証

CodexへのApple公式plugin登録と新規sessionのツール公開、miniからの映像配信、実機操作、署名・配布、再起動復帰を残す。miniのMCP起動失敗はCLI経路の利用を妨げない。

## 実装後の実走（2026-11-09）

- ios-host.pyのprobeをPro、mini、mini-vmで実行し、さらにmini-vm経由でminiをprobeした。
  ProはMCP initialize/tools/list成功、miniはAppSandbox未解決symbolでbridge起動失敗、
  mini-vmはLinuxとしてMac実行先が必要と判定した。存在と動作を分離した。
- macOSのTailscale SSHは `exit 4` もtransport終了値0となり、同一client→mini-vmは4だった。
  miniの /usr/bin/login 経由の非TTY実行は上流issues/18256と一致する。共通executorが返す
  子の終了値を使う方式でminiの失敗4・signal終了143・日本語stdinを実測した。
- miniのCLIでpaired device列挙は0件。実機installは未実施。使い捨てiPhone17 Simulatorを
  作成・boot完了・preflight・screenshot取得して実フレームを確認し、当該端末を削除した。
  idbは未導入でタップは未検証。別targetのxcodebuild warningは停止せず、screenshotに必要な前提だけ確認した。
- Proのxcrun xcodeprojで新project.xcproj内部形式のprojectを作成し、target/group/include/settingsから
  SwiftUIアプリを構成して未署名build成功。既存project.pbxprojの設定read/writeもscratchで成功。
  .xcodeproj入口は変わらないので、.xcprojを独立した入力拡張子として追加する必要はなかった。
  共通project selectorを実機buildとASC uploadへ適用し、Proの新形式とminiの旧形式でplanを確認した。
- ProのClaudeへ公式xcode@claude-plugins-officialをinstallし、enabled=trueを確認。
  旧xcode-mcpはuser scopeで既にdisabledだった。Codexのbuild-ios-apps内XcodeBuildMCPは別実装であり削除しない。
  CodexへのApple公式plugin登録と新規sessionのツール公開は別途確認する。
- miniのsigning/runner監査、固定commitの未署名archive結果はasc-mcpのdocs/ad-hoc-delivery.mdが正本。
  GUIではDevelopment identityのみ確認し、Distribution資材は保護領域を含め未確定。
  remote serve-simの実ストリーム・署名・実機インストール・再起動復帰はこの検証の成功に含めない。
