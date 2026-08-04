#!/bin/bash
set -e
cd "$(dirname "$0")"

APP_NAME="Hover"
APP_BUNDLE="$APP_NAME.app"

# Every Swift file under Sources belongs to the app, so let the shell find them.
# This used to be a hand-kept list, which silently went stale whenever a file was
# added — the app build then failed with a puzzling "cannot find X in scope" even
# though the tests (which use Package.swift) were perfectly happy.
SOURCES=(Sources/*.swift)

echo "Building $APP_NAME..."

swiftc -O -o "$APP_NAME" \
    "${SOURCES[@]}" \
    -framework SwiftUI \
    -framework ScreenCaptureKit \
    -framework AVFoundation \
    -framework CoreMedia \
    -framework AppKit \
    -framework Carbon

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mv "$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"
# Images the app loads at run time: the app icon, the welcome logo, the menu-bar
# moth, and the Obsidian mark in the output picker. Optional, so a missing one
# doesn't fail the build — the app falls back to a system symbol.
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP_BUNDLE/Contents/Resources/"
[ -f Logo.png ] && cp Logo.png "$APP_BUNDLE/Contents/Resources/Logo.png"
[ -f Moth.svg ] && cp Moth.svg "$APP_BUNDLE/Contents/Resources/Moth.svg"
[ -f Obsidian.svg ] && cp Obsidian.svg "$APP_BUNDLE/Contents/Resources/Obsidian.svg"
cp Scripts/diarize.py "$APP_BUNDLE/Contents/Resources/diarize.py"

# When the releaser (or a developer) has built helpers into dist/helpers/, copy
# them into the local bundle so InstallLayout takes the same presence-based
# path a release build would. Absent cache → no change to the Homebrew / diar-venv
# day-to-day loop.
if [ -d dist/helpers ] \
    && [ -x dist/helpers/whisper-cli ] \
    && [ -x dist/helpers/sherpa-onnx-offline-speaker-diarization ] \
    && compgen -G "dist/helpers/libonnxruntime*.dylib" >/dev/null; then
    echo "Copying release helpers from dist/helpers/ into $APP_BUNDLE/Contents/Helpers/"
    mkdir -p "$APP_BUNDLE/Contents/Helpers"
    cp -R dist/helpers/. "$APP_BUNDLE/Contents/Helpers/"
fi

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
    <string>com.local.hover</string>
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

# Sign for local development. If you've created a self-signed "Hover Local Dev"
# identity in Keychain Access, we use it (that keeps macOS mic / screen-recording
# permissions across rebuilds). Otherwise we fall back to ad-hoc signing, which
# always works but may re-prompt for permissions after a rebuild.
if security find-identity -v -p codesigning | grep -q "Hover Local Dev"; then
    codesign --force --deep --sign "Hover Local Dev" "$APP_BUNDLE"
else
    echo "No 'Hover Local Dev' identity found — using ad-hoc signing."
    codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo "Done! Run with:"
echo "  open $APP_BUNDLE"
