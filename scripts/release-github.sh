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
  VISIBILITY="$(gh repo view "$REPO" --json visibility --jq '.visibility')"
  if [[ "$VISIBILITY" != "PUBLIC" ]]; then
    echo "The anonymous update feed requires a PUBLIC repository: $REPO" >&2
    exit 1
  fi
fi

mkdir -p "$RELEASE_DIR"
ARCHIVE_NAME="Macdora-${VERSION}-macOS-arm64.zip"
ARCHIVE_PATH="$RELEASE_DIR/$ARCHIVE_NAME"
SHA256_PATH="${ARCHIVE_PATH}.sha256"

rm -f "$ARCHIVE_PATH" "$SHA256_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ARCHIVE_PATH"
(
  cd "$RELEASE_DIR"
  /usr/bin/shasum -a 256 "$ARCHIVE_NAME" > "${ARCHIVE_NAME}.sha256"
)

echo "Packaged release archive: $ARCHIVE_PATH"
echo "Generated SHA-256 manifest: $SHA256_PATH"

if [[ "$PUBLISH" == "1" ]]; then
  # Release assets live beside the source; the app consumes them anonymously.
  NOTES="Macdora ${TAG} · 早期预览（Build ${BUNDLE_BUILD}）。支持 macOS 15 及以上的 Apple Silicon Mac。轻量安装包不附带 Android 环境或第三方应用；首次使用点击下载环境，已有环境直接复用。源码、版本发布和无需 GitHub Key 的更新入口现统一在本仓库。Agent 接入是后续演进方向，当前尚未提供通用 Agent 控制接口。此包使用 Developer ID 签名，尚未进行 Apple 公证。"
  EXTRA_ASSETS=()
  if [[ -f "$PROJECT_ROOT/plugins/registry.json" && -f "$PROJECT_ROOT/plugins/dist/builtin.developer.location.auplugin" ]]; then
    EXTRA_ASSETS+=("$PROJECT_ROOT/plugins/registry.json" "$PROJECT_ROOT/plugins/dist/builtin.developer.location.auplugin" "$PROJECT_ROOT/plugins/dist/builtin.developer.location.auplugin.sha256")
  fi
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "$TAG" "$ARCHIVE_PATH" "$SHA256_PATH" "${EXTRA_ASSETS[@]}" --clobber --repo "$REPO"
  else
    gh release create "$TAG" "$ARCHIVE_PATH" "$SHA256_PATH" "${EXTRA_ASSETS[@]}" \
      --repo "$REPO" \
      --target main \
      --title "Macdora ${TAG}" \
      --notes "$NOTES"
  fi
  echo "Published ${TAG} to GitHub Releases (${REPO})."
fi
