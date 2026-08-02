---
name: appstoreconnect-upload
description: |
  Archive and upload iOS/macOS apps to App Store Connect (TestFlight/App Store) via CLI.
  Use when: (1) User wants to deploy to TestFlight, (2) User wants to upload to App Store,
  (3) User says "deploy", "upload", "archive", "TestFlight", "App Store Connect", or similar.
compatibility: >-
  macOS + Xcode。Apple Developer Program(有償)への登録と、App Store Connect にアクセスできる
  Apple ID が必要。ネットワーク接続必須。
---

# App Store Connectへarchive/uploadする

plan → validate → executeの順で進める。既定動作はplanのみで、archiveもネットワークuploadも行わない。
実uploadにはユーザーの明示的な依頼と`--upload`が必要。

## 手順

1. scheme、Bundle Identifier、version/build number、XcodeのTeam設定を確認する。初期設定や
   署名診断が必要なら`references/troubleshooting.md`を読む。

2. 既定の`assets/ExportOptions.plist`を確認する。異なるmethodやteam指定が必要ならコピーを
   プロジェクト側で編集し、`--export-options`で渡す。skill内asset自体は変更しない。

3. planを生成し、JSONのproject、archive path、export path、destinationを確認する。

   ```bash
   scripts/appstoreconnect_upload.sh \
     --project ./MyApp.xcodeproj \
     --scheme MyApp
   ```

4. ユーザーが実uploadを依頼し、planが正しい場合だけ、同じ引数に`--upload`を追加する。
   自動署名更新が必要と確認できた場合だけ`--allow-provisioning-updates`も追加する。

   ```bash
   scripts/appstoreconnect_upload.sh \
     --project ./MyApp.xcodeproj \
     --scheme MyApp \
     --upload
   ```

5. stdoutのJSONと終了コードを確認する。archive成功とupload成功を分け、App Store Connect側で
   processing中のbuildが現れたことまで確認して完了とする。

詳細な引数・安全境界・終了コードは`scripts/appstoreconnect_upload.sh --help`を読む。
