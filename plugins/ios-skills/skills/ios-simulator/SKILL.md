---
name: ios-simulator
description: 起動済み iOS Simulator を CLI から操作・視認する(タップ/スワイプ/テキスト入力/ハードウェアボタン/ディープリンク/スクリーンショット/アクセシビリティ走査)。使用タイミング: (1)「シミュレータでアプリを動かして/確認して」(2)「この画面タップして」「スクショ撮って」(3)「onboarding フローを試して」(4)「iPhone で見た目を確認」など、実機ではなく Simulator 上でアプリを見て触る必要がある時。(5)**Simulator に状態を用意したい時** — 資格情報・API キー・OS のアカウント(CalDAV/メール等)・到達画面。`SIMCTL_CHILD_*` の env 注入 / `simctl clone`(種があれば 16.7 秒・0タップ)/ `.mobileconfig`(**アカウント系ペイロードは効かない**)/ **まっさら端末では CalDAV アカウントの初回追加が必ず失敗するという既知の罠(回避策は `webcal://` の照会カレンダーを1つ先に入れること)**まで扱う。**Simulator を触らずに済ませる判断(env 注入で状態を作る/WebView はブラウザで見る/反復検証は XCUITest へ昇格)もこのスキルの守備範囲**なので、「シミュレータで◯◯を検証したい」と言われた時点で最初に読むこと。macOS のシステムプロキシ(Proxyman 等)が新品 Simulator の TLS を落とす罠もここ。実機は対象外(それは ios-device-build)。裏は xcrun simctl + idb。
---

# iOS Simulator 操作(CLI)

起動済みの iOS Simulator を **ターミナルから**操作・視認するスキル。Claude Code Desktop の
「iOS Simulator ペイン」(`mcp__Claude_Code_iOS_Simulator__control`)は Desktop 専用
(`sessionType==="ccd"` ゲート・アプリ内蔵 MCP・live streaming 用の native sidecar 依存)だが、
その中身を分解すると **`xcrun simctl` + `idb`** の2つで構成されている。本スキルは Desktop の
ペイン(ユーザーが横で眺める view)を捨て、**操作プリミティブだけ**を CLI で再現する。
build は同梱しない — ビルドは `ios-device-build` 相当または各プロジェクトのビルドツールに任せ、
本スキルは「ビルド済み .app を simulator に入れて触る」ところから担当する。

> 由来: Anthropic の Desktop ツール定義から抽出したコンテキストエンジニアリング(座標系・
> ワークフロー規律・ジェスチャの機微・エラー復帰の作法)を写経・翻案している。原文の要旨は
> 各節の引用ブロックに残す。
>
> **2026-08-01 全面改訂。** 同日に4本の対照実験(env 注入 / 録画と HID の対照実験 /
> `simctl clone` と `.mobileconfig` / WebView のブラウザ引き剥がし)を回した結果、
> **旧版の記述が複数、実測で否定された**。撤回した記述と「なぜそう信じられていたか」は
> `references/retracted-2026-08-01.md` に残してある(消さずに誤診カタログとして保存する方針)。
> 同日の実地記録は `FEEDBACK-2026-08-01-swift-mcp-app.md`。
>
> **2026-08-01 第2ラウンド追記。** 同日夜に「Simulator に CalDAV アカウントを入れる」を
> 決着させるため、端末を作り直しながら5回以上の対照実験を回した。得られた主な成果は3つ:
> **(A) まっさらな Simulator では CalDAV アカウントの初回追加が必ず失敗する**(サーバー実装と
> 無関係・他社サーバーでも再現)/ **(B) macOS のシステムプロキシ(Proxyman 等)が
> 新品 Simulator の TLS を全部落とす** / **(C) Simulator へのテキスト受け渡しは
> `xcrun simctl pbcopy <UDID>` が第一選択**。このラウンドで外した仮説6本も
> `references/retracted-2026-08-01.md` §6〜§11 に追加した(誤診カタログはまた増えた)。
>
> **2026-08-01 第3ラウンド追記(アカウント投入の決着)。** (A) の回避策が
> **「追加→保存→削除→追加」の儀式から「`webcal://` で照会カレンダーを1つ先に入れる」
> (4タップ・テキスト入力0)へ格上げされた**(✅実測。初回から通る)。
> 温めるのに **CalDAV アカウント型である必要は無い**(ユーザー追加アカウントが1つあればよい)。
> 種を1台作れば、以後は **`simctl clone` が 16.7 秒・0タップ**で量産できる。
> 一方 **`.mobileconfig` は「温めれば通る」説が❌否定され**、アカウント系ペイロード全般が
> Simulator ではアカウントを作らないことが確定した(→ `references/retracted-2026-08-01.md` §12)。

---

## ★最初に読む: 棲み分け(idb を安定させるより、idb を使わない経路へ逃がす)

**2026-08-01 の最大の学び。** このスキルのハマりどころの大半は「idb で頑張ろうとしたから」
発生している。やりたいことに応じて、**まず下の表で土俵を選ぶ**こと。

| やりたいこと | 使う手段 | なぜ |
|---|---|---|
| **状態を作る**(資格情報・接続先・アカウント・到達画面) | **タップしない。** 起動環境変数 `SIMCTL_CHILD_*` / URL スキーム / `simctl clone` / `.mobileconfig`(⛔ アカウント系ペイロードは効かない)→ `references/state-provisioning.md` | 実測: API キー入力もログインも飛ばして **0 タップ・2 秒**でチャット可能状態に到達し、実 LLM 往復まで確認できた。座標も IME も HID も関与しない |
| **WKWebView の中身の検証** | **Simulator を使わない。** カード HTML をブラウザで開く → `references/webview-offload.md` | iOS の WebView 内要素は idb でも XCUITest 系でも扱いが弱い。**土俵の外に出すのが正解**。実測で描画・セレクタ操作・クリック・スクロール・コンソール・ダークテーマまで全部ブラウザで確認できた |
| **反復する検証・回帰・入力を伴う操作** | **XCUITest へ昇格する** | 実測: idb + スクショで **30 分**かけて確証が得られなかった検証が、**XCUITest では3本 green で 30 秒**。`accessibilityIdentifier`(座標不要)・`waitForExistence`(固定 sleep 不要)・`XCTAssert`(人が目で見なくてよい)が揃っているため |
| **一度きりの探索・見た目の確認** | **idb + スクショ(= このスキルの本来の守備範囲)** | 探索は idb が速い。ただし下記の「無言の失敗」を必ず踏まえる |

これは idb の否定ではない。**idb で探索して当たりをつけ、固まったら XCUITest へ昇格する**
という流れが実地では最速だった。

