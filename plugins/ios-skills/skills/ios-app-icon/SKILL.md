---
name: ios-app-icon
description: >-
  iOS 26/27 の Liquid Glass アプリアイコン(.icon / Icon Composer 形式)を GUI
  なしで生成・検証し、Xcode プロジェクトへ組み込む。「アプリアイコンを作って/変えて」「AppIcon
  を設定したい」「ビルドしてもアイコンが反映されない」と言われたとき、および .icon / icon.json / ictool /
  appiconset といった語が出たときに使う。アプリのアイコンが話題なら Liquid Glass と明示されなくても参照する(SF
  Symbols・favicon・UI の glassEffect() は対象外)。
compatibility: >-
  macOS + Xcode 26 以降(ictool と Icon Composer が同梱される)。素材の描画に
  swift(CoreGraphics)を使うため Xcode のツールチェーンが要る。Icon Composer.app の GUI を使う場合のみ
  macOS Tahoe 26.4+。
---

# iOS アプリアイコン(Liquid Glass / .icon)

iOS 26 以降のアイコンは `.icon`(Icon Composer 形式)で作る。**Icon Composer.app は GUI だが、
中身は `icon.json` + `Assets/` のディレクトリでしかないので、すべてコードから生成できる。**
さらに同梱の `ictool` で Liquid Glass 適用後の実際の見た目を CLI で書き出せるため、
Simulator も実機も起動せずに「作る → 見る → 直す」を 10 秒で回せる。

このスキルの価値はその反復ループにある。素材の見た目と最終的な見た目は別物なので、
**レンダリングして目で見るまで判断しない**のが最も重要な原則になる。

## 前提

- Xcode 26 以降(`ictool` と Icon Composer が同梱される)
- macOS Tahoe 26.4+(Icon Composer.app の GUI を使う場合のみ)
- SVG 変換ツールは不要。素材は CoreGraphics で描く(`scripts/draw_layers.swift`)

## 進め方

### 1. 参照を作る(デザインから始める場合)

先に純正アイコンを並べて見る。これを飛ばすと、たいてい一世代前の設計言語
(意味を説明するピクトグラム)に沿った案しか出てこない。

```bash
bash scripts/extract_apple_icons.sh /tmp/apple-icons
swift scripts/contact_sheet.swift /tmp/apple-icons /tmp/apple-sheet.png
```

読み取れることは `references/design-rules.md` にまとめてある。要点だけ言うと、
iOS 26 の純正は「背景が白/淡色 + 前景が多色」が主流で、意味を説明せず、
**重なりの透過そのものをデザインにしている**(ショートカットが典型)。

### 2. 素材を作る

構図を JSON で書き、レイヤーごとの透過 PNG を生成する。背景は画像不要
(`icon.json` の `fill` に色を書く)。

```json
{
  "canvas": 1024,
  "safeMargin": 96,
  "autofit": true,
  "layers": [
    { "name": "01-back",  "shape": "roundedRect",
      "cx": 452, "cy": 468, "w": 620, "h": 486, "r": 128, "angle": -6, "color": "#ffffff" },
    { "name": "02-mid",   "shape": "roundedRect",
      "cx": 652, "cy": 664, "w": 356, "h": 268, "r": 70,  "angle": 13, "color": "#fbbf24" },
    { "name": "03-front", "shape": "circle",
      "cx": 790, "cy": 806, "d": 210, "color": "#6366f1" }
  ]
}
```

```bash
swift scripts/draw_layers.swift spec.json out/
# → bbox=(96,198)-(928,827) size=832x630 center=(512,512) SAFE
```

座標は左上原点・上から測った y で書く(デザインツールと同じ感覚)。
`autofit` が bbox を実測して中央寄せ + 安全域いっぱいへスケールするので、
**構図の相対関係だけ考えればよく、絶対座標を詰める必要はない**。
はみ出しは目で判断すると必ず失敗する(理由は `references/design-rules.md` 末尾)。

素材に光沢・影・ぼかし・角丸マスクを描かないこと。システムが付けるので二重になる。

#### 面を積むのに飽きたら「1本の線」で考える

`shape` は `roundedRect` / `circle` / `ring` / `arc` / `capsule` / `path` の6つだが、
**プリミティブを N 個積む構成だけで案を出し続けると、どのアプリでも似た絵になる**
(実際、別々のアプリで作った案が見分けられないところまで行った)。行き詰まったら
`path` に切り替える。`d` は SVG のパスコマンドをほぼ全部解釈する(M L H V C S Q T A Z、
相対版と圧縮記法も可)ので、デザインツールや生成 AI が吐いた `d` をそのまま貼れる。

```json
{ "name": "01", "shape": "path", "cx": 512, "cy": 512, "w": 880, "viewBox": 1000,
  "d": "M120 300H880A100 100 0 010 500...", "thickness": 96, "color": "#f4f2ec" }
```

| キー | 効果 |
| --- | --- |
| `viewBox` | `d` が前提とする正方 viewBox の一辺。`w` との比が拡大率になる |
| `thickness` | **書くと塗りではなく線で描く**(端・角は丸)。渦巻き・蛇行リボンのような「一定の太さの1本の線」はこれでしか作れない — 塗りで作ると輪郭のオフセット曲線を手書きする羽目になる |
| `fillRule: "evenOdd"` | 重なりを穴にする。1つのパスで穴あきの形を作るのに要る |

