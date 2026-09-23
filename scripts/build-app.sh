#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -m)" != arm64 ]]; then
  echo "Stoneaxe supports Apple Silicon only." >&2
  exit 1
fi
build_path="${STONEAXE_BUILD_PATH:-.build/release-build}"
swift build -c release --arch arm64 --disable-sandbox --build-system native --scratch-path "$build_path"
binary_dir="$(swift build -c release --arch arm64 --disable-sandbox --build-system native --scratch-path "$build_path" --show-bin-path)"
mkdir -p "$PWD/dist"
staging_dir="$(mktemp -d "$PWD/dist/.stoneaxe-build.XXXXXX")"
app_dir="$staging_dir/Stoneaxe.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/Stoneaxe" "$app_dir/Contents/MacOS/Stoneaxe"
cp Packaging/Info.plist "$app_dir/Contents/Info.plist"
cp Packaging/Stoneaxe.icns "$app_dir/Contents/Resources/Stoneaxe.icns"
resource_bundle="$binary_dir/Stoneaxe_Stoneaxe.bundle"
if [[ ! -d "$resource_bundle" ]]; then
  echo "Missing SwiftPM resource bundle: $resource_bundle" >&2
  exit 1
fi
ditto "$resource_bundle" "$app_dir/Contents/Resources/Stoneaxe_Stoneaxe.bundle"
if [[ -n "${STONEAXE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$STONEAXE_SIGN_IDENTITY" "$app_dir"
else
  codesign --force --sign - "$app_dir"
fi
codesign --verify --strict "$app_dir"
# Do not overwrite the executable of a running app. Keep the previous bundle
# recoverable, then install the completely built and signed replacement.
if [[ -e "$PWD/dist/Stoneaxe.app" ]]; then
  previous_dir="$(mktemp -d "$PWD/dist/.stoneaxe-previous.XXXXXX")"
  mv "$PWD/dist/Stoneaxe.app" "$previous_dir/Stoneaxe.app"
fi
mv "$app_dir" "$PWD/dist/Stoneaxe.app"
rmdir "$staging_dir"
echo "Built: $PWD/dist/Stoneaxe.app"
