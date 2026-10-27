#!/bin/sh
# Release-build SMKVM and wrap it in $SMKVM_OUT/SMKVM.app (default build/).
#   SMKVM_UNIVERSAL=1        arm64 + x86_64
#   SMKVM_SIGN_IDENTITY=-    ad-hoc signature (used for public downloads)
set -eu
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
ARCHS=""
if [ "${SMKVM_UNIVERSAL:-0}" = 1 ]; then ARCHS="--arch arm64 --arch x86_64"; fi
# shellcheck disable=SC2086
swift build -c release --product SMKVM $ARCHS
# shellcheck disable=SC2086
BIN=$(swift build -c release --show-bin-path $ARCHS)/SMKVM
OUT=${SMKVM_OUT:-build}
APP=$OUT/SMKVM.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SMKVM"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Embed the WebRTC framework (JetKVM console): the binary references it as
# @rpath/WebRTC.framework and its build rpath points into .build/.
FRAMEWORK=$(find .build/artifacts -maxdepth 6 -type d -path '*macos*/WebRTC.framework' | head -1)
if [ -z "$FRAMEWORK" ]; then echo "WebRTC.framework not found under .build/artifacts" >&2; exit 1; fi
mkdir -p "$APP/Contents/Frameworks"
cp -R "$FRAMEWORK" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/SMKVM"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SMKVM</string>
  <key>CFBundleDisplayName</key><string>SMKVM</string>
  <key>CFBundleIdentifier</key><string>io.github.glennswest.smkvm</string>
  <key>CFBundleExecutable</key><string>SMKVM</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
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
if [ -z "$IDENTITY" ]; then
    echo "warning: no signing identity; ad-hoc signing (Keychain will re-prompt after each build)" >&2
    IDENTITY=-
fi
codesign --force --sign "$IDENTITY" "$APP/Contents/Frameworks/WebRTC.framework"
codesign --force --sign "$IDENTITY" "$APP"
echo "built $APP ($VERSION)"
