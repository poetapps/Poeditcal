#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

APP_DIR="$PROJECT_ROOT/.build/Poeditcal.app"
DERIVED_DATA="$PROJECT_ROOT/.build/LocalPackageDerivedData"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/Poeditcal.app"

if [[ "$APP_DIR" != "$PROJECT_ROOT/.build/Poeditcal.app" ]]; then
    echo "Refusing to replace unexpected app path: $APP_DIR" >&2
    exit 1
fi

# Build through Xcode so local packages contain the same compiled Icon Composer
# asset, Sparkle framework, Info.plist values, and helper services as releases.
xcodebuild build \
    -project "$PROJECT_ROOT/PoetAudio.xcodeproj" \
    -scheme PoetAudio \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM=

if [[ ! -d "$BUILT_APP" ]]; then
    echo "Xcode did not produce the expected app at: $BUILT_APP" >&2
    exit 1
fi

rm -rf "$APP_DIR"
ditto "$BUILT_APP" "$APP_DIR"

# Sparkle's downloaded binary framework may retain its upstream signature in a
# local ad-hoc build. Re-sign the complete bundle consistently and disable
# library validation only for this local package so dyld accepts Sparkle.
codesign --force --deep --sign - \
    --entitlements "$PROJECT_ROOT/Packaging/PoetAudio.debug.entitlements" \
    "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

test -f "$APP_DIR/Contents/Resources/Assets.car"
test -f "$APP_DIR/Contents/Resources/poetaudio.icns"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$APP_DIR/Contents/Info.plist")" = "poetaudio"

echo "$APP_DIR"
