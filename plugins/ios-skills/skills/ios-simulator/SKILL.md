---
name: ios-simulator
description: >-
  iOS Simulator を CLI で操作し、検証用の状態(OS アカウント、同じ状態の複数台、資格情報、到達画面)を
  用意する。「シミュレータで動かして」「アカウントを入れて」「端末を複数用意して」「スクショ撮って」
  「デモ動画を撮って」と頼まれたときに使う。タップが無言で失敗する、テキスト入力が化ける、キーボードが
  出ない、TLS が落ちる、アカウントを追加できない、録画の尺が合わない、といった詰まりの診断にも使う。
  Simulator を操作する前に読む。実機は対象外(ios-device-build)。
compatibility: >-
  macOS + フル Xcode(Command Line Tools だけでは不可)。tap/swipe/テキスト入力/アクセシビリティ走査には
  idb が必要 —— idb-companion(nix または brew)と fb-idb(`uv tool install fb-
  idb`)の2コンポーネント。screenshot / launch / openurl は xcrun simctl だけで動く。Python
  スクリプトは uv(PEP 723 インライン依存)で実行する。実機は対象外。
---

# iOS SimulatorをCLI操作する

buildはプロジェクト側の手順に任せる。すべてのコマンドでUDIDを固定し、暗黙の`booted`を使わない。

## 基本手順

1. 対象UDIDを明示する。新規端末ならcreateしてboot完了を待ってからpreflightする。

   ```bash
   SIM_UDID="$(xcrun simctl create '<name>' '<device-type>' '<runtime>')"
   xcrun simctl bootstatus "$SIM_UDID" -b
   export SIM_UDID
   scripts/sim-preflight.sh --udid "$SIM_UDID"
   ```

   既存端末でも最初の対象操作はpreflightにする。warningsの`fix`を実行し、再度preflightしてから
   観測を始める。端末のcreate/bootはpreflightより前でよい。preflightを飛ばすと、以降の観測は
   汚れた土台の上の値になり無効になる。

2. UI操作前に、タップを削れるか判断する。タップを1回も撃たずに終えてよく、「Simulatorでは
   検証しない」という結論もこの手順の正しい終わり方に含める。

   - アプリ内状態: `SIMCTL_CHILD_<VAR>`またはURL scheme。
   - OS状態を複製: seed端末をshutdownし、`simctl clone`。Keychain/資格情報も複製されるため扱いを限定する。
   - CalDAVなどOSアカウント: `references/state-provisioning.md`を先に読む。
   - WKWebView内部: `references/webview-offload.md`を読み、可能ならブラウザで検証する。
   - 反復する回帰操作: XCUITestへ昇格する。一度きりの探索はidbを使う。

3. アプリをinstall/launchし、前面に出たことを確認する。

   ```bash
   xcrun simctl install "$SIM_UDID" ./Build/MyApp.app
   xcrun simctl launch --terminate-running-process "$SIM_UDID" com.example.MyApp
   scripts/sim-shot.sh --udid "$SIM_UDID" ~/tmp-sim/launch.png
   ```

4. 可能なら言語非依存の`AXUniqueId`で操作し、結果を検証する。

   ```bash
   scripts/sim-nav.py --list --udid "$SIM_UDID"
   scripts/sim-nav.py --id '<AXUniqueId>' --until-id '<next-id>' --udid "$SIM_UDID"
   scripts/sim-act.py '<label>' --until '<expected-label>' --udid "$SIM_UDID"
   ```

   `sim-act.py`は再試行するため、トグルなど非冪等操作には使わない。ラベルしかない一回タップは
   `sim-tap.py`、出現待ちは`sim-wait.py`を使う。

5. stdoutのJSON、終了コード、スクリーンショットまたは対象UDIDのログを合わせて成否を判定する。
   終了コードだけでは操作が当たったことにならないので、スクショ差分・`AXValue`・対象UDIDのログの
   いずれかで裏を取る。

## 実測で確定した境界

- `idb ui tap`は外れてもexit 0になりうる。操作後の状態差を別手段で確認する。
- AX frameはpoints、スクリーンショットはpixels。座標タップ時は`point = pixel / scale`。
  小さい要素はスクリーンショット換算よりAX frameを優先する。
- AX treeが要素1個かつframe 0だけなら、まず対象アプリが前面にいないことを疑う。
- screenshot/recordVideoの出力先を`/tmp`配下にすると`NSCocoaErrorDomain code=642`
  (`volume is read only`)で失敗する。ホーム配下の書き込み可能なディレクトリへ出す。
