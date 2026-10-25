#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
PROJECT_DIR="${ROOT_DIR}/Tests/AndroidProbe"
BUILD_DIR="${ROOT_DIR}/.build/android-probe"
SIGNING_DIR="${ROOT_DIR}/.build/android-probe-signing"
DEBUG_KEYSTORE="${SIGNING_DIR}/debug.keystore"

BUILD_TOOLS="${ANDROID_PROBE_BUILD_TOOLS:-${ROOT_DIR}/.cache/android-sdk/build-tools/android-16}"
ANDROID_JAR="${ANDROID_PROBE_ANDROID_JAR:-${ROOT_DIR}/.cache/android-sdk/platforms/android-36/android.jar}"
JDK_HOME="${ANDROID_PROBE_JDK_HOME:-$(bash "$ROOT_DIR/scripts/java-home.sh")}"
if [[ ! -f "$ANDROID_JAR" || ! -x "$BUILD_TOOLS/d8" ]]; then
    python3 "$ROOT_DIR/scripts/prepare-build-inputs.py"
fi

AAPT="${BUILD_TOOLS}/aapt"
D8="${BUILD_TOOLS}/d8"
ZIPALIGN="${BUILD_TOOLS}/zipalign"
APKSIGNER="${BUILD_TOOLS}/apksigner"
APKSIGNER_JAR="${BUILD_TOOLS}/lib/apksigner.jar"
JAVAC="${JDK_HOME}/bin/javac"
JAR="${JDK_HOME}/bin/jar"
JAVA="${JDK_HOME}/bin/java"
KEYTOOL="${JDK_HOME}/bin/keytool"

MANIFEST="${PROJECT_DIR}/AndroidManifest.xml"
SOURCE_ROOT="${PROJECT_DIR}/src"
RESOURCE_ROOT="${PROJECT_DIR}/res"
GEN_DIR="${BUILD_DIR}/generated"
CLASS_DIR="${BUILD_DIR}/classes"
DEX_DIR="${BUILD_DIR}/dex"
UNSIGNED_APK="${BUILD_DIR}/android-use-probe-unsigned.apk"
UNALIGNED_APK="${BUILD_DIR}/android-use-probe-unaligned.apk"
ALIGNED_APK="${BUILD_DIR}/android-use-probe-aligned.apk"
FINAL_APK="${BUILD_DIR}/android-use-probe.apk"

for required_path in \
    "${AAPT}" \
    "${D8}" \
    "${ZIPALIGN}" \
    "${APKSIGNER}" \
    "${APKSIGNER_JAR}" \
    "${JAVAC}" \
    "${JAR}" \
    "${JAVA}" \
    "${KEYTOOL}" \
    "${ANDROID_JAR}" \
    "${MANIFEST}"; do
    if [[ ! -e "${required_path}" ]]; then
        printf 'Missing required build input: %s\n' "${required_path}" >&2
        exit 1
    fi
done

ensure_debug_keystore() {
    if [[ -L "${SIGNING_DIR}" || ( -e "${SIGNING_DIR}" && ! -d "${SIGNING_DIR}" ) ]]; then
        printf 'Unsafe signing directory path: %s\n' "${SIGNING_DIR}" >&2
        exit 1
    fi

    mkdir -p "$(dirname "${SIGNING_DIR}")"
    if [[ ! -e "${SIGNING_DIR}" ]]; then
        mkdir "${SIGNING_DIR}"
    fi
    chmod 700 "${SIGNING_DIR}"

    local legacy_keystore="${BUILD_DIR}/debug.keystore"
    if [[ ! -e "${DEBUG_KEYSTORE}" && ! -L "${DEBUG_KEYSTORE}" \
        && -f "${legacy_keystore}" && ! -L "${legacy_keystore}" ]]; then
        mv "${legacy_keystore}" "${DEBUG_KEYSTORE}"
    fi

    if [[ -L "${DEBUG_KEYSTORE}" || ( -e "${DEBUG_KEYSTORE}" && ! -f "${DEBUG_KEYSTORE}" ) ]]; then
        printf 'Unsafe test keystore path: %s\n' "${DEBUG_KEYSTORE}" >&2
        exit 1
    fi

    if [[ ! -e "${DEBUG_KEYSTORE}" ]]; then
        "${KEYTOOL}" -genkeypair \
            -keystore "${DEBUG_KEYSTORE}" \
            -storepass android \
            -alias androiddebugkey \
            -keypass android \
            -dname "CN=Android Debug,O=Android,C=US" \
            -keyalg RSA \
            -keysize 2048 \
            -validity 10000 \
            >/dev/null 2>&1
    fi

    chmod 600 "${DEBUG_KEYSTORE}"
}

