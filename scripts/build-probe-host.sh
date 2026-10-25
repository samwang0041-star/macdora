#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PROBE="$ROOT/.build/AndroidUseProbe.app"
mkdir -p "$PROBE/Contents/MacOS"
DEFAULT_BIN="$ROOT/artifacts/Macdora.app/Contents/MacOS/AndroidUse"
if [[ ! -f "$DEFAULT_BIN" && -f "$ROOT/artifacts/Android Use.app/Contents/MacOS/AndroidUse" ]]; then
  DEFAULT_BIN="$ROOT/artifacts/Android Use.app/Contents/MacOS/AndroidUse"
fi
cp "${ANDROID_USE_PROBE_BINARY:-$DEFAULT_BIN}" "$PROBE/Contents/MacOS/AndroidUse"
python3 - "$PROBE" <<'PY'
import plistlib,sys
from pathlib import Path
p=Path(sys.argv[1])/'Contents/Info.plist'
p.write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.androiduse.probehost','CFBundleName':'Macdora 本地验收','CFBundleExecutable':'AndroidUse','CFBundlePackageType':'APPL','CFBundleVersion':'1','LSMinimumSystemVersion':'15.0','NSHighResolutionCapable':True}))
PY
SIGN_ID="${ANDROID_USE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -nE '/Developer ID Application:/s/.* ([A-F0-9]{40}) .*/\1/p')}"
if [[ -z "$SIGN_ID" || "$SIGN_ID" == *$'\n'* ]]; then exit 1; fi
codesign --force --options runtime --timestamp=none --sign "$SIGN_ID" "$PROBE"
codesign --verify --strict "$PROBE"
