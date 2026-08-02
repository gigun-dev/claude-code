---
name: ios-simulator
description: >-
  iOS Simulator に**検証用の状態を用意する**のが主戦場 —— OS
  レベルのアカウント投入(CalDAV/メール)、同じ状態の端末を複数台そろえる、資格情報や到達画面を
  env/URL スキームで注入する。**まっさらな端末では OS
  側の落とし穴で必ず失敗する手順があり、知らないと数分〜数十分溶ける。**
  加えて、Simulator まわりでうまくいかないとき(タップが無言で失敗する・テキスト入力が化ける・キーボードが出ない・TLS
  が落ちる・アカウントが追加できない・録画の尺が合わない)の診断と、CLI
  での操作(タップ/入力/スクショ/録画)。「シミュレータで動かして/確認して」「アカウントを入れて」「端末を複数用意して」「スクショ撮って」「デモ動画を撮って」と言われたとき、および
  Simulator が絡んで詰まったときに読む。**Simulator を実際に操作する前に読むこと**
  ——
  環境の事前チェックを飛ばすと以降の観測がすべて無効になる実例が複数ある。実機は対象外(ios-device-build)。
compatibility: >-
  macOS + フル Xcode(Command Line Tools だけでは不可)。tap/swipe/テキスト入力/アクセシビリティ走査には
  idb が必要 —— idb-companion(nix または brew)と fb-idb(`uv tool install fb-
  idb`)の2コンポーネント。screenshot / launch / openurl は xcrun simctl だけで動く。Python
  スクリプトは uv(PEP 723 インライン依存)で実行する。実機は対象外。
---

# iOS Simulator 操作(CLI)

起動済みの iOS Simulator を **ターミナルから**操作・視認する。build は同梱しない(ビルドは
各プロジェクトのツールに任せ、本スキルは「ビルド済み .app を入れて触る」ところから)。

> 由来: Claude Code Desktop の「iOS Simulator ペイン」は Desktop 専用だが、中身は
> **`xcrun simctl` + `idb`** の2つ。本スキルはペイン(ユーザーが眺める view)を捨て、
> 操作プリミティブだけを CLI で再現している。Anthropic のツール定義から翻案した
> コンテキストエンジニアリング(座標系・ワークフロー規律・ジェスチャ・エラー復帰)は各節に残した。
>
> 改訂の経緯(2026-08-01 の3ラウンドで旧版の記述が複数 実測で否定された話)は
> `references/retracted-2026-08-01.md` §0。**本文に引っかかったときだけ**開けばよい。

---

## ★Step 0: アプリを触る前にこれを撃つ

```bash
# 端末を新しく作るなら、まず用意する(preflight は Booted な端末を要求する)
UDID=$(xcrun simctl create "<名前>" <devicetype> <runtime>)
xcrun simctl bootstatus "$UDID" -b

export SIM_UDID="$UDID"                     # 以降すべてこれを使う
scripts/sim-preflight.sh --udid "$SIM_UDID" # 競合・キーボード・プロキシ・idb・scale を一括確認
```

**warnings が出たら、各項目の `fix` を実行してから先へ進む。** ここを飛ばして観測を始めると、
**以降の観測がすべて無効になる**(実測で2回、丸ごと誤診に化けた)。

> ⚠️ **順序の注意(2026-08-02 に記述を訂正)**: 旧版は「**何より先に**撃つ」と書いていたが、
> `sim-preflight.sh` は **Booted な端末を要求する**(Shutdown だと「Booted な端末として
> 見つからない」で止まる)。新規端末を作るワークフローでは**物理的に create/boot が先**になる。
> **境界は「端末を用意する」と「アプリを触る(install / launch / io / idb ui)」の間**であって、
> 「何もしないうち」ではない。既に Booted な端末を使うなら、本当に最初に撃てる。

| 見るもの | 飛ばすと何が起きるか |
|---|---|
| **どの端末が Booted か** | 複数 Booted は現実に起きる(実地で4台の日があった)。`booted` 指定で**他エージェントの端末を触る事故**が実際に起きている |
| **`xcodebuild` の競合** | 同じ端末に XCUITest が向いていると**アプリが強制終了**され、走査が壊れる(→ `references/diagnosis.md` §4) |
| **`ConnectHardwareKeyboard`** | `1` だと**ソフトキーボードが一切出ない**。入力欄を叩いてもキーが出ないので「タップが効かない」→「座標系が違う」と誤診が連鎖し、**「px が正解だ」という完全に誤った結論**まで行った(実測) |
| **システムプロキシ** | Simulator は **macOS のシステムプロキシを継承する**が新品端末はその CA を信頼しない。**HTTPS だけが静かに落ちる**ので「サーバーが落ちている」ように見える。対処は `scripts/sim-trust-ca.sh --udid $SIM_UDID`(落として逃げるより入れた方が復号キャプチャも取れる) |

