#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 /path/to/Poeditcal.app /path/to/Poeditcal-version.dmg" >&2
    exit 64
fi

APP_PATH="$1"
DMG_PATH="$2"

if [[ ! -d "$APP_PATH" || "$APP_PATH" != *.app ]]; then
    echo "App bundle not found: $APP_PATH" >&2
    exit 66
fi

if [[ "$DMG_PATH" != *.dmg ]]; then
    echo "The output path must end in .dmg: $DMG_PATH" >&2
    exit 64
fi

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/poet-audio-dmg.XXXXXX")"
cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

mkdir -p "$(dirname "$DMG_PATH")"
ditto "$APP_PATH" "$STAGING_DIR/Poeditcal.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -volname "Poeditcal" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -ov \
    "$DMG_PATH"

echo "$DMG_PATH"
