# harness の現在地・次の作業

**正典。作業の区切りごとに必ず更新する。** 完了は打ち消し線+✅、状況変化は
`> **YYYY-MM-DD 更新:**` を積層する(計画は消さない)。溜まって読みづらくなったら棚卸しし、
積層を本文へ溶かし込んでからこの節に「第n版」と記す。

> **頭に置くのは3種類だけ: 次の着手 / 未検証の危険 / 裁定待ちの判断。**
> 「何を配るものか」のような概観は書かない — ETH の A/B(arXiv:2602.11988)で
> 「指示は従われるが概観は成果に効かず、コストだけ +20%」と実測されている。
> 概観が要るなら `.claude/rules/harness.md` に一度書けば足りる。
> 完了を書くときは**何をしたかではなく何を確認したか**を書く(検証コマンドと結果)。
> Anthropic の long-running harness の記事に「後続のエージェントが進捗を見て
> 勝手に完了宣言する」観測がある — ✅ が積み上がるほどこの罠は強くなる。

## 現在地(2026-08-06・第2版)

**未検証の危険:**

- `!` 記法(SKILL.md 読み込み時のシェル実行)が実際に発火するか**未確認**。仕様どおりに
  書いてあるが実地で通していない。**次に `/harness:init` か `/harness:doctor` を使うとき、
  最初に survey/check の出力が本文に埋まっているかを見ること。**
  `allowed-tools` は敢えて付けていない(実験的で、「制限」の意味だとスキルが壊れるため)。
- **検知器が黙って死ぬ**ことを誰も検知していない。鮮度検査は2リポジトリで空振りしていた
  (`## 現在地(2026-08-05・第1版)` のように括弧内が日付だけでないとマッチしない)。
  全角括弧の件(v0.2.1)と同型の再発 = 一度直したのに再発した種類のバグ。

**裁定待ち:**

- **auto memory を切るか併用するか。** 既定 ON で `~/.claude/projects/<project>/memory/` に
  溜まるが、machine-local で git に乗らない。「恒久情報はリポジトリ内へ」という harness の
  方針と正面から競合する。
- 頭注入の効果を `evaluations/` で A/B できる立場にある。**指標は成功率ではなく
  ターン数・トークン数**に置く(ETH は成功率で「効かない」と結論したが探索コストは測っていない)。

**導入状況:**

| リポジトリ | 状態 |
|---|---|
| store-redirect | ✅ 最新相当(初適用の実験台) |
| caldav | session-start.sh のみ v0.2.1。comments.md / pre-push はテンプレ以前の原型 |
| swift-mcp-app | 全部テンプレ以前の原型(刻印なし)。interaction.md が paths 無しで常時ロード |
| claude-code(この repo) | ND のみ。フックは pointer 型(マーケットプレイス向けの独自版) |
| tiktok-fetcher / cf-asc-dashbord | check スクリプトは用意済み・ハーネス未導入 |

## 着手順(次にやること)

1. **不具合3を最優先で直す** — `install.sh` の `core.hooksPath` 無条件上書き。既に
   hooksPath を持つリポジトリ(dotfiles)で**既存フックを黙って無効化する**。他の不具合は
   騒がしいだけだが、これは静かに壊す。既存値があれば警告して触らない。
2. **転換3: 検知器を検証する** — install.sh の最後に検知器自身の動作確認を回す。
   ND の見出しから日付が抽出できるか / `comments.md` の glob が1件以上マッチするか。
   公式の `InstructionsLoaded` フック(`load_reason: path_glob_match`)なら実セッションでの
   発火まで確認できる。**swift-mcp-app の事故はこれで二度と起きなくなる。**
3. **不具合1・2を直す** — 鮮度検査の正規表現(日付直後の閉じ括弧を要求している)、
   survey.sh の世代検出が rules の説明文を拾う。
4. **転換1: フックをプラグイン常駐へ** — プラグインの hooks は有効な全リポジトリで発火する
   ので、`session-start.sh` をコピーする必然性が無い。世代ドリフトが消え、検知器の修正が
   即時反映される。pointer 型と頭注入型もフック内の分岐1つで両対応でき、`--pointer-mode` は
   不要になる。**ただし「プラグインを無効化したリポジトリで引き継ぎが静かに死なないか」
   = fail-closed をどう成立させるかを実装前に詰める。**
5. **転換2: 既存 ND の書式を移行** — 頭から概観を落とし、完了を証拠付きに書き換える。
   全リポジトリに波及するので転換1で配布物が減ってからの方が安い。
6. **未導入リポジトリへの展開と原型の取り込み** — tiktok-fetcher / cf-asc-dashbord へ導入、
   caldav / swift-mcp-app の刻印なしファイルをテンプレート版へ寄せる(逆に原型の方が
   良い箇所はテンプレートへ還流させる)。

<!-- session-head-end: ここから下は詳細カタログ。着手する節をそのとき読む -->

## 方針の外部検証(2026-08-05 調査)

**結論: 乗り換え先は無い。harness の思想は業界の現在地と一致している。**
変えるべきは思想ではなく (1) 配り方 (2) 頭に注入する中身の性質 (3) 検知器そのものの検証。
**価値の本体は規約側にあり、配布物は薄いほど良い。**

