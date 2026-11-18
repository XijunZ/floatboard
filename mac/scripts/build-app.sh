#!/bin/bash
# Builds FloatBoard.app and installs it to /Applications (or ~/Applications if not writable).
set -euo pipefail
cd "$(dirname "$0")/.."
# Your own values (bundle id, signing identity) go in scripts/local.env, which git ignores. Example:
#   BUNDLE_ID=com.yourdomain.floatboard
BUNDLE_ID=com.example.floatboard
FEEDBACK_URL=""
[ -f scripts/local.env ] && . scripts/local.env
# What this build is, for "Check for Updates": its commit, its source folder, and the GitHub repository it came from.
SOURCE_DIR="$(cd .. && pwd)"
BUILD_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD 2>/dev/null || true)"
GITHUB_REPO="$(git -C "$SOURCE_DIR" remote get-url origin 2>/dev/null | sed -nE 's#.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$#\1#p')"
# The engine for Mac only mode, always built fresh from ../engine (its packages installed first when missing or out of
# date): an install never ships an old engine.js. Without npm, or when the build fails, it stops and installs nothing.
./scripts/prepare-engine.sh
swift build -c release
APP=build/FloatBoard.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/FloatBoard "$APP/Contents/MacOS/FloatBoard"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/engine.js "$APP/Contents/Resources/engine.js"
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
  <key>FloatBoardFeedbackURL</key><string>${FEEDBACK_URL}</string>
  <key>FloatBoardCommit</key><string>${BUILD_COMMIT}</string>
  <key>FloatBoardSourceDir</key><string>${SOURCE_DIR}</string>
  <key>FloatBoardRepo</key><string>${GITHUB_REPO}</string>
</dict></plist>
PLIST
# Sign with the local "FloatBoard Local Signing" certificate if present, so macOS keeps the
# Accessibility permission across rebuilds; fall back to ad-hoc.
IDENTITY=$(security find-identity -p codesigning 2>/dev/null | awk '/"FloatBoard Local Signing"/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" --identifier "$BUNDLE_ID" "$APP"
# Copied beside the installed app, then swapped in (a failed copy keeps the old one); says where (INSTALLED_AT=).
./scripts/install-app.sh "$APP"