> ⚠️ **観測手段そのものが被験体を壊す。** 「まずプロキシを立てて中身を見る」は極めて自然な第一手なので、
> ネットワーク検証では**ほぼ必ずこの構図に入る**。→ 症状が出た/CA を入れても直らないとき
> `references/system-proxy.md`。

キーボードの判定のコツ: 入力欄タップ後のスクショで **画面下半分にキーの並びが写っているか**を見る。
**日本語 IME の変換候補バーだけが出ていてキーが無い場合も「ソフトキーボードは出ていない」。**

---

## ★典型フロー

```bash
# 0) 事前チェック(上記)。未 boot なら boot + 起動完了待ちが1コマンドで済む
xcrun simctl bootstatus "$SIM_UDID" -b         # 固定 sleep を挟まなくてよい
idb connect "$SIM_UDID" && idb list-targets    # ★ UDID を明示。引数なしでは繋がらない

# 1) ビルド済み .app を投入し、★状態を env で注入して起動(タップを削る第一手)
xcrun simctl install "$SIM_UDID" "path/to/MyApp.app"
SIMCTL_CHILD_MYAPP_API_KEY="$SOME_KEY" \
SIMCTL_CHILD_MYAPP_SPIKE=todos \
  xcrun simctl launch --terminate-running-process "$SIM_UDID" com.example.MyApp

# 2) 目的の画面が出るまで待つ(単発 describe-all ではなくポーリング)
scripts/sim-wait.py "メッセージを入力" --udid "$SIM_UDID" --timeout 15

# 3) 見た目を確認(pixel/point/scale を注記付きで取得)
scripts/sim-shot.sh --udid "$SIM_UDID" ~/tmp-sim/step1.png

# 4) タップは「識別子で・検証つき」で撃つ
scripts/sim-nav.py --id ADD_ACCOUNT --udid "$SIM_UDID"          # ★識別子が分かるなら常にこれ
scripts/sim-act.py "続ける" --until "ようこそ" --udid "$SIM_UDID"  # ラベルしか無いとき

# 5) テキスト入力は IME を経由しない経路が第一選択
printf '%s' 'hello@example.com' | xcrun simctl pbcopy "$SIM_UDID"   # → 入力欄を長押ししてペースト

# 6) ディープリンク(アプリ側に実装があれば、フォーム入力を丸ごと飛ばせる)
xcrun simctl openurl "$SIM_UDID" "myapp://deeplink/path"
```

---

## ★症状 → 対処(うまくいかないときは、まずこの表)

**「失敗した」で止めず、必ず次の一手を撃つ。**

| 症状 | 対処 |
|---|---|
| **タップしたのに何も起きない**(`idb` は成功を返す) | **返り値は証拠にならない。** → 下の「無言の失敗」節。`sim-nav.py`/`sim-act.py` は検証つき |
| Booted 端末が無い | `xcrun simctl bootstatus "<UDID>" -b`(boot + 完了待ちが1コマンド) |
| `idb` が `No targets` | `idb connect <UDID>` → `idb list-targets` で socket を確認(→ `references/setup.md`) |
| **`describe-all` が要素1個・frame 全部 0** | **アプリが前面にいない。** `xcrun simctl launch --terminate-running-process <UDID> <bundle-id>` + 数秒待ち(→ `references/diagnosis.md` §1) |
| **画面に見えている要素が `describe-all` に出てこない** | **AX 走査の穴**(購読確定の赤い ✓ など)。スクショから `pt = px ÷ scale` で撃つ(→ `diagnosis.md` §3) |
| **小さい要素(トグル等)を撃つと成功扱いなのに何も起きない** | スクショ座標の2回変換で誤差が乗っている。**小さい要素は必ず `describe-all` 経由**(→ `diagnosis.md` §2) |
| screenshot が `volume is read only` / `NSCocoaErrorDomain code=642` | 出力先が `/tmp` 配下。`~/tmp-sim/` へ |
| **`NSURLErrorDomain Code=-1200 "A TLS error caused the secure connection to fail."`** / 端末上で「**サーバの識別情報を検証できません**」「**接続はプライベートではありません**」 | **システムプロキシが MITM していて、端末がその CA を信頼していない。** `scripts/sim-trust-ca.sh --udid <UDID>`。⚠️ **CA はローテーションするので、以前入れた端末も突然こうなる** |
| **HTTPS だけが落ちる**(「サーバーが落ちている」ように見える) | 同上。**ビルドが緑でアプリが起動することは、ネットワーク信頼について何も証明しない** |
| **作業が異様に遅い**(タップ数回で数分) | **idb ではなく往復がコスト。** → 「ワークフロー規律」の「往復を減らす」 |
| **入力した文字が化ける**(`hello` → 「へっぉ」) | **IME を通っている。** `xcrun simctl pbcopy` へ逃げる(→「テキスト入力」節) |
| **キーが1つも画面に出ない** | `ConnectHardwareKeyboard` が有効。Step 0 の `fix` |
| `pbcopy` が `NSPOSIXErrorDomain code=60` | ブート直後。**数秒待って再試行すれば通る**。「使えない端末だ」と結論しない |
| **CalDAV 追加でトグル一覧が空 / 保存すると「停止中」** | ⛔ **サーバーを疑う前に端末を疑う。** ユーザー追加アカウントがゼロの端末は初回追加が必ず失敗する(→ 下の 🔴 節) |
| **`webcal://` を撃ったのにホーム画面のまま** | カレンダー App の起動待ち。**10 秒待つ**(実測。4 秒ではまだホーム)。「効かなかった」と即断しない |
| **`SimError code=405 "Unable to lookup in current state: Shutdown"`** | **`simctl keychain` 系は Booted 必須。** 先に `bootstatus <UDID> -b` |
| **`SimError code=405`(clone 実行時)** | 🔁 **逆。`simctl clone` は元デバイスが Shutdown 必須。** 同じ 405 が正反対の理由で出るので、**どちらのコマンドで出たかを必ず見る**(2026-08-02 実測) |
| 端末が別プロセスに掴まれている | **kill しない。** `ps` で終了を待つ(実地では数十秒〜1分で自然終了。→ `diagnosis.md` §4) |
| どれも当たらない | **`shutdown` → `boot` は最終手段。** 上を全部やってから(旧版はこれを第一手に書いていたが、ほとんどのケースで過剰だった) |

