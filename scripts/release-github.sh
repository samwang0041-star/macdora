#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$PROJECT_ROOT"

VERSION="$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION" 2>/dev/null || echo '0.01')"
TAG="v${VERSION}"
# Public source repository also hosts binary assets and the anonymous update feed.
REPO="${MACDORA_GITHUB_REPOSITORY:-samwang0041-star/macdora}"
APP_BUNDLE="${MACDORA_APP_BUNDLE:-$PROJECT_ROOT/artifacts/Macdora.app}"
RELEASE_DIR="${MACDORA_RELEASE_DIR:-$PROJECT_ROOT/artifacts/releases}"
PUBLISH=0
EXPECTED_REPO="samwang0041-star/macdora"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; TAG="v${VERSION}"; shift 2 ;;
    --app) APP_BUNDLE="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --publish) PUBLISH=1; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Macdora app bundle not found at: $APP_BUNDLE" >&2
  echo "Run 'bash scripts/build-macos.sh' first." >&2
  exit 1
fi

REQUIRED_PATHS=(
  "$APP_BUNDLE/Contents/MacOS/AndroidUse"
  "$APP_BUNDLE/Contents/Info.plist"
  "$APP_BUNDLE/Contents/Resources/runtime-manifest.json"
  "$APP_BUNDLE/Contents/Resources/scrcpy-server-v5.0.1"
  "$APP_BUNDLE/Contents/Resources/RuntimeSeed/image/build.prop"
  "$APP_BUNDLE/Contents/Resources/RuntimeSeed/android-use-ime.apk"
  "$APP_BUNDLE/Contents/Resources/RuntimeSeed/libmaccamera_frame_sync.dylib"
  "$APP_BUNDLE/Contents/Resources/RuntimeSeed/libMacdoraMoltenVK.dylib"
)
for req in "${REQUIRED_PATHS[@]}"; do
  if [[ ! -e "$req" ]]; then
    echo "Refusing to package incomplete Macdora bundle; missing required runtime resource: $req" >&2
    echo "Build the lightweight bundle via 'bash scripts/build-macos.sh' before releasing." >&2
    exit 1
  fi
done

BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
BUNDLE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_BUNDLE/Contents/Info.plist")"
if [[ "$BUNDLE_VERSION" != "$VERSION" ]]; then
  echo "Refusing to package version $BUNDLE_VERSION as $VERSION; rebuild Macdora first." >&2
  exit 1
fi
python3 - "$APP_BUNDLE/Contents/Resources/runtime-manifest.json" "$VERSION" "$BUNDLE_BUILD" <<'PY'
import json,sys
with open(sys.argv[1]) as stream:
    manifest=json.load(stream)
if manifest.get('macdoraVersion')!=sys.argv[2] or str(manifest.get('macdoraBuild'))!=sys.argv[3]:
    raise SystemExit('Refusing to package a bundle with inconsistent runtime version metadata.')
if manifest.get('bundlesAndroidRuntime') is not False:
    raise SystemExit('Release installers must contain only the app, without an Android environment.')
from pathlib import Path
resources=Path(sys.argv[1]).parent
for relative in ['RuntimeSeed/emulator','RuntimeSeed/platform-tools','RuntimeSeed/image/system.img',
                 'RuntimeSeed/image/vendor.img','RuntimeSeed/image/kernel-ranchu',
                 'RuntimeSeed/image/ramdisk.img','Target']:
    path=resources/relative
    if path.exists() or path.is_symlink():
        raise SystemExit('Refusing to package bundled Android resources: '+relative)
if any((resources/'RuntimeSeed').glob('.image.*')):
    raise SystemExit('Refusing to package incomplete Android image build artifacts.')
PY
codesign --verify --strict --verbose=2 "$APP_BUNDLE"

if [[ "$PUBLISH" == "1" ]]; then
  if [[ "${MACDORA_CONFIRM_RELEASE:-0}" != "1" ]]; then
    echo "REFUSED: 未获得明确发布授权（需同时显式设置 MACDORA_CONFIRM_RELEASE=1）。" >&2
    exit 1
  fi
  if [[ "$REPO" != "$EXPECTED_REPO" ]]; then
    echo "REFUSED: public releases must target $EXPECTED_REPO, got $REPO." >&2
    exit 1
  fi
  BUNDLE_REPO="$(/usr/libexec/PlistBuddy -c 'Print :MacdoraGitHubRepository' "$APP_BUNDLE/Contents/Info.plist")"
  if [[ "$BUNDLE_REPO" != "$REPO" ]]; then
    echo "REFUSED: app update repository does not match the public release repository." >&2
    exit 1
  fi
  VISIBILITY="$(gh repo view "$REPO" --json visibility --jq '.visibility')"
  if [[ "$VISIBILITY" != "PUBLIC" ]]; then
    echo "The anonymous update feed requires a PUBLIC repository: $REPO" >&2
    exit 1
  fi
  python3 - "$APP_BUNDLE" <<'PY'
