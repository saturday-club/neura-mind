#!/usr/bin/env bash
# launch.sh -- Build NeuraMind and launch it as a proper .app bundle.
# Usage: ./launch.sh [--release]
#
# Flags:
#   --release    Build optimized release binary (default: debug)
#   --no-install Run the bundle from .build/ instead of /Applications

set -euo pipefail

PRODUCT="NeuraMind"
BUNDLE_ID="com.neuramind.app"
SIGN_ID="Apple Development: saaivignesh20@gmail.com (F7Q59S24D2)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build"

# Parse flags
RELEASE=0
NO_INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --release)    RELEASE=1 ;;
        --no-install) NO_INSTALL=1 ;;
    esac
done

if [ "$RELEASE" -eq 1 ]; then
    CONFIG="release"
    BIN="$BUILD_DIR/release/$PRODUCT"
else
    CONFIG="debug"
    BIN="$BUILD_DIR/debug/$PRODUCT"
fi

if [ "$NO_INSTALL" -eq 1 ]; then
    APP_BUNDLE="$BUILD_DIR/$PRODUCT.app"
else
    APP_BUNDLE="/Applications/NeuraMind.app"
fi

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
RESET='\033[0m'

log()  { echo -e "${CYAN}> $*${RESET}"; }
ok()   { echo -e "${GREEN}ok $*${RESET}"; }
warn() { echo -e "${YELLOW}warn $*${RESET}"; }
err()  { echo -e "${RED}err $*${RESET}" >&2; }

# 1. Build
log "Building $PRODUCT ($CONFIG)..."
cd "$SCRIPT_DIR"
if [ "$RELEASE" -eq 1 ]; then
    swift build -c release
else
    swift build
fi
ok "Build complete -> $BIN"

# 2. Stop any running instance
if pgrep -x "$PRODUCT" > /dev/null 2>&1; then
    log "Stopping running $PRODUCT..."
    killall "$PRODUCT" 2>/dev/null || true
    sleep 0.5
fi

# 3. Assemble .app bundle
log "Assembling $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN" "$APP_BUNDLE/Contents/MacOS/$PRODUCT"
"$SCRIPT_DIR/scripts/gen-info-plist.sh" > "$APP_BUNDLE/Contents/Info.plist"

if [ -f "$SCRIPT_DIR/Resources/neuramind.icns" ]; then
    cp "$SCRIPT_DIR/Resources/neuramind.icns" "$APP_BUNDLE/Contents/Resources/neuramind.icns"
    ok "Icon installed"
fi

# 4. Code sign
log "Signing bundle..."
ENTITLEMENTS="$SCRIPT_DIR/Resources/NeuraMind.entitlements"
if codesign --force --deep --sign "$SIGN_ID" \
        --entitlements "$ENTITLEMENTS" \
        "$APP_BUNDLE" 2>/dev/null; then
    ok "Signed with '$SIGN_ID'"
else
    codesign --force --deep --sign - \
        --entitlements "$ENTITLEMENTS" \
        "$APP_BUNDLE" 2>/dev/null || true
    warn "Ad-hoc signed -- run 'make setup-cert' once to preserve permissions across rebuilds"
fi

# 5. Launch
log "Launching $APP_BUNDLE..."
open "$APP_BUNDLE"
ok "NeuraMind launched -- look for the eye icon in your menu bar."