---

## ★棲み分け: idb を安定させるより、idb を使わない経路へ逃がす

**2026-08-01 の最大の学び。** ハマりどころの大半は「idb で頑張ろうとしたから」発生している。
やりたいことに応じて、**まず土俵を選ぶ**:

| やりたいこと | 使う手段 | なぜ |
|---|---|---|
| **状態を作る**(資格情報・接続先・アカウント・到達画面) | **タップしない。** `SIMCTL_CHILD_*` / URL スキーム / `simctl clone` → `references/state-provisioning.md` | 実測: API キー入力もログインも飛ばして **0 タップ・2 秒**でチャット可能状態に到達。座標も IME も HID も関与しない |
| **WKWebView の中身の検証** | **Simulator を使わない。** カード HTML をブラウザで開く → `references/webview-offload.md` | iOS の WebView 内要素は idb でも XCUITest 系でも扱いが弱い。**土俵の外に出すのが正解** |
| **反復する検証・回帰・入力を伴う操作** | **XCUITest へ昇格する** | 実測: idb + スクショで **30 分**かけて確証が得られなかった検証が、**XCUITest では3本 green で 30 秒** |
| **一度きりの探索・見た目の確認** | **idb + スクショ(本スキルの本来の守備範囲)** | 探索は idb が速い。ただし下の「無言の失敗」を必ず踏まえる |

idb の否定ではない。**idb で探索して当たりをつけ、固まったら XCUITest へ昇格**が実地では最速だった。

> ⚠️ **昇格の判断軸は「反復が実際に発生しているか」**であって「自動化できるか」ではない。
> 実例: 設定アプリの自動化は技術的には可能(Simulator なら署名不要)だが、**OS アカウントの投入では
> 採らなかった** —— clone が 0タップ 16.7 秒になった以上、自動化して得するのは「種を1台作る」1回だけで、
> 代わりに**デバイス所有権の衝突リスクを常設する**ことになる(→ `state-provisioning.md` §4-b)。

---

## ★診断の規律(いちばん高くついた学び)

同じ日に、独立した2つのセッションが同じ穴に落ちた。片方は壊れた検証環境(ソフトキーボード無効)の上で
**証明も反証もできない 30 分**を使い、もう片方は筋の通った仮説を**事実として SKILL.md に書いて**
後日の対照実験で否定された。**どちらも「筋が通っていること」を「正しいこと」と取り違えている。**

1. **環境要因を排除する前に立てた仮説は、どれだけ筋が通って見えても採用しない**(→ Step 0)。
2. **実測と推論を必ず書き分ける。** 推論を事実として書くと、次に読む人が検証せずに信じて同じ穴に落ちる。
3. **ground truth は、疑っている道具の外側で取る。** 例: `idb ui tap` が効いたかを **idb の返り値で
   判定しない**。`xcrun simctl io <UDID> screenshot` の前後を `cmp` でバイト比較する。
4. **複数端末を並行して動かすときは、ログを端末ごとに分けて採る。** 混ぜると**存在しない差分**が見え、
   そこから誤った因果が組み上がる(実例: 決定的に見えた 15件 vs 6件 の差は、**15件のうち9件が
   別端末のログ**だった。並べ直すと両者同一 → `references/retracted-2026-08-01.md` §9)。
   → **必ず `xcrun simctl spawn <UDID> log ...` で採取先を UDID に固定する。**
   `log stream --predicate` をホスト側で流すと全 Booted 端末が混ざる。

