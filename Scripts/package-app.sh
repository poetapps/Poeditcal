#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

swift build -c release --disable-sandbox
BIN_DIR="$(swift build -c release --show-bin-path --disable-sandbox)"
APP_DIR="$PROJECT_ROOT/.build/PoetAudio.app"

if [[ "$APP_DIR" != "$PROJECT_ROOT/.build/PoetAudio.app" ]]; then
    echo "Refusing to replace unexpected app path: $APP_DIR" >&2
    exit 1
fi
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
install -m 755 "$BIN_DIR/PoetAudio" "$APP_DIR/Contents/MacOS/PoetAudio"
install -m 644 "$PROJECT_ROOT/Packaging/Info.plist" "$APP_DIR/Contents/Info.plist"
install -m 644 "$PROJECT_ROOT/THIRD_PARTY_NOTICES.md" "$APP_DIR/Contents/Resources/THIRD_PARTY_NOTICES.md"
if [[ -d "$BIN_DIR/Sparkle.framework" ]]; then
    mkdir -p "$APP_DIR/Contents/Frameworks"
    ditto "$BIN_DIR/Sparkle.framework" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
fi
codesign --force --deep --sign - --entitlements "$PROJECT_ROOT/Packaging/PoetAudio.debug.entitlements" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "$APP_DIR"