import hashlib,json,re,subprocess,sys
from pathlib import Path
app=Path(sys.argv[1])
entries=list(app.rglob('*'))
if any(path.is_symlink() for path in entries):
    raise SystemExit('Refusing to publish a bundle containing symbolic links.')
magic={
 b'\xfe\xed\xfa\xce',b'\xce\xfa\xed\xfe',
 b'\xfe\xed\xfa\xcf',b'\xcf\xfa\xed\xfe',
 b'\xca\xfe\xba\xbe',
}
def is_macho(path):
 try:
  with path.open('rb') as stream:
   return stream.read(4) in magic
 except OSError:
  return False
machos=[path for path in entries if path.is_file() and is_macho(path)]
if not machos:
    raise SystemExit('No Mach-O code found in app bundle.')
def team_id(info):
    values=[line.split('=',1)[1].strip() for line in info.splitlines()
            if line.startswith('TeamIdentifier=')]
    return values[0] if len(values)==1 and re.fullmatch(r'[A-Z0-9]{10}',values[0]) else None
teams=set()
for path in machos:
    result=subprocess.run(['/usr/bin/codesign','--display','--verbose=4',str(path)],
                          capture_output=True,text=True,check=True)
    info=result.stdout+result.stderr
    if 'Signature=adhoc' in info or 'Authority=Developer ID Application:' not in info:
        raise SystemExit(f'Unsigned or ad-hoc Mach-O: {path.relative_to(app)}')
    if not re.search(r'(?m)^Timestamp=\S',info):
        raise SystemExit(f'Mach-O lacks a secure timestamp: {path.relative_to(app)}')
    flags=re.search(r'\bflags=0x([0-9a-fA-F]+)',info)
    if not flags or not (int(flags.group(1),16)&0x10000):
        raise SystemExit(f'Mach-O lacks hardened runtime: {path.relative_to(app)}')
    team=team_id(info)
    if team is None:
        raise SystemExit(f'Mach-O lacks TeamIdentifier: {path.relative_to(app)}')
    teams.add(team)
if len(teams)!=1:
    raise SystemExit('Nested Mach-O signing teams do not match.')
team=teams.pop()
requirement=('=anchor apple generic and '
             'certificate leaf[field.1.2.840.113635.100.6.1.13] and '
             f'certificate leaf[subject.OU] = "{team}"')
subprocess.run(['/usr/bin/codesign','--verify','--strict','--verbose=2',
                '-R',requirement,str(app)],check=True)
for path in machos:
    subprocess.run(['/usr/bin/codesign','--verify','--strict','--verbose=2',
                    '-R',requirement,str(path)],check=True)
manifest=json.loads((app/'Contents/Resources/runtime-manifest.json').read_text())
seed=app/'Contents/Resources/RuntimeSeed'
camera=seed/'libmaccamera_frame_sync.dylib'
gpu=seed/'libMacdoraMoltenVK.dylib'
camera_sha=hashlib.file_digest(camera.open('rb'),'sha256').hexdigest()
gpu_sha=hashlib.file_digest(gpu.open('rb'),'sha256').hexdigest()
if (manifest.get('cameraSyncHelperSHA256')!=camera_sha or
    (manifest.get('graphicsDriver') or {}).get('distributionLibrarySHA256')!=gpu_sha):
    raise SystemExit('Signed nested helper hashes do not match the distribution manifest.')
graphics=manifest['graphicsDriver']
if not re.fullmatch(r'[0-9a-f]{64}',str(graphics.get('librarySHA256',''))):
    raise SystemExit('Original GPU build provenance is missing.')
