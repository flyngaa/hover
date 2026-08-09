#!/bin/bash
# Build a Developer ID–signed release Hover.app under dist/release/.
#
# Produces the artifact notarization (ticket 13) will later bless. Does not
# build a DMG or submit to Apple — that stays on ./release.sh.
#
# Requires:
#   - dist/helpers/ cache from Scripts/build-release-helpers.sh
#   - Developer ID Application identity in the Keychain (unless SKIP_SIGN=1)
#
# Set SKIP_SIGN=1 to assemble the release bundle without codesign — useful for
# layout checks. A real release must run without SKIP_SIGN so Developer ID,
# hardened runtime, and timestamp are applied.
#
# Layout:
#   Contents/Helpers/whisper-cli
#   Contents/Helpers/sherpa-onnx-offline-speaker-diarization
#   Contents/Frameworks/libonnxruntime.*.dylib
#
# Signing is inside-out (dylib → helpers → app), hardened runtime, secure
# timestamp, stable identifier per helper. --deep is not used for signing.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Hover"
BUNDLE_ID="com.hover.desktop"
# Common name; resolved to a unique 40-char hash before codesign (see
# require_signing_identity). Override with SIGN_IDENTITY=<hash> when needed.
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Antoine Valente (ALHP6856UK)}"
ENTITLEMENTS="$ROOT/Hover.entitlements"
HELPERS_CACHE="$ROOT/dist/helpers"
RELEASE_DIR="$ROOT/dist/release"
APP_BUNDLE="$RELEASE_DIR/$APP_NAME.app"
ONNXRUNTIME_DYLIB="libonnxruntime.1.27.0.dylib"

WHISPER_SIGN_ID="com.hover.desktop.whisper-cli"
SHERPA_SIGN_ID="com.hover.desktop.sherpa-onnx-diarization"
ONNX_SIGN_ID="com.hover.desktop.onnxruntime"

