# iOS 処理の実行先とツールを選ぶ

作業を依頼された環境と、Xcode を実行する Mac は同じとは限らない。最初に plugin ルートの
`scripts/ios-host.py probe` を実行する。Linux なら利用する Mac を明示し、
`python3 scripts/ios-host.py probe --host <SSH接続先> --mcp` でそちらを調べる。
接続先はユーザーの指定またはプロジェクトの運用設定から選び、名前や接続順では推測しない。

`probe` はインストール、ビルド、GUI 起動を行わない。`--mcp` は起動できる bridge に対して
initialize と tools/list だけを行う。`executables` は PATH 上の存在、`tools` は xcrun の解決結果、
`mcp.ok` と `mcp.tools` は実際の接続結果であり、区別して使う。バイナリが存在しても loader
error で起動できない場合がある。エラーは依存する経路だけを止め、使える CLI 経路へ進む。

## 経路の選択

| 作業 | 選ぶ経路 |
|---|---|
| アプリの build/run・UI 検証 | IDE の MCP が接続でき、必要なツールが利用中のエージェントにも公開されているなら Apple の対応スキルを使う。CLI の tools/list だけでエージェントから呼べるとは判断しない |
| Simulator の複製・OS アカウント・proxy・録画 | ios-simulator の simctl / 同梱スクリプト |
| IDE を介さない実機 build/install/run | ios-device-build の CLI |
| アイコンの生成・render | ios-app-icon。xcodeproj コマンドが実行可能なら組み込みに利用 |
| iPhone へ Ad Hoc OTA 配布 | 登録済みプロジェクトなら asc-mcp。App Store Connect への upload と混同しない |

Apple の DeviceInteraction ツール群を使う場合は対応する `device-interaction` スキルを読む。
workspace session に対象を明示し、install/run、hierarchy と screenshot、操作後の状態を確認し、
最後に session を終了する。対応ツールの名前と引数は現在の schema を使い、別 SDK の同名機能を代用しない。

## リモート CLI

実行先の checkout と出力パスを使う。手元のソースや app を暗黙に同期しない。
同梱スクリプトは次の入口から実行できる（パスは plugin ルートからの相対パス）。

```bash
python3 scripts/ios-host.py run --host <Mac> --cwd /absolute/remote/checkout -- \
  skills/ios-device-build/scripts/device_build.sh --list-devices
python3 scripts/ios-host.py run --host <Mac> --cwd /absolute/remote/checkout -- \
  skills/ios-device-build/scripts/device_build.sh \
  --project /absolute/remote/checkout/App.xcodeproj --scheme App --device '<UDID>' --dry-run
python3 scripts/ios-host.py exec --host <Mac> -- xcrun simctl list devices available
```

`run` は同梱ツールだけを一時ディレクトリへ転送し、終了時に削除する。
`exec` は明示した argv をそのまま実行先の tool に渡し、shell 展開はしない。
標準入力は既定で空にする。pbcopy 等へ渡す場合は `--stdin-file <file>` または
`--stdin-file -` を `--` より前に指定する。シグナル終了は `128 + signal` の失敗値で返す。
どちらもローカルの資格情報や環境変数は
転送しない。プロジェクトの引数・生成物・ログは実行先のパスで、取得が必要なら対象を明示して別途転送する。
渡す引数や実行先の環境に含まれる資格情報まで隔離するものではない。SSH が同じ UID の home や
Keychain にアクセスできる範囲を踏まえ、署名・公開は asc-mcp 側の境界に従う。

macOS の Tailscale SSH では、失敗したコマンドも SSH 自体の終了値が 0 になる
[上流の問題](https://github.com/tailscale/tailscale/issues/18256)がある。この入口は SSH の終了値だけに
依存せず、固定した executor が返す子プロセスの終了値と出力を受け取る。応答が欠落・不正なら失敗にする。
入口を迂回した raw SSH の終了値で build 成功を判定しない。これは悪意あるホストを検証する仕組みではない。

## Apple plugin の更新

`xcrun agent plugin path --plugin-format claude` / `codex` が使える Mac では、Xcode が管理する
plugin を利用し、その内容をこの repo に複製しない。Claude Code は公式 marketplace の
`xcode@claude-plugins-official` を使う。Codex は上記で得た Codex 用 plugin の登録経路を確認する。
既存 xcode-mcp と公式 plugin は同じ xcrun mcpbridge を登録するため、同一ホストで二重有効化しない。
インストール・更新後は新しいセッションでツールの公開と実際の操作を確認する。
古い Xcode では agent / xcodeproj を必須にせず、bridge と CLI をそれぞれ probe する。

## Simulator をブラウザに表示する

`serve-sim` は Simulator のある Mac で起動し、UDID を固定する。対応する ios-simulator-browser
スキルが利用できるならそちらの手順を使う。表示要求があれば、ブラウザで実フレームまで確認する。
リモート Mac の localhost は手元の localhost とは異なる。SSH のローカル転送を明示して
印字された port に接続し、インターネットや LAN 全体に expose する設定へ自動変更しない。
配信を終えるときは当該 UDID の helper だけを停止し、使い捨て端末を片付ける。
