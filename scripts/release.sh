#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${STONEAXE_SIGN_IDENTITY:?Set a Developer ID Application signing identity}"
: "${STONEAXE_NOTARY_PROFILE:?Set an xcrun notarytool keychain profile}"
bash scripts/build-app.sh
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Packaging/Info.plist)
archive="$PWD/dist/Stoneaxe-$version-arm64.zip"
ditto -c -k --keepParent dist/Stoneaxe.app "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$STONEAXE_NOTARY_PROFILE" --wait
xcrun stapler staple dist/Stoneaxe.app
ditto -c -k --keepParent dist/Stoneaxe.app "$archive"
shasum -a 256 "$archive"
