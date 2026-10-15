#!/bin/bash
# Build NotchSend.app with swiftc directly (no Xcode / xcodebuild on this Mac).
# Usage: ./build.sh [output-dir]   (default: ./build)
set -euo pipefail
cd "$(dirname "$0")"

export PATH="/Library/Developer/CommandLineTools/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
SDK="$(xcrun --show-sdk-path 2>/dev/null || echo /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk)"
OUT="${1:-build}"
APP="$OUT/NotchSend.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo ">> swiftc (SDK: $SDK)"
swiftc \
  -O \
  -swift-version 5 \
  -target arm64-apple-macosx14.0 \
  -sdk "$SDK" \
  -o "$APP/Contents/MacOS/NotchSend" \
  Sources/*.swift

cp Info.plist "$APP/Contents/Info.plist"
echo "APPL????" > "$APP/Contents/PkgInfo"
codesign -s - --force "$APP" >/dev/null 2>&1 || true
echo ">> built $APP"