---

## ★最重要ハマりどころ: `idb ui tap` は無言で失敗する

**誤診はほぼ全部これが根っこ。** `idb ui tap` は**当たっても外れても無言で `exit 0` を返す(実測)。**
返り値からは何ひとつ分からない。**「コマンドが成功した = タップが効いた」は成り立たない。**

1. **同梱スクリプトを使う。** `sim-nav.py`(識別子で撃ち、撃った後に画面が変わったか検証する)が第一選択。
   ラベルしか無いなら `sim-act.py`(tap → assert → リトライ)。**素の `idb ui tap` は最後の手段。**
2. **スクショの見た目だけで判定しない。** 実地では、タップは効いてフォーカスも入っていたのに
   **キーボードがまだ出ていない瞬間**を撮って「効かなかった」と誤判定した(FEEDBACK §1)。
   しかもそのときは Step 0 を怠っていて、そもそもキーボードが出ない設定だった。
   **道具の沈黙 × 環境設定の見落としの合わせ技**で誤診は起きる。
3. **ground truth が要るときは、idb の外側で取る。**
   ```bash
   xcrun simctl io "$SIM_UDID" screenshot ~/tmp-sim/before.png
   idb ui tap --udid "$SIM_UDID" 201 337     # rc=0 で返る。これは何の証拠にもならない
   sleep 2
   xcrun simctl io "$SIM_UDID" screenshot ~/tmp-sim/after.png
   cmp ~/tmp-sim/before.png ~/tmp-sim/after.png && echo "★画面は変化していない = タップは無視された"
   ```

⚠️ `sim-act.py` の2つの落とし穴(どちらも実地で踏んだ):

- **非冪等な操作(トグル類)に使うと逆の状態になる。** 1回目が実は効いていたのに assert が間に合わず
  2回目が飛ぶと閉じてしまう。安全なのは冪等/準冪等な操作(送信・画面遷移・ダイアログを閉じる)だけ。
- **assert 条件が原理的に真になりうるか**を確認する。実地では「送信済みテキストが履歴に残り続ける UI」に
  `--until-gone "<送信した文字列>"` を掛け、**送信は成功しているのに「3回失敗」と報告された**。

> **一手で直らなかったら** `references/diagnosis.md`(frame 0 の意味 / 座標系 / AX 走査の穴 / 所有権)。

---

## 🔴 まっさらな Simulator では CalDAV アカウントの初回追加が**必ず**失敗する

**症状(実測)**: **ユーザー追加アカウントが1つも無い** Simulator で CalDAV アカウントを追加すると、
**サーバー検証は成功するのに「カレンダー/リマインダー」のトグル一覧が空**になる。保存すると
**データクラス0個 = 「停止中」のアカウント**ができる。

**⛔ ここでサーバー側のデバッグに入ってはいけない。** 他社サーバー(Vikunja のデモ)でも再現する
**iOS 側の挙動**であって、自作サーバーの RFC 準拠とは無関係。
まず**「この端末にユーザー追加アカウントが1つでもあるか」**を疑う。

**✅ 回避策**: **CalDAV を追加する前に `webcal://` で照会カレンダーを1つ入れて端末を「温める」。**
**4タップ・テキスト入力ゼロ**で、CalDAV は1回目からトグル一覧が出る。温めるアカウントの**型は問わない**
(照会カレンダーで足りる。接続先ホストにも依存しない)。

```bash
xcrun simctl openurl "$SIM_UDID" 'webcal://<公開 ics の URL>'   # 照会 URL が埋まった状態でシートが出る
sleep 10   # ★ 直後4秒はまだホーム画面。カレンダー App の起動待ち(✅実測)
#  → 「許可しない」×2(通知/位置情報)→「検索」→ **赤い ✓**
#  🔴 赤い ✓ は describe-all に出てこない(✅実測)。スクショで座標を取るしかない
```

⚠️ 最初から入っている「**日本の祝日**」は数に入らない(`HolidayCalDaemonAccount` という
システム管理のデーモンアカウント。**これでは温まらない**ことを実測)。温めた後は同名の行が2つ並び
**UI では区別できない**ので、**温まったかの判定は `Accounts3.sqlite` の `ZACCOUNTTYPE` を JOIN して見る。**

→ **端末が何台も要るなら、手作業は種1台で1回だけ払い、あとは `simctl clone` で運ぶ**
(✅実測 **16.7 秒・0タップ**。Keychain ごと運ばれ、clone 先で同期が動くことまで確認済み)。

