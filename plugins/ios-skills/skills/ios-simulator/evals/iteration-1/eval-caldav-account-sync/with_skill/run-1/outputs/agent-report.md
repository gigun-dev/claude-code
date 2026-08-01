# iOS Simulator E2E 疎通確認 — 作業レポート(未完了で打ち切り)

## 結論

**「自作 CalDAV サーバーに書き込んだ予定が純正カレンダーアプリに同期されて表示される」ところまでは確認できなかった。**
60分の目安に対し43分経過した時点でコーディネーターの指示により打ち切り。
アカウント登録までは成功し、同期がまだ確認できていない状態(検索で「結果なし」)で終了。

## 実時間の内訳(概算、開始 0:16 JST 〜 打ち切り指示 0:59 JST ごろ、実働 約43分)

- **準備(0:16〜0:30、約14分)**: スキル読み込み(ios-simulator, ios-device-verification)、
  既存 Simulator 一覧確認、CalDAV サーバーの calendar-home-set / カレンダー一覧を PROPFIND で確認、
  検証用イベント(UID: `e2e-test-1785597420-caldav-e2e-verify`)を ICS 生成して PUT(201 Created)。
  新規 Simulator `E2E-CalDAV-Verify` を作成・boot・idb connect。
- **アカウント登録の試行錯誤(0:30〜0:39、約9分)**: `.mobileconfig` を
  `scripts/make-mobileconfig.ts`(`CALDAV_HOST=caldav.gigun-dev.workers.dev`)で生成し、
  ローカル `python3 -m http.server` 経由で Simulator の Safari から開いてインストール。
  座標系のミス(displayed screenshot 座標をそのまま idb ui tap に渡してしまう/pixel→point 変換を
  一部忘れる)で無駄なタップが複数回発生したが、`idb ui describe-all` で座標を取り直す運用に
  切り替えてからは安定。プロファイルのインストール自体は完了(「インストール完了」画面、
  Settings > 一般 > VPN とデバイス管理 で `E2E-Verify` アカウント登録を確認)。
- **同期確認で詰まる(0:39〜0:59、約20分)**: カレンダーアプリを開いても該当日(2026/8/2)に
  予定が出ない。検索(「E2E TEST」)でも「結果なし」。原因調査のため Safari で
  `https://caldav.gigun-dev.workers.dev/dav/` を直接開き、**「接続はプライベートではありません」**
  という TLS 警告を発見 → 証明書詳細で発行元が **「Proxyman CA」** であることを確認。
  Mac 上で常時起動している Proxyman がシステムプロキシ(port 9090)経由で
  `caldav.gigun-dev.workers.dev` を SSL Proxying の Include リストに登録済み(検証用にほかの
  Simulator 群で使っていると思われる恒常設定)だったため、Simulator 側が Proxyman の CA を
  信頼しておらず TLS ハンドシェイクが失敗 → iOS の CalDAV アカウントの初回同期も同じ理由で
  失敗していたと推測。この1ドメインだけ `mcp__proxyman__toggle_ssl_proxying_domain` で
  一時的に SSL Proxying を無効化し、Safari で再度開いて通常の Basic 認証ダイアログが出ることを
  確認(TLS 警告は解消)。その後カレンダーアプリへ戻り再同期を試みたが、**Settings アプリの
  ナビゲーション(戻るボタンの座標特定)に手間取り**、同期完了の確認まで到達する前に
  打ち切り指示を受けた。

## どこまで到達したか

- ✅ 検証用イベントをサーバーへ PUT(201 Created)
- ✅ 新規 Simulator(`E2E-CalDAV-Verify`)作成・起動
- ✅ `.mobileconfig` 経由で CalDAV アカウント登録(Settings 上で
  サーバ `caldav.gigun-dev.workers.dev` / ユーザ名 `admin` の設定を確認)
- ✅ TLS 警告(Proxyman CA 起因)の原因特定と、対象ドメインのみの一時回避
- ❌ **カレンダーアプリでの予定の表示確認は未達**(検索で「結果なし」のまま打ち切り)
- ❌ スクリーンショットによる「予定が見えている」証拠は**取得できていない**

## 詰まった箇所とその原因

1. **座標系の混同(自己解決)**: スクリーンショットの displayed ピクセル座標をそのまま
   `idb ui tap` の points 座標として使ってしまうミスを複数回犯した(General 設定のはずが
   Apple Intelligence 設定が開く、スクロールが効かない、など)。
   `idb ui describe-all` の frame をそのまま使う(pixel/point 変換不要)方式に切り替えてから安定した。
   `ios-simulator` スキルに座標系の注意書きがあったにもかかわらず、手計算に頼った箇所で
   ミスを繰り返した。**教訓: 最初から describe-all 一本にすべきだった。**
2. **Proxyman による TLS MITM(部分的に解決)**: `caldav.gigun-dev.workers.dev` が Proxyman の
   SSL Proxying Include リストに既存登録されていたため、新規 Simulator からのアクセスが
   すべて「信頼されない証明書」扱いになり、CalDAV アカウントの同期が失敗していたと推測される。
   `mcp__proxyman__toggle_ssl_proxying_domain` で対象ドメインだけ一時的に無効化 → 有効化に戻す、
   という形で作業終了時に**元の状態へ復元済み**。ただし **この変更がアカウント同期を実際に
   回復させたかどうかは確認できないまま打ち切った**(TLS 警告は消えたが、その後カレンダー
   アプリでの表示確認まで到達していない)。iOS の CalDAV アカウントは初回同期に失敗すると
   自動リトライまで時間がかかる可能性があり、単に時間切れだった可能性もある。
