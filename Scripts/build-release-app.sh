#!/bin/bash
# Archive the canonical Xcode product, stage release-only helpers, then sign.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Hover"
BUNDLE_ID="com.hover.desktop"
APP_VERSION="${APP_VERSION:-1.0.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
SKIP_SIGN="${SKIP_SIGN:-0}"

ENTITLEMENTS="$ROOT/Hover.entitlements"
HELPERS_CACHE="$ROOT/dist/helpers"
RELEASE_DIR="$ROOT/dist/release"
APP_BUNDLE="$RELEASE_DIR/$APP_NAME.app"
ARCHIVE_PATH="$ROOT/.build/release/Hover.xcarchive"
ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"

WHISPER_SIGN_ID="com.hover.desktop.whisper-cli"

die() {
    echo "error: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

assert_arm64() {
    [[ "$(uname -m)" == "arm64" ]] || die "Apple Silicon only (found $(uname -m))"
}

require_helpers_cache() {
    [[ -d "$HELPERS_CACHE" ]] || die "helpers cache missing at $HELPERS_CACHE — run Scripts/build-release-helpers.sh"
    [[ -x "$HELPERS_CACHE/whisper-cli" ]] || die "missing $HELPERS_CACHE/whisper-cli"
}

require_entitlements() {
    [[ -f "$ENTITLEMENTS" ]] || die "missing entitlements file: $ENTITLEMENTS"
    plutil -lint "$ENTITLEMENTS" >/dev/null || die "invalid entitlements file"
    if grep -E 'app-sandbox|disable-library-validation|get-task-allow' "$ENTITLEMENTS" >/dev/null; then
        die "entitlements must not include sandbox, disable-library-validation, or get-task-allow"
    fi
    grep -q 'com.apple.security.device.audio-input' "$ENTITLEMENTS" \
        || die "entitlements missing com.apple.security.device.audio-input"
}

sign_macho() {
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" \
        --identifier "$2" \
        "$1"
}

sign_app() {
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" \
        --identifier "$BUNDLE_ID" \
        --entitlements "$ENTITLEMENTS" \
        "$1"
}

verify_signature() {
    local details
    codesign -vvv --deep --strict "$1"
    details="$(codesign -dvv "$1" 2>&1)"
    printf '%s\n' "$details" | grep -q 'Authority=Developer ID Application:' \
        || die "signature is not a Developer ID Application signature"
    printf '%s\n' "$details" | grep -Eq 'flags=.*runtime' \
        || die "signature is missing hardened runtime"
    printf '%s\n' "$details" | grep -q 'Timestamp=' \
        || die "signature is missing a secure timestamp"
    if codesign -d --entitlements :- "$1" 2>/dev/null \
        | grep -q 'com.apple.security.get-task-allow'; then
        die "distribution signature must not include get-task-allow"
    fi
}

assert_arm64
require_cmd xcodebuild
require_cmd ditto
require_cmd plutil
require_helpers_cache
require_entitlements
[[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "APP_VERSION must be MAJOR.MINOR.PATCH (found $APP_VERSION)"

if [[ "$SKIP_SIGN" != "1" ]]; then
    [[ -n "$SIGN_IDENTITY" ]] \
        || die "SIGN_IDENTITY must be supplied by the human or CI release environment"
    require_cmd codesign
else
    echo "note: SKIP_SIGN=1 — assembling an unsigned release bundle"
fi

echo "==> Archiving the canonical Hover scheme"
rm -rf "$ARCHIVE_PATH"
xcodebuild archive \
    -project "$ROOT/Hover.xcodeproj" \
    -scheme Hover \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    MARKETING_VERSION="$APP_VERSION" \
    CURRENT_PROJECT_VERSION="$APP_VERSION"

[[ -d "$ARCHIVED_APP" ]] || die "archive did not contain $ARCHIVED_APP"
"$ROOT/Scripts/validate-app-bundle.sh" "$ARCHIVED_APP" "$APP_VERSION"

echo "==> Staging release-only helpers"
rm -rf "$APP_BUNDLE"
mkdir -p "$RELEASE_DIR"
ditto "$ARCHIVED_APP" "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/Helpers"

ditto "$HELPERS_CACHE/whisper-cli" \
    "$APP_BUNDLE/Contents/Helpers/whisper-cli"
chmod +x "$APP_BUNDLE/Contents/Helpers/whisper-cli"

"$ROOT/Scripts/validate-app-bundle.sh" "$APP_BUNDLE" "$APP_VERSION" 1

if [[ "$SKIP_SIGN" != "1" ]]; then
    echo "==> Signing inside-out (helper → app)"
    sign_macho "$APP_BUNDLE/Contents/Helpers/whisper-cli" "$WHISPER_SIGN_ID"
    sign_app "$APP_BUNDLE"
    verify_signature "$APP_BUNDLE"
fi

echo
echo "Release app ready:"
echo "  $APP_BUNDLE"
