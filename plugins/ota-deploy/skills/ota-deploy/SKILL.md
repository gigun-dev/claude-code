---
name: ota-deploy
description: >-
  iOS(.ipa, ad-hoc)/Android(.apk)をビルドし、Tailscale 経由の HTTPS インストールページで
  手元のスマホへ配る。使用タイミング: (1)「OTA で配って」(2)「スマホに入れたい」「TestFlight
  を通さず実機に入れたい」(3)「ビルドを Tailscale で配信して」(4)「インストールページを作って」
  (5) Mac 再起動後に配信を再開したいとき。ケーブル接続の実機ビルドは ios-device-build を使う。
compatibility: >-
  macOS。iOS は Xcode と有効な署名(Team ID・端末 UDID 登録済み)、Android は Android SDK +
  Gradle。python3・Tailscale(Mac とスマホが同じ tailnet、HTTPS/MagicDNS/Serve 有効)が必要。
  scripts/ は上流 mariosaputra/ota-deploy の逐語 vendor(MIT)。
---

# OTA 配信(ota-deploy)

`scripts/ota-deploy.sh` が、ビルド → `~/.ota-deploy/public/<slug>/` へ成果物とインストール
ページを生成 → `python3 -m http.server` + `tailscale serve` で `https://<TS_HOST>/<slug>/`
に公開、までを行う。変更履歴は前回ビルド以降の git コミットから自動で作る。

## 手順

1. 前提を確認する。足りなければ実行せず、何が足りないかをユーザーに伝える。

   ```bash
   tailscale status            # Mac の MagicDNS 名(例 your-mac.tailnet.ts.net)= TS_HOST
   xcodebuild -version         # iOS を配るとき
   ```

   iOS の ad-hoc ビルドは、プロビジョニングプロファイルに UDID が登録された端末でしか
   起動しない。未登録なら developer.apple.com で登録してもらう(このスキルからは登録しない)。

2. 設定ファイルを作る。雛形は `scripts/ota.conf.example`。置き場所は対象プロジェクト直下の
   `ota.conf` か `~/.ota-deploy/<slug>.conf`。**プラグインのディレクトリ内には置かない**
   (更新で消える)。Telegram のトークンを書くことがあるので、プロジェクト直下に置くなら
   `.gitignore` に `ota.conf` を足す。

   最低限の項目: `APP_NAME` / `APP_SLUG`(プロジェクトごとに一意)/ `PLATFORMS` / `TS_HOST` /
   `PORT`(全プロジェクトで同じ値)。iOS は `IOS_PROJECT` か `IOS_WORKSPACE`、`IOS_SCHEME`、
   `IOS_BUNDLE_ID`、`IOS_TEAM_ID`。Android は `ANDROID_PROJECT_DIR`、`ANDROID_GRADLE_TASK`、
   `ANDROID_APK_GLOB`。Flutter などは `IOS_BUILD_CMD` + `IOS_IPA_GLOB` /
   `ANDROID_BUILD_CMD` + `ANDROID_APK_GLOB` でビルドコマンドを差し替える(雛形のコメント参照)。
   値は推測で埋めず、プロジェクトから読めないもの(Team ID など)はユーザーに聞く。

3. 実行する。

   ```bash
   scripts/ota-deploy.sh /path/to/ota.conf                  # PLATFORMS を全部ビルド
   scripts/ota-deploy.sh /path/to/ota.conf --ios            # 今回は iOS だけ
   scripts/ota-deploy.sh /path/to/ota.conf --ipa App.ipa    # ビルド済み成果物を配るだけ
   scripts/ota-deploy.sh /path/to/ota.conf -m "hotfix"      # 変更履歴の文言を上書き
   scripts/ota-deploy.sh /path/to/ota.conf --serve-only     # 配信だけ再開(Mac 再起動後)
   ```

   成功すると `✅ Build N ready (ios android) → https://<TS_HOST>/<slug>/` を出す。この URL を
   ユーザーに渡す(iOS は Safari、Android は Chrome で開く)。

## 失敗したとき

| 症状 | 原因 / 対処 |
|---|---|
| スマホで "refused to connect" | 配信が止まっている → `--serve-only`。スマホ側の Tailscale 接続も確認 |
| ホスト名が引けない | スマホが tailnet 外、または MagicDNS 無効 |
| iOS で入るが起動しない | UDID がプロファイルに無い → 登録して再ビルド |
| iOS で "Unable to install" | `IOS_EXPORT_METHOD` が Xcode と合っていない(`release-testing` / 旧 Xcode は `ad-hoc`) |
| Android で "App not installed" | 既存アプリと署名が違う → アンインストールしてから。AAB ではなく APK が必要 |

`tailscale serve` の失敗はスクリプトが握りつぶす(`|| true`)。URL が開けないときは
`tailscale serve status` と `/tmp/ota-deploy-http.log` を見る。

## 触らないもの

- `scripts/` 配下は上流の逐語コピー。挙動を変えたいときはローカルで編集せず、
  上流から取り直す(プラグインの README に取得元の revision がある)。
- 生成物と状態(ビルド番号・変更履歴)は `~/.ota-deploy/`(`OTA_HOME` で変更可)にある。
  ビルド番号をリセットしたいという依頼でなければ消さない。