> ⚠️ **「XCUITest へ昇格」が常に正しいわけではない(2026-08-01 第3ラウンドの判断)。**
> 設定アプリ(`XCUIApplication(bundleIdentifier: "com.apple.Preferences")`)の自動化は
> **技術的には可能**(Simulator なら署名不要・ホストアプリ不要)。それでも
> **OS アカウントの投入では採らなかった** —— clone が **0タップ 16.7 秒**になった以上、
> 自動化して得するのは「種を1台作る」1回だけで、代わりに
> **デバイス所有権の衝突リスクを常設する**ことになる(→ 下の「デバイスの所有権」)。
> **昇格の判断軸は「反復が実際に発生しているか」。** 1回きりの作業に昇格コストは払わない。
> 詳細な検討は `references/state-provisioning.md` §4-b。

---

## ★診断の規律(今日いちばん高くついた学び)

同じ日に、**独立した2つのセッションが同じ穴に落ちた**。

- 片方は「アプリのジェスチャ実装が原因では」という仮説をコードから筋道立てて組み立て、
  検証環境(ソフトキーボード無効)が壊れていたので**証明も反証もできない 30 分**を使った。
- もう片方は「録画と HID が同じ IO ポートを取り合っている」という筋の通った仮説を
  **事実として SKILL.md に書き**、後日の対照実験で否定された。

どちらも「筋が通っていること」を「正しいこと」と取り違えている。規律は3つ:

1. **環境要因を排除する前に立てた仮説は、どれだけ筋が通って見えても採用しない。**
   まず観測手段が生きているかを確かめる(下の事前チェック)。
2. **実測と推論を必ず書き分ける。** この SKILL.md でも「実測」「推論(未検証)」を明示している。
   推論を事実として書くと、次に読む人が検証せずに信じて同じ穴に落ちる。
3. **ground truth は、疑っている道具の外側で取る。** 例: `idb ui tap` が効いたかを
   `idb` の返り値で判定しない。`xcrun simctl io <UDID> screenshot` の前後を `cmp` で
   バイト比較する(実際にこれで「タップが無視された」ことを確定させた)。
4. **複数端末を並行して動かすときは、ログを端末ごとに分けて採る。**(2026-08-01 第2ラウンド追記)
   混ぜると**存在しない差分**が見え、そこから誤った因果が組み上がる。実例: 「失敗する1回目だけ
   5周リトライしている(15件)/成功する2回目は6件」という決定的に見える差分を掴んだが、
   15件のうち**9件は別端末のログだった**。時刻順に並べ直すと両試行とも6件で同一。
   → `xcrun simctl spawn <UDID> log ...` のように**必ず UDID で採取先を固定し、
   出力ファイルも端末ごとに分ける**。`log stream --predicate` をホスト側で流すと
   全 Booted 端末が混ざる。解剖は `references/retracted-2026-08-01.md` §9。

---

## 前提ツール

- **xcrun / Xcode**: フル Xcode 必須(Command Line Tools だけでは idb-companion がビルド・
  動作しない)。`xcrun simctl list devices booted` で Booted な端末を確認できること。
- **idb**(2コンポーネント):
  - `idb-companion`(ネイティブ gRPC デーモン)← **nixpkgs にある**(`idb-companion`, aarch64-darwin)。
    dotfiles の nix で導入するのが推奨。Homebrew の `idb-companion` でも可。
  - `fb-idb`(Python 製 CLI `idb`。`idb ui tap` 等を叩く側)← **nixpkgs に無い**。
    **uv で導入**する:
    ```bash
    uv tool install fb-idb        # => ~/.local/bin/idb
    ```
- idb を使う前に companion を端末へアタッチ(初回のみ):
  ```bash
  idb connect <UDID>              # ← UDID を明示する。引数なしは現行 CLI では機能しない
  idb list-targets                # Booted な simulator と companion socket を確認
  ```
  > **2026-07-31 訂正:** 旧版の本スキルは `idb connect`(引数なし)と書いていたが、
  > fb-idb の現行 CLI では**アタッチされない**。`idb list-targets` の該当行が
  > `No Companion Connected` のままになり、以降の `idb ui *` が無反応になる。
  > **UDID を明示すれば** `... | /tmp/idb/<UDID>_companion.sock` に変わって使えるようになる。
  > 以後 `idb ui *` にも `--udid <UDID>` を毎回付ける(Booted が複数あると誤配送する)。

idb が無くても **screenshot / launch / open_url は simctl だけで動く**。tap/swipe/text/button と
アクセシビリティ走査だけが idb 必須。

## ★事前チェック(ここを飛ばすと、以降の観測がすべて無効になる)

```bash
# 1) どの端末が Booted か。★複数 Booted は現実に起きる(実地で4台の日があった)
xcrun simctl list devices booted
export SIM_UDID=<対象の UDID>          # 以降のスクリプトは全部これを使う

# 2) 同じ端末を掴みに来る他プロセスがいないか(→「デバイスの所有権」節)
ps aux | grep -i xcodebuild | grep -v grep

# 3) ★入力・キーボードが絡む検証をするなら必ず: ソフトキーボードが出る設定か
defaults read com.apple.iphonesimulator ConnectHardwareKeyboard
#   → 1 なら「ハードウェアキーボード接続」状態。**画面上のソフトキーボードは一切表示されない**
defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false
#   → 反映には Simulator.app の再起動が要ることがある。GUI なら I/O > Keyboard >
#     Connect Hardware Keyboard(⌘K)

# 4) ★ネットワーク・TLS・アカウント追加が絡む検証をするなら必ず: システムプロキシが有効でないか
networksetup -getsecurewebproxy "Wi-Fi"        # Enabled: Yes なら HTTPS が全部 MITM されている
pgrep -lf 'Proxyman|Charles|mitmproxy'         # キャプチャツールが動いていないか(ERE で一括)
#   → Simulator は **macOS のシステムプロキシ設定を継承する**。
#     詳細は直下の「4 を飛ばすと何が起きるか」節
```

**3 を飛ばすと何が起きるか(実測・FEEDBACK §0)**: 入力欄をタップしてもキーボードが出ないため、
「タップが効いていない」→「アプリの不具合でキーボードが出ない」→ 座標系を疑い始めて
**「px が正解だ」という完全に誤った結論**へ、という誤診の連鎖が起きた。
判明したのは、ユーザーが Simulator 上で ⌘K を押したときだった。

判定のコツ: 入力欄タップ後のスクショで **画面下半分にキーの並びが写っているか**を見る。
**日本語 IME の変換候補バーだけが出ていてキーが無い場合も「ソフトキーボードは出ていない」。**

### 4 を飛ばすと何が起きるか(実測・2026-08-01 第2ラウンド): 新品 Simulator の TLS が全部落ちる

**Simulator は macOS のシステムプロキシ設定を継承する。** Proxyman などが
`127.0.0.1:9090` に自分をプロキシとして設定していると **Simulator の通信も全部 MITM される**。
そして **新品の Simulator はそのルート CA を信頼していない**ので、

- Safari やアカウント追加で「**サーバの識別情報を検証できません**」ダイアログが出る
- アプリの通信は静かに失敗する(HTTPS だけが落ちるので「サーバーが落ちている」ように見える)

