#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${CONFIGURATION:-release}"
identity="${SIGNING_IDENTITY:--}"
architecture_args=(--arch "$(uname -m)")
case "${1:-}" in
  "") ;;
  --universal) architecture_args=(--arch arm64 --arch x86_64) ;;
  *) echo "Usage: bash scripts/build-app.sh [--universal]" >&2; exit 2 ;;
esac

swift build --configuration "$configuration" --product CheatSheet "${architecture_args[@]}"
bin_path="$(swift build --configuration "$configuration" --show-bin-path "${architecture_args[@]}")"
app="dist/CheatSheet Modern.app"
if [[ -L "$app" ]]; then
  echo "Refusing to replace a symlink: $app" >&2
  exit 1
fi
# Only this generated bundle is replaced; nothing in /Applications is touched.
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" .build/AppIcon.iconset
cp "$bin_path/CheatSheet" "$app/Contents/MacOS/CheatSheet"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp -R Resources/en.lproj Resources/zh-Hans.lproj "$app/Contents/Resources/"
xcrun swift scripts/make-icon.swift .build/AppIcon.iconset
xcrun iconutil --convert icns .build/AppIcon.iconset --output "$app/Contents/Resources/AppIcon.icns"
plutil -lint "$app/Contents/Info.plist"

if [[ "$identity" == "-" ]]; then
  codesign --force --sign - "$app"
else
  codesign --force --options runtime --timestamp --sign "$identity" "$app"
fi
codesign --verify --deep --strict --verbose=2 "$app"
echo "Built: $app"
if [[ "$identity" == "-" ]]; then
  echo "Local ad-hoc signature only. Use Developer ID signing and notarization before distribution."
fi
