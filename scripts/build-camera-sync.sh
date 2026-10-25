#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SRC="$PROJECT_ROOT/Guest/CameraSync/MacCameraFrameSync.m"
OUT_DIR="$PROJECT_ROOT/.build/camera-sync"
OUT_DYLIB="$OUT_DIR/libmaccamera_frame_sync.dylib"

if [[ -L "$OUT_DIR" ]]; then exit 1; fi
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

xcrun clang -dynamiclib \
    -arch arm64 \
    -mmacosx-version-min=15.0 \
    -fobjc-arc \
    -O2 \
    -Wall -Wextra \
    -framework Foundation \
    -framework AVFoundation \
    -framework CoreMedia \
    -framework Accelerate \
    "$SRC" \
    -o "$OUT_DYLIB"

chmod 755 "$OUT_DYLIB"
SIGN_ID="${ANDROID_USE_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_ID" ]]; then
    SIGN_ID="$(security find-identity -v -p codesigning | sed -nE '/Developer ID Application:/s/.* ([A-F0-9]{40}) .*/\1/p' | head -n 1)"
fi
if [[ -n "$SIGN_ID" ]]; then
    codesign --force --timestamp=none --sign "$SIGN_ID" "$OUT_DYLIB"
fi
printf 'Built MacCamera frame sync helper: %s\n' "$OUT_DYLIB"