デバイスログにも痕跡が出る(この3点セットが揃ったらプロキシを疑う):

```
[C47 127.0.0.1:9090 ready parent-flow (satisfied (Path is satisfied), ... proxy ...)]
  ↓
SecTrustEvaluateIfNecessary
  ↓
Task <...> finished with error [-999]      # NSURLErrorCancelled = 信頼評価で切られた
```

**対処: CA を端末の信頼ストアに入れる。** これで復号キャプチャも同時に取れるので一石二鳥
(プロキシを落として逃げるより、入れてしまう方が実験には有利)。

```bash
xcrun simctl keychain <UDID> add-root-cert \
  "$HOME/Library/Application Support/com.proxyman.NSProxy/app-data/proxyman-ca.pem"
# `xcrun simctl keychain` のサブコマンドは add-root-cert / add-cert / reset の3つ
```

> **皮肉な注意点(次に誰かが必ず踏む)**: このラウンドでは
> **「キャプチャに使おうとしていた Proxyman が、そのまま交絡因子になった」。**
> CalDAV やネットワークまわりを Simulator で検証するとき、「まずプロキシを立てて中身を見る」のは
> 極めて自然な最初の一手なので、**観測手段そのものが被験体を壊す**構図に入りやすい。
> 「診断の規律」1 の「環境要因を排除する前に立てた仮説は採用しない」の典型例。
> なお **CA を入れた端末でも後述の CalDAV 初回追加失敗は再現した** ので、
> プロキシは「別個の罠」であって主症状の原因ではなかった(→ `references/retracted-2026-08-01.md` §7)。

---

## ★最重要ハマりどころ 1: `idb ui tap` は無言で失敗する

**今日の誤診はほぼ全部これが根っこ。** `idb ui tap` は
**当たっても外れても無言で `exit 0` を返す(実測)。** 返り値からは何ひとつ分からない。
「コマンドが成功した = タップが効いた」は**成り立たない**。

### タップの成否判定の手順

1. **撃った後は `describe-all` を撮り直す。** 狙った要素の状態変化(focused/selected)や
   新しい要素の出現で判定する。→ `scripts/sim-wait.py` / `scripts/sim-act.py`
2. **スクショの見た目だけで判定しない。** 実地では、タップは効いてフォーカスも入っていたのに
   **キーボードがまだ出ていない瞬間**を撮って「効かなかった」と誤判定した(FEEDBACK §1)。
   さらにそのときは事前チェック 3 を怠っていて、そもそもキーボードが出ない設定だった。
   **道具の沈黙 × 環境設定の見落としの合わせ技**で誤診は起きる。
3. **ground truth が要るときは、idb の外側で取る。**
   ```bash
   xcrun simctl io "$SIM_UDID" screenshot ~/tmp-sim/before.png
   idb ui tap --udid "$SIM_UDID" 201 337     # rc=0 で返ってくる。これは何の証拠にもならない
   sleep 2
   xcrun simctl io "$SIM_UDID" screenshot ~/tmp-sim/after.png
   cmp ~/tmp-sim/before.png ~/tmp-sim/after.png && echo "★画面は変化していない = タップは無視された"
   ```
   実際にこの手順で「`idb` は成功と言うが画面はバイト単位で不変」を確定させた(track2)。
4. **`scripts/sim-act.py`(tap → assert → リトライ)を使う。** ただし下記2点に注意:
   - ⚠️ **非冪等な操作(トグル類)に使うと逆の状態になる。** サイドバー開閉のような操作で、
     1回目が実は効いていたのに assert が間に合わず2回目が飛ぶと閉じてしまう(track1 の教訓)。
     安全に使えるのは冪等/準冪等な操作(送信・画面遷移・ダイアログを閉じる)だけ。
   - ⚠️ **assert 条件が原理的に真になりうるか**を確認する。実地では「送信済みテキストが
     チャット履歴に残り続ける UI」に `--until-gone "<送信した文字列>"` を掛けたため、
     **送信は成功しているのに「3回失敗」と報告された**。

### 🔴 裏返しの罠: **`describe-all` に出てこない要素が実在する**(2026-08-01 第3ラウンド)

上の判定手順は `describe-all` を土台にしているが、**AX 走査は全知ではない。**
実測で確認された不可視要素:

- **照会カレンダー(`webcal://`)購読確定の赤い ✓ ボタン**が `describe-all` に**一切出ない**。
  画面には明確に描かれているのに、走査結果には存在しない。
- **ソフトキーボードのキー**(別プロセス = SpringBoard 側の要素なので安定して現れない。
  → 「テキスト入力」節)。

**症状は「タップすべき要素が見つからない」**なので、
**「まだ画面が出ていない」「タップが効いていない」と誤診しやすい**(= ハマりどころ 1 と同じ絵になる)。

規律:

- **`describe-all` が空振りしたら、次は必ずスクショを撮って目で確認する。**
  走査で見つからない ≠ 画面に無い。
- 見えているのに走査に出ないなら **スクショ座標を pt に変換してタップする**
  (pt = px ÷ scale。→ ハマりどころ 3)。`scripts/sim-shot.sh` が scale を毎回出す。
- **`describe-all` を「唯一の真実」にしない。** ground truth はスクショ側にもある。

---

## ★最重要ハマりどころ 2: `frame:{0,0,0,0}` の要素1個 = 「前面にいない」印

`idb ui describe-all` がこれだけを返すことがある:

```json
[{"AXFrame":"{{0, 0}, {0, 0}}","frame":{"y":0,"x":0,"width":0,"height":0},"AXLabel":null, ...}]
```

> **訂正(2026-08-01):** 旧版はこれを「AX/HID が壊れた」と診断し、復旧手段として
> `shutdown` → `boot` → `idb connect` を書いていた。**誤診だった。**
> 詳しい解剖は `references/retracted-2026-08-01.md` §3。

**これは「対象アプリが前面にいない」印。** 復旧は Simulator の再起動ではない:

```bash
xcrun simctl launch --terminate-running-process "$SIM_UDID" <bundle-id>
sleep 5     # レイアウト確定を待つ。短いと空/部分的な結果になる
idb ui describe-all --udid "$SIM_UDID" --json   # → 正常に 20 要素返った(実測)
```

`xcrun simctl io ... screenshot` は**この状態でも正常に撮れ続ける**ので、
「Simulator は生きているのに走査だけ通らない」という紛らわしい絵になる。
アプリが前面から落ちる原因で実地で確認されたもの:

- **同一デバイスへの外部 `xcodebuild test`(XCUITest)の割り込み** → 次節「デバイスの所有権」
- `xcrun simctl launch` 直後の、まだ前面化しきっていない一瞬。
  → **単発の `describe-all` を1回撃つのではなく `sim-wait.py` のポーリング経由で判定する。**

---

