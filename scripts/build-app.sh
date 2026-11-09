#!/usr/bin/env bash
# Builds Glint in release mode (Apple Silicon) and assembles build/Glint.app, signed ad hoc.
# Glint needs no privacy permissions, so a stable signing identity isn't required.
#
# Optional environment (used by the release workflow):
#   VERSION=1.2.3   stamp the bundle version (defaults to Resources/Info.plist)
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_ARGS=(-c release --arch arm64)
swift build "${BUILD_ARGS[@]}"

APP="build/Glint.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/Glint" "$APP/Contents/MacOS/Glint"
cp Resources/Info.plist "$APP/Contents/Info.plist"
strip -x "$APP/Contents/MacOS/Glint"

if [[ -n "${VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi

codesign --force --sign - --identifier com.jasonxu.glint "$APP"
codesign --verify --strict "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1))"
