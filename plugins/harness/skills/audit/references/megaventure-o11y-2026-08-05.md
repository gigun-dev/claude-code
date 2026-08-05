# 国内メガベンチャーのオブザーバビリティ実施状況(2026-08-05 調査スナップショット)

> 軽量 Web 調査(haiku サブエージェント)。出典 URL のある主張のみ。「公開情報なし」は
> 未採用の意味ではなく、当時の検索で一次資料が見つからなかったという意味。

| 企業 | OTel | バックエンド | LLM観測 | 特記事項 |
|---|---|---|---|---|
| ABEMA | 採用済み | Google Cloud Trace + Datadog | 公開情報なし | 165万スパン/秒、tail-based sampling |
| メルカリ | 不明 | Datadog | 公開情報なし | 決済基盤のダッシュボード刷新事例 |
| ZOZO | 検討中 | Datadog 主力 + CloudWatch/Sentry | 公開情報なし | serverless APM、Istio 統合 |
| LINEヤフー | 採用済み | Honeycomb(試験) + Google Cloud | 公開情報なし | OTel Java Agent、Wide Events |
| リクルート/DeNA/SmartNews/Sansan/freee | — | — | — | 一次資料見つからず |

## 傾向(当時)

1. OTel 採用は段階的(ABEMA・LINEヤフーが先行)。バックエンドは Datadog が実績筆頭。
2. 大規模ではテールベースサンプリングによるコスト制御が必須プラクティス。
3. **LLM オブザーバビリティは黎明期** — 大手の採用公開事例なし。Datadog LLM Observability の
   試験導入(Timmy・IVRy 等)が出始め。Langfuse は東京リージョン対応済み。
4. 共通形: 「計装は OTel で標準化、バックエンドはマネージドのいいとこ取り」。

## 我々の構成への含意

- 計装=OTel / バックエンド=マネージド(Grafana Cloud) / LLM 特化層(Langfuse)併設は
  業界パターンと整合。LLM 観測はまだ誰も正解を持っていない領域なので、自セッションでの
  実践がそのまま先行投資になる。
- 規模が出たら次に効くのはサンプリング戦略(ABEMA の教訓)。個人利用では不要。

出典:
- https://findy-tools.io/articles/abematv/37
- https://engineering.mercari.com/blog/entry/20231220-datadog-dashboard-for-observability/
- https://techblog.zozo.com/entry/fbz-serverless-with-datadog-apm/
- https://techblog.lycorp.co.jp/ja/20251029a
- https://techblog.lycorp.co.jp/ja/20250219b
- https://speakerdeck.com/k6s4i53rx/practical-llm-observability-with-datadog
- https://langfuse.com/japan
- https://findy-tools.io/articles/o11y-202408/22 (21社特集・追加調査用)
