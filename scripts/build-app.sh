#!/usr/bin/env bash
# Builds Agent2.app (universal) into dist/, plus a zip for GitHub Releases.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.1.1}"
BUILD="${BUILD:-1}"
DIST="$ROOT/dist"
APP="$DIST/Agent2.app"

cd "$ROOT/app"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Agent2"

rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Agent2"

# Icon and logos are drawn by the app itself from the pixel-bird grid.
ASSETS="$DIST/assets"
rm -rf "$ASSETS" && mkdir -p "$ASSETS"
"$APP/Contents/MacOS/Agent2" --export-assets "$ASSETS"
iconutil -c icns "$ASSETS/Agent2.iconset" -o "$APP/Contents/Resources/Agent2.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Agent2</string>
  <key>CFBundleDisplayName</key><string>Agent2</string>
  <key>CFBundleIdentifier</key><string>za.co.shakatec.agent2</string>
  <key>CFBundleExecutable</key><string>Agent2</string>
  <key>CFBundleIconFile</key><string>Agent2</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSMicrophoneUsageDescription</key><string>Agent2 listens while you hold Control+Option so you can talk to your agents.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Agent2 turns what you say into text for your agents, on this Mac where possible.</string>
  <key>NSAppleEventsUsageDescription</key><string>Agent2 opens desktop chat apps when you hand a message to them.</string>
  <key>NSHumanReadableCopyright</key><string>© $(date +%Y) Shakatec. MIT licensed.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature (no Apple Developer ID). Set SIGN_ID to sign properly.
codesign --force --deep --sign "${SIGN_ID:--}" "$APP"

(cd "$DIST" && rm -f Agent2-macOS.zip && ditto -c -k --keepParent Agent2.app Agent2-macOS.zip)
echo "Built $APP and $DIST/Agent2-macOS.zip"