die() {
    echo "error: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

assert_arm64() {
    local arch
    arch="$(uname -m)"
    [[ "$arch" == "arm64" ]] || die "Apple Silicon only (found $arch)"
}

require_helpers_cache() {
    [[ -d "$HELPERS_CACHE" ]] || die "helpers cache missing at $HELPERS_CACHE — run Scripts/build-release-helpers.sh"
    [[ -x "$HELPERS_CACHE/whisper-cli" ]] || die "missing $HELPERS_CACHE/whisper-cli"
    [[ -x "$HELPERS_CACHE/sherpa-onnx-offline-speaker-diarization" ]] \
        || die "missing $HELPERS_CACHE/sherpa-onnx-offline-speaker-diarization"
    [[ -f "$HELPERS_CACHE/$ONNXRUNTIME_DYLIB" ]] \
        || die "missing $HELPERS_CACHE/$ONNXRUNTIME_DYLIB"
}

require_signing_identity() {
    # Fail fast before compile. codesign rejects a common name that matches
    # more than one cert (System + login after a re-import) — pin a hash.
    # Prefer the login keychain copy so we don't flip between duplicates
    # across runs (head -1 of find-identity is order-unstable).
    if [[ "$SIGN_IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]]; then
        return 0
    fi
    local name="$SIGN_IDENTITY"
    local login_kc="$HOME/Library/Keychains/login.keychain-db"
    local matches count hash=""

    if [[ -f "$login_kc" ]]; then
        hash="$(security find-certificate -a -c "$name" -Z "$login_kc" 2>/dev/null \
            | awk '/^SHA-1 hash:/{print $3; exit}')"
    fi
    matches="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -F "\"$name\"" || true)"
    [[ -n "$matches" ]] || die "signing identity not found: $name"
    count="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
    if [[ ! "$hash" =~ ^[0-9A-Fa-f]{40}$ ]]; then
        hash="$(printf '%s\n' "$matches" | head -1 | awk '{print $2}')"
    fi
    [[ "$hash" =~ ^[0-9A-Fa-f]{40}$ ]] \
        || die "could not parse signing identity hash for: $name"
    if [[ "$count" -gt 1 ]]; then
        echo "note: $count identities match '$name'; preferring login keychain hash $hash"
    fi
    SIGN_IDENTITY="$hash"
}

require_entitlements() {
    [[ -f "$ENTITLEMENTS" ]] || die "missing entitlements file: $ENTITLEMENTS"
    plutil -lint "$ENTITLEMENTS" >/dev/null \
        || die "entitlements failed plutil -lint: $ENTITLEMENTS"
    # Distribution must stay minimal: audio-input only.
    if grep -E 'app-sandbox|disable-library-validation|get-task-allow' "$ENTITLEMENTS" >/dev/null; then
        die "entitlements must not include sandbox, disable-library-validation, or get-task-allow"
    fi
    grep -q 'com.apple.security.device.audio-input' "$ENTITLEMENTS" \
        || die "entitlements missing com.apple.security.device.audio-input"
}

helper_rpaths() {
    otool -l "$1" | awk '/cmd LC_RPATH/{getline; getline; sub(/^ *path /,""); sub(/ \(offset.*/,""); print}'
}

# Point the speaker-tagging helper at Contents/Frameworks for onnxruntime.
prepare_sherpa_frameworks_rpath() {
    local binary="$1"
    local rpath
    while IFS= read -r rpath; do
        [[ -n "$rpath" ]] || continue
        install_name_tool -delete_rpath "$rpath" "$binary" 2>/dev/null || true
    done < <(helper_rpaths "$binary")
    install_name_tool -add_rpath '@loader_path/../Frameworks' "$binary"
}

sign_macho() {
    local path="$1"
    local identifier="$2"
    # Helpers and the dylib get hardened runtime + timestamp + stable -i.
    # No entitlements on nested Mach-Os (dylibs must not carry them; helpers
    # do not need audio-input — only the app does).
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" \
        --identifier "$identifier" \
        "$path"
}

sign_app() {
    local path="$1"
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" \
        --identifier "$BUNDLE_ID" \
        --entitlements "$ENTITLEMENTS" \
        "$path"
}

verify_signature() {
    local path="$1"
    local details
    echo "==> Verifying signature"
    codesign -vvv --deep --strict "$path"
    echo
    # codesign -dvv writes details to stderr.
    details="$(codesign -dvv "$path" 2>&1)"
    printf '%s\n' "$details" | sed 's/^/  /'
    echo
    printf '%s\n' "$details" | grep -q 'Authority=Developer ID Application:' \
        || die "codesign -dvv did not show Developer ID Application authority"
    printf '%s\n' "$details" | grep -Eq 'flags=.*runtime' \
        || die "codesign -dvv did not show hardened runtime flag"
    printf '%s\n' "$details" | grep -q 'Timestamp=' \
        || die "codesign -dvv did not show a secure timestamp"
    # Distribution signature must not grant the debugger entitlement.
    if codesign -d --entitlements :- "$path" 2>/dev/null \
        | grep -q 'com.apple.security.get-task-allow'; then
        die "distribution signature must not include get-task-allow"
    fi
    # Advisory only. `distribution` fails with "Notary Ticket Missing" before
    # ./release.sh staples the DMG; `notary-submission` sometimes emits a bare
    # "Gatekeeper rejected this file" even when codesign --deep --strict is
    # clean. codesign checks above are the hard gate; notarytool submit is
    # authoritative for Apple's acceptance.
    if command -v syspolicy_check >/dev/null 2>&1; then
        echo "==> syspolicy_check notary-submission (advisory)"
        if ! syspolicy_check notary-submission "$path"; then
            echo "warning: syspolicy_check reported issues; continuing because codesign verified Developer ID + runtime + timestamp"
            echo "warning: notarytool submit (in ./release.sh) is the authoritative check"
        fi
    fi
}

echo "Building release $APP_NAME.app under $RELEASE_DIR"
echo "  identity  $SIGN_IDENTITY"
echo "  bundle id $BUNDLE_ID"
echo

SKIP_SIGN="${SKIP_SIGN:-0}"

assert_arm64
require_cmd swiftc
require_cmd codesign
require_cmd install_name_tool
require_cmd otool
require_cmd plutil
require_helpers_cache
require_entitlements
[[ -f "$ROOT/ThirdPartyLicenses.txt" ]] \
    || die "missing ThirdPartyLicenses.txt at repo root"

if [[ "$SKIP_SIGN" != "1" ]]; then
    require_cmd security
    require_signing_identity
else
    echo "note: SKIP_SIGN=1 — assembling unsigned release bundle"
fi

# --- compile -----------------------------------------------------------------
SOURCES=(Sources/*.swift)
echo "==> Compiling $APP_NAME"
swiftc -O -o "$ROOT/$APP_NAME" \
    "${SOURCES[@]}" \
    -framework SwiftUI \
    -framework ScreenCaptureKit \
    -framework AVFoundation \
    -framework CoreMedia \
    -framework AppKit \
    -framework Carbon

# --- assemble bundle ---------------------------------------------------------
echo "==> Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Helpers"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

mv "$ROOT/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

[ -f AppIcon.icns ] && cp AppIcon.icns "$APP_BUNDLE/Contents/Resources/"
[ -f Logo.png ] && cp Logo.png "$APP_BUNDLE/Contents/Resources/Logo.png"
[ -f Moth.svg ] && cp Moth.svg "$APP_BUNDLE/Contents/Resources/Moth.svg"
[ -f Obsidian.svg ] && cp Obsidian.svg "$APP_BUNDLE/Contents/Resources/Obsidian.svg"
cp Scripts/diarize.py "$APP_BUNDLE/Contents/Resources/diarize.py"
cp Scripts/hover "$APP_BUNDLE/Contents/Resources/hover"
chmod +x "$APP_BUNDLE/Contents/Resources/hover"
cp ThirdPartyLicenses.txt "$APP_BUNDLE/Contents/Resources/ThirdPartyLicenses.txt"

# Nested Mach-Os belong in Helpers / Frameworks — never Resources.
cp "$HELPERS_CACHE/whisper-cli" \
    "$APP_BUNDLE/Contents/Helpers/whisper-cli"
cp "$HELPERS_CACHE/sherpa-onnx-offline-speaker-diarization" \
    "$APP_BUNDLE/Contents/Helpers/sherpa-onnx-offline-speaker-diarization"
cp "$HELPERS_CACHE/$ONNXRUNTIME_DYLIB" \
    "$APP_BUNDLE/Contents/Frameworks/$ONNXRUNTIME_DYLIB"
chmod +x \
    "$APP_BUNDLE/Contents/Helpers/whisper-cli" \
    "$APP_BUNDLE/Contents/Helpers/sherpa-onnx-offline-speaker-diarization"

prepare_sherpa_frameworks_rpath \
    "$APP_BUNDLE/Contents/Helpers/sherpa-onnx-offline-speaker-diarization"

cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Hover</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.hover.desktop</string>
    <key>CFBundleName</key>
    <string>Hover</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Hover needs microphone access to transcribe audio.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Hover needs Screen Recording access to capture system and app audio for transcription.</string>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
</dict>
</plist>
PLIST

plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null

# --- sign inside-out ---------------------------------------------------------
if [[ "$SKIP_SIGN" != "1" ]]; then
    echo "==> Signing inside-out (dylib → helpers → app)"
    sign_macho "$APP_BUNDLE/Contents/Frameworks/$ONNXRUNTIME_DYLIB" "$ONNX_SIGN_ID"
    sign_macho "$APP_BUNDLE/Contents/Helpers/whisper-cli" "$WHISPER_SIGN_ID"
    sign_macho "$APP_BUNDLE/Contents/Helpers/sherpa-onnx-offline-speaker-diarization" "$SHERPA_SIGN_ID"
    sign_app "$APP_BUNDLE"

    verify_signature "$APP_BUNDLE"
else
    # install_name_tool invalidates the cache's ad-hoc signature; re-ad-hoc so
    # the unsigned release bundle is still loadable for local smoke checks.
    codesign --force --sign - \
        "$APP_BUNDLE/Contents/Frameworks/$ONNXRUNTIME_DYLIB"
    codesign --force --sign - \
        "$APP_BUNDLE/Contents/Helpers/whisper-cli"
    codesign --force --sign - \
        "$APP_BUNDLE/Contents/Helpers/sherpa-onnx-offline-speaker-diarization"
    codesign --force --sign - "$APP_BUNDLE"
    echo "note: SKIP_SIGN=1 — ad-hoc only; run without SKIP_SIGN for Developer ID"
fi

echo
echo "Release app ready:"
echo "  $APP_BUNDLE"
if [[ "$SKIP_SIGN" != "1" ]]; then
    echo
    echo "Next: wrap in a notarized DMG via ./release.sh (ticket 13)."
fi
