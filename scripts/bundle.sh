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
  <key>CFBundleIdentifier</key><string>io.github.glennswest.smkvm</string>
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
# Sign with a stable identity so Keychain "Always Allow" survives rebuilds
# (an ad-hoc signature changes every build, and macOS asks again).
# Override with SMKVM_SIGN_IDENTITY; falls back to ad-hoc if none exists.
IDENTITY=${SMKVM_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "warning: no signing identity; ad-hoc signing (Keychain will re-prompt after each build)" >&2
    codesign --force --sign - "$APP"
fi
echo "built $APP ($VERSION)"