## ★最重要ハマりどころ 3: 座標系は **points**(pt が正しい)

**スクリーンショットは pixels、`idb ui tap` は points**。両者は端末のスケール係数
(Retina なら 2〜3倍)だけズレる。

> **訂正(2026-08-01):** 一時「pt では効かない、px が正解」という結論が実地セッションで
> 立てられたが、**これは誤り**。`idb ui tap` は points が正しい(実測:
> `describe-all` のルートが `{x:0,y:0,width:402,height:874}` を返す端末で、入力欄中心
> `181 812` のタップは効き、スクショのピクセル値 `543 2436` は**画面外として完全に無視**された)。
> 誤結論の原因は座標系ではなく、最重要ハマりどころ 1(無言の失敗)と事前チェック 3
> (ソフトキーボード無効)の合わせ技。解剖は `references/retracted-2026-08-01.md` §4。

規律は2つ:

1. **タップ先はアクセシビリティで取る(第一選択)。** `idb ui describe-all` は各要素の frame を
   **points** で返す。要素の中心(centerX/centerY)をタップすれば、スケール変換もスクショ座標も
   一切要らない。→ `scripts/sim-tap.py`(ラベル一致で中心タップ)。
2. **どうしてもスクショ座標からタップするなら、必ずスケールで割って points に変換する。**
   `scripts/sim-shot.sh` はスクショと同時に **pixel 実寸・point 実寸・scale** を出力する。
   point 座標 = pixel 座標 ÷ scale。
   - 実地では**トグルスイッチのような小さい要素で顕著に外す**。2回の変換で誤差が乗り、
     **タップは成功扱いなのに何も起きない**。**小さい要素では必ず describe-all を使う。**

> Anthropic 原文(control description / schema)より:
> *"Coordinates are in device points (origin top-left); the 'launch' result reports the device's
> point dimensions."* / 実行時にも毎回 *"Coordinate space for screenshot/tap/swipe: {W}x{H}
> pixels (origin top-left)."* を**スクショと一緒に明示**している。= 見ている座標空間と打つ座標空間を
> 毎回言語化して食い違いを消す設計。本スキルの `sim-shot.sh` はこの一文を再現する。

---

## 🔴 まっさらな Simulator では CalDAV アカウントの初回追加が**必ず**失敗する(回避策は確定済み)

**2026-08-01 第2ラウンドの最大の発見。Simulator で CalDAV を扱う人が最初に踏む罠。**
**回避策は第3ラウンドで `webcal://` 前置き(4タップ)に確定した。**
詳細な観測ログと状態プロビジョニングへの落とし込みは
`references/state-provisioning.md` §4 にある(ここは要約)。

**症状(実測)**: **ユーザー追加アカウントが1つも無い** Simulator で
「設定 → アプリ → カレンダー → アカウント → アカウントを追加 → その他 → CalDAVアカウント」を
実行すると、**サーバー検証は成功するのに、次に出るべき「カレンダー/リマインダー」の
トグル一覧が空**になる。そのまま保存すると **データクラス0個 = 「停止中」のアカウント**ができる。

**✅ 回避策(第3ラウンドの実測で確定・推奨)**: **CalDAV を追加する前に、`webcal://` で
照会カレンダーを1つ入れて端末を「温める」。** **4タップ・テキスト入力ゼロ**で済み、
**CalDAV は1回目からトグル一覧が出る。**

```bash
xcrun simctl openurl "$SIM_UDID" 'webcal://<公開 ics の URL>'   # 照会 URL が埋まった状態でシートが出る
sleep 10   # ★ 直後4秒はまだホーム画面。カレンダー App の起動待ち(✅実測)
#  → 「許可しない」×2(通知/位置情報)→「検索」→ **赤い ✓**
#  🔴 赤い ✓ は `idb ui describe-all` に出てこない(✅実測)。スクショで座標を取るしかない
```

**⛔ 第2ラウンドで書いていた「追加 → 保存 → 削除 → 追加」の儀式はもう不要**
(約30タップ・入力6回。webcal 前置きは4タップ・入力0)。儀式の手順自体は
`references/state-provisioning.md` §4 に**記録として残してある**。

**✅ 温めるのに CalDAV アカウント型である必要は無い(実測)。** 照会カレンダー
(`SubscribedCalendar`)は CalDAV とは別のアカウント型だが、これで温まる。
→ **条件は「ユーザーが追加したアカウントが1つ以上ある」こと**であって、接続先ホストにも
アカウント型にも依存しない。

**これはサーバー実装とは無関係の iOS 側の挙動**。対照実験(すべて新規作成した端末・実測):

| 条件 | 1回目でトグルが出るか |
|---|---|
| 新品 + 自作サーバー(Cloudflare Workers) | ❌ |
| 新品 + 同上(事前にリマインダー/カレンダー App を起動して温めた) | ❌ |
| 新品 + 別ホスト(Cloud Run。`:8443` に応答しない入口) | ❌ |
| **新品 + 完全に無関係な他社 CalDAV サーバー(Vikunja のデモ)** | ❌ |
| 既に CalDAV アカウントが1つある端末 + 別ホスト | ✅ |
| ✅ **新品 + `webcal://` の照会カレンダーを1つ入れた端末** | ✅ **出た** |

**「自分のサーバーが RFC に準拠していないからだ」と読んではいけない。** 他社サーバーでも同じ。
サーバー側のデバッグに入る前に、必ず**「この端末にユーザー追加アカウントが1つでもあるか」**を確認する
(CalDAV でなくてよい。照会カレンダーで足りる)。

**なぜ今まで気づかなかったか**: iOS の挙動検証は従来**実機**でやっていた。実機には
Apple ID やメールのアカウントが既にあるので「ユーザー追加アカウントがゼロ」の状態にならず、
この現象に当たらない。**まっさらな Simulator 特有。**

⚠️ 新品端末に最初から入っている「**日本の祝日**」は数に入らない(`HolidayCalDaemonAccount` という
システム管理のデーモンアカウント。**これでは温まらない**ことを実測)。
🔴 **webcal で温めると、同じ端末に「日本の祝日」の行が2つ並ぶ**(システムのデーモンアカウント =
無力 / ユーザー追加の照会カレンダー = これが温めた)。**表示名が同じなので UI では区別できない。
判定は `Accounts3.sqlite` で `ZACCOUNTTYPE` を JOIN して見る**(✅実測)。

→ **検証端末が何台も要るなら、手作業は種1台で1回だけ払い、あとは `simctl clone` で運ぶ**
(✅実測 **16.7 秒・0タップ**。Keychain ごと運ばれ、clone 先で実際に同期が動くことまで確認済み)。
根拠・観測ログ・コピペで動く2段構えの手順は `references/state-provisioning.md` §4。

---

## ★デバイスの所有権: 1デバイスにつき自動操作クライアントは1つ

