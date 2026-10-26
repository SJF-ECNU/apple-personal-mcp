#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
APM_IDENTITY=$(security find-identity -v -p codesigning | awk '/^[[:space:]]*[0-9]+\)/ {print $2; exit}')
if [ -z "$APM_IDENTITY" ]; then echo 'A code-signing identity is required for XPC.' >&2; exit 1; fi
APM_APP="$PWD/build/ApplePersonalMCP.app"
mkdir -p "$APM_APP/Contents/MacOS" "$APM_APP/Contents/Helpers" "$APM_APP/Contents/Library/LaunchAgents" "$APM_APP/Contents/Resources/Licenses"
chmod -R u+w "$APM_APP"
cp .build/debug/ApplePersonalMCPHost "$APM_APP/Contents/MacOS/ApplePersonalMCPHost"
cp .build/debug/apple-personal-mcp "$APM_APP/Contents/Helpers/apple-personal-mcp"
cp Resources/Info.plist "$APM_APP/Contents/Info.plist"
cp Resources/com.shjf.apple-personal-mcp.service.plist "$APM_APP/Contents/Library/LaunchAgents/"
cp .build/checkouts/apple-mail-mcp/LICENSE "$APM_APP/Contents/Resources/Licenses/apple-mail-mcp.txt"
cp .build/checkouts/swift-sdk/LICENSE "$APM_APP/Contents/Resources/Licenses/swift-sdk.txt"
cp .build/checkouts/Madrid/LICENSE.md "$APM_APP/Contents/Resources/Licenses/Madrid.txt"
codesign --force --sign "$APM_IDENTITY" --identifier com.shjf.apple-personal-mcp.bridge --options runtime --timestamp=none "$APM_APP/Contents/Helpers/apple-personal-mcp"
codesign --force --sign "$APM_IDENTITY" --identifier com.shjf.apple-personal-mcp --options runtime --timestamp=none --entitlements Resources/entitlements.plist "$APM_APP"
codesign --verify --deep --strict "$APM_APP"
if [ "${1:-}" = '--install' ]; then
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
