#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APM_ICONSET="$PWD/build/AppIcon.iconset"
mkdir -p "$APM_ICONSET"
for APM_SIZE in 16 32 128 256 512; do
    sips -z "$APM_SIZE" "$APM_SIZE" Resources/AppIcon.png --out "$APM_ICONSET/icon_${APM_SIZE}x${APM_SIZE}.png" >/dev/null
    APM_RETINA=$((APM_SIZE * 2))
    sips -z "$APM_RETINA" "$APM_RETINA" Resources/AppIcon.png --out "$APM_ICONSET/icon_${APM_SIZE}x${APM_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$APM_ICONSET" -o Resources/AppIcon.icns
