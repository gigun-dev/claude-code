# iOS実機ビルドのトラブルシューティング

## デバイスを列挙できない

- 実機をUSBまたは信頼済みネットワークで接続し、ロックを解除する。
- MacとiPhoneの「このコンピュータを信頼」を完了する。
- `scripts/device_build.sh --list-devices` のJSONに対象UDIDがあることを確認する。
- CoreDeviceServiceがタイムアウトした場合は、実行環境の権限とXcodeの初回セットアップを確認する。

## ビルドに失敗する

スクリプトは専用の新規DerivedDataを使うため、別ビルドの古い`.app`を拾わない。stderrの
`xcodebuild`診断を読み、Signing & Capabilities、Team、プロビジョニング、共有schemeを確認する。

## インストールまたは起動に失敗する

- `--device`へ名前ではなく`--list-devices`が返した正確なUDIDを渡す。
- 実機のロックを解除し、必要なら「VPNとデバイス管理」で開発元を信頼する。
- 複数のapp productがある場合は`--bundle-id`でインストール対象を明示する。
- launchだけを切り分ける場合は、まず`--no-launch`でbuild/installまで確認する。

終了コード10/11/12はbuild/install/launchの境界に対応する。自動処理ではメッセージ文字列でなく
終了コードとstdoutのJSONを使う。
