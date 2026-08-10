#!/bin/bash
# Run the standard Swift Testing target against the production app graph.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

xcodebuild test \
    -project "$ROOT/Hover.xcodeproj" \
    -scheme Hover \
    -configuration Debug \
    -derivedDataPath "$ROOT/.build/xcode-derived-data" \
    CODE_SIGNING_ALLOWED=NO \
    "$@"
