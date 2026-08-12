#!/bin/bash
# Build Hover through the shared Xcode scheme.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIGURATION="${1:-Debug}"
DERIVED_DATA="$ROOT/.build/xcode-derived-data"
LOCAL_SIGN_IDENTITY="${HOVER_LOCAL_SIGN_IDENTITY:--}"

die() {
    echo "error: $*" >&2
    exit 1
}

case "$CONFIGURATION" in
    Debug|Release) ;;
    *)
        die "configuration must be Debug or Release"
        ;;
esac

xcodebuild build \
    -project "$ROOT/Hover.xcodeproj" \
    -scheme Hover \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO

APP_BUNDLE="$DERIVED_DATA/Build/Products/$CONFIGURATION/Hover.app"
"$ROOT/Scripts/validate-app-bundle.sh" "$APP_BUNDLE"

echo "==> Signing Hover for local development"
# Ad-hoc signing is the zero-setup default so a contributor needs no Apple
# account, key, or certificate. macOS may ask an ad-hoc build to re-authorize
# protected resources after its code changes. Developers who already have a
# stable identity may opt in with HOVER_LOCAL_SIGN_IDENTITY="Identity Name".
codesign --force --deep \
    --sign "$LOCAL_SIGN_IDENTITY" \
    --identifier com.hover.desktop \
    --entitlements "$ROOT/Hover.entitlements" \
    "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo
echo "Hover is ready at:"
echo "  $APP_BUNDLE"
