#!/usr/bin/env bash
set -euo pipefail
umask 077

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
INPUT_ROOT="$PROJECT_ROOT/Guest/GNSSKeepWarm"
OUTPUT_ROOT="$PROJECT_ROOT/.build/gnss-keepwarm"
TOOLS="${ANDROID_USE_BUILD_TOOLS:-$PROJECT_ROOT/.cache/android-sdk/build-tools/android-16}"
ANDROID_JAR="${ANDROID_USE_ANDROID_JAR:-$PROJECT_ROOT/.cache/android-sdk/platforms/android-36/android.jar}"
TASK_JDK="${ANDROID_USE_JDK:-$(bash "$PROJECT_ROOT/scripts/java-home.sh")}"
KEYSTORE=""
CREATE_KEYSTORE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keystore) KEYSTORE="${2:?Missing keystore path}"; shift 2 ;;
    --create-keystore) CREATE_KEYSTORE=1; shift ;;
    --help|-h)
      printf '%s\n' 'Usage: build-gnss-keepwarm.sh --keystore FILE [--create-keystore]'
      exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[[ -n "$KEYSTORE" ]] || { printf '%s\n' 'Select your APK signing keystore explicitly with --keystore.' >&2; exit 2; }
for tool in aapt d8 zipalign; do
  [[ -x "$TOOLS/$tool" ]] || { printf 'Missing Android build tool: %s\n' "$tool" >&2; exit 1; }
done
[[ -f "$ANDROID_JAR" && -f "$TOOLS/lib/apksigner.jar" && -x "$TASK_JDK/bin/javac" ]] || {
  printf '%s\n' 'Android platform, apksigner, or JDK is missing. Prepare the project build inputs first.' >&2
  exit 1
}
export JAVA_HOME="$TASK_JDK"
export PATH="$TASK_JDK/bin:$TOOLS:$PATH"
export LC_ALL=C
export TZ=UTC
export MACDORA_GNSS_KEYSTORE_PASSWORD="${MACDORA_GNSS_KEYSTORE_PASSWORD:-android}"

python3 - "$PROJECT_ROOT" "$OUTPUT_ROOT" "$KEYSTORE" "$CREATE_KEYSTORE" "$TASK_JDK" <<'PY'
import os
from pathlib import Path
import stat
import subprocess
import sys

root, output, key, create, jdk = sys.argv[1:]
root = Path(root).resolve()
output = Path(output)
key = Path(key).expanduser().absolute()
for candidate in (output, key):
    for part in (candidate, *candidate.parents):
        if part.is_symlink():
            raise SystemExit('Refusing a symlink in a build or signing path.')
if key.is_relative_to(root) and not key.is_relative_to(root / '.build'):
    raise SystemExit('Store signing material outside public sources or under ignored .build/.')
output.mkdir(parents=True, exist_ok=True)
if not key.exists():
    if create != '1':
        raise SystemExit('Keystore is missing; use --create-keystore with your selected path.')
    key.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    subprocess.run([
        str(Path(jdk) / 'bin/keytool'), '-genkeypair', '-keystore', str(key),
        '-storetype', 'PKCS12', '-storepass:env', 'MACDORA_GNSS_KEYSTORE_PASSWORD',
        '-keypass:env', 'MACDORA_GNSS_KEYSTORE_PASSWORD', '-alias', 'macdora-gnss',
        '-keyalg', 'RSA', '-keysize', '2048', '-validity', '10000',
        '-dname', 'CN=Macdora GNSS Helper', '-noprompt',
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    key.chmod(0o600)
attrs = key.stat()
if not stat.S_ISREG(attrs.st_mode) or attrs.st_mode & 0o077 or attrs.st_uid != os.getuid():
    raise SystemExit('The selected keystore must be an owner-only regular file (0600).')
PY

TASK_WORK="$(mktemp -d "$OUTPUT_ROOT/work-XXXXXXXX")"
cleanup() {
  python3 - "$TASK_WORK" <<'PY'
from pathlib import Path
import shutil
import sys
path = Path(sys.argv[1])
if path.name.startswith('work-') and not path.is_symlink():
    shutil.rmtree(path)
PY
}
trap cleanup EXIT
mkdir -p "$TASK_WORK/generated" "$TASK_WORK/classes" "$TASK_WORK/dex"
"$TOOLS/aapt" package -f -m -J "$TASK_WORK/generated" -M "$INPUT_ROOT/AndroidManifest.xml" \
  -S "$INPUT_ROOT/res" -I "$ANDROID_JAR" -F "$TASK_WORK/unsigned.apk"
JAVA_FILES=()
while IFS= read -r input; do JAVA_FILES[${#JAVA_FILES[@]}]="$input"; done < <(find "$INPUT_ROOT/src" "$TASK_WORK/generated" -type f -name '*.java' | sort)
"$TASK_JDK/bin/javac" --release 8 -encoding UTF-8 -g:none -Xlint:-options \
  -classpath "$ANDROID_JAR" -d "$TASK_WORK/classes" "${JAVA_FILES[@]}"
CLASS_FILES=()
while IFS= read -r input; do CLASS_FILES[${#CLASS_FILES[@]}]="$input"; done < <(find "$TASK_WORK/classes" -type f -name '*.class' | sort)
"$TOOLS/d8" --release --min-api 29 --lib "$ANDROID_JAR" --output "$TASK_WORK/dex" "${CLASS_FILES[@]}"

# Normalize all ZIP metadata before alignment and RSA signing.
python3 - "$TASK_WORK" <<'PY'
from pathlib import Path
import sys
import zipfile
work = Path(sys.argv[1])
with zipfile.ZipFile(work / 'unsigned.apk') as source:
    entries = {i.filename: (source.read(i), i.compress_type) for i in source.infolist() if not i.is_dir()}
entries['classes.dex'] = ((work / 'dex/classes.dex').read_bytes(), zipfile.ZIP_DEFLATED)
with zipfile.ZipFile(work / 'normalized.apk', 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as output:
    for name, (data, compression) in sorted(entries.items()):
        info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
        info.create_system = 3
        info.external_attr = 0o100644 << 16
        info.compress_type = compression
        output.writestr(info, data)
PY
"$TOOLS/zipalign" -f -p 4 "$TASK_WORK/normalized.apk" "$TASK_WORK/aligned.apk"
"$TASK_JDK/bin/java" -jar "$TOOLS/lib/apksigner.jar" sign \
  --ks "$KEYSTORE" --ks-key-alias macdora-gnss \
  --ks-pass env:MACDORA_GNSS_KEYSTORE_PASSWORD --key-pass env:MACDORA_GNSS_KEYSTORE_PASSWORD \
  --v1-signing-enabled false --v2-signing-enabled true --v3-signing-enabled true --v4-signing-enabled false \
  --out "$TASK_WORK/au-gnss-keepwarm.apk" "$TASK_WORK/aligned.apk"
"$TASK_JDK/bin/java" -jar "$TOOLS/lib/apksigner.jar" verify --verbose "$TASK_WORK/au-gnss-keepwarm.apk"
"$TOOLS/zipalign" -c 4 "$TASK_WORK/au-gnss-keepwarm.apk"
mv "$TASK_WORK/au-gnss-keepwarm.apk" "$OUTPUT_ROOT/au-gnss-keepwarm.apk"
printf 'Built GNSS helper: %s\n' "$OUTPUT_ROOT/au-gnss-keepwarm.apk"