**実測(track1)**: `xcodebuild test`(XCUITest)と `idb` を同じデバイスへ同時に向けると、
**アプリが強制終了され SpringBoard に戻される**。その結果 `describe-all` は
`frame:{0,0,0,0}` の1要素だけを返すようになる(= 上のハマりどころ 2 の典型的な引き金)。

規律:

- **作業前に `ps aux | grep xcodebuild` で衝突を確認する。** 割当デバイスの UDID が
  他プロセスの `-destination` に入っていないか見る。
- **`xcodebuild` は既定のシミュレータを掴みに来る**ので、idb 作業は**名前付きのハーネス機**に寄せる
  (例: `MCPHost Harness A`)。既定機を idb 作業に使うと、他人の `xcodebuild` に踏まれる。
- **複数 Booted は現実に起きる。** 実地で4台同時 Booted の日があった。
  **`booted` 指定は事故になる** —— 実際に `simctl io booted screenshot` で
  **別エージェントが作業中の端末を撮ってしまった**(読み取り専用だったので実害はなかったが事故)。
  → だから本スキルのスクリプト4本は `--udid`/`SIM_UDID` を**必須**にしてある。
- 他人のプロセスを kill する判断はしない。`ps` で PID の終了を待ってから再開するのが安全
  (実地では数十秒〜1分で自然終了した)。
- 💡 **この衝突は「導入コスト」として数える。** 第3ラウンドで「設定アプリの操作を XCUITest 化する」案を
  見送った決め手はここだった —— **1回きりの作業のために、所有権の事故面を常設で増やす**のは割に合わない
  (`references/state-provisioning.md` §4-b)。

---

## ★テキスト入力: 「キーボードが出ない」と「入力が化ける」は**別問題**

混ぜると誤診する。切り分けは以下:

| 症状 | 原因 | 対処 |
|---|---|---|
| **キーが1つも画面に出ない**(候補バーだけの場合も含む) | `ConnectHardwareKeyboard` が有効(ホスト側の設定) | 事前チェック 3。`defaults write ... -bool false` |
| **キーは出るが文字が化ける**(`hello` → 「へっぉ」) | **キーボード言語 / IME** | 下記 |

### `idb ui text` は現在のキーボード言語を通る(実測)

日本語キーボードだと ASCII がローマ字変換される:

```
入力: "hello"   → 実際: 「へっぉ」   ← 実測
```

母音がひらがなに、子音がローマ字入力の途中状態のまま残る。`.` は「。」になる。
**URL・ユーザ名・メールアドレスのように英字と記号が混ざる文字列は全滅する**
(ホスト名を1本打つと、英字・ひらがな・全角句点が混ざった別物になる)。

**エラーにならず、それらしい文字列が入る**ので気づきにくい。
`idb ui text` の返り値は成功のままで、スクショを撮って初めて分かる。

確実に ASCII を入れる手段:

- **`xcrun simctl pbcopy <UDID>` + 長押しペースト(第一選択)** — IME を経由しない。
  **UDID を取れるので複数 Booted 環境でも誤爆しない。** 詳細は次項。
  弱点はメニュー(ペースト)のタップが座標依存なところだけ。
- **XCUITest の `typeText`** — 反復するなら結局これが一番確実(→ 棲み分けの表)。
- **Caps Lock(HID usage `57`)を1回送る** — 設定 > 一般 > キーボード > ハードウェアキーボード の
  「Caps Lock 言語切り替え」(既定 ON)に依る。ロック状態なので以降のフィールドにも持続する。
  ```bash
  idb ui tap  --udid "$SIM_UDID" <x> <y>
  idb ui key  --udid "$SIM_UDID" 57            # 英語入力モードへトグル
  idb ui text --udid "$SIM_UDID" "caldav.example.com"
  ```
  ⚠️ **効くこともあれば効かないこともある。「1回送れば必ず効く」でも「使えない」でもない(実測)。**

  | 状況 | 実測 |
  |---|---|
  | Simulator を **shutdown/boot した直後**のセッション(第2ラウンド) | ❌ 効かず、長文が盛大に化けた |
  | **`simctl create` → `bootstatus` 直後**の新品端末(第3ラウンド) | ✅ **1発で効き、サーバ/ユーザ名/パスワードの3フィールドをまたいで持続した** |

  → **結論はどちらか一方への断定ではなく「毎回プローブする」。**
  Caps Lock を送ったら、**必ず短い ASCII プローブ(`"abc"`)を1回打って化けていないか確認**してから
  本文を打つ(下記の「実地で安定した手順」と同じ規律)。
  💡 **効いたときはタップ数で `pbcopy` 経路に勝つ**(長押し → ペーストのメニュー操作が要らない)ので、
  **`pbcopy` の前に1回試す価値はある**。効かなければ即 `pbcopy` へ逃げる。

> **実地で安定した手順(track1)**: 本文を打つ前に**短い ASCII プローブ(`"abc"` など)を
> 1回打って、化けていないかを目で確認してから本文を打つ**。
> **入力後は必ず目視 / describe-all で確認する。** 化けていても静かに通る。

### Simulator にテキストを渡すなら `xcrun simctl pbcopy <UDID>`(2026-08-01 第2ラウンド)

```bash
printf '%s' 'caldav.example.com' | xcrun simctl pbcopy "$SIM_UDID"
# → 端末のペーストボードに直接入る。あとは入力欄を長押し → ペースト
```

**macOS 側でコピーしてもシミュレータに貼れないことがある。**
`defaults read com.apple.iphonesimulator PasteboardAutomaticSync` が `1`(有効)でも起きる。
理由は**経路が違う**こと:

| 経路 | 仕組み | 弱点 |
|---|---|---|
| macOS で ⌘C してから Simulator で貼る | **Simulator.app が同期して**端末へ運ぶ | フォアグラウンド遷移などの**イベント駆動**。**複数台起動時**や、Simulator ウィンドウを一度も切り替えずに貼ろうとすると**取りこぼす** |
| **`xcrun simctl pbcopy <UDID>`** | **端末のペーストボードへ直接書く** | 同期という不確実な一段が無い。UDID 指定なので誤配送もしない |

→ **`idb ui text` の IME 化けの回避策としても、`pbcopy` を第一選択にする。**
「同期が効いていないのか、コピー自体が失敗したのか」を切り分ける手間が丸ごと消える。

⚠️ **既知の癖(実測)**: **端末のブート直後は `pbcopy` が失敗することがある。**

```
NSPOSIXErrorDomain code=60   # ETIMEDOUT(推論: 端末側のペーストボードサービスがまだ上がっていない)
```

**数秒待って再試行すれば通る。**「pbcopy が使えない端末だ」と結論しないこと。

### キーボードの出現判定を `describe-all` の文字列一致でやらない(FEEDBACK §4)

「`Return`/`space`/`delete` が含まれるか」で判定したが、キーボードが出ていないのに判定が揺れた。
**キーボードは別プロセス(SpringBoard 側)の要素**なので、アプリの走査結果に安定して現れない。
→ 確実にやるなら **XCUITest の `app.keyboards.element`**。idb 側でやるならスクショの下部領域を見る。

