# Xcode / XcodeGen への組み込みと落とし穴

## 置き場所と設定

```
Sources/.../Resources/
├── AppIcon.icon/                       iOS 26+ の Liquid Glass 本体
│   ├── icon.json
│   └── Assets/*.png
└── Assets.xcassets/
    └── AppIcon.appiconset/             旧 OS 用フォールバック(任意)
        ├── Contents.json
        └── AppIcon-1024.png
```

ビルド設定に**アイコン名の指定が必要**:

```
ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon
```

Xcode が新規プロジェクトに自動で入れる設定だが、XcodeGen の素の target には付かない。
無いと素材を同梱しても actool がどれを採用するか分からず、**アイコンが空のままビルドが通る**。

## 落とし穴1: XcodeGen が .icon を展開してしまう

`.icon` は拡張子付きのディレクトリなので、XcodeGen は既定で中身を個別ファイルとして
登録する。すると `icon.json` と各レイヤー PNG がバラバラの resource として
Copy Bundle Resources に入り、Xcode はパッケージとして認識できずアイコンが反映されない。

`project.yml` で単一ファイル扱いを宣言する([XcodeGen #1556](https://github.com/yonaskolb/XcodeGen/issues/1556)):

```yaml
options:
  fileTypes:
    "icon":
      file: true
```

## 落とし穴2: appiconset の single-size は `scale` でなく `size`

Xcode 15+ は 1024 の 1 枚だけで全サイズを賄えるが、`Contents.json` の書き方を間違えると
**警告だけ出して画像が無視され、ビルドは成功する**(アイコンが空のまま気づけない)。

失敗する書き方:

```json
{ "filename":"AppIcon-1024.png", "idiom":"universal", "platform":"ios", "scale":"1x" }
```

```
warning: The app icon set "AppIcon" has an unassigned child.
```

正しい書き方 —— `scale` ではなく `size` を書く:

```json
{
  "images" : [
    { "filename" : "AppIcon-1024.png", "idiom" : "universal",
      "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
```

`Assets.xcassets/` 直下にも `Contents.json`(`info` だけ)が要る。

## .icon と appiconset は共存できる

両方置いても競合しない。actool に両方が渡され、`--app-icon AppIcon` で一括処理される。
検証時に確認できること:

- `Assets.car` に `.icon` のレンダリング済みバリアントが入る(サイズが数 MB 単位で増える)
- バンドル直下に `AppIcon60x60@2x.png` / `AppIcon76x76@2x~ipad.png` が生成される
  —— **旧 OS 用のフラット版は Xcode が自動生成する**
- `Info.plist` に `CFBundleIconName = AppIcon` が入る

つまり `.icon` だけでも旧 OS は賄える。appiconset は deploymentTarget が古く
確実を期したいときの保険。

## 組み込み後の検証コマンド

```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -name "YourApp.app" -path "*Debug-iphonesimulator*" | head -1)

# アイコンが焼き込まれたか
test -f "$APP/Assets.car" && stat -f%z "$APP/Assets.car"
/usr/libexec/PlistBuddy -c "Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName" "$APP/Info.plist"

# actool が素材を無視していないか(ビルドログ)
grep -E "warning: The app icon|CompileAssetCatalog" build.log
```

`Assets.car` が無い / `CFBundleIconName` が無い場合は素材が採用されていない。
ビルドログの `actool` 行に `--app-icon` が渡っているか、警告が出ていないかを見る。

## 参考: 実機での確認

`ictool` のレンダリングと実機の見た目は基本的に一致するが、最終確認は実機が確実。
Liquid Glass が効くのは iOS 26 以降。実機の OS バージョンは:

```bash
xcrun devicectl list devices --json-output /tmp/d.json
python3 -c "import json;d=json.load(open('/tmp/d.json'));[print(x['deviceProperties']['name'],x['deviceProperties'].get('osVersionNumber')) for x in d['result']['devices']]"
```

実機のスクリーンショットは `devicectl` からは取得できないので、ホーム画面の確認は
人の目に頼ることになる。Simulator なら `xcrun simctl io booted screenshot` で撮れる。