3. **Settings アプリのナビゲーション**: プロファイルインストール後の詳細画面から
   Settings ルートに戻る際、戻るボタンの label が階層ごとに変わる(前ページ名がボタンラベルに
   なる iOS の挙動)ため、決め打ち座標でのタップが何度も外れた。describe-all で都度ラベルを
   確認する必要があった。

## 参照した資料(実際に開いたもの)

- **`ios-skills:ios-simulator` スキル**(Skill 呼び出しで読み込み) — 座標系の規律・
  `idb ui describe-all` の使い方・日本語 IME 回避(Caps Lock トグル)を実際に使用。
  **非常に役立った**。特に Caps Lock トリガー(HID usage 57)は Safari の検索欄・mobileconfig
  URL 入力で有効に機能した。
- **`.claude/skills/ios-device-verification` スキル**(Skill 呼び出しで読み込み) — iOS 26 の
  アカウント追加経路の変更点、Simulator でも検証可能という記載を参照。ただし今回は
  `.mobileconfig` 経由のインストールを選んだため、設定アプリの手動フロー詳細は使わなかった。
- **`scripts/make-mobileconfig.ts`**(Read) — 環境変数で host/user/pass/desc を上書きできる仕様を
  確認し、`CALDAV_HOST=caldav.gigun-dev.workers.dev` で実行。**役に立った**(手入力の
  IME 事故を避けられた)。
- **`Makefile`**(grep のみ、内容は読んでいない) — `mobileconfig` ターゲットの存在確認のみ。
- **Proxyman MCP ツール群**(`get_system_proxy_status` / `get_ssl_proxying_list` /
  `toggle_ssl_proxying_domain`) — ドキュメントではなくツールそのものを都度呼んで状態確認。
  `mcp__proxyman__search_docs` + `WebFetch` で
  `https://docs.proxyman.com/debug-devices/ios-simulator` の内容を1回参照
  (証明書インストール手順の確認用。結局この手順は使わず、SSL Proxying の一時無効化で回避)。
- **CLAUDE.md / docs/modeling 系は開いていない**(今回は「本番サーバーへの疎通確認」で
  ローカル dev/proxy/tunnel 構成を使わなかったため、`docs/modeling/06` 等の実機検証ログは
  参照していない。本来は同ログに追記すべきだが、未完了のため見送った)。

## やり直した回数

- **Simulator の作り直し: 0回**(最初に作成した `E2E-CalDAV-Verify` のみ使用)。
- **mobileconfig の生成: 1回**(host を workers.dev 直結に指定して一発で成功)。
- **プロファイルインストールの試行: 1回**(Safari ダウンロード→設定アプリで許可→
  インストール、まで一連の流れは1回で完了。躓いたのは主に「タップ座標」であって
  フロー自体のやり直しではない)。
- **座標ミスによる誤タップ: 4〜5回程度**(General設定のつもりがSiri設定に飛ぶ、
  スクロールが効かない、など)。いずれも describe-all で座標を取り直して復帰。
  「やり直し」というより「同一画面内でのリトライ」に近い。

## 検証データを消したか

- **サーバー上のテストイベント**: 削除済み。`DELETE /dav/calendars/admin/calendar/e2e-test-1785597420-caldav-e2e-verify.ics`
  → `204 No Content`。念のため `GET` で再確認し `404` を確認済み(存在しないことを確認)。
- **Proxyman の SSL Proxying 設定**: `caldav.gigun-dev.workers.dev` を一時無効化していたが、
  作業終了時に **enabled へ復元済み**(元の状態に戻した)。
- **既存データ**(admin の他の予定・カレンダー)には触れていない。
- **Simulator `E2E-CalDAV-Verify`(UDID: F724295C-6C73-4B39-8AB7-38FFC762E141)**: **削除せず残置**
  (コーディネーター指示により状態確認のため保持)。内部には検証用の CalDAV アカウント
  プロファイル(`E2E-Verify`、サーバ `caldav.gigun-dev.workers.dev`、ユーザ名 `admin`、
  パスワードはプロファイル内に平文で保持)が入ったままなので、**確認が終わったら
  プロファイル削除または Simulator ごと削除することを推奨**。
- ローカルで一時起動した `python3 -m http.server 8973`(mobileconfig 配布用)は停止済み。

## 次にやるなら(引き継ぎメモ)

1. `E2E-CalDAV-Verify` Simulator を再度使い、カレンダーアプリで pull-to-refresh するか、
   一度アカウントを無効化→有効化して強制再同期を試す(iOS の CalDAV アカウントは
   初回同期失敗後の自動リトライ間隔が読めないため)。
2. それでも同期されない場合、Proxyman 側で `caldav.gigun-dev.workers.dev` への
   実際のリクエストが Simulator から届いているか(`mcp__proxyman__list_network_requests`
   相当、または `get_flows`)で裏取りする。
3. 表示確認ができたら、テスト予定は必ずまた削除すること(今回作った分は既に削除済みなので
   新規に作り直すこと)。
