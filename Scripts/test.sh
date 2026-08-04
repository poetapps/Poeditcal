#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

swift build --build-tests --disable-sandbox
BIN_DIR="$(swift build --show-bin-path --disable-sandbox)"

# SwiftPM links binary frameworks into the test bundle but does not currently
# copy Sparkle into the bundle's runtime search path. Put it in the path that
# the generated test runner already checks.
if [[ -d "$BIN_DIR/Sparkle.framework" ]]; then
    mkdir -p "$BIN_DIR/PackageFrameworks"
    ditto "$BIN_DIR/Sparkle.framework" "$BIN_DIR/PackageFrameworks/Sparkle.framework"
fi

swift test --skip-build --disable-sandbox
