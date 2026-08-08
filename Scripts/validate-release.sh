#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 v1.2.3" >&2
    exit 64
fi

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="$1"
VERSION="${TAG#v}"
PLIST="$PROJECT_ROOT/Packaging/Info.plist"

if [[ "$TAG" != v* || "$VERSION" == "$TAG" ]]; then
    echo "Release tags must look like v1.2.3" >&2
    exit 65
fi

PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"

if [[ "$VERSION" != "$PLIST_VERSION" ]]; then
    echo "Tag $TAG does not match CFBundleShortVersionString $PLIST_VERSION" >&2
    exit 65
fi

if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "CFBundleVersion must be a positive integer; found $BUILD_NUMBER" >&2
    exit 65
fi

if [[ ! -f "$PROJECT_ROOT/ReleaseNotes/$VERSION.md" ]]; then
    echo "Missing release notes: ReleaseNotes/$VERSION.md" >&2
    exit 66
fi

echo "Validated Poeditcal $VERSION (build $BUILD_NUMBER)"
