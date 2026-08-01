#!/usr/bin/env bash
# レイヤー PNG 群から .icon バンドル(Icon Composer 形式)を組み立てる。
#
# .icon は拡張子こそ付いているが実体はディレクトリで、中身は icon.json + Assets/ だけ。
# つまり Icon Composer.app(GUI)を開かなくてもプログラムから完全に生成できる。
# スキーマの出典: https://github.com/dfabulich/unofficial-apple-icon-composer-json-schema
#
# 使い方:
#   build_icon.sh <出力先.icon> <背景色hex> <レイヤーPNG...>
# 例:
#   build_icon.sh AppIcon.icon '#312e81' out/01-back.png out/02-mid.png out/03-front.png
#
# 【重なり順・間違えやすい】icon.json の layers は **先頭が最前面**(手前→奥)。
# CSS や Photoshop のレイヤーパネルと同じ向きで、描画順(先に描いたものが奥)とは逆。
# したがってこのスクリプトにも **手前から順に** ファイルを渡す。
#   build_icon.sh out.icon '#fff' 03-front.png 02-mid.png 01-back.png
# 逆に渡すと、奥に置いたつもりの大きな面が最前面に来て手前の要素を覆い隠す。
# エラーも警告も出ず「素材には描いてあるのにレンダリングでは消える」形で出るので、
# _composite.png に写っているのに ictool の出力から消えていたら、まずここを疑う。

set -euo pipefail

if [ $# -lt 3 ]; then
  echo "usage: $0 <output.icon> <background-hex> <layer.png> [layer.png ...]" >&2
  exit 2
fi

OUT="$1"; BG="$2"; shift 2

# icon.json の色は "srgb:R,G,B,A"(各成分 0..1 の小数)で書く。#rrggbb から変換する。
hex_to_srgb() {
  local h="${1#\#}"
  printf 'srgb:%.5f,%.5f,%.5f,1.00000' \
    "$(echo "ibase=16; $(echo "${h:0:2}" | tr 'a-f' 'A-F')" | bc | awk '{print $1/255}')" \
    "$(echo "ibase=16; $(echo "${h:2:2}" | tr 'a-f' 'A-F')" | bc | awk '{print $1/255}')" \
    "$(echo "ibase=16; $(echo "${h:4:2}" | tr 'a-f' 'A-F')" | bc | awk '{print $1/255}')"
}

rm -rf "$OUT"
mkdir -p "$OUT/Assets"

LAYERS=""
i=0
for f in "$@"; do
  i=$((i + 1))
  base="$(basename "$f")"
  cp "$f" "$OUT/Assets/$base"
  # レイヤー名は人が読む用。Icon Composer で開いたときに意味が分かる名前にしておくと後で楽。
  name="$(basename "$base" .png)"
  [ $i -gt 1 ] && LAYERS="$LAYERS,"
  LAYERS="$LAYERS
        {
          \"image-name\" : \"$base\",
          \"name\" : \"$name\",
          \"glass\" : true
        }"
done

# specular / translucency / shadow はグループ単位で効く。
# ここでは「素材には光沢を描かず、システムに付けさせる」既定値を入れている。
# 数値を変えたいときは生成後の icon.json を直接編集してよい(ictool で即プレビューできる)。
cat > "$OUT/icon.json" <<JSON
{
  "fill" : {
    "solid" : "$(hex_to_srgb "$BG")"
  },
  "groups" : [
    {
      "name" : "Main",
      "specular" : true,
      "translucency" : {
        "enabled" : true,
        "value" : 0.5
      },
      "shadow" : {
        "kind" : "neutral",
        "opacity" : 0.5
      },
      "layers" : [$LAYERS
      ]
    }
  ],
  "supported-platforms" : {
    "squares" : "shared"
  }
}
JSON

echo "built $OUT ($i layers, bg $BG)"
