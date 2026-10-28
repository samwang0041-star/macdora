#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
VENDOR_DIR="$PROJECT_ROOT/Vendor/scrcpy-5.0.1"
UPSTREAM_DIR="$PROJECT_ROOT/.cache/upstream/scrcpy-5.0.1"
UPSTREAM_ARCHIVE="$PROJECT_ROOT/.cache/upstream/scrcpy-v5.0.1-commit.tar.gz"
BUILD_DIR="$PROJECT_ROOT/.build/scrcpy-ordered"
SOURCE_DIR="$BUILD_DIR/source/server"
GEN_DIR="$BUILD_DIR/gen"
CLASSES_DIR="$BUILD_DIR/classes"
WORK_DIR="$BUILD_DIR/work"
TESTS_DIR="$BUILD_DIR/tests"

PLATFORM_ARCHIVE="$PROJECT_ROOT/.cache/downloads/platform-36_r02.zip"
BUILD_TOOLS_ARCHIVE="$PROJECT_ROOT/.cache/downloads/build-tools_r36_macosx.zip"
SDK_DIR="$PROJECT_ROOT/.cache/android-sdk"
PLATFORM_DIR="$SDK_DIR/platforms/android-36"
BUILD_TOOLS_DIR="$SDK_DIR/build-tools/android-16"
JAVA_HOME_DEFAULT="$(bash "$PROJECT_ROOT/scripts/java-home.sh")"
JAVA_HOME="${JAVA_HOME:-$JAVA_HOME_DEFAULT}"

SOURCE_SHA256="a0d699fc7388b8252416c49e6293639de39ab76a03e7302ddced56c284d45200"
SERVER_SHA256="764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536"
MANUAL_BUILDER_SHA256="1d3df77343f35c6b2a82bd782bb265ecaca8431d9e09cae0e79b93756738f748"
PATCH_SHA256="0a95edaed02b78f249cff01e38f259ed2b30406f16bfa4d4fa660ff954c10d03"
PLATFORM_ZIP_SHA256="37607369a28c5b640b3a7998868d45898ebcb777565a0e85f9acf36f29631d2e"
BUILD_TOOLS_ZIP_SHA256="04e7f3a72044de4926fa038fa0e251a37bba1e1c3fb8beab6f8401bfd9eb4bf3"

die() {
    printf 'build-ordered-server: %s\n' "$*" >&2
    exit 1
}

sha256() {
    shasum -a 256 "$1" | awk '{print $1}'
}

require_sha256() {
    local path="$1"
    local expected="$2"
    [[ -f "$path" ]] || die "Missing required file: $path"
    local actual
    actual="$(sha256 "$path")"
    [[ "$actual" == "$expected" ]] || die "SHA-256 mismatch for $path: expected $expected, got $actual"
}

require_sha1() {
    local path="$1"
    local expected="$2"
    local actual
    actual="$(shasum -a 1 "$path" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || die "SHA-1 mismatch for $path: expected $expected, got $actual"
}

if [[ ! -f "$UPSTREAM_ARCHIVE" || ! -f "$PLATFORM_ARCHIVE" || ! -f "$BUILD_TOOLS_ARCHIVE" || ! -f "$PROJECT_ROOT/.cache/upstream/scrcpy-server-v5.0.1" || ! -d "$UPSTREAM_DIR/server/src" ]]; then
    python3 "$PROJECT_ROOT/scripts/prepare-build-inputs.py"
fi
require_sha256 "$UPSTREAM_ARCHIVE" "$SOURCE_SHA256"
require_sha256 "$PROJECT_ROOT/.cache/upstream/scrcpy-server-v5.0.1" "$SERVER_SHA256"
require_sha256 "$VENDOR_DIR/scripts/build_without_gradle.sh" "$MANUAL_BUILDER_SHA256"
require_sha256 "$VENDOR_DIR/ordered-touch.patch" "$PATCH_SHA256"
require_sha256 "$PLATFORM_ARCHIVE" "$PLATFORM_ZIP_SHA256"
require_sha256 "$BUILD_TOOLS_ARCHIVE" "$BUILD_TOOLS_ZIP_SHA256"
require_sha1 "$PLATFORM_ARCHIVE" "2c1a80dd4d9f7d0e6dd336ec603d9b5c55a6f576"
require_sha1 "$BUILD_TOOLS_ARCHIVE" "199ae0047ee61e842f8ee0c6d3918e44fb9a1f83"