💡 **設定アプリの経路は `AXUniqueId` で辿れる。識別子は言語設定に依存しない**(端末を英語にして
ラベルが全部変わっても識別子集合の diff はゼロ、を実測)。`sim-nav.py --id <ID>` にそのまま渡せる:

```
com.apple.settings.apps → com.apple.mobilecal → ACCOUNTS → ADD_ACCOUNT
  → (ここから先は AXUniqueId が無い)ラベル「その他のアカウントを追加…」→「CalDAVアカウント」
```

> **これ以上の詳細が要るのは次の3つだけ** → `references/state-provisioning.md` §4:
> ①種を1台作る手順を最初から踏む ②`Accounts3.sqlite` の実際のクエリが要る
> ③「サーバーは無関係」の根拠(6条件の対照実験)を自分で確かめたい。

---

## ★テキスト入力: 「キーボードが出ない」と「入力が化ける」は**別問題**

混ぜると誤診する。**キーが1つも出ない**なら原因はホスト側の `ConnectHardwareKeyboard`(Step 0)。
**キーは出るが化ける**なら原因は IME。

> 🔴 **そもそも `idb ui text` は非 ASCII を送れない**(2026-08-02 実測)。化けるのではなく
> **HID キーコード変換の時点で例外**になる: `Exception: No keycode found for 打`。
> **しかも例外が出ても終了コードは 0**(ハマりどころ「無言で失敗する」は `text` にも当てはまる)。
> → **日本語・絵文字・記号を入れるなら選択肢は `pbcopy` + ペースト一択。** IME の設定をいじっても直らない。

確実に ASCII を入れる手段は3つ:

1. **`xcrun simctl pbcopy <UDID>` + 長押しペースト(第一選択)** — IME を経由しない。UDID 指定なので
   複数 Booted でも誤爆しない。弱点はペーストのメニュータップが座標依存なところだけ。
   ```bash
   printf '%s' 'caldav.example.com' | xcrun simctl pbcopy "$SIM_UDID"
   ```
2. **Caps Lock(HID usage `57`)を1回送る** — 効けばタップ数で pbcopy に勝つが、
   **効くこともあれば効かないこともある(実測)。** 送ったら**必ず短い ASCII プローブ(`"abc"`)で
   化けていないか確認**してから本文を打つ。効かなければ即 1. へ逃げる。
3. **XCUITest の `typeText`** — 反復するなら結局これが一番確実(→ 棲み分けの表)。

> **打った後は必ず目視 / `describe-all` で確認する。化けていても `idb ui text` は成功を返す。**

→ **化けが直らない / `pbcopy` が失敗する / キーボードの出現判定を実装したい**とき
`references/text-input.md`(ローマ字化けの実例・Caps Lock の実測表・pbcopy の経路比較)。

---

## その他のハマりどころ

- **スクショの出力先は `$HOME` 配下にする**(`/tmp` は書けない)。`NSCocoaErrorDomain code=642
  "the volume ... is read only"` が出たらこれ。**エージェント実行環境の sandbox** が弾いており
  **simctl の権限問題ではない**ので `sudo` でも Simulator 再起動でも直らない。セッションの
  scratchpad が `/tmp` 配下にある場合も同じ。→ `sim-shot.sh` は既定を `~/tmp-sim/` にしている。
- **`idb ui describe-all` は JSONL ではなく入れ子の JSON 配列のことがある。** 1行1要素だと思って
  `for line in sys.stdin: json.loads(line)` すると `'list' object has no attribute 'get'` で落ちる。
  **全体を1つの JSON として読み、再帰で歩く**(同梱スクリプトはそうしてある。自前で書かない)。

---

## 状態プロビジョニング(タップせずに状態を作る)→ `references/state-provisioning.md`

**idb を触る前に、まずここで「タップを削れないか」を考える。** 要点:

- **起動時 env 注入 `SIMCTL_CHILD_<VAR>`(第一選択)** — アプリに渡る。**0 タップ・2 秒**で
  ログイン済み状態に到達できた(実測)。⚠️ **アプリ側が読んでいなければ黙って無効**なので、
  注入したら必ず「効いた証拠」を画面かログで取る。
- ⛔ **env は OS 側の状態(アカウント・Keychain・設定アプリ)には届かない。** アプリ内に閉じた状態だけ。
- **`simctl clone`** — 一度手で作った端末を**バイト単位で量産**(Keychain・アカウント込み・**16.7 秒・0タップ**)。
  ⚠️ **元デバイスは Shutdown 必須**(Booted だと `code=405`)。⚠️ **資格情報ごと運ぶので CI 向きではない。**
- ⛔ **`.mobileconfig` は Simulator では効かない。** インストールは「完了」まで行くのに
  **`Accounts3.sqlite` に行が増えない**。CalDAV 固有ではなく**アカウント系ペイロード全般**
  (認証不要の照会カレンダー単体でも作られないことを確認済み)。**実機では有効。**
  💡 適用判定は UI ではなく `ProfileTruth.plist` / `MCProfileEvents.plist` を見る。
