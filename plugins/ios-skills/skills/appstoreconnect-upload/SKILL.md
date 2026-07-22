---
name: appstoreconnect-upload
description: |
  Archive and upload iOS/macOS apps to App Store Connect (TestFlight/App Store) via CLI.
  Use when: (1) User wants to deploy to TestFlight, (2) User wants to upload to App Store,
  (3) User says "deploy", "upload", "archive", "TestFlight", "App Store Connect", or similar.
---

# App Store Connect Upload

Archive and upload iOS apps to App Store Connect using xcodebuild CLI.

## Prerequisites

### 1. Apple Developer Program
- **年会費**: 12,980円（日本）/ $99（米国）
- 登録: https://developer.apple.com/programs/

### 2. Xcodeの設定

**アカウント追加:**
- Xcode → Settings (⌘,) → Accounts → 「+」でApple IDを追加
- App Store Connectへのアクセス権があるApple IDが必要

**署名証明書:**
- 自動署名を有効にしておけばXcodeが自動管理
- Project → Signing & Capabilities → 「Automatically manage signing」をON
- Team: 自分のDeveloper Teamを選択

### 3. App Store Connectでのアプリ登録

初回アップロード前に必要:
1. https://appstoreconnect.apple.com にログイン
2. 「マイApp」→「+」→「新規App」
3. 以下を入力:
   - プラットフォーム: iOS
   - 名前: アプリ名
   - プライマリ言語
   - Bundle ID: Xcodeプロジェクトと一致させる
   - SKU: 任意の識別子

### 4. プロジェクト設定

**Info.plist / Project設定で必要なもの:**
- Bundle Identifier（例: `com.yourcompany.appname`）
- Version（Marketing Version）: `1.0.0`形式
- Build Number: 整数（アップロードごとにインクリメント）

### 5. チェックリスト

| 項目 | 確認 |
|------|------|
| Apple Developer Program加入 | □ |
| XcodeにApple IDを追加 | □ |
| 自動署名を有効化 | □ |
| App Store Connectでアプリ作成 | □ |
| Bundle IDが一致 | □ |
| ExportOptions.plistを配置 | □ |

## Workflow

### 1. Create ExportOptions.plist (if not exists)

Copy from `templates/ExportOptions.plist` in this skill directory to project root:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>upload</string>
</dict>
</plist>
```

### 2. Archive

```bash
xcodebuild archive \
  -project <PROJECT>.xcodeproj \
  -scheme <SCHEME> \
  -archivePath ./build/<NAME>.xcarchive \
  -destination 'generic/platform=iOS'
```

For workspace:
```bash
xcodebuild archive \
  -workspace <WORKSPACE>.xcworkspace \
  -scheme <SCHEME> \
  -archivePath ./build/<NAME>.xcarchive \
  -destination 'generic/platform=iOS'
```

### 3. Export & Upload

```bash
xcodebuild -exportArchive \
  -archivePath ./build/<NAME>.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath ./build/export \
  -allowProvisioningUpdates
```

### 4. Verify Success

Look for:
```
** ARCHIVE SUCCEEDED **
** EXPORT SUCCEEDED **
```

## One-liner

```bash
xcodebuild archive -project <PROJECT>.xcodeproj -scheme <SCHEME> -archivePath ./build/<NAME>.xcarchive -destination 'generic/platform=iOS' && \
xcodebuild -exportArchive -archivePath ./build/<NAME>.xcarchive -exportOptionsPlist ExportOptions.plist -exportPath ./build/export -allowProvisioningUpdates
```

## Post-upload

- App will appear in App Store Connect within 5-30 minutes
- TestFlight builds require compliance review before distribution
- Notify user with `say "アップロード完了"` when done

---

## Troubleshooting

### "Failed to Use Accounts" エラー

このエラーはXcodeのキーチェーン認証情報が壊れている場合に発生します。

**詳細ログの確認：**
```bash
cat /var/folders/*/T/<PROJECT>_*.xcdistributionlogs/IDEDistribution.standard.log | tail -50
```

「Failed to find an account with App Store Connect access for team」というメッセージが表示される場合、以下の手順で解決します。

**解決手順：**

1. **キーチェーン認証情報を削除：**
```bash
security delete-generic-password -s "Xcode-Token" 2>/dev/null
security delete-generic-password -s "Xcode-AlternateDSID" 2>/dev/null
```

2. **Xcodeを再起動：**
```bash
killall Xcode; sleep 2; open /Applications/Xcode.app
```

3. **Xcodeで再認証：**
   - **Xcode** → **Settings** (⌘,) → **Accounts**
   - Apple IDを選択
   - 「Manage Certificates」または「Sign in...」をクリック
   - パスワードを入力して認証を更新

4. **エクスポートを再実行**

### "ARCHIVE FAILED" ビルドエラー

DerivedDataが壊れている場合に発生することがあります。

**解決手順：**
```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/<PROJECT>-*
```

その後、アーカイブを再実行します。

### dSYM警告

「Upload Symbols Failed」の警告は、サードパーティフレームワーク（Sentryなど）のdSYMが含まれていない場合に表示されます。アップロード自体は成功しており、クラッシュレポートに若干影響がある程度で、通常は無視して問題ありません。