- `idb`が`No targets`を返すのはcompanion未接続。`idb connect <UDID>` →
  `idb list-targets`でsocketを確認する。端末側の異常と誤診しない。
- 仮想化リストは表示中要素しかAX treeに出ない。`sim-nav.py --scroll-max`を増やす。
- `idb ui text`は非ASCIIを送れず、失敗してもexit 0になりうる。日本語・絵文字・記号は
  `xcrun simctl pbcopy "$SIM_UDID"`とペーストを使う。詳細は`references/text-input.md`。
- SimulatorはmacOSのsystem proxyを継承する。HTTPSだけ失敗する場合は
  `references/system-proxy.md`と`scripts/sim-trust-ca.sh`を使い、ホスト全体のproxy設定を変更しない。
- `simctl keychain`はBooted端末、`simctl clone`のsourceはShutdown端末を要求する。同じcode 405でも
  実行コマンドを見て原因を分ける。
- 新品SimulatorのCalDAV初回追加にはOS側の罠がある。サーバーを調べる前に
  `references/state-provisioning.md`のseed/clone手順とDBでの判定を使う。
- `simctl io recordVideo`は静止区間で実時間と一致しないことがある。停止時は実PIDへSIGINTし、
  process exitをpollする。詳しくは`references/recording.md`。
- デモ動画は`setpts`で引き伸ばさず、止まっている区間を切る。要るのは実時間の忠実さではなく
  画面が動いている割合で、実測では先頭トリムが99%、`setpts`が64%だった。`setpts`は計測用途だけ。
- 複数端末のログはホスト側`log stream`で混ぜず、`xcrun simctl spawn <UDID> log ...`で分離する。
- 端末は作成者も用途も持たない(`simctl list -j`は`lastBootedAt`まで)。**名前がライフサイクル契約**で、
  使い捨ては`w-`、永続seedは`seed-`。`trap`で消す(`references/state-provisioning.md` §1-b)。
  既定名のまま放置した端末を作業台にしない —— `simctl clone`のsourceに選ばれて、
  案ごとの差が消えた実例がある。

## 同梱スクリプト

全scriptは`--help`を持つ。データはstdoutのJSON、診断はstderr。`--udid`または`SIM_UDID`を使う。

| script | 用途 |
|---|---|
| `scripts/sim-preflight.sh` | キーボード、proxy、idb、scale、競合の事前確認 |
| `scripts/sim-nav.py` | `AXUniqueId`探索・scroll・検証つきtap |
| `scripts/sim-tap.py` | ラベル部分一致の単発tap。事後検証なし |
| `scripts/sim-wait.py` | ラベルの出現・消失をpoll |
| `scripts/sim-act.py` | tap → assert → bounded retry |
| `scripts/sim-shot.sh` | screenshotとpixel/point/scale取得 |
| `scripts/sim-trust-ca.sh` | 対象端末だけへroot CAを追加。`--dry-run`あり |
| `scripts/sim-rec.sh` | 実時間が必要で録画中に操作しない場合のffmpeg録画 |
| `scripts/sim-reap.sh` | 使い捨て端末(`w-`)の棚卸しと回収。既定はdry-run |

## 必要なときだけ読むreferences

| reference | 読む条件 |
|---|---|
| `references/state-provisioning.md` | env/URL/cloneでタップを減らす、CalDAV seedを作る、`.mobileconfig`可否を判断する |
| `references/diagnosis.md` | `describe-all`が空・部分的、または`frame:{0,0,0,0}`で`AXLabel`が`null`の1要素だけ / 画面に見えている要素が走査に出ない / 長いリストの下側が出てこない / 座標タップが効かない(特に小さい要素) / タップ後にアプリがSpringBoardへ落ちる / 他プロセスの`xcodebuild`と同じ端末を取り合う |
| `references/text-input.md` | 非ASCII、IME、pbcopy、キーボード判定 |
| `references/system-proxy.md` | HTTPS/TLSだけ失敗、CA追加後も失敗 |
| `references/setup.md` | idb未導入、companion未接続 |
| `references/recording.md` | 録画の尺、デモの死に区間の切り方、停止、ffmpegとの選択 |
| `references/webview-offload.md` | WKWebViewをブラウザへ切り出して確認する |
