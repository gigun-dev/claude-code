# テレメトリ方針 2026-08-05(当時の裁定スナップショット)

> 「当時の状態」の記録。次回監査でライブ状態との差分を見る材料であり、現在の真実ではない。

## 裁定: フライホイール設計としての Langfuse + OTel 採用(SaaS 先行)

目的は「Claude Code の分析を安く済ませる」ではなく、**プロダクト運用で使う観測基盤の
筋肉を自分のセッションで先に鍛える**こと。この目的関数の下での構成:

- **Lane A(稼働中)**: Claude Code 組み込み OTel(公式・安定インターフェース)で
  メトリクス+ログを **Grafana Cloud**(OTLP ゲートウェイ ap-northeast-0)へ。
  当初ローカル `grafana/otel-lgtm` コンテナで始めたが、実測 RAM 800MiB 常駐 +
  イメージ 3.1GB + OrbStack 起動依存が見合わないため Cloud へ移行(コンテナは削除)。
  設定は zshrc → `~/.config/claude-code/grafana-otlp.env`(600・git 管理外)。
  settings.json は dotfiles で git 管理されるため秘密を置けないのが理由。
- **Lane B(稼働中)**: hooks → **Langfuse の OTLP エンドポイント**でトレース。
  参考実装(https://tubone-project24.xyz/2026/03/13/claude-code-langfuse-hooks-tracing/ )は
  Ingestion API を叩くが、**これは公式に deprecated で Cloud v4 で削除される** —
  公式が「今すぐ OpenTelemetry エンドポイントへ移行せよ」と勧告しているため OTLP で実装。
  結果、Lane A と計装の考え方が統一された。
  実装: `dotfiles/claude/hooks/langfuse-otlp.sh`。ID は hook 入力の prompt_id /
  tool_use_id から md5 で決定論的に導出するため、参考記事が「泥臭い」と呼んだ
  ファイルベース状態管理は開始時刻の記録のみに縮小できた。
  データモデル: Session=CC セッション / Trace=1ターン / 子 span=ツール実行・サブエージェント。
  既知のリスク: hook 入力スキーマへの依存(Claude Code の更新で壊れうる)。
  Extended Thinking は仕様変更で取得不可。練習コストとして受容する判断。
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