print(f'Developer ID TeamIdentifier: {team}')
print('Verified signed Mach-O, timestamps, hardened runtime, manifest hashes, and provenance.')
PY
  if ! /usr/bin/xcrun stapler validate "$APP_BUNDLE" >/dev/null 2>&1; then
    echo "REFUSED: app does not contain a valid stapled notarization ticket." >&2
    exit 1
  fi
  if ! /usr/sbin/spctl --assess --type execute --verbose=4 "$APP_BUNDLE" >/dev/null 2>&1; then
    echo "REFUSED: Gatekeeper execution assessment failed." >&2
    exit 1
  fi
  if [[ -x /usr/bin/syspolicy_check ]] && \
     ! /usr/bin/syspolicy_check distribution "$APP_BUNDLE" --verbose >/dev/null 2>&1; then
    echo "REFUSED: distribution readiness assessment failed." >&2
    exit 1
  fi
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "REFUSED: GitHub Release $TAG already exists; bump VERSION/Build instead of overwriting assets." >&2
    exit 1
  fi
fi

mkdir -p "$RELEASE_DIR"
ARCHIVE_NAME="Macdora-${VERSION}-macOS-arm64.zip"
ARCHIVE_PATH="$RELEASE_DIR/$ARCHIVE_NAME"
SHA256_PATH="${ARCHIVE_PATH}.sha256"
TEMP_ARCHIVE="$RELEASE_DIR/.${ARCHIVE_NAME}.$$.tmp"
TEMP_SHA256="$RELEASE_DIR/.${ARCHIVE_NAME}.$$.sha256.tmp"

if [[ -e "$TEMP_ARCHIVE" || -L "$TEMP_ARCHIVE" || -e "$TEMP_SHA256" || -L "$TEMP_SHA256" ]]; then
  echo "REFUSED: temporary package output already exists: $TEMP_ARCHIVE" >&2
  exit 1
fi
if ! /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$TEMP_ARCHIVE"; then
  /bin/rm -f "$TEMP_ARCHIVE" "$TEMP_SHA256"
  echo "REFUSED: could not create the temporary release archive." >&2
  exit 1
fi
CHECKSUM_OUTPUT="$(
  cd "$RELEASE_DIR"
  /usr/bin/shasum -a 256 "$(basename "$TEMP_ARCHIVE")"
)" || {
  /bin/rm -f "$TEMP_ARCHIVE" "$TEMP_SHA256"
  echo "REFUSED: could not create the temporary checksum manifest." >&2
  exit 1
}
CHECKSUM="${CHECKSUM_OUTPUT%% *}"
if [[ ! "$CHECKSUM" =~ ^[0-9a-f]{64}$ ]]; then
  /bin/rm -f "$TEMP_ARCHIVE" "$TEMP_SHA256"
  echo "REFUSED: checksum output was invalid." >&2
  exit 1
fi
printf '%s  %s\n' "$CHECKSUM" "$ARCHIVE_NAME" > "$TEMP_SHA256"
/bin/mv -f "$TEMP_ARCHIVE" "$ARCHIVE_PATH"
/bin/mv -f "$TEMP_SHA256" "$SHA256_PATH"

echo "Packaged release archive: $ARCHIVE_PATH"
echo "Generated SHA-256 manifest: $SHA256_PATH"

if [[ "$PUBLISH" == "1" ]]; then
  # Release assets live beside the source; the app consumes them anonymously.
  NOTES="Macdora ${TAG} · 早期预览（Build ${BUNDLE_BUILD}）。支持 macOS 15 及以上的 Apple Silicon Mac。轻量安装包不附带 Android 环境或第三方应用；首次使用点击下载环境，已有环境直接复用。源码、版本发布和无需 GitHub Key 的更新入口现统一在本仓库。Agent 接入是后续演进方向，当前尚未提供通用 Agent 控制接口。此包使用 Developer ID 签名，已完成 Apple 公证；App 内已钉附公证票据。"
  EXTRA_ASSETS=()
  if [[ -f "$PROJECT_ROOT/plugins/registry.json" && -f "$PROJECT_ROOT/plugins/dist/builtin.developer.location.auplugin" ]]; then
    EXTRA_ASSETS+=("$PROJECT_ROOT/plugins/registry.json" "$PROJECT_ROOT/plugins/dist/builtin.developer.location.auplugin" "$PROJECT_ROOT/plugins/dist/builtin.developer.location.auplugin.sha256")
  fi
  gh release create "$TAG" "$ARCHIVE_PATH" "$SHA256_PATH" "${EXTRA_ASSETS[@]}" \
    --repo "$REPO" \
    --target main \
    --latest \
    --title "Macdora ${TAG}" \
    --notes "$NOTES"
  echo "Published ${TAG} to GitHub Releases (${REPO})."
fi
