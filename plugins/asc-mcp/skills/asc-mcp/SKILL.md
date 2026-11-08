---
name: asc-mcp
description: Build a registered iOS app from a GitHub PR or commit using remote MCP, check build progress, and return a private iPhone install link. Use for cloud-to-Mac builds without local Xcode access.
metadata:
  version: "0.2.0"
---

`list_apps`で登録済みprojectを確認し、指定されたPR番号または40桁commit SHAを`build_app`へ渡す。両方を同時に指定しない。未登録repoはサービス設定への追加が必要。

Ad Hoc OTA の目的は、通知リンクから対象 iPhone にインストールして起動すること。App Store 提出・
TestFlight upload へ振り替えない。Linux の依頼元に Xcode を入れず、登録済み Mac runner へ渡す。

返されたjob IDを`get_build`へ渡して結果を確認する。受付をビルド成功と扱わず、GitHubの実行状態と配布URLを報告する。`dispatch_unknown`は受付応答を確認できなかった状態で、自動再送せず既存jobとGitHub実行を確認する。

ビルド成功、IPA の署名検証、通知受付、iPhone のインストール・起動を別々に確認する。
過去の成功を現在の署名資材や runner の稼働証拠にしない。本人操作が必要なインストール承認まで
依頼された処理を進め、その時点で対象ビルドと確認内容を示す。

接続時はMCPホストのOAuthログインを使う。AppleやGitHubの秘密鍵をチャットへ渡さない。ローカルでASCを直接使う作業は作者のASC pluginへ任せる。

サービス実装・環境構築は https://github.com/gigun-dev/asc-mcp 。
