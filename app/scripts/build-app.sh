#!/bin/bash
# Builds FloatBoard.app and installs it to /Applications (or ~/Applications if not writable).
set -euo pipefail
cd "$(dirname "$0")/.."
# Your own values (bundle id, signing identity) go in scripts/local.env, which git ignores. Example:
#   BUNDLE_ID=com.yourdomain.floatboard
BUNDLE_ID=com.example.floatboard
[ -f scripts/local.env ] && . scripts/local.env
swift build -c release
APP=build/FloatBoard.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/FloatBoard "$APP/Contents/MacOS/FloatBoard"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>FloatBoard</string>
  <key>CFBundleDisplayName</key><string>FloatBoard</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>FloatBoard</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHumanReadableCopyright</key><string>Built from source</string>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>${BUNDLE_ID}.connect</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>CFBundleURLSchemes</key><array><string>floatboard</string></array>
  </dict></array>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Sign with the local "FloatBoard Local Signing" certificate if present, so macOS keeps the
# Accessibility permission across rebuilds; fall back to ad-hoc.
IDENTITY=$(security find-identity -p codesigning 2>/dev/null | awk '/"FloatBoard Local Signing"/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" --identifier "$BUNDLE_ID" "$APP"
DEST=/Applications
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
pkill -x FloatBoard 2>/dev/null || true
rm -rf "$DEST/FloatBoard.app"
cp -R "$APP" "$DEST/"
echo "Installed to $DEST/FloatBoard.app"