---

## その他のハマりどころ

### 1. スクショの出力先は `$HOME` 配下にする(`/tmp` は書けない)

```bash
❌ xcrun simctl io "$SIM_UDID" screenshot /tmp/.../s1.png
   → An error was encountered processing the command (domain=NSCocoaErrorDomain, code=642):
     You can't save the file ... because the volume "Macintosh HD" is read only.
✅ mkdir -p ~/tmp-sim && xcrun simctl io "$SIM_UDID" screenshot ~/tmp-sim/s1.png
```

エージェント実行環境の sandbox が `/tmp` 配下への書き込みを弾く。
**simctl 側の権限問題ではない**ので、`sudo` や Simulator の再起動をしても直らない。
セッション用の scratchpad が `/tmp` 配下にある場合も同じく弾かれる。
→ `scripts/sim-shot.sh` は既定の出力先を `~/tmp-sim/` にし、`/tmp` 配下を指定されたら警告する。

### 2. `idb ui describe-all` は JSONL ではなく**入れ子の JSON 配列**のことがある

1行1要素だと思って `for line in sys.stdin: json.loads(line)` すると
`AttributeError: 'list' object has no attribute 'get'` で落ちる。
**全体を1つの JSON として読み、再帰で歩く**のが正しい(現行版は flat な配列を返すが、
バージョン差で壊れないように再帰にしておく)。

```bash
idb ui describe-all --udid "$SIM_UDID" 2>/dev/null | python3 -c "
import sys,json
data=json.load(sys.stdin)
def walk(n):
    if isinstance(n,list):
        for i in n: walk(i)
        return
    if isinstance(n,dict):
        t=(n.get('AXLabel') or '')
        if isinstance(t,str) and t.strip():
            f=n.get('frame',{})
            print(repr(t),'->',round(f.get('x',0)+f.get('width',0)/2), round(f.get('y',0)+f.get('height',0)/2))
        for v in n.values(): walk(v)
walk(data)
"
```

出力は `'ラベル' -> centerX centerY` の **points**。そのまま `idb ui tap` に渡せる。

---

## 状態プロビジョニング(タップせずに状態を作る)→ `references/state-provisioning.md`

要点だけ:

- **起動環境変数**: `SIMCTL_CHILD_<VAR>=… xcrun simctl launch <UDID> <bundle>` で
  アプリの `ProcessInfo.processInfo.environment` に届く(根拠は `xcrun simctl help launch` の最終行)。
  **アプリ側に env のエスケープハッチを仕込んでおくと、資格情報入力もログインも全部飛ばせる。**
  実測で **0 タップ・2 秒**でチャット可能状態に到達し、実 LLM 往復まで確認できた。
  ⚠️ 落とし穴: 「効いたように見えて実は env を読む経路に到達していない」ことがある。
  A/B を取るかコードを読んで確認する。
- **`simctl clone`**: インストール済みアプリ・UserDefaults・**Keychain**・`Accounts3.sqlite`・
  外観設定を**バイト単位で運ぶ**(実測。Keychain はアプリが実際に復号して読めるところまで確認)。
  **ソースが Shutdown 必須**(booted だと `code=405`)。
  ✅ **実測 16.7 秒・0タップ**(shutdown 1.8s + clone 4.8s + `bootstatus -b` 10.1s)。
  clone 先で**本番サーバーの同期が実際に動く**ところまで確認済み(Proxyman の root CA も運ばれる)。
  💡 **`xcrun simctl bootstatus <UDID> -b` は boot + 起動完了待ちを1コマンドでやる**ので、
  プロビジョニングの `boot` + 固定 `sleep` は全部これに置き換えられる。
  ⚠️ 落とし穴: `get_app_container` は clone 直後に**コピー元のパスを返し続ける**ので、
  必要なら直接パスを組み立てる。
- **`.mobileconfig`**: `xcrun simctl openurl <UDID> "file://<path>.mobileconfig"` で
  Safari のプロファイル DL フローが起動する(**HTTP サーバー不要**)。
  `xcrun simctl openurl <UDID> "App-prefs:root=General"` で設定アプリの一般画面へ直接ジャンプ。
  実測で **6 タップ**でインストール完了(手入力は約 20 タップ)。
  ⛔ **アカウント投入には使えないことが確定した(✅実測)。** CalDAV も照会カレンダーも、
  「インストール完了」まで到達するのに `Accounts3.sqlite` の行数が変わらない。
  **端末を温めても駄目**(その説は❌否定された → `references/retracted-2026-08-01.md` §12)。
  = **アカウント系ペイロード全般が Simulator では効かない。CalDAV 固有ですらない。**
  💡 配送とペイロード適用の切り分けは UI ではなく `ProfileTruth.plist` /
  `MCProfileEvents.plist` を見る(→ `references/state-provisioning.md` §3)。
- 🔴 **CalDAV アカウント入りの端末を作る**: **まっさらな Simulator は初回追加が必ず失敗する**
  (上の 🔴 節)。手順は2段構え —— **① 一度だけ: `webcal://` で照会カレンダーを1つ入れて
  (4タップ)から CalDAV を追加(1回目で通る)し、その端末を種にする。
  ② 以後: `simctl clone` で量産(16.7 秒・0タップ)。**
  ⛔ 儀式(追加→保存→削除→追加)も `.mobileconfig` も不要/不可。→ `references/state-provisioning.md` §4

## 録画 → `references/recording.md`

要点だけ:

- **`simctl io recordVideo` の尺は実時間と一致しない。これは作法では直らない。**
  イベント駆動の可変フレームレートで、**静止画面 15 秒の録画が `nb_frames=1`** になった(実測)。
  実時間が要るなら後段で `setpts` 補正するか別手段を採る。
- **正しい停止作法**: stderr の `Recording started` を待って開始 → **実 PID** に SIGINT →
  **プロセスの exit をポーリングで待つ**。`pkill -f` + `sleep` は信用しない。
  この作法なら「停止後に尺が伸びる」症状は**再現しなかった**(実測)。
- **`ffmpeg -f avfoundation` への全面移行は推奨しない。** 尺は正確(実測 15.01s → 15.57s)だが、
  フル画面 30fps H.264 で CPU 32〜34%・`libx264` が level limit 超過を警告するほど重く、
  **録画中の `idb ui tap` が広く無視された**(20 回中 10 回失敗。`simctl io screenshot` の
  バイト比較で裏取り済み)。
- **ツールに関係なく効く実務ルール: 撮るときは触らない、触るときは撮らない。**
- ⚠️ 一般的な罠: **start/stop を別プロセス呼び出しに分ける録画スクリプトでは bash 組み込みの
  `wait $pid` が効かない**(自分の子でないので即失敗して何も待たない)。`kill -0` のポーリングで
  exit を待つ。これを踏むと `moov atom not found` の壊れた mp4 ができる。

