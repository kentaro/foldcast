#!/bin/bash
# Build FoldCast.app — a proper bundle so macOS attributes the Screen
# Recording permission to *this app* (granted once, then it sticks),
# instead of to whatever terminal launched it.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▸ swift build -c release"
swift build -c release

APP="FoldCast.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/foldcast "$APP/Contents/MacOS/foldcast"
[ -f assets/FoldCast.icns ] && cp assets/FoldCast.icns "$APP/Contents/Resources/FoldCast.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>FoldCast</string>
  <key>CFBundleDisplayName</key><string>FoldCast</string>
  <key>CFBundleIdentifier</key><string>com.kentaro.foldcast</string>
  <key>CFBundleExecutable</key><string>foldcast</string>
  <key>CFBundleIconFile</key><string>FoldCast</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSScreenCaptureUsageDescription</key>
  <string>FoldCast streams a virtual extended display to your phone.</string>
</dict></plist>
PLIST

# Sign with the STABLE self-signed identity so the app's designated
# requirement never changes — Screen Recording is granted once, then sticks.
# Falls back to ad-hoc only if the identity is missing.
SIGN_KC="$HOME/Library/Keychains/foldcast-signing.keychain-db"
SIGN_CN="FoldCast Self Signed"
if security find-identity -p codesigning "$SIGN_KC" 2>/dev/null \
     | grep -q "$SIGN_CN"; then
  KCP="$(cat "$HOME/.foldcast/signing.pass" 2>/dev/null || true)"
  [ -n "$KCP" ] && security unlock-keychain -p "$KCP" "$SIGN_KC" 2>/dev/null || true
  codesign --force --deep \
    --sign "$SIGN_CN" --keychain "$SIGN_KC" \
    --identifier com.kentaro.foldcast \
    --entitlements scripts/foldcast.entitlements "$APP"
  echo "▸ signed with stable identity: $SIGN_CN"
else
  echo "▸ WARNING: stable identity missing — run scripts/setup-signing.sh"
  echo "  (falling back to ad-hoc; macOS will re-prompt on every rebuild)"
  codesign --force --deep --sign - \
    --entitlements scripts/foldcast.entitlements "$APP" 2>/dev/null \
    || codesign --force --deep --sign - "$APP"
fi

echo "▸ built $(pwd)/$APP"
echo "  Launch:  open $APP --args --fps 30"
echo "  First run will ask for Screen Recording permission — approve it in"
echo "  System Settings ▸ Privacy & Security ▸ Screen Recording, then relaunch."
