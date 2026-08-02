# MCPHost デモ動画 撮影レポート

## 成果物

- **最終動画**: `/Users/gigun/ghq/github.com/gigun-dev/swift-mcp-app/docs/demo-media/mcphost-tomorrow-agenda-demo.mp4`
  (元の生録画: `/Users/gigun/ghq/github.com/gigun-dev/swift-mcp-app/tmp-demo/mcphost-demo-raw.mov`)
- 内容: MCPHost(既に起動・接続済みの状態)のチャットに `What is on my calendar tomorrow?` と入力して送信
  → `caldav` MCP の `list-events-expanded` が green check 付きで呼ばれる
  → カレンダーカード(「カレンダー 8/3〜8/4」「明日 8/3(月) 09:00 週次ミーティング」)が表示
  → LLM のテキスト応答まで完了、を収録。実尺は約36〜38秒(元の102秒録画から idle 区間をトリミング)。
- 作成した Simulator: **`DEMO-MCPHost`**(UDID `2E279310-211B-4978-B59D-1559FB084C14`, iPhone 17 Pro / iOS 26.4)。
  指示通り**削除せず残しています**。

## 質問文について(依頼と異なる点の申告)

依頼文の例は「明日の予定は?」(日本語)でしたが、**実際には英語 `What is on my calendar tomorrow?` を使いました**。
理由: idb の `ui text` は printable ASCII しか送れず、日本語は原理的に打てません(クリップボード経由の
paste も試す時間がなく断念)。「〜のような質問」という依頼文の余地に頼った判断です。機能的な見せ場
(MCP ツール呼び出し→カード表示)は言語に依存しないため、内容としては要求を満たしていると判断しましたが、
**厳密には依頼と異なる**ので明記します。

## かかった実時間と内訳(合計 約53分: 00:15〜01:08 JST)

- **準備(約12分)**: README/Makefile/project.yml、`docs/next-directions.md`、
  `docs/ios-simulator-best-practices.md`、`.claude/skills/ios-e2e-verify/SKILL.md`、
  `ios-skills:ios-simulator` スキルの読み込み。既存 Simulator 一覧確認(保全対象の再確認)。
  Simulator 作成・boot・`make gen`。caldav 本番の tomorrow イベントを MCP 経由で事前確認
  (「週次ミーティング」が実在することを確認できたのは幸運でした)。
- **ビルド・起動(約11分)**: `make run` のシェル変数展開バグにより **保護対象の `iPhone 17`
  シミュレータへ誤ってアプリを install/launch してしまう事故**が発生。その後 UDID を全コマンドに
  ハードコードして正しい `DEMO-MCPHost` へビルド・install・launch。
- **試行錯誤(約22分)**:
  - 座標系の取り違え(スクリーンショット px と `idb ui tap` の point 空間)でタップが数回空振り。
  - caldav 本番への接続が **TLS error -1200** で失敗 → 原因は Proxyman のシステムプロキシが
    `caldav.gigun-dev.workers.dev` を MITM 傍受しており、新規 Simulator に CA 証明書が
    信頼されていなかったため。**Proxyman MCP で状態確認 → 該当 Simulator にだけ**
    `xcrun simctl keychain <udid> add-root-cert` で CA を信頼させて解決(グローバル設定は不変更)。
  - OAuth 同意ページのパスワード欄に test fixture `changeme` を入力し許可、接続成功(tools=25)。
  - 日本語 IME による ASCII 文字化け(`hello`→`て st123` のような破損)。Caps Lock トグル
    (HID usage 57)で英語入力に固定し解決。
- **撮影(約8分)**: 1回目の録画は成功したが、ツール呼び出し間の待ち時間(エージェント側の処理時間)が
  そのまま録画に乗り、**102秒中 実際の操作は42〜78秒の約36秒だけ**という長い無駄録画になった。
  2回目(アプリの再起動シーンも含めて撮り直す試み)は `SimRenderServer.SimulatorError` で録画開始に
  失敗(同時に他プロセスが `CalDAV-Spare-01` 等を操作しており、レンダーサーバのリソース競合と推測)。
  時間切れが近かったため2回目は諦め、1回目の録画を ffmpeg でトリミングして最終成果物とした。

## 詰まった箇所とその原因・解決

1. **`UDID=... make run SIMULATOR_UDID=$UDID` が保護対象 `iPhone 17` を誤操作**(最重要インシデント)。
   - 原因: bash の prefix 変数代入(`VAR=val cmd arg=$VAR`)は同一コマンドライン内の他の展開には
     反映されない(シェル状態がコマンド間で持続しない実行環境だったため `$UDID` が未定義→空、
     `make` が既定の `SIMULATOR="iPhone 17"` にフォールバックし、ちょうど1台だけ一致したため
     エラーにならず素通りした)。
   - 結果: `iPhone 17`(UDID `EF5D841C-...`)に MCPHost を install・launch(PID 12241)。
   - 復旧: `xcrun simctl terminate` で止めようとしたが **権限クラシファイアにブロックされ実行できず**。
     以降 `iPhone 17` への操作は一切試みていません。**アプリがフォアグラウンドで起動した状態のままの
     可能性があります**。ユーザー側で状態確認・対処をお願いします。
   - 教訓として以降は UDID を全コマンドにハードコードし、同種の事故は再発しませんでした。