- 🔴 **CalDAV アカウント入りの端末を作る**: 上の 🔴 節。**① 一度だけ `webcal://` で温めてから
  CalDAV を追加し種にする ② 以後は `simctl clone` で量産。**

## 録画 → `references/recording.md`

- **`simctl io recordVideo` の尺は実時間と一致しない。これは作法では直らない。**
  イベント駆動の可変フレームレートで、**静止画面 15 秒の録画が `nb_frames=1`** になった(実測)。
- **正しい停止作法**: stderr の `Recording started` を待って開始 → **実 PID** に SIGINT →
  **プロセスの exit をポーリングで待つ**。`pkill -f` + `sleep` は信用しない。
- **`ffmpeg` への全面移行は推奨しない。** 尺は正確だが CPU 32〜34% と重く、
  **録画中の `idb ui tap` が 20 回中 10 回無視された**(simctl 録画中は 20/20 成功)。
- **ツールに関係なく効く実務ルール: 撮るときは触らない、触るときは撮らない。**
- ⚠️ 一般的な罠: **start/stop を別プロセス呼び出しに分ける録画スクリプトでは `wait $pid` が効かない**
  (自分の子でないので即失敗して何も待たない)。`kill -0` のポーリングで exit を待つ。
  踏むと `moov atom not found` の壊れた mp4 ができる。

---

## スクリプト

すべて **`--udid <UDID>`(または環境変数 `SIM_UDID`)必須**。`booted` 暗黙解決は 2026-08-01 に
**意図的に廃止した** —— 複数 Booted 環境で他エージェントの端末を誤爆する事故が実際に起きたため。
**データは stdout に JSON、経過・警告・診断は stderr。** 各 `--help` に終了コード表がある。

- **`sim-preflight.sh`** — 上の Step 0。各警告に**そのまま実行できる `fix` コマンド**が付く。
- **`sim-nav.py`** — **`AXUniqueId`(言語非依存の識別子)でタップする。** 木に無ければ自動スクロールして
  探し、**撃つ直前に座標を読み直し、撃った後に画面が変わったか検証**して変わらなければ非ゼロ終了。
  `--list` で現在画面の識別子一覧、`--until-id` で厳密検証。**識別子が分かるなら常にこれ。**
- **`sim-tap.py`** — ラベル部分一致で1回タップする低レベルプリミティブ(**検証はしない**)。
  ラベルは言語設定で変わるので `sim-nav.py` の方が堅い。`--duration 0.05` で「確実に短いタップ」を明示できる。
- **`sim-wait.py`** — ラベルが現れる(`--gone` なら消える)まで待つ。
- **`sim-act.py`** — tap → assert(`--until` / `--until-gone`)→ 外れたら再タップ。⚠️ 上の落とし穴2点。
- **`sim-shot.sh`** — スクショ + **pixel 実寸 / point 実寸 / scale** を JSON で返す(座標空間を毎回明示)。
- **`sim-trust-ca.sh`** — MITM プロキシのルート CA を**その端末にだけ**入れる。冪等・`--dry-run` あり。
  **グローバル設定は一切変更しない**(`simctl keychain reset` は破壊的なので呼べない設計)。
- **`sim-rec.sh`** — ffmpeg による Simulator ウィンドウ録画。**既定の録画手段ではない**
  (既定は `xcrun simctl io <UDID> recordVideo`)。実時間と一致する尺が要る & **録画中に触らない**ときだけ。

Python の4本は **uv の PEP 723 インラインスクリプト**(事前 pip 不要・stdlib のみ)。
`uv run scripts/sim-act.py ...` でも `./scripts/sim-act.py ...` でも動く。

## アクション対応表(Desktop control → CLI)

| Desktop action | CLI 等価 |
|---|---|
| `launch` | `xcrun simctl install $SIM_UDID <App>.app` → `xcrun simctl launch --terminate-running-process $SIM_UDID <bundle-id>` |
| (状態つき launch) | `SIMCTL_CHILD_<VAR>=… xcrun simctl launch $SIM_UDID <bundle-id>` |
| `screenshot` | `scripts/sim-shot.sh --udid $SIM_UDID [出力パス]` |
| `tap` | `scripts/sim-nav.py --id <AXUniqueId> --udid $SIM_UDID`(**推奨**)/ 素で撃つなら `idb ui tap --udid $SIM_UDID <x> <y>`(**points**) |
| `swipe` | `idb ui swipe --udid $SIM_UDID <x1> <y1> <x2> <y2> [--duration 0.3]` |
| `text` | `printf '%s' "<string>" \| xcrun simctl pbcopy $SIM_UDID` → 長押しペースト(**推奨**)/ `idb ui text --udid $SIM_UDID "<string>"`(⚠️ IME を通る) |
| `button` | `idb ui button --udid $SIM_UDID <HOME\|LOCK\|SIRI\|SIDE_BUTTON\|APPLE_PAY>` |
| `open_url` | `xcrun simctl openurl $SIM_UDID <url>`(`file://` や `App-prefs:root=General` も通る) |
| (Desktop に無い強化) | `idb ui describe-all --udid $SIM_UDID --json`(アクセシビリティ走査。座標ズレ根絶の要) |
| `attach`/`detach` | 該当なし(live ペインは Desktop 専用。CLI は screenshot で確認) |