> **撤回(2026-08-01):** 旧版の「`recordVideo` 中にタップすると HID が死ぬ / `idb kill` では
> 戻らず shutdown→boot が必要」「`pkill -INT` しても録画が生き続け尺が伸びる」は
> **対照実験で否定された**(simctl 録画中の 20 タップは 20/20 成功)。
> 詳細と、なぜそう信じられていたかは `references/retracted-2026-08-01.md` §1・§2。

---

## アクション対応表(Desktop control → CLI)

**スクリプト4本はすべて `--udid <UDID>` 必須**(環境変数 `SIM_UDID` でも可)。

| Desktop action | CLI 等価 |
|---|---|
| `launch` | `xcrun simctl install $SIM_UDID <App>.app` → `xcrun simctl launch --terminate-running-process $SIM_UDID <bundle-id>` |
| (状態つき launch) | `SIMCTL_CHILD_<VAR>=… xcrun simctl launch $SIM_UDID <bundle-id>`(→ 状態プロビジョニング) |
| `screenshot` | `scripts/sim-shot.sh --udid $SIM_UDID [出力パス]`(simctl io + 実寸/scale 注記) |
| `tap` | `idb ui tap --udid $SIM_UDID <x> <y>`(**points**)/ ラベル指定は `scripts/sim-tap.py "<label>" --udid $SIM_UDID` |
| (tap + 成否 assert) | `scripts/sim-act.py "<label>" --until "<label2>" --udid $SIM_UDID`(**推奨**。無言の失敗を潰す) |
| (要素の出現待ち) | `scripts/sim-wait.py "<label>" --udid $SIM_UDID [--gone]` |
| `swipe` | `idb ui swipe --udid $SIM_UDID <x1> <y1> <x2> <y2> [--duration 0.3]` |
| `text` | `idb ui text --udid $SIM_UDID "<string>"`(⚠️ IME を通る。上記「テキスト入力」節) |
| (text の確実版) | `printf '%s' "<string>" \| xcrun simctl pbcopy $SIM_UDID` → 入力欄を長押ししてペースト(**IME も同期も経由しない**) |
| `button` | `idb ui button --udid $SIM_UDID <HOME\|LOCK\|SIRI\|SIDE_BUTTON\|APPLE_PAY>` |
| `open_url` | `xcrun simctl openurl $SIM_UDID <url>`(`file://` や `App-prefs:root=General` も通る) |
| (Desktop に無い強化) | `idb ui describe-all --udid $SIM_UDID --json`(アクセシビリティ走査。座標ズレ根絶の要) |
| `attach`/`detach` | 該当なし(live ペインは Desktop 専用。CLI は screenshot でスナップショット確認) |

## スクリプト

いずれも **`--udid <UDID>` か環境変数 `SIM_UDID` が必須**(未指定は「次の一手」つきで即エラー)。
`booted` 暗黙解決は 2026-08-01 に**意図的に廃止した** —— 複数 Booted 環境で
他エージェントの端末を誤爆する事故が実際に起きたため。便利さより明示を採る。

- `scripts/sim-shot.sh --udid <UDID> [出力パス]` — スクショを撮り、**pixel 実寸・point 実寸・scale** を
  出力(座標空間を毎回明示)。既定の出力先は `~/tmp-sim/sim-shot-<UNIX時刻>.png`
  (`/tmp` は sandbox に弾かれるため)。simctl のみで動く(scale 算出時のみ idb を参照)。
  point 幅が 0 に潰れていたら「アプリが前面にいない」旨の切り分けも出す。
- `scripts/sim-tap.py "<ラベル>" --udid <UDID>` — `describe-all` からラベル一致要素を探し、
  その**中心(points)**をタップ。**低レベルプリミティブ(1回撃つだけ・成否は判定しない)。**
  `--duration 0.05` で「確実に短いタップ」を明示できる(既定 duration だとテキスト入りの
  入力欄で選択メニュー Select/Select All/AutoFill が出ることがある)。
- `scripts/sim-wait.py "<ラベル>" --udid <UDID> [--gone] [--timeout 15]` — ラベルが現れる
  /(`--gone` で)消えるまでポーリングし、frame を JSON で出す。
- `scripts/sim-act.py "<ラベル>" --until "<ラベル2>" --udid <UDID>` — tap → assert → 外れたら再タップ
  (既定3回)。**成否判定つきなので、原則こちらを使う。**
  ⚠️ 非冪等な操作(トグル類)には使わない。assert 条件が原理的に真になりうるかも確認する。

上記4本は **uv の PEP 723 インラインスクリプト**(事前 pip 不要・stdlib のみ)。
`uv run scripts/sim-act.py ...` でも `./scripts/sim-act.py ...` でも動く。

- `scripts/sim-rec.sh <start [out.mp4]|stop>` — **既定の録画手段ではない。** Simulator ウィンドウだけを
  macOS 側の画面キャプチャ(`ffmpeg -f avfoundation`)で録る。**「実時間と一致する尺が要る」かつ
  「録画中にタップしない」ときにだけ使う。** 録画中に idb で操作する必要があるなら
  `simctl io recordVideo`(+ `references/recording.md` §2 の停止作法)を使うこと ——
  対照実験で **ffmpeg 録画中は 20 タップ中 10 回が無視された**(simctl 録画中は 20/20 成功)。
  UDID を取らないのは、macOS のウィンドウを撮る仕組みで**シミュレータの識別子を使わない**ため
  (= 複数 Booted でも「最前面の Simulator ウィンドウ」しか撮れないという別種の曖昧さがある。
  撮る前に狙いの端末が前面かを必ず確認する)。詳細と実測値は `references/recording.md`。

---

## ワークフロー規律(Anthropic のプロンプトから翻案)

> *"call 'attach' FIRST, before building … 'screenshot' and input actions are headless and need no
> panel. Don't open the panel when the user only asked to build/compile or to run unit tests."*

CLI にはペインが無いので attach は不要だが、思想は残す:

- **見た目の確認は screenshot で行う**(headless・安い)。派手な操作の前後で撮って差分を見る。
- **操作(tap/swipe/text)の直後は状態が変わる前に screenshot** を撮って結果を検証する。
  アニメーション中は 1 拍置く(`sleep 0.4` 程度)。
  ただし**スクショだけで成否を決めない**(最重要ハマりどころ 1)。固定 `sleep` より
  `sim-wait.py` のポーリングの方が確実。
- ビルド/ユニットテストだけを頼まれた時は simulator を触らない。
- 実機(「私の iPhone で」)は対象外 → `ios-device-build` に回し、本スキルは simulator のみと明言。

## ジェスチャの機微(Anthropic schema より)

- **`tap` の長押し**: `idb ui tap --udid <UDID> x y --duration <sec>`。`> 0.5` で long-press 相当。
  逆に**短いタップを意図するなら `--duration 0.05` を明示**した方が安定する(FEEDBACK §7)。
