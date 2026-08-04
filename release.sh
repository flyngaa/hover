#!/bin/bash
# Cut a notarized, stapled dist/Hover.dmg from a clean checkout.
#
# Single release entrypoint. Day-to-day work stays on ./build.sh.
# Does NOT invoke Scripts/build-release-helpers.sh — fill dist/helpers/
# yourself when the pinned helper versions change.
#
# Stages (unattended after preflight):
#   1. Fail fast unless Developer ID, hover-notary, and dist/helpers/ exist
#   2. Build + sign the release app (Scripts/build-release-app.sh)
#   3. Wrap it in a plain UDIF DMG (app + Applications symlink, volume Hover)
#   4. notarytool submit --wait; surface the submission log on rejection
#   5. stapler staple + validate
#   6. Print dist/Hover.dmg
#
# Set SKIP_NOTARIZE=1 to stop after the DMG is built (layout smoke). Pair with
# SKIP_SIGN=1 to assemble without Keychain access — useful for checking the
# DMG contains only the app and Applications symlink, no models.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="Hover"
SIGN_IDENTITY="Developer ID Application: Antoine Valente (ALHP6856UK)"
NOTARY_PROFILE="hover-notary"
HELPERS_CACHE="$ROOT/dist/helpers"
RELEASE_APP="$ROOT/dist/release/$APP_NAME.app"
DMG_PATH="$ROOT/dist/$APP_NAME.dmg"
ONNXRUNTIME_DYLIB="libonnxruntime.1.27.0.dylib"

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
    security find-identity -v -p codesigning 2>/dev/null \
        | grep -F "$SIGN_IDENTITY" >/dev/null \
        || die "signing identity not found: $SIGN_IDENTITY"
}

# Confirm the Keychain profile exists and can authenticate before we build.
require_notary_profile() {
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        die "notary Keychain profile '$NOTARY_PROFILE' missing or unusable — run: xcrun notarytool store-credentials $NOTARY_PROFILE"
    fi
}

# Thin UDIF: signed app + Applications symlink. No models, no helper archive,
# no custom background art or window layout.
build_dmg() {
    local stage entries
    stage="$(mktemp -d "${TMPDIR:-/tmp}/hover-dmg.XXXXXX")"

    cleanup_stage() {
        rm -rf "$stage"
    }
    trap cleanup_stage EXIT

    [[ -d "$RELEASE_APP" ]] || die "release app missing at $RELEASE_APP"
    require_cmd ditto
    require_cmd hdiutil

    echo "==> Building UDIF DMG (volume $APP_NAME)"
    ditto "$RELEASE_APP" "$stage/$APP_NAME.app"
    ln -s /Applications "$stage/Applications"

    # Stage must be exactly the app + Applications symlink — nothing else.
    entries="$(find "$stage" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
    [[ "$entries" == "2" ]] || die "DMG stage must contain only $APP_NAME.app and Applications"
    [[ -d "$stage/$APP_NAME.app" ]] || die "DMG stage missing $APP_NAME.app"
    [[ -L "$stage/Applications" ]] || die "DMG stage missing Applications symlink"
    [[ ! -e "$stage/models" ]] || die "DMG stage must not contain model data"
    [[ ! -e "$stage/helpers" ]] || die "DMG stage must not contain a helper archive"

    mkdir -p "$(dirname "$DMG_PATH")"
    rm -f "$DMG_PATH"
    hdiutil create \
        -volname "$APP_NAME" \
        -srcfolder "$stage" \
        -ov \
        -format UDZO \
        "$DMG_PATH" >/dev/null

    cleanup_stage
    trap - EXIT
}

# Submit and wait. On rejection, fetch and print the notarization log so the
# releaser sees Apple's reason instead of a bare failure.
notarize_dmg() {
    local submit_out submit_status submission_id
    require_cmd xcrun

    echo "==> Submitting $DMG_PATH to notarytool (profile $NOTARY_PROFILE)"
    set +e
    submit_out="$(xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait 2>&1)"
    submit_status=$?
    set -e
    printf '%s\n' "$submit_out"

    submission_id="$(printf '%s\n' "$submit_out" | awk '/^[[:space:]]*id:[[:space:]]*/{print $2; exit}')"

    if [[ "$submit_status" -ne 0 ]] \
        || printf '%s\n' "$submit_out" | grep -Eqi 'status:[[:space:]]*(Invalid|Rejected)'; then
        if [[ -n "$submission_id" ]]; then
            echo "==> Fetching notarization log for $submission_id" >&2
            xcrun notarytool log "$submission_id" \
                --keychain-profile "$NOTARY_PROFILE" >&2 || true
        else
            echo "error: could not parse submission id from notarytool output" >&2
        fi
        die "notarization rejected"
    fi

    printf '%s\n' "$submit_out" | grep -Eqi 'status:[[:space:]]*Accepted' \
        || die "notarization did not report Accepted"
}

staple_and_validate() {
    echo "==> Stapling $DMG_PATH"
    xcrun stapler staple "$DMG_PATH"
    echo "==> Validating staple"
    xcrun stapler validate "$DMG_PATH"
}

# --- main --------------------------------------------------------------------

SKIP_SIGN="${SKIP_SIGN:-0}"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"

echo "Releasing $APP_NAME → $DMG_PATH"
echo

assert_arm64
require_cmd hdiutil
require_helpers_cache

if [[ "$SKIP_SIGN" != "1" ]]; then
    require_cmd security
    require_signing_identity
else
    echo "note: SKIP_SIGN=1 — release app will be assembled without Developer ID"
fi

if [[ "$SKIP_NOTARIZE" != "1" ]]; then
    require_cmd xcrun
    require_notary_profile
else
    echo "note: SKIP_NOTARIZE=1 — will stop after building the DMG"
fi

echo "==> Building release app"
# Never call Scripts/build-release-helpers.sh from this entrypoint.
SKIP_SIGN="$SKIP_SIGN" "$ROOT/Scripts/build-release-app.sh"

build_dmg

if [[ "$SKIP_NOTARIZE" == "1" ]]; then
    echo
    echo "DMG ready (not notarized):"
    echo "  dist/$APP_NAME.dmg"
    exit 0
fi

notarize_dmg
staple_and_validate

echo
echo "dist/$APP_NAME.dmg"
