#!/usr/bin/env bash
# インストール済み Simulator ランタイムから、Apple 純正アプリのアイコン素材を抽出する。
#
# なぜこれが効くか:
# 「モダンなアイコンを作って」と言われて手が止まるのは、参照する設計言語が無いから。
# 純正アイコンを実際に並べて見ると、思い込みが具体的に壊れる。実例:
#   - 背景は白/淡色が主流(カレンダー・リマインダー・ヘルス・ファイル)。
#     ブランド色のベタ塗り一択は古い。ベタ塗りはメッセージなど一部だけ。
#   - 前景は多色でよい(リマインダーの青赤橙、ウォレットの3色カード)。
#   - カレンダーは日付を数字でなくドット格子で抽象化する。意味を説明しない。
#   - ショートカットは半透明の角丸菱形が2枚重なるだけ。重なりの透過そのものがデザイン。
#     Liquid Glass は重なりを屈折させるので、この語彙が最も「iOS 26 らしく」出る。
#
# 取れるのは AppIcon60x60@2x.png(120px・Liquid Glass 適用前のフラット素材)。
# 小さいが、構図・配色・抽象度を読むには十分。
#
# 使い方:
#   extract_apple_icons.sh <出力ディレクトリ> [アプリ名...]
# アプリ名を省略すると代表的なものを集める。
# 抽出後 contact_sheet.swift に通すと一覧で比較できる。

set -euo pipefail

OUT="${1:?usage: $0 <outDir> [AppName...]}"
shift || true

DEFAULT_APPS=(MobileSMS MobileCal Reminders MobileNotes Music AppStore Weather Maps
              Podcasts MobileTimer Health Shortcuts Passbook Freeform Journal Files
              Preferences Camera MobileMail Photos Stocks Home)
APPS=("$@")
[ ${#APPS[@]} -eq 0 ] && APPS=("${DEFAULT_APPS[@]}")

# ランタイムは Xcode 同梱と、別ボリュームにマウントされる新形式の2系統がある。
RUNTIME_DIR=$(find /Library/Developer/CoreSimulator/Volumes \
                   /Library/Developer/CoreSimulator/Profiles/Runtimes \
                   /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Library/Developer/CoreSimulator/Profiles/Runtimes \
                   -maxdepth 6 -name "*.simruntime" 2>/dev/null | head -1)

if [ -z "$RUNTIME_DIR" ]; then
  echo "error: no iOS simruntime found. Install a Simulator runtime via Xcode." >&2
  exit 1
fi

APP_DIR="$RUNTIME_DIR/Contents/Resources/RuntimeRoot/Applications"
if [ ! -d "$APP_DIR" ]; then
  echo "error: Applications dir not found under $RUNTIME_DIR" >&2
  exit 1
fi

echo "runtime: $RUNTIME_DIR"
mkdir -p "$OUT"

i=0
for app in "${APPS[@]}"; do
  f="$APP_DIR/$app.app/AppIcon60x60@2x.png"
  if [ -f "$f" ]; then
    i=$((i + 1))
    cp "$f" "$OUT/$(printf '%02d' $i)-$app.png"
  fi
done

echo "extracted $i icons to $OUT"
[ $i -eq 0 ] && echo "(none matched — アプリ名は MobileSMS / MobileCal のような内部名で指定する)" >&2
exit 0
