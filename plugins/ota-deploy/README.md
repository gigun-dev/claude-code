# ota-deploy — iOS/Android ビルドを Tailscale 経由でスマホへ配る

TestFlight・Play Console を通さず、Mac でビルドした `.ipa`(ad-hoc)/ `.apk` を
Tailscale の HTTPS 上のインストールページから手元のスマホへ入れる 1 skill のプラグイン。

- 出典: <https://github.com/mariosaputra/ota-deploy>(commit `8350eb6e6bb556540ce242b172f4fb9760707aea`)
- ライセンス: MIT(`skills/ota-deploy/scripts/LICENSE`)
- `skills/ota-deploy/scripts/` の `ota-deploy.sh` / `template.html` / `ota.conf.example` / `LICENSE` は
  **逐語の複製**。更新は上流から取り直して丸ごと入れ替える —— **ローカルで編集しない。**
- `SKILL.md` はこのリポジトリで書いたもの。設定の置き場所と実行手順を上流 README から要約している。
