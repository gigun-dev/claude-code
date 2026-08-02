# Simulatorの状態プロビジョニング

UI操作を始める前に、env、URL scheme、cloneでタップを減らす。OSアカウントとKeychainは
アプリのenvでは作れないため、seed端末を一度作ってcloneする。

## 1. アプリ内状態は`SIMCTL_CHILD_*`で注入する

```bash
SIMCTL_CHILD_MYAPP_API_KEY="$SOME_KEY" \
SIMCTL_CHILD_MYAPP_SPIKE=todos \
  xcrun simctl launch --terminate-running-process "$SIM_UDID" com.example.MyApp
```

`SIMCTL_CHILD_`を外した名前がアプリの`ProcessInfo.processInfo.environment`へ届く。
資格情報、接続先、到達画面のdebug hookを分離し、release buildでは無効化する。

注入後は画面か対象UDIDのログで効果を確認する。期待結果が出ただけではenvとの因果を示さないため、
flagなしの対照か、実際にenvを読むコードpathを確認する。OSアカウント、Keychain、設定アプリには届かない。

起動後に何度も状態を変えるなら、アプリ固有URL schemeも使える。

```bash
xcrun simctl openurl "$SIM_UDID" 'myapp://add-server?name=x&url=https%3A%2F%2Fexample.com'
```

## 2. OS状態はseedを`simctl clone`する

Keychain、Accounts database、インストール済みapp、UserDefaultsなどを一度だけseedへ用意し、複製する。
clone sourceはShutdown必須、clone先は`bootstatus -b`でboot完了まで待つ。

```bash
SEED='<seed-UDID>'
xcrun simctl shutdown "$SEED"
NEW="$(xcrun simctl clone "$SEED" 'Worker-01')"
xcrun simctl bootstatus "$NEW" -b
printf '%s\n' "$NEW"
```

実測ではshutdown 1.8秒、clone 4.8秒、bootstatus 10.1秒、合計16.7秒だった。環境により変動する。
Keychainとアカウントも複製されるので、実credentialを含むseedをCIへ持ち込まず、アクセスを限定する。
seedを更新するとき以外はShutdownで保管する。

clone後の状態は、DB/fileの存在だけでなくアプリを起動して実際に認証・同期できることまで確認する。
`get_app_container`がclone直後にsource側pathを返す場合は、clone側の実pathも確認する。

## 3. `.mobileconfig`をSimulatorのアカウント投入に使わない

Simulatorではprofile install UIが「完了」を表示しても、CalDAVやSubscribed Calendarなど
アカウント系payloadが`Accounts3.sqlite`へ作成されないことを確認済み。配送成功とpayload適用は別物。
実機向けprofileとしては有効だが、SimulatorのOSアカウント投入には使わずseed/cloneを使う。

適用可否を調べる場合はUI表示でなくprofile storeと対象subsystemのdatabaseを確認する。
非アカウント系payloadはこの結果から一括して不可能とは判断しない。

## 4. CalDAVアカウント入りseedを作る

新品Simulatorでは、server検証が成功しても初回CalDAV追加のdata class toggleが空になり、
停止中アカウントになることがある。これは他社serverでも再現したOS側の状態依存で、
serverのRFC実装を調べる前に端末側を切り分ける。

確認済みの回避は、ユーザー追加のSubscribed Calendarを先に1件作ってからCalDAVを追加すること。
最初から存在する`HolidayCalDaemonAccount`は代用にならない。

### 一度だけseedを作る

1. 端末をcreateし、boot完了後にpreflightする。

   ```bash
   SEED="$(xcrun simctl create 'CalDAV-Seed' '<device-type>' '<runtime>')"
   xcrun simctl bootstatus "$SEED" -b
   scripts/sim-preflight.sh --udid "$SEED"
   ```

2. system proxyが有効なら`scripts/sim-trust-ca.sh --udid "$SEED"`を使う。host全体のproxyを変更しない。

3. 公開ICSを`webcal://`で開き、Subscribed Calendarを追加する。Calendar appの初回起動は遅いため、
   固定4秒で失敗判定せず、画面を確認する。購読確定の要素がAX treeに出ない場合は
   `sim-shot.sh`のscaleを使って座標をpointsへ変換する。

   ```bash
   xcrun simctl openurl "$SEED" 'webcal://<public-ics-url>'
   ```

4. 設定アプリからCalDAVを追加する。iOS 26ではCalendar account画面への安定したdeep linkを
   確認できていないため、`App-prefs:root=General`で設定を前面化し、AX identifierを優先して辿る。

   ```text
   com.apple.settings.apps → com.apple.mobilecal → ACCOUNTS → ADD_ACCOUNT
   ```

   以降はidentifierがない項目があるため、ラベルまたはスクリーンショットで確認する。
   credential入力は`references/text-input.md`のpbcopy経路を使う。

5. UIの同名表示でなく`Accounts3.sqlite`をtype JOINして確認する。

   ```bash
   DB="$HOME/Library/Developer/CoreSimulator/Devices/$SEED/data/Library/Accounts/Accounts3.sqlite"
   sqlite3 "$DB" \
     'SELECT a.Z_PK,t.ZACCOUNTTYPEDESCRIPTION,a.ZUSERNAME,a.ZACCOUNTDESCRIPTION,a.ZACTIVE
        FROM ZACCOUNT a LEFT JOIN ZACCOUNTTYPE t ON a.ZACCOUNTTYPE=t.Z_PK;'
   sqlite3 "$DB" 'SELECT * FROM Z_2ENABLEDDATACLASSES;'
   ```

   system由来とユーザー追加の「日本の祝日」が同名で並ぶことがあるため、descriptionだけで判定しない。
   アカウントrowとenabled data classesの両方を確認し、実際の同期まで試す。

6. seedをshutdownし、以後は§2のcloneだけを使う。壊れたworkerはseedから作り直す。

## 5. 手段の選択

| 作る状態 | 手段 |
|---|---|
| API key、接続先、到達画面 | debug限定`SIMCTL_CHILD_*` |
| 起動後に繰り返すapp内遷移 | app固有URL scheme |
| OS account、Keychain、設定済み端末 | seed + `simctl clone` |
| 実機のmanaged configuration | `.mobileconfig` |
| SimulatorのCalDAV account | Subscribed Calendarでseedを用意し、以後clone |

直接`Accounts3.sqlite`を書き換える方法はschema・Keychain・accountsd cacheを同時に壊しうるため使わない。
反復検証のため設定アプリ操作を自動化するより、seedを一度作ってcloneする方を優先する。