2. **caldav 本番への接続が TLS エラーで失敗** → 原因は Proxyman のシステムプロキシ(ユーザーの
   他の検証作業用と思われる)。`caldav.gigun-dev.workers.dev` を SSL Proxying 対象にしたまま。
   Proxyman の設定自体は変更せず、新規 Simulator にだけ CA を信頼させて解決(影響範囲を局所化)。
3. **タップ座標の取り違え** → `idb ui describe-all` の AX frame(points)を使わず目視のスクリーン
   ショット座標をそのまま渡して空振り。スケール換算(px÷3)と AX frame 参照で解決。
4. **日本語 IME の文字化け** → `ios-skills:ios-simulator` スキルに書かれていた Caps Lock
   (HID usage 57)トリックで解決。ただし**真の日本語文字入力そのものは未解決**(idb は ASCII のみ)。
5. **`xcrun simctl io recordVideo` の録画時間とコンテナメタデータの乖離** →
   ツール呼び出し間のエージェント処理時間がそのまま録画に乗り、`ffprobe` の `duration` や
   デフォルトの `image2` 連番抽出(`ffmpeg -i x.mov f_%04d.png`)が**コンテナの不正確な平均フレームレート
   メタデータに基づいてフレームを大量に間引く**(450フレーム中 440枚をドロップして 10枚しか
   書き出さない)という罠を踏み、一時「録画の中身が空白」と誤診断しかけた。
   `-fps_mode passthrough` で全フレームを保持し、`ffprobe frame=pts_time` で実際の変化点
   (42.4s〜78.1s)を特定して解決。
6. **2回目の録画が `SimRenderServer.SimulatorError` で開始失敗** → 未解決。他プロセスが
   `CalDAV-Spare-01`(保護対象)を同時に操作していたことを `ps aux` で確認しており、
   レンダーサーバのリソース競合が濃厚な原因と推測するが、確証はありません。

## 参照した資料(実際に開いたもののみ)

- `swift-mcp-app/README.md`、`Makefile`、`project.yml`(Read/Bash で内容確認)
- `swift-mcp-app/docs/next-directions.md`(冒頭の現在地セクション)
- `swift-mcp-app/docs/ios-simulator-best-practices.md`(全文)— 座標系・証拠の作法などは有用。
  「Codex非依存化」に関する大部分は今回のタスクには不要だった。
- `swift-mcp-app/.claude/agents/simulator-operator.md`(全文)— 今回は自分で直接操作したため
  このサブエージェント自体は使わなかったが、操作方針の要約として参照した。
- `swift-mcp-app/.claude/skills/ios-e2e-verify/SKILL.md`(全文)— **最も役に立った**。
  `SIMCTL_CHILD_` 経由の env 渡し、`changeme` test credential の扱い、座標系(918px/402pt→今回は
  1206px/402pt 実測)、日本語 IME の罠と回避策(候補バー確定)の存在を事前に知れたのは有益だった。
  ただし実際の回避には後述の `ios-simulator` スキルの Caps Lock トリックの方を使った。
- `ios-skills:ios-simulator` スキル(Skill ツールでロード)— Caps Lock トリック、
  `describe-all` の JSON 構造(入れ子配列)、スクショ保存先の sandbox 制限など、**今回のハマりどころと
  直接一致する内容が多く非常に役立った**。
- `swift-mcp-app/docs/presentation-plan.md` は `grep` のみ(全文は読んでいない)。
  デモ①②の台本があることは分かったが、時間の都合で参照せず独自に進めた。
- `docs/design/*.md` などその他の設計ドキュメントは**参照していません**。
- Proxyman MCP ツール(`get_ssl_proxying_list` / `get_proxy_status` / `get_certificate_status`)を
  実行して状況把握に使用。設定変更は行わず、証明書ファイルの場所を突き止めるのに `find` を使用。

## やり直した回数

- Simulator 作成: 1回(作り直しなし)。
- アプリの install/launch: **誤操作で `iPhone 17` へ1回**(事故・上記参照)。正しい `DEMO-MCPHost` へは
  ビルドから2回(1回目は cold state 確認、2回目は録画中の再起動)。
- OAuth 同意: 実質1回で完走(その前に TLS エラーで1回失敗しているが、これは認証以前の接続エラー)。
- チャット送信のリハーサル: 1回(録画なしで成功確認)。
- **録画: 2回試行、成功は1回**(2回目は `SimRenderServer` エラーで録画自体が始まらず失敗)。
- 動画トリミング: ffmpeg でのタイムスタンプ破損(非単調 DTS)により2〜3回やり直し、
  最終的に `-fps_mode passthrough` での再エンコード経由で成功。

## 総括

狙っていた絵(チャット送信→MCPツール呼び出し→カレンダーカード表示)は**リハーサルと録画の両方で
再現に成功**しており、動画ファイルとして残っています。一方で、作業プロセスとしては
**保護対象シミュレータへの誤操作という重大なミスを1件起こしており**、これは bash のクセ
(prefix 変数代入が同一行の他の展開に効かない)を軽視したことが直接原因です。以後は
すべてのコマンドで UDID をハードコードする運用に切り替えて再発は防ぎましたが、
`iPhone 17` 上のアプリ状態(フォアグラウンド起動のまま)は未復旧です。ご確認をお願いします。
