---
name: ios-device-build
description: >-
  Swift/iOSアプリを実機にビルド・インストール・起動する。使用タイミング:
  (1)「実機にビルドして」(2)「iPhoneで動かして」(3)「デバイスにインストールして」(4)「実機で確認して」(5)「実機デプロイ」など実機デバッグが必要な時。xcodebuild
  → devicectl install → devicectl launchの一連のフローを自動化。
compatibility: >-
  macOS + Xcode。接続された iOS 実機と、有効な開発者証明書・プロビジョニングプロファイルが必要。xcodebuild /
  devicectl を使う。Simulator は対象外(それは ios-simulator)。
---

# iOS実機ビルド

対象を推測せず、プロジェクト・scheme・UDIDを明示して実行する。スクリプトはstdoutへJSON、
診断へstderr、工程別の終了コードを返す。

## 手順

1. 接続済み実機を列挙し、ユーザーが指定した端末のUDIDを選ぶ。

   ```bash
   scripts/device_build.sh --list-devices
   ```

2. 外部変更を行う前にplanを確認する。

   ```bash
   scripts/device_build.sh \
     --project ./MyApp.xcodeproj \
     --scheme MyApp \
     --device '<UDID>' \
     --dry-run
   ```

3. 同じ明示引数から`--dry-run`だけ外し、build → install → launchを実行する。
   起動不要なら`--no-launch`、複数app productがあるなら`--bundle-id`を追加する。

4. stdoutの`status`、終了コード、実機上の起動結果を確認する。コマンド終了だけで
   アプリ機能のE2E成功とは判定しない。

`--device`は環境変数`IOS_DEVICE_UDID`でも指定できる。名前・接続順・`booted`に基づく暗黙選択はしない。
毎回新しい明示DerivedDataを使うため、グローバルDerivedDataの古い`.app`を拾わない。

詳細なオプションと終了コードは`scripts/device_build.sh --help`を読む。失敗時は
`references/troubleshooting.md`を読む。
