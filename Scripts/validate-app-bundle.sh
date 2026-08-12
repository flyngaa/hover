#!/bin/bash
# Validate metadata and resources owned by the canonical Hover Xcode target.
set -euo pipefail

APP_BUNDLE="${1:-}"
EXPECTED_VERSION="${2:-}"
REQUIRE_RELEASE_LAYOUT="${3:-0}"

die() {
    echo "error: $*" >&2
    exit 1
}

[[ -n "$APP_BUNDLE" ]] || die "usage: $0 PATH_TO_HOVER_APP [EXPECTED_VERSION] [REQUIRE_RELEASE_LAYOUT]"
[[ -d "$APP_BUNDLE" ]] || die "app bundle not found: $APP_BUNDLE"

PLIST="$APP_BUNDLE/Contents/Info.plist"
RESOURCES="$APP_BUNDLE/Contents/Resources"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/Hover"

[[ -f "$PLIST" ]] || die "missing Info.plist"
plutil -lint "$PLIST" >/dev/null || die "invalid Info.plist"

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null
}

[[ "$(plist_value CFBundleIdentifier)" == "com.hover.desktop" ]] \
    || die "unexpected bundle identifier"
[[ "$(plist_value LSMinimumSystemVersion)" == "14.2" ]] \
    || die "deployment target must be macOS 14.2"
[[ -n "$(plist_value NSMicrophoneUsageDescription)" ]] \
    || die "microphone usage description is missing"
[[ -n "$(plist_value NSAudioCaptureUsageDescription)" ]] \
    || die "system audio capture usage description is missing"
[[ -z "$(plist_value NSScreenCaptureUsageDescription)" ]] \
    || die "screen capture usage description must not be present"

if [[ -n "$EXPECTED_VERSION" ]]; then
    [[ "$(plist_value CFBundleShortVersionString)" == "$EXPECTED_VERSION" ]] \
        || die "marketing version does not match $EXPECTED_VERSION"
    [[ "$(plist_value CFBundleVersion)" == "$EXPECTED_VERSION" ]] \
        || die "build version does not match $EXPECTED_VERSION"
fi

[[ -x "$EXECUTABLE" ]] || die "main executable is missing or not executable"
for resource in AppIcon.icns Logo.png Moth.svg Obsidian.svg diarize.py hover ThirdPartyLicenses.txt; do
    [[ -f "$RESOURCES/$resource" ]] || die "required resource is missing: $resource"
done
[[ -x "$RESOURCES/hover" ]] || die "Agent Mode wrapper is not executable"

[[ ! -e "$RESOURCES/models" ]] || die "model data must not be bundled"
[[ ! -e "$RESOURCES/helpers" ]] || die "helper archives must not be bundled as resources"

if [[ "$REQUIRE_RELEASE_LAYOUT" == "1" ]]; then
    [[ -x "$APP_BUNDLE/Contents/Helpers/whisper-cli" ]] \
        || die "release bundle is missing whisper-cli"
    [[ -x "$APP_BUNDLE/Contents/Helpers/sherpa-onnx-offline-speaker-diarization" ]] \
        || die "release bundle is missing the speaker-diarization helper"
    [[ -f "$APP_BUNDLE/Contents/Frameworks/libonnxruntime.1.27.0.dylib" ]] \
        || die "release bundle is missing ONNX Runtime"
fi

echo "Validated $APP_BUNDLE"
