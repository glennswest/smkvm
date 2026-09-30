#!/bin/sh
# Build the downloadable app for a GitHub release: universal, ad-hoc signed
# (a personal development certificate would publish its account email in
# the signature and can't be notarised anyway), zipped with a checksum.
# Output: build/release/SMKVM-<version>-macos.zip (+ .sha256)
set -eu
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
OUT=build/release
rm -rf "$OUT"
mkdir -p "$OUT"
SMKVM_UNIVERSAL=1 SMKVM_SIGN_IDENTITY=- SMKVM_OUT="$OUT" scripts/bundle.sh
ZIP="$OUT/SMKVM-$VERSION-macos.zip"
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$OUT/SMKVM.app" "$ZIP"
(cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
lipo -archs "$OUT/SMKVM.app/Contents/MacOS/SMKVM"
codesign -dv "$OUT/SMKVM.app" 2>&1 | grep -E "^Signature|^Authority" || true
echo "$ZIP"