規則的に折り返す長い線(角型スパイラル、蛇行する走査線)は手で書くより**生成したほうが速い**。
折れ線の頂点列を作り、各頂点を半径 r の円弧で丸めて `d` に落とすだけで済む。
角を丸めるときは「頂点の手前 r で止めて次の辺の r 先へ `A` で繋ぐ」、
SVG は y 下向きなので外積が正なら `sweep-flag` は 1。

### 3. .icon にしてレンダリングする

```bash
bash scripts/build_icon.sh AppIcon.icon '#312e81' out/01-back.png out/02-mid.png out/03-front.png
bash scripts/render_icon.sh AppIcon.icon /tmp/renders
swift scripts/contact_sheet.swift /tmp/renders /tmp/modes.png
```

6モード(Default / Dark / Clear Light / Clear Dark / Tinted Light / Tinted Dark)が出る。
Tinted で前景が沈む場合は前景を白に寄せる。効果の数値を変えたいときは
生成された `icon.json` を直接編集してよい(スキーマは `references/icon-json-schema.md`)。

### 4. 複数案を比較する

1案ずつ見ると全部それなりに見えるので、3〜6案を並べて判断する。
`contact_sheet.swift` は各案を「大 + 120pt + 80pt」で並べる。
**実サイズで潰れる案は落とす** —— 1024px で成立していても 80pt で読めない案は多い
(3枚以上重ねた案はだいたいこれで落ちる)。

人に見せるときは自己評価を添える。どれが良いと思うか、なぜか、どこが弱いか。
そして**難点が分かっているものは見せる前に直す**。

### 5. プロジェクトへ組み込む

`.icon` を `Sources/.../Resources/` などソースに含まれる場所へ置き、ビルド設定に
`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` を入れる。

**XcodeGen を使っている場合は `project.yml` にこれが必須**:

```yaml
options:
  fileTypes:
    "icon":
      file: true
```

無いと `.icon` がディレクトリとして展開され、パッケージとして認識されずアイコンが出ない。

旧 OS 用のフラット版は Xcode が自動生成するので appiconset は必須ではない。
確実を期すなら `flatten_icon.swift` で作って `AppIcon.appiconset` に置く
(このとき `Contents.json` は `scale` ではなく **`size`** を書く。間違えると
警告だけ出て無言で無視される)。

詳細と検証コマンドは `references/xcode-integration.md`。

### 6. 検証する

```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -name "YourApp.app" -path "*Debug-iphonesimulator*" | head -1)
test -f "$APP/Assets.car" && stat -f%z "$APP/Assets.car"
/usr/libexec/PlistBuddy -c "Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName" "$APP/Info.plist"
```

`Assets.car` が無い、`CFBundleIconName` が無い、ビルドログに
`warning: The app icon set "AppIcon" has an unassigned child` が出ている場合は
素材が採用されていない。

## 画像生成 AI を使う場合

gpt-image などは**構図の発想を広げる用途では有効**だが、返るのは合成済みラスター1枚で
レイヤーに分解できない。有効なのは分業:

1. 「ベタ塗り背景 + 白い平面シルエットが数個、光沢・影・3D・角丸マスクなし、
   1024×1024 フルブリード」と**制約を明示して**案を出させる
   (制約を書かないと必ずテカリと立体表現が乗る)
2. 気に入った構図を選び、`draw_layers.swift` で透過レイヤーとして描き起こす
3. `.icon` にして `ictool` で確認

生成物をそのまま appiconset に入れることもできるが、レイヤー分離を捨てるので
Liquid Glass の効果は浅くなる。

## スクリプト

| スクリプト | 用途 |
| --- | --- |
| `scripts/draw_layers.swift` | 構図 JSON → レイヤー PNG。bbox 実測 + autofit + 安全域検査 |
| `scripts/build_icon.sh` | レイヤー PNG 群 → `.icon` バンドル |
| `scripts/render_icon.sh` | `.icon` → 全6モードの PNG(ictool) |
| `scripts/contact_sheet.swift` | 複数 PNG → 比較シート(大 + 実サイズ) |
| `scripts/flatten_icon.swift` | レイヤー → appiconset 用フラット 1024 |
| `scripts/extract_apple_icons.sh` | Simulator ランタイムから純正アイコンを抽出 |

## 参考資料

| ファイル | 内容 |
| --- | --- |
| `references/icon-json-schema.md` | `icon.json` の全キー、FillValue、ictool の使い方 |
| `references/design-rules.md` | 描いてはいけないもの、iOS 26 の設計言語、案の出し方 |
| `references/xcode-integration.md` | XcodeGen / appiconset の落とし穴、検証コマンド |

一次資料: [WWDC26 s8012](https://developer.apple.com/videos/play/wwdc2026/8012/) /
[WWDC25 s361](https://developer.apple.com/videos/play/wwdc2025/361/) /
[icon.json スキーマ(非公式)](https://github.com/dfabulich/unofficial-apple-icon-composer-json-schema)

## iOS 27 について

iOS 26 向けに作った `.icon` は**再オーサリング不要**。新しいレンダリングが自動適用され、
再コンパイルすら要らない。ただし iOS 27 は透過度を下げる方向に変わっており、これは
自動ではないので、アイコンごとに見直すとよい。
