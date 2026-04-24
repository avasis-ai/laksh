#!/usr/bin/env bash
# Build Laksh.icns from icon-512.svg using qlmanage + sips + iconutil.
set -euo pipefail

cd "$(dirname "$0")/.."

SVG="Sources/Laksh/Resources/icon-512.svg"
OUT_DIR="build/icon.iconset"
ICNS="build/Laksh.icns"

rm -rf "$OUT_DIR" "$ICNS"
mkdir -p "$OUT_DIR"

# Render the SVG once at 1024 then downscale with sips.
TMP_PNG="$(mktemp -d)/icon-1024.png"
qlmanage -t -s 1024 -o "$(dirname "$TMP_PNG")" "$SVG" >/dev/null 2>&1
mv "$(dirname "$TMP_PNG")/$(basename "$SVG").png" "$TMP_PNG"

for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" \
            "64:icon_32x32@2x" "128:icon_128x128" "256:icon_128x128@2x" \
            "256:icon_256x256" "512:icon_256x256@2x" "512:icon_512x512" \
            "1024:icon_512x512@2x"; do
    size="${spec%%:*}"
    name="${spec##*:}"
    sips -z "$size" "$size" "$TMP_PNG" --out "$OUT_DIR/${name}.png" >/dev/null
done

iconutil -c icns "$OUT_DIR" -o "$ICNS"
echo "Built $ICNS"
