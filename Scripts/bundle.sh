#!/bin/zsh
# Builds BeadyEye and wraps it in BeadyEye.app (unsigned, ad-hoc signed for local use).
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-release}
swift build -c "$CONFIG"
APP=build/BeadyEye.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp ".build/$CONFIG/BeadyEye" "$APP/Contents/MacOS/BeadyEye"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Beady Eye</string>
  <key>CFBundleDisplayName</key><string>Beady Eye</string>
  <key>CFBundleIdentifier</key><string>dev.addywaddy.beadyeye</string>
  <key>CFBundleExecutable</key><string>BeadyEye</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
