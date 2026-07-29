#!/bin/bash
# Runs the unit test suite.
#
# On this Mac (Command Line Tools, no full Xcode), `swift test` can't execute a
# test bundle, so the tests are built as a small executable that runs
# swift-testing directly. This just launches it.
#
# With full Xcode installed, `swift test` also works.
set -e
cd "$(dirname "$0")"

echo "Running tests..."
swift run TranscriberTests "$@"
