#!/bin/bash
set -e
cd "$(dirname "$0")"

APP_NAME="Hover"
APP_BUNDLE="$APP_NAME.app"
SOURCES=(
    Sources/Main.swift
    Sources/CLIOptions.swift
    Sources/HoverCLI.swift
    Sources/Models.swift
    Sources/Selection.swift
    Sources/SettingsStore.swift
    Sources/BrandColors.swift
    Sources/HideWindowTitle.swift
    Sources/HotKeys.swift
    Sources/WAVFile.swift
    Sources/Chunker.swift
    Sources/AudioCapture.swift
    Sources/LiveAudioCapture.swift
    Sources/Transcriber.swift
    Sources/TranscriptStore.swift
    Sources/VaultFinder.swift
    Sources/TranscriberEngine.swift
    Sources/TranscriberEngine+Transcripts.swift
    Sources/TranscriberEngine+Selection.swift
    Sources/TranscriberEngine+Output.swift
    Sources/TranscriberEngine+Diarization.swift
    Sources/OutputOptionsButton.swift
    Sources/TranscriberApp.swift
    Sources/ContentView.swift
    Sources/SidebarView.swift
    Sources/ToolbarButtons.swift
    Sources/DetailViews.swift
    Sources/WelcomeView.swift
)

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
# Icon and logo are optional assets — don't fail the build if one is missing.
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP_BUNDLE/Contents/Resources/"
[ -f Logo.svg ] && cp Logo.svg "$APP_BUNDLE/Contents/Resources/Logo.svg"
[ -f Logo.png ] && cp Logo.png "$APP_BUNDLE/Contents/Resources/Logo.png"
cp Scripts/diarize.py "$APP_BUNDLE/Contents/Resources/diarize.py"

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
