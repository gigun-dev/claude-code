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

plan → validate → executeの順で進める。**既定の完了形はplanを出して止まること**で、archiveも
ネットワークuploadも行わずに終えてよい。

## 手順

1. scheme、Bundle Identifier、version/build number、XcodeのTeam設定を確認する。初期設定や
   署名診断が必要なら`references/troubleshooting.md`を読む。署名エラーはstderrの最初の1件だけを
   読んで直す。既存DerivedDataやKeychainをまとめて消すと、原因が分からないまま他のプロジェクトの
   署名まで壊す。

2. 既定の`assets/ExportOptions.plist`を確認する。異なるmethodやteam指定が必要ならコピーを
   プロジェクト側で編集し、`--export-options`で渡す。skill内asset自体は変更しない。

3. planを生成し、JSONのproject、archive path、export path、destinationを確認する。

   ```bash
   scripts/appstoreconnect_upload.sh \
     --project ./MyApp.xcodeproj \
     --scheme MyApp
   ```

4. ユーザーが実uploadを依頼し、planが正しい場合だけ、同じ引数に`--upload`を追加する。
   `--allow-provisioning-updates`は、それが必要だと確認できたときだけ足す。

   ```bash
   scripts/appstoreconnect_upload.sh \
     --project ./MyApp.xcodeproj \
     --scheme MyApp \
     --upload
   ```

5. stdoutのJSONと終了コードを確認する。終了コード10(archive)と11(export/upload)を分けて読み、
   archive成功をupload成功として報告しない。dSYM警告はupload成否と切り離して扱う。App Store
   Connect側でprocessing中のbuildが現れたことまで確認して完了とする。

詳細な引数・安全境界・終了コードは`scripts/appstoreconnect_upload.sh --help`を読む。
