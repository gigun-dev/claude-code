# システムプロキシが Simulator の TLS を全部落とす

**開くタイミング**: 端末で「**サーバの識別情報を検証できません**」が出た / HTTPS だけが静かに失敗する /
「サーバーが落ちている」ように見えるがサーバー側のログにリクエストが届いていない /
キャプチャツール(Proxyman・Charles・mitmproxy)を立てた状態で Simulator を検証している。

**先に `scripts/sim-preflight.sh` を実行していれば、この状態は警告として出る。**
出ていないなら、まずそちらを実行するほうが速い。

---

## 何が起きているか

**Simulator は macOS のシステムプロキシ設定を継承する。** Proxyman などが `127.0.0.1:9090` に
自分をプロキシとして設定していると **Simulator の通信も全部 MITM される**。
そして **新品の Simulator はそのルート CA を信頼していない**ので:

- Safari やアカウント追加で「**サーバの識別情報を検証できません**」ダイアログが出る
- アプリの通信は静かに失敗する(**HTTPS だけが落ちる**ので「サーバーが落ちている」ように見える)

アプリ側にはこう出る(**この文字列で grep できるように原文のまま置く**):

```
NSURLErrorDomain Code=-1200 "A TLS error caused the secure connection to fail."
# Safari で開くと: 接続はプライベートではありません / サーバの識別情報を検証できません
```

デバイスログにも痕跡が出る。**この3点セットが揃ったらプロキシを疑う**:

```
[C47 127.0.0.1:9090 ready parent-flow (satisfied (Path is satisfied), ... proxy ...)]
  ↓
SecTrustEvaluateIfNecessary
  ↓
Task <...> finished with error [-999]      # NSURLErrorCancelled = 信頼評価で切られた
```

⚠️ **ビルドが緑でアプリが起動することは、ネットワーク信頼について何も証明しない。**
実走行では「`make run` が通ってアプリが立ち上がった」ことが順調だという誤った手応えを作り、
TLS で詰まるまで7分かかった。**通信を伴う検証は、最初の1手の前にプロキシを見る。**

⚠️ **CA はローテーションする。更新されると、以前 CA を入れた端末が全部だまって無効になる。**
「前にこの端末で通ったから今日も通るはず」は成り立たない(2026-07-23 に OAuth を完走した端末が
2026-08-02 には `要認証` に戻っていた)。**端末の状態は腐る。記録には必ず「いつ時点か」を添える。**

## 対処: プロキシを落とすのではなく CA を端末に入れる

復号キャプチャも同時に取れるので一石二鳥。**プロキシを落として逃げるより、入れてしまう方が実験には有利。**

```bash
scripts/sim-trust-ca.sh --udid "$SIM_UDID"        # 冪等。--dry-run で何を入れるか確認できる
```

素で撃つなら:

```bash
xcrun simctl keychain <UDID> add-root-cert \
  "$HOME/Library/Application Support/com.proxyman.NSProxy/app-data/proxyman-ca.pem"
# `xcrun simctl keychain` のサブコマンドは add-root-cert / add-cert / reset の3つだけ
```

## 皮肉な注意点(次に誰かが必ず踏む)

**「キャプチャに使おうとしていた Proxyman が、そのまま交絡因子になった。」**

CalDAV やネットワークまわりを Simulator で検証するとき、「まずプロキシを立てて中身を見る」のは
**極めて自然な最初の一手**なので、**観測手段そのものが被験体を壊す**構図に入りやすい。
SKILL.md「診断の規律」1 の「環境要因を排除する前に立てた仮説は採用しない」の典型例。

> **Why not「じゃあプロキシが原因だった」で終わらせないか**: **CA を入れた端末でも
> CalDAV 初回追加の失敗は再現した。** プロキシは**別個の罠**であって主症状の原因ではなかった。
> CAでTLSが直ってもCalDAV初回追加が失敗する場合は、別の端末状態問題として
> `state-provisioning.md`のseed手順を確認する。
