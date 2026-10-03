---
name: ota-deploy
description: Build or publish iOS IPA and Android APK install pages over Cloudflare Access or private Tailscale HTTPS. Use for OTA/ad-hoc distribution, installing a build from a phone browser, or restarting an existing OTA server.
metadata:
  version: "0.2.0"
---

同梱CLIは、このskillのディレクトリから `../../bin/ota-deploy.sh` の絶対パスで呼ぶ。テンプレートと設定例も同じ `bin/` にある。Claude CodeとCodexで共通。

対象repoの既存 `ota.conf` を読む。無ければ `../../bin/ota.conf.example` を基に対象repoへ作成し、プロジェクト・scheme・bundle ID・署名team、またはGradle task/artifactを実ファイルから確認する。`APP_SLUG` はプロジェクト固有の英数字・ハイフンで明示し、`TS_HOST` は配布するMacの実際のTailscale DNS名を使う。既存Serve設定と共有PORTを確認する。設定はshellとして読み込まれるため、信頼できるものを使い、端末固有値・秘密はGitに含めない。

macOS、Python3、対象platformのbuild toolが必要。Tailscale配布にはTailscale、Cloudflare配布にはBunと `cloudflare/` の依存が必要。iOS OTAはHTTPSと端末UDIDを含むad-hoc署名が必要。登録済み端末は `xcrun devicectl list devices` とApple Developerのprofileを照合する。対象を特定できない値は推測せず確認する。

```sh
"<skill-dir>/../../bin/ota-deploy.sh" /absolute/path/ota.conf --ios
"<skill-dir>/../../bin/ota-deploy.sh" /absolute/path/ota.conf --android
"<skill-dir>/../../bin/ota-deploy.sh" /absolute/path/ota.conf --ipa /absolute/path/App.ipa
"<skill-dir>/../../bin/ota-deploy.sh" /absolute/path/ota.conf --apk /absolute/path/app.apk
"<skill-dir>/../../bin/ota-deploy.sh" /absolute/path/ota.conf --serve-only
```

実行は対象repoを作業ディレクトリとする。iOSのworkspace/project、Androidのproject dir、カスタムbuild hookは設定例を参照する。生成物は `~/.ota-deploy/public/<slug>/`、build番号・changelogは `~/.ota-deploy/state/<slug>/`。`OTA_HOME`で変更可能。

終了後は生成artifact・iOS manifestのbundle ID/URL、`tailscale serve status` と配布HTTPSの応答を確認してURLを渡す。上流はServe失敗を終了コードへ反映しないため、表示された「ready」だけで配布成功と扱わない。iPhoneのSafariからのinstall・起動は、build/配布ページ生成とは別の確認として報告する。

Cloudflare配布は `OTA_PUBLIC_ORIGIN` とprivateな `OTA_WRANGLER_CONFIG` を読む。配布ページ・設定・鍵の作成手順は `../../README.md`。既存のWorker／Access／R2へ公開し、固定ページURLを渡す。Accessのリダイレクトだけでインストール成功とせず、署名manifestとIPA取得、実機installを分けて確認する。Bark通知の実機到達とSafari指定も本人確認が必要。
