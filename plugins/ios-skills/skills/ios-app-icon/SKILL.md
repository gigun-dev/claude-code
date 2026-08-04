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

# Liquid Glassアプリアイコンを作る

`.icon`は`icon.json`と`Assets/`からなるbundleで、GUIなしに生成できる。素材と最終renderは別物なので、
作成 → `ictool` render → 実サイズ比較のloopを必ず回す。

## 手順

1. デザインから始める場合は純正アイコンを抽出し、構図・配色・抽象度を比較する。

   ```bash
   scripts/extract_apple_icons.sh /tmp/apple-icons
   swift scripts/contact_sheet.swift /tmp/apple-icons /tmp/apple-sheet.png
   ```

   判断基準は`references/design-rules.md`を読む。blur、shadow、specular、bevel、glow、
   opacity/translucency effectはIcon Composerへ任せ、iOS角丸maskも素材へ焼かない。

   一方で**素材自身の色とその階調はsystemが作らない**。純正を実測するとbackgroundもlayerも
   多段gradientを持っており、全layerをベタ塗りにすると案が平坦になり、質感がすべてsystem由来に
   なって案ごとの違いが消える。gradient、重なりの合成、rim light、環境影を素材へ焼く判断と
   失敗パターンは`references/native-look.md`。焼いたときはsystem effectとの二重を
   6 appearanceで必ず確認する(rim lightはspecularに近いので特に)。

2. 素材の複雑さで経路を選ぶ。

   - 基本図形とpathで速く構図を作る: `scripts/draw_layers.swift <spec.json> <outDir>`。
     bbox実測とautofitを使えるが、余白が構図の一部なら`"autofit": false`も比較する。
   - gradient、mask、blur、blendが必要: 1つのSVGへ`data-layer`付きgroupを書き、
     `scripts/render_svg.swift <icon.svg> <outDir> --size 1024`で同一座標系のPNGへ分解する。
   - どちらも中央約81%の安全域を守る。SVG pathやJSON schemaの詳細はreferencesへ進む。

3. レイヤーを`.icon`へ組み立てる。`build_icon.sh`へは**手前から奥**の順で渡す。
   既存bundleを置換するときだけ`--force`を明示する。

   ```bash
   scripts/build_icon.sh AppIcon.icon '#312e81' \
     out/03-front.png out/02-mid.png out/01-back.png
   ```

   `_composite.png`にある要素が最終renderで消えた場合はlayer順を疑う。`icon.json`の詳細は
   `references/icon-json-schema.md`を読む。

4. 全appearanceをrenderし、複数案を実サイズで比較する。

   ```bash
   scripts/render_icon.sh AppIcon.icon /tmp/renders
   swift scripts/contact_sheet.swift /tmp/renders /tmp/modes.png
   ```

   Default / Dark / Clear Light / Clear Dark / Tinted Light / Tinted Darkの6種を確認する。
   3〜6案を並べ、120ptと80ptで潰れる案を落とす。render scriptが非0なら、一部画像があっても
   成功扱いにしない。

5. Xcodeへ組み込み、build productを検証する。XcodeGenでは`.icon`を単一fileとして扱う設定が必要。
   `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`、`Assets.car`、`CFBundleIconName`、actool warningを確認する。
   配置、XcodeGen、旧OS向けappiconset、生成元の除外は`references/xcode-integration.md`を読む。

6. 最終的にSimulatorまたは実機のホーム画面で確認する。system versionごとに効果が異なりうるため、
   サポート対象OSごとにappearanceを確認する。

## 同梱resource

| resource | 用途 |
|---|---|
| `scripts/render_svg.swift` | SVG/CSS → `data-layer`別の透過PNG |
| `scripts/draw_layers.swift` | JSON構図 → bbox/autofit付き透過PNG |
| `scripts/build_icon.sh` | PNG群 → `.icon`。既存置換は`--force`必須 |
| `scripts/render_icon.sh` | `.icon` → 6 appearance。失敗を非0で返す |
| `scripts/contact_sheet.swift` | 複数PNGを大/120pt/80ptで比較 |
| `scripts/flatten_icon.swift` | 旧形式appiconset向けflat 1024 PNG |
| `scripts/extract_apple_icons.sh` | Simulator runtimeから純正iconを抽出 |
| `references/design-rules.md` | システム効果との境界、安全域、構図の規則 |
| `references/native-look.md` | 素材へ焼くgradient/rim light/環境影のSVG recipe、純正の実測値、失敗パターン |
| `references/icon-json-schema.md` | layer順、FillValue、appearance、ictool |
| `references/xcode-integration.md` | Xcode/XcodeGen/appiconset/検証 |

各scriptの引数は`--help`で確認する。生成元のSVG/specはcommitし、アプリbundleからは除外する。