- **`swipe` 既定 0.3s**。速さは `--duration` で調整。
- **エッジ 4pt 以内から始まる swipe は OS ジェスチャになる**(原文: *"a 'swipe' whose start point is
  within 4pt of an edge performs the OS edge gesture instead of a plain drag — left=back,
  top=notification shade, bottom=home/app-switcher, right=Control Center"*)。コンテンツを
  ドラッグ/スクロールしたい時は**縁から 4pt 以上内側**を始点にする。逆に戻る/ホーム等の OS
  ジェスチャを出したい時は縁ちょうどから始める。

## エラー復帰の作法(Anthropic のエラー文言に倣う)

「失敗した」で止めず**次の一手を必ず添える**。原文例:
`No booted simulator named 'X'. Boot it with: xcrun simctl boot X — then retry this action.`

- Booted 端末が無い → **`xcrun simctl bootstatus "<UDID>" -b`** してからリトライ
  (`boot` + 起動完了待ちが1コマンド。固定 `sleep` を挟まなくてよい)。
- idb コマンドが `No targets` → `idb connect <UDID>` / `idb list-targets` で companion 接続を確認。
- `describe-all` が要素1個・frame 全部 0 → **アプリが前面にいない。**
  `xcrun simctl launch --terminate-running-process <UDID> <bundle-id>` + 数秒待ち。
- screenshot が `volume is read only` → 出力先が `/tmp` 配下。`~/tmp-sim/` へ。
- 端末上で「**サーバの識別情報を検証できません**」 → **macOS のシステムプロキシが MITM している。**
  `xcrun simctl keychain <UDID> add-root-cert <ca.pem>` で CA を入れる(事前チェック 4)。
- **CalDAV アカウント追加でトグル一覧が空 / 保存すると「停止中」** → **サーバーを疑う前に端末を疑う。**
  ユーザー追加アカウントがゼロの端末の初回追加は必ず失敗する。
  **`xcrun simctl openurl <UDID> 'webcal://<公開 ics>'` で照会カレンダーを1つ入れてから追加し直す**
  (4タップ。儀式は不要 —— 上の 🔴 節 / `references/state-provisioning.md` §4)。
- **`webcal://` を撃ったのにホーム画面のまま** → **カレンダー App の起動待ち。10 秒待つ**(実測。
  4 秒ではまだホーム画面)。「効かなかった」と即断しない。
- **購読の「✓」など、画面に見えている要素が `describe-all` に出てこない** → **AX 走査の穴。**
  スクショを撮って px を読み、`pt = px ÷ scale` でタップする(ハマりどころ 1 の裏返しの罠)。
- `xcrun simctl pbcopy` が `NSPOSIXErrorDomain code=60` → ブート直後。数秒待って再試行。
- **`shutdown` → `boot` → `idb connect` は最終手段。** 上の切り分けを全部やってから使う
  (旧版はこれを第一の復旧手段として書いていたが、ほとんどのケースで過剰だった)。

---

## 典型フロー

```bash
# 0) 端末を1台に確定させる(★複数 Booted は現実に起きる)
xcrun simctl list devices booted
export SIM_UDID=<対象の UDID>
xcrun simctl bootstatus "$SIM_UDID" -b         # 未 boot ならここで boot + 起動完了待ち(固定 sleep 不要)
ps aux | grep -i xcodebuild | grep -v grep     # 所有権の衝突チェック
idb connect "$SIM_UDID" && idb list-targets

# 0-b) 入力が絡むなら必ず(ここを飛ばすと以降の観測が全部無効になる)
defaults read com.apple.iphonesimulator ConnectHardwareKeyboard   # 1 ならソフトキーボードが出ない

# 1) ビルド済み .app を投入し、★状態を env で注入して起動(タップを削る第一手)
xcrun simctl install "$SIM_UDID" "path/to/MyApp.app"
SIMCTL_CHILD_MYAPP_API_KEY="$SOME_KEY" \
SIMCTL_CHILD_MYAPP_SPIKE=todos \
  xcrun simctl launch --terminate-running-process "$SIM_UDID" com.example.MyApp

# 2) 目的の画面が出るまで待つ(単発 describe-all ではなくポーリング)
scripts/sim-wait.py "メッセージを入力" --udid "$SIM_UDID" --timeout 15

# 3) 見た目を確認(pixel/point/scale を注記付きで取得)
scripts/sim-shot.sh --udid "$SIM_UDID" ~/tmp-sim/step1.png

# 4) タップは「成否 assert つき」で撃つ(sim-tap.py は成否を判定しない低レベル版)
scripts/sim-act.py "続ける" --until "ようこそ" --udid "$SIM_UDID"

# 5) テキスト入力は、先に短い ASCII プローブで IME を確かめてから本文
idb ui text --udid "$SIM_UDID" "abc"
scripts/sim-shot.sh --udid "$SIM_UDID" ~/tmp-sim/probe.png   # 「あbc」等に化けていないか目視
idb ui text --udid "$SIM_UDID" "hello@example.com"
#    化けるなら IME を経由しない経路へ逃げる(ブート直後は code=60 で失敗するので数秒待って再試行)
printf '%s' 'hello@example.com' | xcrun simctl pbcopy "$SIM_UDID"   # → 入力欄を長押ししてペースト

# 6) ディープリンク(アプリ側に実装があれば、フォーム入力を丸ごと飛ばせる)
xcrun simctl openurl "$SIM_UDID" "myapp://deeplink/path"
```

---

## 参照ファイル

- `references/state-provisioning.md` — env 注入 / URL スキーム / `simctl clone` / `.mobileconfig` /
  **§4 CalDAV アカウント(初回追加が必ず失敗する挙動と、`webcal://` 前置き + clone の2段構え手順)**
  / §4-b 検討して採らなかった経路(XCUITest 自動化・`Accounts3.sqlite` 直書き)。
  **タップを減らす手段のカタログ。まずここを読んでから idb を触るかを決める。**
- `references/recording.md` — 画面録画(尺の実態・正しい停止作法・ffmpeg 比較・一般的な罠)。
- `references/webview-offload.md` — WKWebView の中身をブラウザで検証する経路。
- `references/retracted-2026-08-01.md` — **撤回した記述と誤診の解剖(§1〜§12)。**
  「この症状はこう誤診しやすい」というカタログとして保存してある。
  誤診の型は3つ: **筋の通った推論を検証せずに信じた**(§1〜§5・§6〜§11)/
  **観測データが汚染されていた**(§9)/ **本物の発見を別の未解決問題の説明に流用した**(§12)。
- `FEEDBACK-2026-08-01-swift-mcp-app.md` — この日の実地記録(生の記録として残してある。
  §0 のソフトキーボード問題、§1 の座標系誤診、§6 の XCUITest 比較が特に重要)。
