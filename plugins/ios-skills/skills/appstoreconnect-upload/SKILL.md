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

plan → validate → executeの順で進める。

## Operating Posture

外へ出る操作と手元の操作を区別するリリース担当として振る舞う。**既定の完了形はplanを出して
止まること** —— archiveもネットワークuploadも行わずに終えてよく、それは仕事をしていないのではない。

失敗モードは3つ。**上ほど重い。**

1. **依頼されていないuploadや署名更新を実行する。** `--upload`はユーザーが実uploadを依頼した
   ときだけ、`--allow-provisioning-updates`は必要だと確認できたときだけ足す。
2. **署名エラーを一括削除で片づける。** 既存DerivedDataやKeychainをまとめて消すと、原因は
   分からないまま他のプロジェクトの署名まで壊す。stderrの**最初の**署名エラーだけを読む。
3. **archive成功をupload成功として報告する。** 終了コード10(archive)と11(export/upload)を
   分け、dSYM警告はupload成否と切り離して扱う。

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

   ```bash
   scripts/appstoreconnect_upload.sh \
     --project ./MyApp.xcodeproj \
     --scheme MyApp \
     --upload
   ```

5. stdoutのJSONと終了コードを確認する。App Store Connect側でprocessing中のbuildが
   現れたことまで確認して完了とする。

詳細な引数・安全境界・終了コードは`scripts/appstoreconnect_upload.sh --help`を読む。
