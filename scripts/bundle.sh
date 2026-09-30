#!/bin/sh
# Release-build SMKVM and wrap it in build/SMKVM.app (ad-hoc signed).
set -eu
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
swift build -c release --product SMKVM
BIN=$(swift build -c release --show-bin-path)/SMKVM
APP=build/SMKVM.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SMKVM"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SMKVM</string>
  <key>CFBundleDisplayName</key><string>SMKVM</string>
  <key>CFBundleIdentifier</key><string>lo.g8.smkvm</string>
  <key>CFBundleExecutable</key><string>SMKVM</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <!-- Old BMC web UIs are plain HTTP (or TLS 1.0 with self-signed certs). -->
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "built $APP ($VERSION)"
