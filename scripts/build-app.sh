#!/usr/bin/env bash
# Builds Agent2.app (universal) into dist/, plus a .dmg (and a .zip) for GitHub Releases.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.1.8}"
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

# Releases are signed with the self-signed "Agent2 Code Signing (Shakatec)" certificate
# when it's in the keychain, so macOS keeps Accessibility and other permissions across
# updates (an ad-hoc signature changes with every build). Builds without it are ad-hoc.
# Not a Developer ID: Gatekeeper still asks once ("Open Anyway").
AGENT2_CERT="32F85530436C518C3575B88F6B6A7B1781B3F69D"
if [ -z "${SIGN_ID:-}" ] && security find-identity -p codesigning | grep -q "$AGENT2_CERT"; then SIGN_ID="$AGENT2_CERT"; fi
codesign --force --deep --sign "${SIGN_ID:--}" "$APP"
codesign -dr - "$APP" 2>&1 | grep designated

(cd "$DIST" && rm -f Agent2-macOS.zip && ditto -c -k --keepParent Agent2.app Agent2-macOS.zip)

# Disk image: Agent2.app beside an Applications shortcut, on a branded background
# with an arrow between them. Finder lays the window out via AppleScript.
DMG="$DIST/Agent2.dmg"
STAGE="$DIST/dmg"
RW="$DIST/Agent2-rw.dmg"
rm -rf "$STAGE" "$DMG" "$RW" && mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
"$APP/Contents/MacOS/Agent2" --dmg-background "$DIST/dmgbg" >/dev/null
tiffutil -cathidpicheck "$DIST/dmgbg/background.png" "$DIST/dmgbg/background@2x.png" -out "$STAGE/.background/background.tiff" 2>/dev/null
hdiutil create -volname "Agent2" -srcfolder "$STAGE" -fs HFS+ -format UDRW -size 60m -ov "$RW" >/dev/null
# Detach any copy of the volume that's already mounted, then mount ours.
for v in /Volumes/Agent2*; do [ -d "$v" ] && hdiutil detach "$v" -force -quiet || true; done
DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk '/Apple_HFS/ {print $1}')
VOL="/Volumes/Agent2"
sleep 1
if ! osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "Agent2"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 104
    set text size of opts to 12
    set background picture of opts to file ".background:background.tiff"
    set position of item "Agent2.app" of container window to {170, 200}
    set position of item "Applications" of container window to {470, 200}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
then
  echo "warning: Finder layout skipped (allow Automation of Finder to get the styled window)" >&2
fi
SetFile -a V "$VOL/.background" 2>/dev/null || true
chmod -Rf go-w "$VOL" 2>/dev/null || true
sync
hdiutil detach "$DEV" -quiet || hdiutil detach "$DEV" -force -quiet
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -rf "$RW" "$STAGE" "$DIST/dmgbg"
echo "Built $APP, $DMG and $DIST/Agent2-macOS.zip"
