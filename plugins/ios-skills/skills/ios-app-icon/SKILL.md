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

素材と最終renderは別物。作成 → `ictool` render → 実サイズ比較のloopを必ず回す。

## Operating Posture

iOS 26のホーム画面に並べて古く見えないかだけを見る、目の厳しいアイコンデザイナーとして振る舞う。
既定は通さないこと —— 素材を描く前に下のゲートで落とす。**モチーフを振り直す判断だけで終えてよく、
PNGが0枚でも失敗ではない。**

失敗モードは3つ。**上ほど重い。**

1. **一世代前の設計言語のまま作り切る。** 手順は全部通り6 appearanceも出るのに、ホーム画面へ
   置くと古い。手順の中では検出できないので、**描く前のゲートだけが止められる場所**になる。
2. **はみ出しと潰れを目で判断する。** 回転は外接矩形を対角へ膨らませるため見積もれず、実地では
   右端1024pxまで溢れたまま**3世代連続で見落とした**。bboxを実測する。
3. **素材の見た目で採否を決める。** `_composite.png`とictool通過後は別物で、1024pxで成立して
   いても80ptで潰れる。

## 描く前のゲート

素材を1枚でも描く前に通す。**該当したらモチーフを振り直す**(根拠は`references/design-rules.md`)。

| 該当 | 直し方 |
|---|---|
| 意味を説明する絵(吹き出し=チャット、リング=カレンダー) | 説明的ピクトグラムは古びる。抽象的な記号と構成で成立させる(純正のカレンダーは数字でなくドット格子) |
| シェイプが5個以上、または細い線・小さい形がある | 屈折が汚れる(Appleが最多の失敗として名指し)。2〜4個へ削る |
| 文字・数字・ロゴタイプがある | 形へ置き換える(SVGを使うならアウトライン化) |
| 前景が濃色・多色 | Tintedでコントラストを失う。前景は白〜near-whiteの単色にする |
| 純正アイコンをまだ並べていない | 思い込み(たいてい一世代前)に沿った案しか出ない。手順1を先に回す |

## 手順

1. デザインから始める場合は純正アイコンを抽出し、構図・配色・抽象度を比較する。

   ```bash
   scripts/extract_apple_icons.sh /tmp/apple-icons
   swift scripts/contact_sheet.swift /tmp/apple-icons /tmp/apple-sheet.png
   ```

   blur、shadow、specular、bevel、glow、opacity/translucency effect、iOS角丸maskは
   素材へ焼かずIcon Composerへ任せる。一方で**素材自身の色とその階調はsystemが作らない** ——
   全layerをベタ塗りにすると案ごとの違いが消える。gradient、重なりの合成、rim light、環境影を
   焼く判断と失敗パターンは`references/native-look.md`。焼いたら6 appearanceで
   system effectとの二重を確認する(rim lightはspecularに近いので特に)。

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

6. 最終的にSimulatorまたは実機のホーム画面で確認する。効果はsystem versionで異なりうるので、
   サポート対象OSごとにappearanceを確認する。

## 同梱resource

手順で使う`scripts/`(`render_svg` / `draw_layers` / `build_icon` / `render_icon` /
`contact_sheet` / `extract_apple_icons`)の引数は`--help`で確認する。
`scripts/flatten_icon.swift`は旧形式appiconset向けのflat 1024 PNGを作る。
生成元のSVG/specはcommitし、アプリbundleからは除外する。

| reference | 読む条件 |
|---|---|
| `references/design-rules.md` | ゲート各項目の根拠、安全域、構図の規則、案の出し方 |
| `references/native-look.md` | 素材へ焼くgradient/rim light/環境影のSVG recipe、純正の実測値、失敗パターン |
| `references/icon-json-schema.md` | layer順、FillValue、appearance、ictool |
| `references/xcode-integration.md` | Xcode/XcodeGen/appiconset/検証 |
