# テレメトリ方針 2026-08-05(当時の裁定スナップショット)

> 「当時の状態」の記録。次回監査でライブ状態との差分を見る材料であり、現在の真実ではない。

## 裁定: フライホイール設計としての Langfuse + OTel 採用(SaaS 先行)

目的は「Claude Code の分析を安く済ませる」ではなく、**プロダクト運用で使う観測基盤の
筋肉を自分のセッションで先に鍛える**こと。この目的関数の下での構成:

- **Lane A(導入済み)**: Claude Code 組み込み OTel(公式・安定インターフェース)。
  dotfiles の settings.json `env` に `CLAUDE_CODE_ENABLE_TELEMETRY=1` + OTLP
  (http/protobuf → `localhost:4318`)。受け口はローカルの `grafana/otel-lgtm`
  コンテナ(OrbStack、Grafana UI は :3000)。メトリクス(トークン・コスト・セッション)と
  イベントログの時系列。
- **Lane B(次の作業)**: hooks → Langfuse Ingestion API のトレース連携
  (参考実装: https://tubone-project24.xyz/2026/03/13/claude-code-langfuse-hooks-tracing/ )。
  Langfuse Cloud 無料枠を使う(self-host は後回し — 計装・Judge 設計の練習が先、
  ホスティング運用は必要になってから)。**ユーザー側作業: Langfuse Cloud の
  アカウント/プロジェクト作成と API キー発行が必要。**
  既知のリスク: transcript 内部仕様(stop_reason・JSONL 形式)への依存が深く、
  Claude Code の更新で壊れうる。Extended Thinking は仕様変更で取得不可。
  練習コストとして受容する判断。
- **将来**: Langfuse の LLM-as-a-Judge でプロンプト/スキル品質の自動採点。

## 見送り(理由付き)

- **claude-devtools**(ローカル transcript の GUI ビューア): 便利だが受動的な閲覧ツールで、
  フライホイール(データを貯めて agentic に改善を回す)には組み込めない。目的違いで見送り。
- **Langfuse self-host**: Postgres+ClickHouse+Redis+MinIO のスタックで Workers には
  載らない。ホスティング練習の価値はあるが、計装の練習が先。再訪トリガー:
  プロダクト側でデータ主権・コストが問題になったとき。

## 前提となる事実(2026-08-05 時点)

- transcript は `cleanupPeriodDays: 9999` で実質無期限保持 — 一次データの蓄積は既に
  行われており、cclens(マクロ集計)はその上のレンズ。バックアップは未設定(残課題)。
- Claude Code の OTel はメトリクス+ログのみで、Langfuse が受けるトレース(Spans)とは
  形式不一致 — トレースが欲しければ hooks 連携が必要(Lane B の存在理由)。
