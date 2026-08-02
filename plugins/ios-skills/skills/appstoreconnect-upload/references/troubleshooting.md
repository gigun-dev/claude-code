# App Store Connect archive/uploadの準備と診断

## 実行前の準備

- Apple Developer ProgramとApp Store Connectへの権限を確認する。
- XcodeのAccountsでApple IDとTeamを設定し、対象schemeをsharedにする。
- Bundle Identifier、Marketing Version、Build NumberをApp Store Connectの登録と一致させる。
- `assets/ExportOptions.plist`を既定として使うか、プロジェクト固有plistを`--export-options`で明示する。

## archiveが失敗する

stderrの最初の署名エラーを確認する。scheme、Team、証明書、プロビジョニング、destinationが主な境界。
既存DerivedDataやKeychainを一括削除しない。XcodeのAccounts画面で状態を確認し、必要な再認証だけを行う。

## export/uploadが失敗する

- archive成功とupload成功を分けて判断する。終了コード10はarchive、11はexport/upload。
- App Store Connect上のBundle IDとbuild number重複を確認する。
- account/teamエラーはXcodeのAccountsで対象teamへのアクセスを確認する。
- dSYM警告は依存frameworkごとに扱いが異なるため、upload成否と分離して確認する。

スクリプトは既存archive/export pathを上書きしない。再実行時は新しい出力pathを指定し、
失敗archiveを証拠として残す。
