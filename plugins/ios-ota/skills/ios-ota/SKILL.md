---
name: ios-ota
description: Unified iOS OTA build, automatic App ID/Capability/Ad Hoc profile provisioning, ephemeral Keychain signing, private HTTPS install link delivery, and App Store Connect CLI Code Mode (asc_search / asc_execute). Use for both local Mac and remote phone/cloud iOS OTA distribution.
metadata:
  version: "0.3.0"
---

# ios-ota

iOS アプリの発行物（Explicit App ID・Push通知等の Capability・Ad Hoc Provisioning Profile）の自動確保、未署名アーカイブビルド、一時 Keychain での Ad Hoc 署名、Cloudflare R2 (`install.097969.xyz`) への HTTPS 公開、Bark 通知までを **Local（手元の Mac）と Remote（スマホ/クラウドからの MCP）で単一エンジンに統一** したスキル。

## 1. Remote MCP 経由（スマホ・クラウド・別ホストから依頼するとき）

- **ビルドと OTA 配信**:
  1. `list_apps` で登録済みプロジェクトと固定インストール URL (`https://install.097969.xyz/<slug>/`) を確認する。
  2. `build_app` に `project` と、`pr`（オープンな同一リポジトリ PR 番号）または `commit`（40桁 SHA）のどちらか一方を渡してジョブを起動する。
  3. 返された `job_id` を `get_build` に渡して進捗・結果・インストール URL を確認する。
- **App Store Connect CLI Code Mode (`asc_search` / `asc_execute`)**:
  1. `asc_search` にクエリ（例: `"bundle-ids"`, `"push notifications"`, `"ad hoc profile"`, `"reconcile"`）を渡して、対応する `asc` サブコマンド・フラグ・例を JSON で検索する。
  2. `asc_execute` に構造化 `argv`（例: `["bundle-ids", "list", "--output", "json"]`）を渡して検証・実行する。App ID 作成や Capability 追加などの変更系コマンドは `allow_mutations: true` を明示したときだけ許可される（`delete` / `nuke` / `revoke` / `auth` / `@file:` / `@env:` は常時拒否）。

## 2. Local CLI 経由（手元の Mac で直接ビルド・OTA 配信するとき）

各アプリのリポジトリに独自設定ファイル（旧 `ota.conf`）は不要で、標準の `project.yml`（または `.xcodeproj`）から Bundle ID・Scheme・Team ID・Entitlements（Push通知 `aps-environment` や App Groups 等）を自動検出する。

```sh
# 1. Gate 1: 未署名 Release アーカイブ（CODE_SIGNING_ALLOWED=NO）のビルドと digest 検証のみ実行
uv run python3 "<plugin-root>/scripts/ios_ota.py" --repo /path/to/app-repo --unsigned-only

# 2. 自動プロビジョニング + 一時 Keychain 署名 + ASC prepare 検証 + R2 公開 & Bark 通知まで一気通貫実行
sops-env -- uv run python3 "<plugin-root>/scripts/ios_ota.py" --repo /path/to/app-repo
```

- `ASC_SIGNING_PROFILE_BASE64`（または `ASC_SIGNING_PROFILES_JSON`）が渡されていればそれを使用し、未指定かつ App Store Connect API 資格情報（`ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_PRIVATE_KEY*`）がある場合は、`scripts/provision_ad_hoc.py` がアーカイブの Bundle ID と Entitlements を検査して不足している App ID・Capability・Ad Hoc Profile を自動確保する。

## 3. 段階別の受入ゲート

ビルド受付・成功だけで実機インストール完了と扱わず、以下の4段階を区別して報告する：
1. **Build (Unsigned Archive)**: `CODE_SIGNING_ALLOWED=NO` でのアーカイブ生成と `archiveDigest` 記録。
2. **Provision & Sign**: App ID / Capability / Ad Hoc Profile の整合確認、一時 Keychain (`asc signing run`) での署名と即時 wipe、`asc distribute prepare` による署名・Profile 検証。
3. **HTTPS Publish & Notify**: R2 (`install.097969.xyz/<slug>/`) への公開と Bark 通知受付。
4. **Device Install**: 本人の iPhone (Safari) でのインストール承認・起動・対象ビルド一致確認。