- **ETH Zurich [arXiv:2602.11988](https://arxiv.org/abs/2602.11988)** — SWE-bench Lite +
  実物の AGENTS.md を持つリポジトリでの A/B。「コンテキストファイルは成功率を改善せず、
  推論コストを平均 20% 以上増やす」「**指示はよく従われるが、リポジトリ概観は役に立たない**」。
  エージェントが従わないのではなく、従っているのに概観が効かない。
- **[Anthropic: Effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)** —
  「後続のエージェントが進捗を見て、勝手に完了と宣言する」観測。対策は
  「E2E 検証が通ってから初めて passes を立てる」。**harness の「完了は打ち消し線+✅」様式が
  直撃する罠。**
- **memory bank 系は上流ごと死んだ** — Roo-Code は 2026-05-15 archived、メンテナが
  「Memory banks don't work without significant manual maintenance」と明言。
  `roo-code-memory-bank` の作者本人が md 方式を捨てて MCP+RAG へ移行。
- **agent-os は自作機構を捨てた** — v3 で「spec 執筆は Plan mode、タスク分解は todo list に
  任せる」とし、残したのは standards の索引化と選択的注入だけ = `.claude/rules/` と同じ結論。

**SDD との関係**: 似て非なるもの。SDD の spec は「これから何を作るか」を実装**前**に書く
駆動文書で正典は仕様側にあるが、ND は「今どこにいるか」を作業**中**に書く状態文書で
正典はコード側にある。時制と権威の向きが逆。上記の agent-os の撤退と ETH の結果は、
むしろ**重い spec 層を持つことへの警告**として読む。共通点は「タスクの明文化を人間の記憶では
なくファイルに置く」の一点だけ。

**ドキュメントの置き場の序列**(この序列が設計判断を決める):
①コードの近くにコメント → ②全体像の最小限を repo の docs → ③跨ぐ経緯は Issue/PR コメント。
③が限度。**跨ぎの経緯だけは①②で受けられないので外に出す**(report.sh がこれ)。

## 既知の不具合(2026-08-05 時点)

| # | 箇所 | 内容 |
|---|---|---|
| 1 | `assets/session-start.sh` | 鮮度検査の正規表現が日付直後の閉じ括弧を要求。`(2026-08-05・第1版)` にマッチせず2リポジトリで死んでいる |
| 2 | `scripts/survey.sh` | 世代検出が `.claude/rules/harness.md` の説明文を拾い `harness-template v (未導入)` という矛盾出力 |
| 3 | `scripts/install.sh` | `core.hooksPath` を無条件上書き。既存 hooksPath を持つリポジトリで既存フックを黙って無効化 |
| 4 | `assets/comments-rule.md` | `paths:` 付きのため**コンパクションで消える**。最も効いてほしい長時間の実装作業中に失われる。核を CLAUDE.md 側に置く二段構えが要る |

## subagent への到達範囲(運用上の帰結)

- custom subagent(implementer / artisan)には CLAUDE.md 階層と project rules が**届く**
  → `comments.md` は実装役に効いている。
- **SessionStart フックの注入は subagent には入らない。**
- 公式ドキュメント上、**built-in の Explore と Plan は CLAUDE.md すら読まない**。
  → Explore/Plan に調べさせるときは**正典のパスをプロンプトに明記する**必要がある。

## 設計の根拠(敵対的検証で確定したもの)

v0.1.0 に対し観点を分けた3体(実行系を実際に壊す / 公式仕様へ接地 / 設計レッドチーム)で
敵対的検証を実施し、21指摘のうち14を採用。**深刻度「高」の指摘2件は偽陽性**で、公式
ドキュメントの原文引用と本番実績で棄却している(指摘は裁定するもので、従うものではない)。
方法は `plugins/harness/skills/doctor/references/adversarial-verification.md`。

- **fail-closed**: マーカーが無いとき全文注入へフォールバックせず警告して止まる。
- **行頭アンカー**: 散文中で `session-head-end` に言及しただけで頭が切断される誤爆を防ぐ。
- **計測は寛容に、教える書式は厳密に**: 書式が少しズレただけで腐敗検知が静かに死ぬ設計にしない。
- **鮮度検査**: 現在地の日付 vs 最終コミット日(ただし不具合1で空振り中)。
- **閾値の上げ方向調整を禁止**: 警告を消す最小コスト行動が閾値引き上げにならないように。
- **バージョン刻印**: 「そのファイルの内容が最後に変わった版」。ファイルごとに違うのが正常。

未解決の指摘: 運用契約の強制機構は無い(検知器のみ)。チーム共有リポでは
`.claude/settings.json` + フック .sh のコミットが「clone した全員のセッション開始時に
実行されるコード」になる(個人リポ前提と注意書きしてあるだけ)。

## skill 構成(cclens に倣った整理)

**動詞で分ける。実装で分けない。** cclens の doctor(診る)/ optimize(直す)/ query(訊く)は
同じデータへの違う意図なので重複しない。当初 audit(手順書)と doctor(検査)に分けたが
どちらも「診る」で冗長だったため 2026-08-05 に doctor へ統合した。

- **`/harness:init`**(入れる) — survey.sh(読み取り専用・`!` で自動実行)+ install.sh(破壊的)
- **`/harness:doctor`**(診る) — check.sh(検査)+ report.sh(検査が外れたら配布元へ起票)

**SKILL.md は薄く保ち、ロジックはスクリプトへ**(cclens の各 skill は 49〜60 行)。
init の 129 行はまだ厚いので削る候補。

## 抜け漏れ点検(2026-08-05・実物比較)

推測ではなく caldav/swift-mcp-app の実物と比較して4件見つけ、install.sh に取り込んだ:
`.gitignore` の `.claude/settings.local.json`(store-redirect で漏れ寸前だった)、
`docs/log.md`(`--with-log`)、`.codex/README.md`(保守規約)、`.agents/skills/*` symlink。

## この repo 固有の事情

- **マーケットプレイス型なので単一の「現在地」が無い。** フックは全文注入ではなく
  `docs/<component>/next-directions.md` への軽量 pointer(2026-08-02 の判断)。
- pre-push 用の検証コマンドが無い。plugin.json / marketplace.json の JSON 妥当性と
  shell スクリプトの構文チェックは自動化する価値がある(未着手)。
