#!/bin/bash
# Build Hover through the shared Xcode scheme.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIGURATION="${1:-Debug}"
DERIVED_DATA="$ROOT/.build/xcode-derived-data"

case "$CONFIGURATION" in
    Debug|Release) ;;
    *)
        echo "error: configuration must be Debug or Release" >&2
        exit 1
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

echo
echo "Hover is ready at:"
echo "  $APP_BUNDLE"