export JAVA_HOME="${JDK_HOME}"
export PATH="${JDK_HOME}/bin:${BUILD_TOOLS}:${PATH}"

ensure_debug_keystore

rm -rf "${BUILD_DIR}"
mkdir -p "${GEN_DIR}" "${CLASS_DIR}" "${DEX_DIR}"

"${AAPT}" package \
    -f \
    -m \
    -J "${GEN_DIR}" \
    -M "${MANIFEST}" \
    -S "${RESOURCE_ROOT}" \
    -I "${ANDROID_JAR}" \
    -F "${UNSIGNED_APK}"

JAVA_SOURCES=()
while IFS= read -r java_source; do
    JAVA_SOURCES[${#JAVA_SOURCES[@]}]="${java_source}"
done < <(find "${SOURCE_ROOT}" "${GEN_DIR}" -name '*.java' -type f | sort)
if [[ "${#JAVA_SOURCES[@]}" -eq 0 ]]; then
    printf 'No Java sources found under %s\n' "${SOURCE_ROOT}" >&2
    exit 1
fi

"${JAVAC}" \
    --release 8 \
    -encoding UTF-8 \
    -Xlint:-options \
    -classpath "${ANDROID_JAR}" \
    -d "${CLASS_DIR}" \
    "${JAVA_SOURCES[@]}"

CLASS_FILES=()
while IFS= read -r class_file; do
    CLASS_FILES[${#CLASS_FILES[@]}]="${class_file}"
done < <(find "${CLASS_DIR}" -name '*.class' -type f | sort)
if [[ "${#CLASS_FILES[@]}" -eq 0 ]]; then
    printf 'No compiled classes found under %s\n' "${CLASS_DIR}" >&2
    exit 1
fi

"${D8}" \
    --min-api 29 \
    --lib "${ANDROID_JAR}" \
    --output "${DEX_DIR}" \
    "${CLASS_FILES[@]}"

cp "${UNSIGNED_APK}" "${UNALIGNED_APK}"
(
    cd "${DEX_DIR}"
    "${JAR}" uf "${UNALIGNED_APK}" classes.dex
)

"${ZIPALIGN}" -f -p 4 "${UNALIGNED_APK}" "${ALIGNED_APK}"

"${JAVA}" -jar "${APKSIGNER_JAR}" sign \
    --ks "${DEBUG_KEYSTORE}" \
    --ks-key-alias androiddebugkey \
    --ks-pass pass:android \
    --key-pass pass:android \
    --out "${FINAL_APK}" \
    "${ALIGNED_APK}"

"${JAVA}" -jar "${APKSIGNER_JAR}" verify \
    --verbose \
    --print-certs \
    "${FINAL_APK}" | tee "${BUILD_DIR}/apksigner-verify.txt"

"${ZIPALIGN}" -c -v 4 "${FINAL_APK}" >/dev/null

BADGING="$("${AAPT}" dump badging "${FINAL_APK}")"
PERMISSIONS="$("${AAPT}" dump permissions "${FINAL_APK}")"

printf '%s\n' "${BADGING}" | grep -F "package: name='local.androiduse.probe'" >/dev/null
printf '%s\n' "${BADGING}" | grep -F "sdkVersion:'29'" >/dev/null
printf '%s\n' "${BADGING}" | grep -F "targetSdkVersion:'34'" >/dev/null
printf '%s\n' "${BADGING}" | grep -F "launchable-activity: name='local.androiduse.probe.MainActivity'" >/dev/null

python3 - "${PERMISSIONS}" <<'PY'
import sys
permissions = [line.strip() for line in sys.argv[1].splitlines()
               if line.strip().startswith('uses-permission:')]
if permissions != ["uses-permission: name='android.permission.CAMERA'"]:
    raise SystemExit('Probe must declare CAMERA only; no network or storage permissions: ' + repr(permissions))
PY

printf 'Built and verified: %s\n' "${FINAL_APK}"
printf 'Package: local.androiduse.probe | minSdk 29 | targetSdk 34 | permissions: CAMERA only\n'
