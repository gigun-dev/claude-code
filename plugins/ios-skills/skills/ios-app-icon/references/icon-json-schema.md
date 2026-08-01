# icon.json スキーマ(.icon バンドルの中身)

`.icon` は拡張子付きのディレクトリ(macOS のパッケージ)で、中身はこれだけ:

```
AppIcon.icon/
├── icon.json          構造と効果の定義
└── Assets/
    ├── 01-back.png    レイヤー画像(SVG も可)
    └── 02-front.png
```

**Icon Composer.app(GUI)を開かなくても、この2つを書けば完全な .icon になる。**
出典: [unofficial-apple-icon-composer-json-schema](https://github.com/dfabulich/unofficial-apple-icon-composer-json-schema)
(Apple は公式スキーマを公開していない。上記は実際のバンドルから起こされたもので、
`ictool` に通して検証すれば正しさを確認できる)

## 最小構成

背景は画像不要で、`fill` に色を書くだけでよい。前景だけ透過 PNG を置く。

```json
{
  "fill" : { "solid" : "srgb:0.19216,0.18039,0.50588,1.00000" },
  "groups" : [
    {
      "name" : "Main",
      "specular" : true,
      "layers" : [
        { "image-name" : "01-front.png", "name" : "Front", "glass" : true }
      ]
    }
  ],
  "supported-platforms" : { "squares" : "shared" }
}
```

## トップレベル

| キー | 型 | 説明 |
| --- | --- | --- |
| `groups` | Group[] | 必須。**先頭が最前面**(手前→奥の順。下記の注意を読むこと) |
| `supported-platforms` | object | 必須。`{"squares":"shared"}` が iOS/macOS 共用。watchOS の円形は `{"circles":["watchOS"]}` |
| `fill` | FillValue | 背景。省略すると背景なし |
| `fill-specializations` | Specialization[] | appearance ごとに背景を変える |
| `color-space-for-untagged-svg-colors` | string | `srgb` / `display-p3` / `extended-gray` |

## Group

Liquid Glass の効果は**グループ単位**で効く。だから「ガラスにしたい層」と
「ガラスにしたくない層(既にレンダリング済みのラスター画像・ウォーターマーク等)」は
別グループに分ける。

| キー | 型 | 説明 |
| --- | --- | --- |
| `layers` | Layer[] | 必須 |
| `name` | string | 表示名 |
| `specular` | bool | 鏡面ハイライト。iOS 27 では内外どちらに出すかをシステムが自動判断する |
| `blur-material` | number\|null | すりガラス感 |
| `translucency` | `{enabled,value}` | 透過。**背景側にだけ使うと可読性が保てる**(前景に強くかけると沈む) |
| `shadow` | `{kind,opacity}` | kind は `neutral` / `layer-color` / `none` |
| `lighting` | string | `combined` / `individual` |
| `opacity`, `blend-mode`, `hidden`, `position` | | |

`*-specializations` で appearance(`dark` / `tinted`)や idiom ごとに上書きできる。

## ★重なり順は「先頭が最前面」(実測・間違えやすい)

`groups` も `layers` も、**配列の先頭に書いたものが一番手前に描かれる**。
CSS や Photoshop のレイヤーパネルと同じ向きで、描画順(先に描いたものが奥)とは**逆**。

これを取り違えると **奥に置いたつもりの大きな面が最前面に来て、手前に置いたつもりの
小さい要素を完全に覆い隠す**。しかもエラーも警告も出ず「素材には描いてあるのに
レンダリングでは消える」という形で出るので、素材側や translucency を疑って時間を溶かす。

切り分け方: `draw_layers.swift` が出す `_composite.png` に要素が写っているのに
`ictool` の出力から消えていたら、まず重なり順を疑う。配列を逆順にして再レンダリングすれば
1回で確定する。

```jsonc
"layers": [
  { "image-name": "03-front.png", ... },  // ← 最前面
  { "image-name": "02-mid.png",   ... },
  { "image-name": "01-back.png",  ... }   // ← 最背面(背景 fill のすぐ上)
]
```

## Layer

| キー | 型 | 説明 |
| --- | --- | --- |
| `image-name` | string | 必須。`Assets/` 内のファイル名(**拡張子込み**) |
| `name` | string | 必須。表示名 |
| `glass` | bool | このレイヤーをガラスとして扱うか |
| `fill` | FillValue | 画像のアルファを色で塗る。素材を白一色で作っておき色は JSON 側で決める、という運用ができる |
| `position` | `{scale, translation-in-points}` | |
| `opacity`, `blend-mode`, `hidden` | | |

## FillValue

```json
{ "solid": "srgb:0.5,0.5,0.5,1.0" }
{ "linear-gradient": ["srgb:...", "srgb:..."],
  "orientation": { "start": {"x":0,"y":0}, "stop": {"x":0,"y":1} } }
{ "automatic-gradient": "srgb:..." }
"automatic" | "system-dark" | "system-light" | "none"
```

色は `"srgb:R,G,B,A"` で各成分 0..1 の小数。`#4f46e5` なら
`srgb:0.30980,0.27451,0.89804,1.00000`。

## ictool(CLI レンダラ)

```
/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool
```

```bash
ictool AppIcon.icon --export-image --output-file out.png \
  --platform iOS --rendition TintedDark \
  --width 1024 --height 1024 --scale 1 \
  --tint-color 0.25 --tint-strength 0.75
```

`--rendition` に指定できるのは `Default` / `Dark` / `ClearLight` / `ClearDark` /
`TintedLight` / `TintedDark`。**出力には iOS の角丸マスクがかかった状態**で書き出される
(appiconset 用のフラット画像として流用してはいけない)。

`--platform` は `iOS` / `macOS` / `watchOS`。
