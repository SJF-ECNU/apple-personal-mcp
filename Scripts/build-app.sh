#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APM_CONFIGURATION=debug
APM_INSTALL=false
for APM_ARG in "$@"; do
    case "$APM_ARG" in
        --release) APM_CONFIGURATION=release ;;
        --install) APM_INSTALL=true ;;
        *) echo 'Usage: build-app.sh [--release] [--install]' >&2; exit 2 ;;
    esac
done
swift build -c "$APM_CONFIGURATION"
APM_BIN=$(swift build -c "$APM_CONFIGURATION" --show-bin-path)
APM_IDENTITY=$(security find-identity -v -p codesigning | awk '/^[[:space:]]*[0-9]+\)/ {print $2; exit}')
if [ -z "$APM_IDENTITY" ]; then echo 'A code-signing identity is required for XPC.' >&2; exit 1; fi
APM_APP="$PWD/build/ApplePersonalMCP.app"
if [ "$APM_CONFIGURATION" = release ]; then APM_APP="$PWD/build/release/ApplePersonalMCP.app"; fi
mkdir -p "$APM_APP/Contents/MacOS" "$APM_APP/Contents/Helpers" "$APM_APP/Contents/Library/LaunchAgents" "$APM_APP/Contents/Resources/Licenses"
chmod -R u+w "$APM_APP"
cp "$APM_BIN/ApplePersonalMCPHost" "$APM_APP/Contents/MacOS/ApplePersonalMCPHost"
cp "$APM_BIN/apple-personal-mcp" "$APM_APP/Contents/Helpers/apple-personal-mcp"
cp Resources/Info.plist "$APM_APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APM_APP/Contents/Resources/AppIcon.icns"
cp Resources/com.shjf.apple-personal-mcp.service.plist "$APM_APP/Contents/Library/LaunchAgents/"
cp .build/checkouts/apple-mail-mcp/LICENSE "$APM_APP/Contents/Resources/Licenses/apple-mail-mcp.txt"
cp .build/checkouts/swift-sdk/LICENSE "$APM_APP/Contents/Resources/Licenses/swift-sdk.txt"
cp .build/checkouts/Madrid/LICENSE.md "$APM_APP/Contents/Resources/Licenses/Madrid.txt"
cp LICENSE "$APM_APP/Contents/Resources/Licenses/ApplePersonalMCP.txt"
cp THIRD_PARTY_NOTICES.md "$APM_APP/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md"
if [ "$APM_CONFIGURATION" = release ]; then
    strip -S "$APM_APP/Contents/MacOS/ApplePersonalMCPHost" "$APM_APP/Contents/Helpers/apple-personal-mcp"
fi
codesign --force --sign "$APM_IDENTITY" --identifier com.shjf.apple-personal-mcp.bridge --options runtime --timestamp=none "$APM_APP/Contents/Helpers/apple-personal-mcp"
codesign --force --sign "$APM_IDENTITY" --identifier com.shjf.apple-personal-mcp --options runtime --timestamp=none --entitlements Resources/entitlements.plist "$APM_APP"
codesign --verify --deep --strict "$APM_APP"
if [ "$APM_INSTALL" = true ]; then
    APM_DEST=/Applications/ApplePersonalMCP.app
    if [ -e "$APM_DEST" ]; then
        APM_EXISTING=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APM_DEST/Contents/Info.plist")
        if [ "$APM_EXISTING" != 'com.shjf.apple-personal-mcp' ]; then echo 'Refusing to replace a different app.' >&2; exit 1; fi
    fi
    ditto "$APM_APP" "$APM_DEST"
    echo "$APM_DEST"
else
    echo "$APM_APP"
fi