## ワークフロー規律とジェスチャ(Anthropic の Desktop ツール定義から翻案)

### 🔴 往復を減らす —— 遅いのは idb ではない(2026-08-02 実測)

| 操作 | 実測(アイドル時) |
|---|---|
| `idb ui tap` | **0.08 秒** |
| `idb ui describe-all` | 0.14〜0.28 秒 |
| `xcrun simctl io screenshot` | 0.24 秒 |
| `scripts/sim-shot.sh`(scale 込み) | 0.48 秒 |
| **タップ5連発を1コマンドで** | **0.46 秒** |

**1タップごとにシェルを1往復すると、数タップで数分が溶ける。** コストは idb ではなく
**ツール呼び出しの往復**。画面遷移のひとまとまりは**1コマンドにまとめて撃ち、最後に1枚撮って確認する**。

```bash
U="$SIM_UDID"
idb ui tap --udid "$U" 201 337 && sleep 0.4 && \
idb ui tap --udid "$U" 201 420 && sleep 0.4 && \
xcrun simctl io "$U" screenshot ~/tmp-sim/after.png
```

> ⚠️ **座標を変数に入れて回すループは zsh で壊れる。** `for c in "201 337"; do idb ui tap $U $c` は
> bash なら2引数に割れるが、**zsh は引用符なしの変数展開を単語分割しない**ので `"201 337"` が
> 1引数のまま渡り、**タップが実行されない**。stderr を捨てていると無言の失敗に見え、
> 「座標が古くなった」と誤診する(実際に踏んだ)。配列で回すなら `coords=(201 337 201 420)` と
> **数値を平坦に**持ち、2つずつ取り出す。
>
> **Why not「だから XCUITest へ昇格」としないか**: この遅さは idb の性質ではないので、
> 昇格しても往復の問題は残る(1テスト実行あたりのビルド待ちに化けるだけ)。
> **昇格の判断軸は「反復が実際に発生しているか」のまま**(→ 棲み分けの表)。
>
> ⚠️ **「idb ui tap が 110 秒かかる」という報告は実測で否定済み**(1400倍の誤り)。
> 往復コストを idb のコストに誤帰属したもの。**遅いと感じたら、まず上の表の値を自分で取り直す**
> ——「診断の規律」2(実測と推論を書き分ける)と 3(疑っている道具の外側で測る)の実例。

### そのほか

- **見た目の確認は screenshot で行う**(headless・安い)。操作の直後、状態が変わる前に撮る。
  ただし**スクショだけで成否を決めない**。固定 `sleep` より `sim-wait.py` のポーリング。
- **ビルド/ユニットテストだけを頼まれた時は simulator を触らない。**
  実機(「私の iPhone で」)も対象外 → `ios-device-build` に回す。
- **長押しは `--duration <sec>`**(`> 0.5` で long-press 相当)。逆に**短いタップを意図するなら
  `--duration 0.05` を明示**した方が安定する(FEEDBACK §7)。`swipe` は既定 0.3s。
