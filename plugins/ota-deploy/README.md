# OTA Deploy

Claude CodeとCodexから、iOS IPA・Android APKをCloudflare AccessまたはTailscale内のHTTPSインストールページで配布する共通skill。App Storeへの提出とは別の、登録済み端末への試用build配布に使う。

```sh
claude plugin install ota-deploy@gigun
codex plugin add ota-deploy@gigun
```

「このアプリをOTA配布して」と依頼するか、`ota-deploy:ota-deploy` を指定する。対象repoの `ota.conf` と署名・配布設定を確認し、同梱CLIを呼ぶ。設定例は `bin/ota.conf.example`。インストールしただけでは署名やServe設定を変更しない。

上流: [mariosaputra/ota-deploy](https://github.com/mariosaputra/ota-deploy)。`bin/ota-deploy.sh`・`bin/template.html`・`bin/ota.conf.example`・`LICENSE` はcommit `8350eb6e6bb556540ce242b172f4fb9760707aea`を基に同梱し、Cloudflare配布を追加している。MIT © 2026 Mario Saputra。更新時はローカルの配布拡張を維持し、下記を実行する。

```sh
python3 plugins/ota-deploy/tests/run.py
bash scripts/verify.sh
```

隔離試験はTailscale/curlをstubにし、prebuilt IPA/APKの配置、manifest、ページ、連続buildのchangelog、serve-onlyを確認する。実際の署名・端末install・tailnet配布は対象アプリで別途確認する。

## Cloudflare配布

`cloudflare/` はAccess JWTを検証するWorkerと、非公開R2へ公開するクライアント。ルートはアプリ一覧、`/<slug>/` は最新版、Install時に10分有効のmanifest/IPAリンクを発行する。アプリ本体はSHA256単位の固定パスに置き、アップロードが揃ってからlatestを更新する。ログインを外したdownload経路にもWorkerの署名検証が必要。

`cd plugins/ota-deploy/cloudflare && bun install` で配布クライアントの依存を導入する。`wrangler.jsonc` を端末のprivate設定へコピーし、`main` をWorkerの絶対パス、`account_id`・custom-domain route・`vars.PUBLIC_ORIGIN`・`ACCESS_ISSUER`・`ACCESS_AUD` を対象環境に設定する。Accessには配布ホスト全体の許可ポリシーと、`/download/*` だけのBypassアプリを作る。`workers_dev`・preview URLは無効のままにする。R2バケットは公開しない。

Workerの`DOWNLOAD_SECRET`は暗号化保管したランダム鍵を`wrangler secret bulk`で渡す。`wrangler deploy --config <private-config>`で配備する。本人環境のAccessはdotfilesの`tofu/ota.tf`、署名鍵は`secrets/ota-env.age`が管理する。

`ota.conf` に`OTA_PUBLIC_ORIGIN`・`OTA_WRANGLER_CONFIG`・`OTA_R2_BUCKET`を設定すると、ビルド後にR2へアップロードし、Tailscale Serveは使わない。Bark通知には`BARK_ENV_FILE`で既存のage暗号化通知設定を指定する。通知のリンクは固定ページのSafariスキーム、本文は通常HTTPS URL。サーバー受付成功と実機到達は別に確認する。通知失敗もCLIの失敗として返るが、既に配布したビルドは取り消さない。

```sh
cd plugins/ota-deploy/cloudflare
bun run test
```

受け入れは、未ログインの一覧・発行拒否、改ざん・期限切れリンクの拒否、署名済みmanifest/IPAの取得、Tailscaleを切った実機でのBark→Safari→ログイン→install→起動。Accessで共有相手を許可しても、Ad Hoc署名にはその端末の登録が必要。
