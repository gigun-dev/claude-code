# harness 作業ログ

> 時系列の生記録。**追記専用アーカイブ**で、通常は全文ロードしない。
> 現在地と計画は `docs/harness/next-directions.md`。

## 2026-08-05

harness プラグインを新規作成し v0.6.0 まで到達(作業は store-redirect のセッションで実施)。

- **発端**: 複数リポジトリのハーネス整備を検討する中で、caldav / swift-mcp-app が
  独自に育てていた「セッション引き継ぎの正典 + SessionStart 頭注入」が有効に機能している
  一方、cf-asc-dashbord の next-directions は1ヶ月放置で腐っていた。書式ではなく
  「更新ルールの明文化 + 腐敗を機械検知する仕組み」が生死を分けていると判断し、
  テンプレート化に踏み切った。
- **正典の確定**: コメント文化は4リポジトリで4変種に乖離していた。一次資料
  (https://x.com/yuki_arano/status/2067462860771623245 )を references に保存し、
  4項に整理して配布物にした。系譜は cf-asc(07-05)→ tiktok(07-06)→ caldav(07-08、
  rules 化してパススコープを付けた進化形)→ swift-mcp-app(07-15)。
- **v0.1.0**: init skill(散文手順)+ ND/フック/rules のテンプレート。
- **敵対的検証**: 観点を分けた3体で 21 指摘。fail-closed 化・行頭アンカー・鮮度検査・
  頭の行数計測・閾値引き上げ禁止・バージョン刻印を採用(v0.2.0)。
  深刻度「高」の2件(stdout 注入不可説・enabledPlugins 形式)は偽陽性として棄却。
- **v0.2.1**: caldav の棚卸し(頭 380→57 行)で、鮮度検査が全角括弧「現在地（…）」を
  読めず**一度も効いていなかった**ことが判明。全角/半角両対応に。
  同時に、caldav の ND にはマーカーが2本あり 229 行が「頭でもカタログでもない曖昧域」に
  なっていたことも発見。
- **v0.3.0**: pre-push 品質ゲートを追加。caldav で実証済みだったがテンプレート化されて
  いなかった。検証コマンドを `{{CHECK_COMMAND}}` で外出しし、**make を前提にしない**
  (Makefile を持たないリポジトリの方が多い)。
- **v0.5.0**: Agent Skills 仕様の `scripts/` 規約に沿って、機械的作業を install.sh へ全部移した。
  散文手順の解釈は非決定的で、このセッション中にも実際に手順の抜けが起きていた。
- **v0.6.0**: `!` 記法(dynamic context injection)で survey.sh を自動実行し、調査も決定論化。
  **survey.sh は読み取り専用・install.sh は `!` に置かない** — `!` はスキルを読んだだけで
  無条件に走るため、破壊的スクリプトを置くと事故になる。
  同時に抜け漏れ点検(実物比較)で4件(gitignore / log.md / codex README / .agents symlink)を修正。
- **展開**: store-redirect へ初適用(実験台)。caldav のフックを v0.2.1 へ更新。
  この repo へ引き継ぎ(このファイルと next-directions.md)。