while read -r expected relative_path; do
    [[ -n "$expected" ]] || continue
    case "$relative_path" in
        .cache/*)
            require_sha256 "$PROJECT_ROOT/$relative_path" "$expected"
            ;;
        *)
            require_sha256 "$VENDOR_DIR/$relative_path" "$expected"
            ;;
    esac
done < "$VENDOR_DIR/SHA256SUMS"

rm -rf "$BUILD_DIR/source" "$GEN_DIR" "$CLASSES_DIR" "$WORK_DIR" "$TESTS_DIR"
mkdir -p "$SOURCE_DIR" "$GEN_DIR/com/genymobile/scrcpy" "$CLASSES_DIR" "$WORK_DIR" "$TESTS_DIR"

cp -R "$UPSTREAM_DIR/server/src" "$SOURCE_DIR/"
cp "$VENDOR_DIR/scripts/build_without_gradle.sh" "$BUILD_DIR/source/server/"

patch --batch --fuzz=0 -p1 -d "$BUILD_DIR/source" < "$VENDOR_DIR/ordered-touch.patch"

for path in \
    server/src/main/java/com/genymobile/scrcpy/control/ControlMessage.java \
    server/src/main/java/com/genymobile/scrcpy/control/ControlMessageReader.java \
    server/src/main/java/com/genymobile/scrcpy/control/Controller.java \
    server/src/main/java/com/genymobile/scrcpy/control/DeviceMessage.java \
    server/src/main/java/com/genymobile/scrcpy/control/DeviceMessageWriter.java \
    server/src/main/java/com/genymobile/scrcpy/control/DisplayConfigurationCoordinator.java \
    server/src/main/java/com/genymobile/scrcpy/control/DisplayStreamConfiguration.java \
    server/src/main/java/com/genymobile/scrcpy/control/TouchFinishedPolicy.java \
    server/src/main/java/com/genymobile/scrcpy/video/CaptureControl.java \
    server/src/main/java/com/genymobile/scrcpy/video/NewDisplayCapture.java \
    server/src/main/java/com/genymobile/scrcpy/video/SurfaceEncoder.java \
    server/src/test/java/com/genymobile/scrcpy/control/ControlMessageReaderTest.java \
    server/src/test/java/com/genymobile/scrcpy/control/ControllerTouchOrderedTest.java \
    server/src/test/java/com/genymobile/scrcpy/control/DeviceMessageWriterTest.java \
    server/src/test/java/com/genymobile/scrcpy/control/DisplayConfigurationProtocolTest.java; do
    [[ -f "$BUILD_DIR/source/$path" ]] || die "Patch did not produce $path"
done

if [[ ! -f "$PLATFORM_DIR/android.jar" ]]; then
    mkdir -p "$SDK_DIR/platforms"
    unzip -q "$PLATFORM_ARCHIVE" -d "$SDK_DIR/platforms"
fi
if [[ ! -x "$BUILD_TOOLS_DIR/d8" ]]; then
    mkdir -p "$SDK_DIR/build-tools"
    unzip -q "$BUILD_TOOLS_ARCHIVE" -d "$SDK_DIR/build-tools"
fi

"$BUILD_TOOLS_DIR/aidl" -o"$GEN_DIR" -I"$SOURCE_DIR/src/main/aidl" \
    "$SOURCE_DIR/src/main/aidl/android/content/IOnPrimaryClipChangedListener.aidl"
"$BUILD_TOOLS_DIR/aidl" -o"$GEN_DIR" -I"$SOURCE_DIR/src/main/aidl" \
    -p "$PLATFORM_DIR/framework.aidl" \
    "$SOURCE_DIR/src/main/aidl/android/view/IDisplayWindowListener.aidl"

cat > "$GEN_DIR/com/genymobile/scrcpy/BuildConfig.java" <<'EOF'
package com.genymobile.scrcpy;

public final class BuildConfig {
    public static final boolean DEBUG = false;
    public static final String VERSION_NAME = "5.0.1";
}
EOF

JAVA="$JAVA_HOME/bin/java"
JAVAC="$JAVA_HOME/bin/javac"
[[ -x "$JAVA" && -x "$JAVAC" ]] || die "JDK 21 not found at $JAVA_HOME"

JUNIT="$PROJECT_ROOT/.build/scrcpy-ordered/deps/junit-4.13.2.jar"
HAMCREST="$PROJECT_ROOT/.build/scrcpy-ordered/deps/hamcrest-core-1.3.jar"
JUNIT_URL="https://repo1.maven.org/maven2/junit/junit/4.13.2/junit-4.13.2.jar"
HAMCREST_URL="https://repo1.maven.org/maven2/org/hamcrest/hamcrest-core/1.3/hamcrest-core-1.3.jar"
JUNIT_SHA256="8e495b634469d64fb8acfa3495a065cbacc8a0fff55ce1e31007be4c16dc57d3"
HAMCREST_SHA256="66fdef91e9739348df7a096aa384a5685f4e875584cce89386a7a47251c4d8e9"
DEPENDENCIES_DIR="$PROJECT_ROOT/.build/scrcpy-ordered/deps"

fetch_pinned() {
    local path="$1"
    local url="$2"
    local expected="$3"
    local temporary="$path.tmp"

    mkdir -p "$DEPENDENCIES_DIR"
    if [[ -f "$path" ]]; then
        local actual
        actual="$(sha256 "$path")"
        if [[ "$actual" == "$expected" ]]; then
            return
        fi
    fi
    curl --fail --location --retry 2 --output "$temporary" "$url"
    local actual
    actual="$(sha256 "$temporary")"
    if [[ "$actual" != "$expected" ]]; then
        mv "$temporary" "$temporary.invalid"
        die "Downloaded dependency SHA-256 mismatch for $url: expected $expected, got $actual"
    fi
    mv "$temporary" "$path"
}

fetch_pinned "$JUNIT" "$JUNIT_URL" "$JUNIT_SHA256"
fetch_pinned "$HAMCREST" "$HAMCREST_URL" "$HAMCREST_SHA256"

FOCUSED_CLASSES="$TESTS_DIR/classes"
FOCUSED_TESTS="$TESTS_DIR/test-classes"
mkdir -p "$FOCUSED_CLASSES" "$FOCUSED_TESTS"
JAVA_SRC="$SOURCE_DIR/src/main/java"
"$JAVAC" -Xlint:-options -encoding UTF-8 -source 1.8 -target 1.8 \
    -bootclasspath "$PLATFORM_DIR/android.jar" \
    -cp "$BUILD_TOOLS_DIR/core-lambda-stubs.jar:$GEN_DIR" \
    -d "$FOCUSED_CLASSES" \
    "$JAVA_SRC"/android/content/*.java \
    "$JAVA_SRC"/com/genymobile/scrcpy/*.java \
    "$JAVA_SRC"/com/genymobile/scrcpy/control/*.java \
    "$JAVA_SRC"/com/genymobile/scrcpy/device/*.java \
    "$JAVA_SRC"/com/genymobile/scrcpy/display/*.java \
    "$JAVA_SRC"/com/genymobile/scrcpy/model/*.java \
    "$JAVA_SRC"/com/genymobile/scrcpy/util/*.java \
    "$JAVA_SRC"/com/genymobile/scrcpy/video/*.java \
    "$JAVA_SRC"/com/genymobile/scrcpy/wrappers/*.java \
    "$JAVA_SRC"/com/genymobile/scrcpy/opengl/*.java \
    "$JAVA_SRC"/com/genymobile/scrcpy/audio/*.java \
    "$GEN_DIR/com/genymobile/scrcpy/BuildConfig.java"

TEST_SRC="$SOURCE_DIR/src/test/java/com/genymobile/scrcpy/control"
"$JAVAC" -Xlint:-options -encoding UTF-8 -source 1.8 -target 1.8 \
    -bootclasspath "$PLATFORM_DIR/android.jar" \
    -cp "$FOCUSED_CLASSES:$JUNIT:$HAMCREST:$BUILD_TOOLS_DIR/core-lambda-stubs.jar" \
    -d "$FOCUSED_TESTS" \
    "$TEST_SRC/ControlMessageReaderTest.java" \
    "$TEST_SRC/DeviceMessageWriterTest.java" \
    "$TEST_SRC/ControllerTouchOrderedTest.java" \
    "$TEST_SRC/DisplayConfigurationProtocolTest.java"

"$JAVA" -cp "$FOCUSED_CLASSES:$FOCUSED_TESTS:$JUNIT:$HAMCREST" \
    org.junit.runner.JUnitCore \
    com.genymobile.scrcpy.control.ControlMessageReaderTest \
    com.genymobile.scrcpy.control.DeviceMessageWriterTest \
    com.genymobile.scrcpy.control.ControllerTouchOrderedTest \
    com.genymobile.scrcpy.control.DisplayConfigurationProtocolTest

mkdir -p "$BUILD_DIR/upstream-build"
ANDROID_HOME="$SDK_DIR" \
ANDROID_PLATFORM=36 \
ANDROID_BUILD_TOOLS=android-16 \
BUILD_DIR="$BUILD_DIR/upstream-build" \
PATH="$JAVA_HOME/bin:$PATH" \
    "$SOURCE_DIR/build_without_gradle.sh"

UPSTREAM_SERVER="$BUILD_DIR/upstream-build/scrcpy-server"
[[ -f "$UPSTREAM_SERVER" ]] || die "Manual compiler did not produce $UPSTREAM_SERVER"
SERVER="$BUILD_DIR/scrcpy-server"
cp "$UPSTREAM_SERVER" "$SERVER"

CHECK_DIR="$WORK_DIR/dex-check"
mkdir -p "$CHECK_DIR"
unzip -p "$SERVER" classes.dex > "$CHECK_DIR/classes.dex"
[[ -f "$CHECK_DIR/classes.dex" ]] || die "scrcpy-server does not contain classes.dex"
grep -aFq "TouchFinishedPolicy" "$CHECK_DIR/classes.dex" \
    || die "Patched touch policy missing from DEX"
grep -aFq "DisplayConfigurationCoordinator" "$CHECK_DIR/classes.dex" \
    || die "Display reconfiguration coordinator missing from DEX"
server_sha="$(sha256 "$SERVER")"

cat > "$BUILD_DIR/BUILD-MANIFEST.json" <<EOF
{
  "upstreamVersion": "5.0.1",
  "upstreamCommit": "a60891aea193d92e7e5c3942700eca63f9d19a5f",
  "sourceArchiveSHA256": "$SOURCE_SHA256",
  "upstreamServerSHA256": "$SERVER_SHA256",
  "orderedTouchPatchSHA256": "$PATCH_SHA256",
  "manualCompilerSHA256": "$MANUAL_BUILDER_SHA256",
  "androidPlatform": "36_r02",
  "androidPlatformArchiveSHA256": "$PLATFORM_ZIP_SHA256",
  "androidBuildTools": "36.0.0",
  "androidBuildToolsArchiveSHA256": "$BUILD_TOOLS_ZIP_SHA256",
  "javaVersion": "21",
  "protocol": {
    "requestType": 128,
    "requestSize": 9,
    "responseType": 3,
    "responseSize": 14
  },
  "displayConfigurationProtocol": {
    "requestType": 129,
    "requestSize": 25,
    "responseType": 4,
    "responseSize": 6,
    "ackTimeoutMilliseconds": 5000
  },
  "serverSHA256": "$server_sha"
}
EOF

printf 'Ordered-touch server: %s\nSHA-256: %s\n' "$SERVER" "$server_sha"