- 🔴 **エッジ 4pt 以内から始まる swipe は OS ジェスチャになる**(原文: *"a 'swipe' whose start point is
  within 4pt of an edge performs the OS edge gesture instead of a plain drag — left=back,
  top=notification shade, bottom=home/app-switcher, right=Control Center"*)。
  **コンテンツをスクロールしたいなら縁から 4pt 以上内側を始点にする。** 戻る/ホームは縁ちょうど。

---

## 参照ファイル(いつ開くか)

| ファイル | 開くタイミング |
|---|---|
| `references/state-provisioning.md` | **idb を触る前に**「タップを削れないか」を決めるとき / CalDAV 端末を種から作るとき(§4)/ 採らなかった経路の検討(§4-b) |
| `references/diagnosis.md` | 「症状 → 対処」で当たりは付いたが**一手で直らなかった**とき |
| `references/text-input.md` | 文字化けが直らない / `pbcopy` が失敗する / キーボード出現判定を実装する |
| `references/system-proxy.md` | 「サーバの識別情報を検証できません」/ HTTPS だけ落ちる / CA を入れても直らない |
| `references/setup.md` | `idb` が入っていない / `No Companion Connected` が直らない |
| `references/recording.md` | 録画の尺が合わない / 停止スクリプトを書く / ffmpeg と比較する |
| `references/webview-offload.md` | WKWebView の中身を検証する(= Simulator を使わない経路)。**配色・コントラストの監査**をするなら「監査のチェックリスト」を必ず見る —— 色の値だけ見て**変数が代入されているかを見落とす**失敗が実測で出ている |
| `references/retracted-2026-08-01.md` | **本文に引っかかったとき**(「昔はこう書いてあった気が」)/ 誤診カタログとして学ぶとき。誤診の型は3つ: 筋の通った推論を検証せずに信じた(§1〜§11)/ 観測データが汚染されていた(§9)/ 本物の発見を別の未解決問題の説明に流用した(§12) |
| `FEEDBACK-2026-08-01-swift-mcp-app.md` | この日の実地記録(生記録)。§0 ソフトキーボード・§1 座標系誤診・§6 XCUITest 比較 |

---

## 📐 このスキルを保守する人へ — **どこが効いているかは測ってある**

2026-08-02 に **eval 6本すべてに A/B(手引き有り/無しの対照)を取り、計 25 run** を回した。
**「役に立ちそう」で足さない。効きが測られている領域とそうでない領域がはっきりしている。**

| 領域 | 手引き無しとの差 | 判定 |
|---|---|---|
| **OS レベルの状態づくり**(アカウント投入・端末の量産・`Accounts3.sqlite` での判定) | **3.6倍速・+3/7** | ✅ **ここが本体** |
| **日本語・非 ASCII の入力** | **成功 vs 失敗**(baseline は 780秒かけて1文字も入れられず) | ✅ **決定的** |
| UI 操作・録画(デモ動画) | 差なし(汚染を除いた実測でも baseline 753s < 852s) | — |
| onboarding の通し確認 | 差なし(**baseline の方が 39% 速い**) | — |
| **端末の量産**(アカウント入りを3台) | **差なし**(baseline 1.37倍・**clone を自力で使った**) | 🔴 **予測が外れた** |
| コードを読んで推論(WebView の配色監査など) | **baseline の方が深い指摘を出した** | ❌ **効いていない** |

**効いているものの中心は「モデルが自力で辿り着けない一次情報」**だった ——
新品端末では CalDAV 初回追加が必ず失敗する / `clone` が 16.7 秒 / `idb ui text` は非 ASCII を
送れない / `simctl keychain` は Booted 必須で `clone` は Shutdown 必須。
**いずれも実測しないと分からず、知らなければ再発見に総時間の 38% を溶かす。**

逆に、**一般的な作法・有能なモデルなら自力で選ぶ判断**は、書いても測ると差が出なかった
(例:「WebView はブラウザで見る」は**手引き無しの run も独立に選んだ**)。

> 🔧 **訂正を2回重ねた末の結論(2026-08-02)**: 「一次情報だけが効く」→「観点も転移する」→
> **最終形は「転移するか」と「差が出るか」を分けること。**
> **観点のカタログは転移する**(チェックリスト5項目すべてが所見を生み、うち2件は
> 「項目が無ければ発想が出なかった」と実行側が申告)。**しかし、モデルが自力で同じ観点に至る
> 領域では、書いても差は出ない**(同じ監査を手引き無しで3回回して、3回とも同等に到達した)。
>
> **→ 書く価値があるのは「転移し、かつモデルが自力では至らない」ものだけ。**
> 条件はもう一つ: **答えではなく観点を書くこと。** 答えを書くと eval が記憶を測るだけになる。
>
> ⚠️ **ただしこの基準は未完成(2/3 的中)。** 事前登録して3回試し、
> 「差が出る」(日本語入力)と「差が出ない」(onboarding)は当てたが、
> **「端末の量産」で外した** —— baseline は既存端末から `clone` を自力で見つけた。
> **知識が差を生むのは「その知識が実際に必要になる状況」に限る。**
> 環境に既に答えがあれば(= アカウント入りの端末が転がっていれば)、知識は差を生まない。
> **「一次情報を持つか」だけでは効き目を予測できない。** 状況側の条件が要る。

### だから、足す前にこれを問う

1. **それは実測で得た一次情報か?** 推論・一般論なら足さない。
2. **知らないと何分溶けるか?** 答えられないなら優先度は低い。
3. **A/B で差が出るか?** 出ないと予想されるなら、**書かないほうがスキルは鋭くなる。**

> **測り方は `evals/` にある。** `BENCHMARK.md` に結果、`NOTES.md` に方法論の落とし穴
> (動画の変化区間は `mpdecimate` で測る・ハッシュ差は再エンコードのノイズを拾う、など)。
> **A/B を取らないと「スキルが足を引っ張っている」ことに気づけない** ——
> with_skill 単体では webview は 4/4 満点で、問題があること自体が見えなかった。
