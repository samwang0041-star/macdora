#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
INPUT_ROOT="$PROJECT_ROOT/Guest/DirectInput"
OUTPUT_ROOT="$PROJECT_ROOT/.build/android-ime"
SIGNING_ROOT="$PROJECT_ROOT/.build/android-ime-signing"
TOOLS="${ANDROID_USE_BUILD_TOOLS:-$PROJECT_ROOT/.cache/android-sdk/build-tools/android-16}"
ANDROID_JAR="${ANDROID_USE_ANDROID_JAR:-$PROJECT_ROOT/.cache/android-sdk/platforms/android-36/android.jar}"
TASK_JDK="${ANDROID_USE_JDK:-$(bash "$PROJECT_ROOT/scripts/java-home.sh")}"
if [[ ! -f "$ANDROID_JAR" || ! -x "$TOOLS/d8" ]]; then
    python3 "$PROJECT_ROOT/scripts/prepare-build-inputs.py"
fi
export JAVA_HOME="$TASK_JDK"
export PATH="$TASK_JDK/bin:$TOOLS:$PATH"
if [[ -L "$OUTPUT_ROOT" ]]; then exit 1; fi
rm -rf "$OUTPUT_ROOT"
mkdir -p "$OUTPUT_ROOT/generated" "$OUTPUT_ROOT/classes" "$OUTPUT_ROOT/dex"
if [[ -L "$SIGNING_ROOT" ]]; then exit 1; fi
mkdir -p "$SIGNING_ROOT"; chmod 700 "$SIGNING_ROOT"
KEYSTORE="$SIGNING_ROOT/local.keystore"
if [[ -L "$KEYSTORE" ]]; then exit 1; fi
COMMON_GIT_DIR="$(git -C "$PROJECT_ROOT" rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -n "$COMMON_GIT_DIR" ]]; then
    SHARED_SIGNING_ROOT="$(cd "$PROJECT_ROOT" && cd "$COMMON_GIT_DIR/.." && pwd -P)/.build/android-ime-signing"
    SHARED_KEYSTORE="$SHARED_SIGNING_ROOT/local.keystore"
    LOCK_DIR="$SHARED_SIGNING_ROOT/.keystore.lock"
    mkdir -p "$SHARED_SIGNING_ROOT"
    chmod 700 "$SHARED_SIGNING_ROOT"
    LOCK_WAIT=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        sleep 0.1
        LOCK_WAIT=$((LOCK_WAIT + 1))
        if [[ $LOCK_WAIT -ge 100 ]]; then
            echo "Timed out waiting for shared keystore lock: $LOCK_DIR" >&2
            exit 1
        fi
    done
    trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
    if [[ ! -f "$SHARED_KEYSTORE" ]]; then
        TMP_KEYSTORE="$SHARED_SIGNING_ROOT/local.keystore.$$"
        keytool -genkeypair -keystore "$TMP_KEYSTORE" -storepass android -alias localime -keypass android \
            -dname 'CN=Android Use Local Input' -keyalg RSA -keysize 2048 -validity 10000 >/dev/null 2>&1
        chmod 600 "$TMP_KEYSTORE"
        mv -f "$TMP_KEYSTORE" "$SHARED_KEYSTORE"
    fi
    if [[ "$SHARED_KEYSTORE" != "$KEYSTORE" ]]; then
        cp -p "$SHARED_KEYSTORE" "$KEYSTORE"
    fi
    rmdir "$LOCK_DIR" 2>/dev/null || true
    trap - EXIT
fi
if [[ ! -e "$KEYSTORE" ]]; then
    keytool -genkeypair -keystore "$KEYSTORE" -storepass android -alias localime -keypass android \
        -dname 'CN=Android Use Local Input' -keyalg RSA -keysize 2048 -validity 10000 >/dev/null 2>&1
fi
chmod 600 "$KEYSTORE"
"$TOOLS/aapt" package -f -m -J "$OUTPUT_ROOT/generated" -M "$INPUT_ROOT/AndroidManifest.xml" \
    -S "$INPUT_ROOT/res" -I "$ANDROID_JAR" -F "$OUTPUT_ROOT/unsigned.apk"
JAVA_FILES=()
while IFS= read -r input; do JAVA_FILES[${#JAVA_FILES[@]}]="$input"; done < <(find "$INPUT_ROOT/src" "$OUTPUT_ROOT/generated" -type f -name '*.java' | sort)
"$TASK_JDK/bin/javac" --release 8 -encoding UTF-8 -Xlint:-options -classpath "$ANDROID_JAR" -d "$OUTPUT_ROOT/classes" "${JAVA_FILES[@]}"
CLASS_FILES=()
while IFS= read -r input; do CLASS_FILES[${#CLASS_FILES[@]}]="$input"; done < <(find "$OUTPUT_ROOT/classes" -type f -name '*.class' | sort)
"$TOOLS/d8" --min-api 29 --lib "$ANDROID_JAR" --output "$OUTPUT_ROOT/dex" "${CLASS_FILES[@]}"
cp "$OUTPUT_ROOT/unsigned.apk" "$OUTPUT_ROOT/unaligned.apk"
(cd "$OUTPUT_ROOT/dex"; "$TASK_JDK/bin/jar" uf "$OUTPUT_ROOT/unaligned.apk" classes.dex)
"$TOOLS/zipalign" -f -p 4 "$OUTPUT_ROOT/unaligned.apk" "$OUTPUT_ROOT/aligned.apk"
"$TASK_JDK/bin/java" -jar "$TOOLS/lib/apksigner.jar" sign --ks "$KEYSTORE" --ks-key-alias localime \
    --ks-pass pass:android --key-pass pass:android --out "$OUTPUT_ROOT/android-use-ime.apk" "$OUTPUT_ROOT/aligned.apk"
"$TASK_JDK/bin/java" -jar "$TOOLS/lib/apksigner.jar" verify --verbose "$OUTPUT_ROOT/android-use-ime.apk"
"$TOOLS/zipalign" -c 4 "$OUTPUT_ROOT/android-use-ime.apk"
printf 'Built own direct-input helper: %s\n' "$OUTPUT_ROOT/android-use-ime.apk"
