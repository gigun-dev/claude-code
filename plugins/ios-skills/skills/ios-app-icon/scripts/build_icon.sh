#!/usr/bin/env bash
# レイヤーPNG群からIcon Composer形式の.icon bundleを安全に組み立てる。

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: build_icon.sh [--force] <output.icon> <background-hex> <layer.png> [layer.png ...]

Layers must be passed front-to-back. Existing output is never replaced unless --force is
explicitly supplied. The bundle is completed in a sibling temporary directory before publish.

Options:
  --force      Replace an existing .icon output after the new bundle is complete
  -h, --help   Show this help
EOF
}

FORCE=false
if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then usage; exit 0; fi
if [[ ${1:-} == "--force" ]]; then FORCE=true; shift; fi
[[ $# -ge 3 ]] || { usage >&2; exit 2; }

OUT="$1"
BG="$2"
shift 2

[[ "$OUT" == *.icon ]] || { echo "error: output must end in .icon" >&2; exit 2; }
[[ "$BG" =~ ^#[0-9A-Fa-f]{6}$ ]] || { echo "error: background must be #RRGGBB" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found" >&2; exit 3; }

PARENT="$(dirname "$OUT")"
BASE="$(basename "$OUT")"
[[ "$BASE" != ".icon" ]] || { echo "error: output basename must not be empty" >&2; exit 2; }
mkdir -p "$PARENT"
PARENT="$(cd "$PARENT" && pwd)"
[[ "$PARENT" != "/" ]] || { echo "error: refusing to create an icon bundle directly under /" >&2; exit 2; }
OUT="$PARENT/$BASE"

if [[ -e "$OUT" || -L "$OUT" ]]; then
  "$FORCE" || { echo "error: output exists; pass --force to replace it: $OUT" >&2; exit 4; }
fi

for layer in "$@"; do
  [[ -f "$layer" ]] || { echo "error: layer is not a file: $layer" >&2; exit 4; }
  [[ "$layer" == *.png ]] || { echo "error: layer must be PNG: $layer" >&2; exit 4; }
done

TMP_BUNDLE="$(mktemp -d "$PARENT/.${BASE}.tmp.XXXXXX")"
cleanup() { [[ -n "${TMP_BUNDLE:-}" && -d "$TMP_BUNDLE" ]] && rm -rf "$TMP_BUNDLE"; }
trap cleanup EXIT
mkdir -p "$TMP_BUNDLE/Assets"

layer_names=()
for layer in "$@"; do
  name="$(basename "$layer")"
  [[ ! -e "$TMP_BUNDLE/Assets/$name" ]] || { echo "error: duplicate layer basename: $name" >&2; exit 4; }
  cp "$layer" "$TMP_BUNDLE/Assets/$name"
  layer_names+=("$name")
done

python3 - "$TMP_BUNDLE/icon.json" "$BG" "${layer_names[@]}" <<'PY'
import json, sys
out, color, *layers = sys.argv[1:]
rgb = [int(color[i:i+2], 16) / 255 for i in (1, 3, 5)]
data = {
    "fill": {"solid": "srgb:" + ",".join(f"{v:.5f}" for v in rgb) + ",1.00000"},
    "groups": [{
        "name": "Main",
        "specular": True,
        "translucency": {"enabled": True, "value": 0.5},
        "shadow": {"kind": "neutral", "opacity": 0.5},
        "layers": [{"image-name": name, "name": name[:-4], "glass": True} for name in layers],
    }],
    "supported-platforms": {"squares": "shared"},
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

if [[ -e "$OUT" || -L "$OUT" ]]; then rm -rf "$OUT"; fi
mv "$TMP_BUNDLE" "$OUT"
TMP_BUNDLE=""
printf 'built %s (%d layers, bg %s)\n' "$OUT" "$#" "$BG"
