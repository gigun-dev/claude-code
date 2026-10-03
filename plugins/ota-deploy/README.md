# OTA Deploy

Claude CodeとCodexから、iOS IPA・Android APKをTailscale内のHTTPSインストールページで配布する共通skill。App Storeへの提出とは別の、登録済み端末への試用build配布に使う。

```sh
claude plugin install ota-deploy@gigun
codex plugin add ota-deploy@gigun
```

「このアプリをTailscale経由でOTA配布して」と依頼するか、`ota-deploy:ota-deploy` を指定する。対象repoの `ota.conf` と署名・Tailscale設定を確認し、同梱CLIを呼ぶ。設定例は `bin/ota.conf.example`。インストールしただけでは署名やServe設定を変更しない。

上流: [mariosaputra/ota-deploy](https://github.com/mariosaputra/ota-deploy)。`bin/ota-deploy.sh`・`bin/template.html`・`bin/ota.conf.example`・`LICENSE` はcommit `8350eb6e6bb556540ce242b172f4fb9760707aea`から変更せず同梱している。MIT © 2026 Mario Saputra。更新時は同じcommitから4ファイルを揃えて差し替え、下記を実行する。

```sh
python3 plugins/ota-deploy/tests/run.py
bash scripts/verify.sh
```

隔離試験はTailscale/curlをstubにし、prebuilt IPA/APKの配置、manifest、ページ、連続buildのchangelog、serve-onlyを確認する。実際の署名・端末install・tailnet配布は対象アプリで別途確認する。
