#!/usr/bin/env bash
# .icon を ictool で全 appearance モードにレンダリングする。
#
# これがこのスキルの要。Icon Composer は GUI だが、同梱の ictool は CLI で、
# Liquid Glass を適用した実際の見た目を PNG に書き出せる。
# つまり「作る → 見る → 直す」の反復を、Simulator も実機も起動せずに 10 秒で回せる。
# 光沢・屈折・影・各モードの色はすべてシステムが生成するので、
# 素材を見ているだけでは最終的な見た目は分からない。必ずこれで確認すること。
#
# 使い方:
#   render_icon.sh <path.icon> <出力ディレクトリ> [サイズ]
#
# 出力は 01-Default / 02-Dark / 03-ClearLight / 04-ClearDark / 05-TintedLight / 06-TintedDark。
# 番号を振ってあるのは、そのまま contact_sheet.swift に渡すと並び順が意図通りになるため。

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage: $0 <path.icon> <outDir> [size=400]" >&2
  exit 2
fi

ICON="$1"; OUT="$2"; SIZE="${3:-400}"
ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"

if [ ! -x "$ICTOOL" ]; then
  echo "error: ictool not found at $ICTOOL (Xcode 26+ required)" >&2
  exit 1
fi

mkdir -p "$OUT"

i=0
for r in Default Dark ClearLight ClearDark TintedLight TintedDark; do
  i=$((i + 1))
  f="$OUT/$(printf '%02d' $i)-$r.png"
  # tint-color / tint-strength は Tinted 系でのみ意味を持つ。他モードでは無視される。
  "$ICTOOL" "$ICON" --export-image --output-file "$f" \
    --platform iOS --rendition "$r" \
    --width "$SIZE" --height "$SIZE" --scale 1 \
    --tint-color 0.25 --tint-strength 0.75 >/dev/null 2>&1 || true
  if [ -f "$f" ]; then echo "OK   $r"; else echo "FAIL $r"; fi
done

echo "rendered to $OUT"
