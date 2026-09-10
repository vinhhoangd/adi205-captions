#!/bin/bash
# Wraps an SPM executable in a real .app bundle.
# Needed twice over: SwiftUI only activates a scene for a bundled app, and
# microphone access (TCC) requires an Info.plist with a usage description.
set -euo pipefail
TARGET="${1:-bench}"
NAME="${2:-CaptionBench}"
ID="com.adi205.captions.${TARGET}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/$NAME.app"

swift build -c release --product "$TARGET" >/dev/null
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/$TARGET" "$APP/Contents/MacOS/$TARGET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$TARGET</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Live lecture captions are generated from the microphone on this Mac.</string>
</dict></plist>
PLIST

codesign --force --sign - --identifier "$ID" "$APP" 2>/dev/null || true
echo "$APP/Contents/MacOS/$TARGET"
