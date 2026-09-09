---
name: pre-push
description: >-
  Set up, inspect, or repair repository Git pre-push checks. Connect the repository's
  CI verification command to its existing hook setup and verify that a failing
  check blocks a push. Use when hook setup or diagnosis is requested.
metadata:
  version: "0.1.0"
---

対象リポジトリで pre-push の導入・点検を行う。点検の依頼なら読み取りと診断まで、導入・修正の依頼ならその範囲の変更を進める。

## 既存の仕組みを確認する

`git status --short`、`git config --show-origin --get core.hooksPath`、`git rev-parse --git-path hooks/pre-push` を確認し、有効なフックの実体と CI・セットアップ手順を読む。設定が無いことと、フックが無いことは別。Husky / Lefthook 等で管理されていれば、その設定へ組み込む。

検証コマンドと対象ブランチはリポジトリの方針に合わせる。既存の指定が無く判断が必要なら、その点だけ確認する。検証コマンドは CI と共通にし、複合処理はリポジトリ側の検証スクリプトへまとめる。

## 導入する

既存 pre-push の別用途の処理を保持する。複数の処理へ分ける場合、push 対象の情報が標準入力に一度だけ届くことを考慮し、先の処理が読み尽くして後の処理が何も検査しない形にしない。

新規のフックには [assets/pre-push](assets/pre-push) を使える。これは main の更新時に `./scripts/verify.sh` を実行する例。対象ブランチと末尾の検証コマンドをそのリポジトリに合わせて編集する。雛形はこのスキルのディレクトリから解決し、コピー先にはプラグインのパスや環境変数を残さない。

フック管理が無ければ `.githooks/pre-push` を作って実行権限を付け、`git config --local core.hooksPath .githooks` で有効化する。既存の `core.hooksPath` を上書きしない。フックと検証スクリプトはリポジトリで管理し、clone 後の有効化を既存のセットアップ手順へ加える。プラグインを入れただけでは各リポジトリの Git 設定は変わらない。

この雛形は現在の作業ツリーで検証を実行する。push するコミットと検査したファイル状態が同一とは限らないため、特定のコミットを検証済みと報告する場合はその一致も確認する。

## 点検する

実行権限・有効な配置・検証コマンドの実在を確認する。対象に合わせたフックを一時リポジトリに置き、検証成功と意図的な失敗の両方で、ローカルの bare リポジトリ（作業ツリーを持たない push 先）への実際の push を試す。終了コードだけでなく、失敗時に push 先の参照が変わらないことも確認する。実リモートにはテスト用の push をしない。

対象ブランチへの更新・対象外ブランチ・ブランチ削除と、既存フックを保持した結果を報告する。雛形を試した結果と、対象リポジトリ固有の検証を実行した結果を区別する。プラグインを使わない通常の Git 操作でも動く状態で渡す。
