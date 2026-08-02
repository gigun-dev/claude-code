#!/usr/bin/env bash
# .iconをictoolで全appearanceへレンダリングする。

set -uo pipefail

usage() {
  cat <<'EOF'
Usage: render_icon.sh <path.icon> <outDir> [size=400]

Render Default, Dark, Clear Light/Dark, and Tinted Light/Dark. Returns nonzero when any
rendition fails; individual ictool diagnostics are written to stderr.

Options:
  -h, --help   Show this help
EOF
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then usage; exit 0; fi
[[ $# -ge 2 && $# -le 3 ]] || { usage >&2; exit 2; }

ICON="$1"
OUT="$2"
SIZE="${3:-400}"
ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"

[[ -d "$ICON" && -f "$ICON/icon.json" ]] || { echo "error: invalid .icon bundle: $ICON" >&2; exit 3; }
[[ "$SIZE" =~ ^[1-9][0-9]*$ ]] || { echo "error: size must be a positive integer" >&2; exit 2; }
[[ -x "$ICTOOL" ]] || { echo "error: ictool not found at $ICTOOL (Xcode 26+ required)" >&2; exit 3; }
mkdir -p "$OUT" || { echo "error: cannot create output directory: $OUT" >&2; exit 3; }

failures=0
i=0
for rendition in Default Dark ClearLight ClearDark TintedLight TintedDark; do
  i=$((i + 1))
  output="$OUT/$(printf '%02d' "$i")-$rendition.png"
  log="$(mktemp "${TMPDIR:-/tmp}/render-icon.XXXXXX")" || exit 3
  rm -f "$output"
  if "$ICTOOL" "$ICON" --export-image --output-file "$output" \
      --platform iOS --rendition "$rendition" \
      --width "$SIZE" --height "$SIZE" --scale 1 \
      --tint-color 0.25 --tint-strength 0.75 >"$log" 2>&1 && [[ -s "$output" ]]; then
    printf 'OK   %s\n' "$rendition" >&2
  else
    printf 'FAIL %s\n' "$rendition" >&2
    sed 's/^/  /' "$log" >&2
    failures=$((failures + 1))
  fi
  rm -f "$log"
done

if [[ "$failures" -ne 0 ]]; then
  echo "error: $failures of 6 renditions failed" >&2
  exit 1
fi
printf 'rendered to %s\n' "$OUT"
