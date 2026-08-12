#!/bin/bash
# Build (or fetch + prepare) the Mach-Os that a release Hover.app carries in
# Contents/Helpers. Output lands in the gitignored cache dist/helpers/.
#
# Companion to Scripts/build-release-app.sh / ./release.sh — those scripts never
# invoke this one. Re-run when the pinned whisper.cpp version below changes.
#
# Produces:
#   dist/helpers/whisper-cli
#
# Load paths are rewritten so each helper resolves libraries relative to itself
# (@loader_path). Nothing points at /opt/homebrew or any absolute path outside
# the eventual app bundle. Signing is left to ./release.sh — upstream prebuilts
# are only prepared for re-signing under our identity.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# --- pinned upstream versions (do not float) ---------------------------------
WHISPER_CPP_TAG="v1.9.1"
WHISPER_CPP_REPO="https://github.com/ggml-org/whisper.cpp.git"

HELPERS_DIR="$ROOT/dist/helpers"
WORK_DIR="$ROOT/dist/helpers-build"
WHISPER_SRC="$WORK_DIR/whisper.cpp"

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

# Fail if any load path is absolute outside the system frameworks/libs, or
# points at Homebrew. Bundle-relative @loader_path / @rpath and Apple system
# paths are fine.
assert_clean_load_paths() {
    local binary="$1"
    local line path
    while IFS= read -r line; do
        # otool -L lines look like: <tab>path (compatibility ...)
        path="${line#"${line%%[![:space:]]*}"}"
        path="${path%% (*}"
        [[ -n "$path" ]] || continue
        [[ "$path" == "$binary:" ]] && continue
        case "$path" in
            /System/*|/usr/lib/*|@loader_path*|@rpath*|@executable_path*)
                ;;
            /opt/homebrew/*|/usr/local/*|/*)
                die "$binary loads non-bundle path: $path"
                ;;
        esac
    done < <(otool -L "$binary")
}

# Upstream prebuilts are ad-hoc/linker-signed. After we rewrite load paths (or
# even just relocate them), macOS kills the unmarked Mach-O (exit 137). Ad-hoc
# re-sign here so the cache is runnable for smoke tests and ready for
# Developer ID re-signing in ./release.sh. The "-" identity is local-only and
# does not touch Keychain credentials.
adhoc_sign() {
    local path="$1"
    codesign --force --sign - "$path"
}

echo "Building release helpers into $HELPERS_DIR"
echo "  whisper.cpp  $WHISPER_CPP_TAG (Metal, static)"
echo

assert_arm64
require_cmd cmake
require_cmd git
require_cmd otool
require_cmd codesign

# Wipe both the scratch tree and the previous cache so a pin/name change
# cannot leave a stale Mach-O beside the new outputs.
rm -rf "$WORK_DIR" "$HELPERS_DIR"
mkdir -p "$WORK_DIR" "$HELPERS_DIR"

# --- whisper-cli (build from pinned tag) ------------------------------------
echo "==> Cloning whisper.cpp @ $WHISPER_CPP_TAG"
git clone --depth 1 --branch "$WHISPER_CPP_TAG" "$WHISPER_CPP_REPO" "$WHISPER_SRC"

echo "==> Configuring whisper.cpp (Metal embedded, no shared libs, no SDL2)"
cmake -S "$WHISPER_SRC" -B "$WHISPER_SRC/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DWHISPER_SDL2=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_SERVER=OFF

echo "==> Building whisper-cli"
cmake --build "$WHISPER_SRC/build" --config Release --target whisper-cli -j "$(sysctl -n hw.ncpu)"

WHISPER_BIN="$WHISPER_SRC/build/bin/whisper-cli"
[[ -x "$WHISPER_BIN" ]] || die "whisper-cli missing at $WHISPER_BIN"

cp "$WHISPER_BIN" "$HELPERS_DIR/whisper-cli"
chmod +x "$HELPERS_DIR/whisper-cli"
adhoc_sign "$HELPERS_DIR/whisper-cli"
assert_clean_load_paths "$HELPERS_DIR/whisper-cli"
echo "    wrote $HELPERS_DIR/whisper-cli"

# Drop the scratch tree; the cache is the only durable output.
rm -rf "$WORK_DIR"

echo
echo "Release helpers ready (safe to re-run; rebuilds from pinned tags):"
echo "  $HELPERS_DIR/whisper-cli"
echo
echo "otool -L summaries:"
otool -L "$HELPERS_DIR/whisper-cli" | sed 's/^/  /'
