#!/usr/bin/env bash
# Builds ShotX.app (release) into ./build. Usage: ./build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="build/ShotX.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ShotX "$APP/Contents/MacOS/ShotX"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ShotX</string>
  <key>CFBundleDisplayName</key><string>ShotX</string>
  <key>CFBundleIdentifier</key><string>dev.shotx.app</string>
  <key>CFBundleExecutable</key><string>ShotX</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>ShotX captures the area of the screen you select.</string>
</dict>
</plist>
PLIST

# Prefer a real signing identity: Screen Recording permission then survives rebuilds.
# Ad-hoc signatures change every build, so macOS will ask for permission again.
IDENTITY="${SHOTX_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
# Fall back to the local self-signed identity (untrusted is fine for local signing).
if [[ -z "$IDENTITY" ]] && security find-identity -p codesigning 2>/dev/null | grep -q '"ShotX Local Signing"'; then
  IDENTITY="ShotX Local Signing"
fi
codesign --force --deep --sign "${IDENTITY:--}" "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x ShotX 2>/dev/null || true
  rm -rf /Applications/ShotX.app
  cp -R "$APP" /Applications/
  open /Applications/ShotX.app
  echo "Installed to /Applications and launched."
fi
