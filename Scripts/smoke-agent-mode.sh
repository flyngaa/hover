#!/bin/bash
# Exercise the headless routing and stdout/stderr contract without recording.
set -euo pipefail

APP_BUNDLE="${1:-}"
[[ -d "$APP_BUNDLE" ]] || {
    echo "error: usage: $0 PATH_TO_HOVER_APP" >&2
    exit 1
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hover-agent-smoke.XXXXXX")"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

"$APP_BUNDLE/Contents/MacOS/Hover" --help \
    >"$TMP_DIR/stdout" \
    2>"$TMP_DIR/stderr"

[[ ! -s "$TMP_DIR/stderr" ]] || {
    echo "error: Agent Mode --help wrote to stderr" >&2
    sed -n '1,20p' "$TMP_DIR/stderr" >&2
    exit 1
}
grep -q '^Hover — record audio and transcribe it, agent-first\.$' "$TMP_DIR/stdout" \
    || {
        echo "error: Agent Mode help output is missing its expected heading" >&2
        exit 1
    }
grep -q '^  hover setup \[--status\]$' "$TMP_DIR/stdout" \
    || {
        echo "error: Agent Mode help output is missing setup usage" >&2
        exit 1
    }

echo "Agent Mode smoke passed for $APP_BUNDLE"
