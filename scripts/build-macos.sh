#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$PROJECT_ROOT"
CONFIGURATION="${ANDROID_USE_BUILD_CONFIGURATION:-release}"
APP="$PROJECT_ROOT/artifacts/Macdora.app"
LEGACY_APP="$PROJECT_ROOT/artifacts/Android Use.app"
MACDORA_VERSION="$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION" 2>/dev/null || echo '0.01')"
MACDORA_BUILD="${MACDORA_BUILD_NUMBER:-6}"
MACDORA_REPO="${MACDORA_GITHUB_REPOSITORY:-samwang0041-star/macdora}"
BUNDLE_RUNTIME="${MACDORA_BUNDLE_RUNTIME:-0}"
if [[ "$BUNDLE_RUNTIME" != "0" && "$BUNDLE_RUNTIME" != "1" ]]; then
  echo "MACDORA_BUNDLE_RUNTIME must be 0 or 1." >&2
  exit 2
fi
IMAGE_NAME="aosp-api37-r6"
IMAGE_SOURCE="$PROJECT_ROOT/.runtime/images/$IMAGE_NAME/arm64-v8a"
IMAGE_METADATA="$PROJECT_ROOT/evidence/research/android17-aosp-image-files.json"
python3 - "$APP/Contents/MacOS/AndroidUse" "$LEGACY_APP/Contents/MacOS/AndroidUse" <<'PY'
import ctypes,subprocess,sys
lib=ctypes.CDLL('/usr/lib/libproc.dylib')
lib.proc_pidpath.argtypes=[ctypes.c_int,ctypes.c_void_p,ctypes.c_uint32]
lib.proc_pidpath.restype=ctypes.c_int
targets=set(sys.argv[1:])
for value in subprocess.run(['ps','-ax','-o','pid='],capture_output=True,text=True,check=True).stdout.splitlines():
 path=ctypes.create_string_buffer(4096)
 if lib.proc_pidpath(int(value),path,4096)>0 and path.value.decode() in targets:
  raise SystemExit('Quit the running Macdora app before replacing its signed bundle.')
PY
if [[ -d "$LEGACY_APP" && ! -d "$APP" ]]; then
  mv "$LEGACY_APP" "$APP"
fi
python3 "$PROJECT_ROOT/scripts/prepare-build-inputs.py"
if [[ "$BUNDLE_RUNTIME" == "1" ]]; then
  python3 "$PROJECT_ROOT/scripts/prepare-build-inputs.py" --runtime
  python3 "$PROJECT_ROOT/scripts/prepare-aosp-image.py" --project-root "$PROJECT_ROOT"
fi
bash "$PROJECT_ROOT/scripts/build-ordered-server.sh"
bash "$PROJECT_ROOT/scripts/build-camera-sync.sh"
bash "$PROJECT_ROOT/scripts/build-moltenvk.sh"
bash "$PROJECT_ROOT/scripts/build-android-ime.sh"
swift build -c "$CONFIGURATION"
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
# A ticket from the previous build does not apply to the newly assembled code.
rm -f "$APP/Contents/CodeResources"
rm -rf "$APP/Contents/Resources"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Notices"
cp "$BIN_DIR/AndroidUse" "$APP/Contents/MacOS/AndroidUse"
if [[ "$CONFIGURATION" == "release" ]]; then
  # Keep local source/object paths and debug symbols out of the distribution.
  xcrun strip -S -x "$APP/Contents/MacOS/AndroidUse"
fi
cp "$PROJECT_ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$PROJECT_ROOT/.build/scrcpy-ordered/scrcpy-server" "$APP/Contents/Resources/scrcpy-server-v5.0.1"
cp "$PROJECT_ROOT/Vendor/scrcpy-5.0.1/LICENSE" "$APP/Contents/Resources/Notices/scrcpy-LICENSE.txt"
cp "$PROJECT_ROOT/LICENSE" "$APP/Contents/Resources/Notices/Macdora-LICENSE.txt"
cp "$PROJECT_ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/Notices/THIRD_PARTY_NOTICES.md"
cp "$PROJECT_ROOT/Vendor/scrcpy-5.0.1/NOTICE" "$APP/Contents/Resources/Notices/scrcpy-NOTICE.txt"
python3 - "$PROJECT_ROOT" "$APP" "$IMAGE_NAME" "$IMAGE_SOURCE" "$IMAGE_METADATA" "$MACDORA_VERSION" "$MACDORA_BUILD" "$BUNDLE_RUNTIME" <<'PY'
import hashlib,json,shutil,subprocess,sys
from pathlib import Path
project,app=map(Path,sys.argv[1:3])
image_name,image_source,image_metadata,macdora_version,macdora_build,bundle_runtime=sys.argv[3:]
bundle_runtime=bundle_runtime=='1'
image_source=Path(image_source)
image_metadata=Path(image_metadata)
if not image_metadata.is_file() or image_metadata.is_symlink():
 raise SystemExit('Image metadata is missing or unsafe')
ordered=json.loads((project/'.build/scrcpy-ordered/BUILD-MANIFEST.json').read_text())
server_digest=hashlib.file_digest((app/'Contents/Resources/scrcpy-server-v5.0.1').open('rb'),'sha256').hexdigest()
if server_digest != ordered['serverSHA256']: raise SystemExit('Ordered server digest mismatch')
seed=app/'Contents/Resources/RuntimeSeed'
seed.mkdir(exist_ok=True)
subprocess.run(['/bin/cp',str(project/'.build/android-ime/android-use-ime.apk'),str(seed/'android-use-ime.apk')],check=True)
subprocess.run(['/bin/cp',str(project/'.build/camera-sync/libmaccamera_frame_sync.dylib'),str(seed/'libmaccamera_frame_sync.dylib')],check=True)
subprocess.run(['/bin/chmod','755',str(seed/'libmaccamera_frame_sync.dylib')],check=True)
gpu_build=project/'.build/moltenvk-upstream/out'
gpu_library=gpu_build/'lib/libMoltenVK.dylib'
gpu_manifest=json.loads((gpu_build/'BUILD-MANIFEST.json').read_text())
gpu_digest=hashlib.file_digest(gpu_library.open('rb'),'sha256').hexdigest()
if gpu_manifest['librarySHA256'] != gpu_digest:
 raise SystemExit('GPU driver digest mismatch')
subprocess.run(['/bin/cp',str(gpu_library),str(seed/'libMacdoraMoltenVK.dylib')],check=True)
gpu_notices=app/'Contents/Resources/Notices/MoltenVK';gpu_notices.mkdir(exist_ok=True)
shutil.copytree(project/'Vendor/MoltenVK-1.4.2/licenses',gpu_notices/'licenses',dirs_exist_ok=True)
shutil.copy2(project/'Vendor/MoltenVK-1.4.2/manifest.json',gpu_notices/'manifest.json')
expected=json.loads(image_metadata.read_text())
if (expected.get('imageBuild')!='CE2A.260420.051.A3 / 16571990'
 or expected.get('androidVersion')!='17' or expected.get('apiLevel')!=37
 or expected.get('abi')!='arm64-v8a' or expected.get('revision')!=6
 or expected.get('tag')!='default'
 or expected.get('source')!='https://dl.google.com/android/repository/sys-img/android/arm64-v8a-37.0_r06.zip'):
 raise SystemExit('Android 17 image metadata identity mismatch')
if bundle_runtime and (not image_source.is_dir() or image_source.is_symlink()):
 raise SystemExit('Android 17 image source is missing or unsafe: '+str(image_source))

def verify_image(root):
 if not root.is_dir() or root.is_symlink():
  raise SystemExit('Image root is not a safe directory: '+str(root))
 expected_files=set(expected['files'])
 actual_files={path.relative_to(root).as_posix() for path in root.rglob('*') if path.is_file() or path.is_symlink()}
 if actual_files!=expected_files:
  raise SystemExit('Image file set mismatch: '+str(root))
 for path in root.rglob('*'):
  if path.is_symlink(): raise SystemExit('Image contains a symbolic link: '+str(path))
 for filename,metadata in expected['files'].items():
  path=root/filename
  if not path.is_file() or path.is_symlink() or path.stat().st_size!=metadata['size']:
   raise SystemExit('Image metadata mismatch: '+filename)
  if hashlib.file_digest(path.open('rb'),'sha256').hexdigest()!=metadata['sha256']:
   raise SystemExit('Image digest mismatch: '+filename)
 properties={}
 for line in (root/'source.properties').read_text().splitlines():
  if line and not line.startswith(('#','!')) and '=' in line:
   key,value=line.split('=',1);properties[key.strip()]=value.strip()
 if properties.get('AndroidVersion.ApiLevel')!='37.0' or properties.get('Pkg.Revision')!='6' or properties.get('SystemImage.TagId')!='default':
  raise SystemExit('Android 17 source.properties mismatch')
 build_properties={}
 for line in (root/'build.prop').read_text().splitlines():
  if line and not line.startswith(('#','!')) and '=' in line:
   key,value=line.split('=',1);build_properties[key.strip()]=value.strip()
 if (build_properties.get('ro.build.id')!='CE2A.260420.051.A3'
  or build_properties.get('ro.build.version.incremental')!='16571990'
  or build_properties.get('ro.build.version.release')!='17'
  or build_properties.get('ro.build.version.sdk')!='37'
  or build_properties.get('ro.build.version.sdk_full')!='37.0'
  or build_properties.get('ro.product.cpu.abi')!='arm64-v8a'):
  raise SystemExit('Android 17 build.prop mismatch')

pending_build_cleanup=[]
if bundle_runtime:
 verify_image(image_source)
 image_destination=seed/'image'
 image_staging=seed/('.image.'+image_name+'.preparing')
 image_previous=seed/('.image.'+image_name+'.previous')
 pending_build_cleanup=[]

 def discard_build_owned(path):
  if path.is_symlink() or path.is_file():
   path.unlink()
  elif path.is_dir():
   for child in path.rglob('*'):
    if child.is_dir() and not child.is_symlink(): child.chmod(child.stat().st_mode | 0o700)
   path.chmod(path.stat().st_mode | 0o700)
   shutil.rmtree(path)
  else:
   raise SystemExit('Unsafe build-owned image path: '+str(path))

 def move_build_owned(source,target):
  if target.exists() or target.is_symlink():
   raise SystemExit('Refusing to replace build-owned path: '+str(target))
  source.rename(target)

 if image_staging.exists() or image_staging.is_symlink():
  discard_build_owned(image_staging)
 if image_previous.exists() or image_previous.is_symlink():
  discard_build_owned(image_previous)
 existing_image_verified=False
 if image_destination.exists() or image_destination.is_symlink():
  try:
   verify_image(image_destination)
   existing_image_verified=True
  except (FileNotFoundError,SystemExit):
   pass
 if not existing_image_verified:
  image_staging.mkdir()
  pending_build_cleanup.append(image_staging)
  try:
   subprocess.run(['/bin/cp','-cR',str(image_source)+'/.',str(image_staging)],check=True)
   verify_image(image_staging)
  except BaseException:
   shutil.rmtree(image_staging,ignore_errors=True)
   pending_build_cleanup.remove(image_staging)
   raise
  if image_destination.exists() or image_destination.is_symlink():
   move_build_owned(image_destination,image_previous)
   pending_build_cleanup.append(image_previous)
  try:
   image_staging.rename(image_destination)
   pending_build_cleanup.remove(image_staging)
  except BaseException:
   if image_previous.exists() and not image_destination.exists():
    move_build_owned(image_previous,image_destination)
    verify_image(image_destination)
   raise
 verify_image(image_destination)
 if image_previous.exists() or image_previous.is_symlink():
  discard_build_owned(image_previous)
  pending_build_cleanup.remove(image_previous)
 sources={
  'emulator':project/'.cache/verified-runtime/emulator',
  'platform-tools':project/'.cache/verified-runtime/platform-tools',
 }
 for name,source in sources.items():
  destination=seed/name
  if not destination.exists():
   temporary=seed/(name+'.preparing')
   if temporary.exists():
    raise SystemExit('Incomplete local seed exists; inspect before retry: '+str(temporary))
   subprocess.run(['/bin/cp','-cR',str(source),str(temporary)],check=True)
   temporary.rename(destination)

else:
 # A release contains app components and image identity, never a copy of Android.
 for destination in ([seed/name for name in ['image','emulator','platform-tools']]
                     + list(seed.glob('.image.*.preparing')) + list(seed.glob('.image.*.previous'))):
  if destination.is_symlink() or destination.is_file(): destination.unlink()
  elif destination.exists():
   for child in destination.rglob('*'):
    if child.is_dir() and not child.is_symlink(): child.chmod(child.stat().st_mode | 0o700)
   destination.chmod(destination.stat().st_mode | 0o700)
   shutil.rmtree(destination)
 image_destination=seed/'image';image_destination.mkdir()
 for filename,content in {
  'source.properties':'AndroidVersion.ApiLevel=37.0\nPkg.Revision=6\nSystemImage.Abi=arm64-v8a\nSystemImage.TagId=default\n',
  'build.prop':'ro.build.id=CE2A.260420.051.A3\nro.build.version.incremental=16571990\nro.build.version.release=17\nro.build.version.sdk=37\nro.build.version.sdk_full=37.0\nro.product.cpu.abi=arm64-v8a\n',
 }.items(): (image_destination/filename).write_text(content)
 target=app/'Contents/Resources/Target'
 if target.is_symlink() or target.is_file(): target.unlink()
 elif target.exists(): shutil.rmtree(target)
if bundle_runtime:
 (app/'Contents/Resources/Notices/AOSP-NOTICE.txt').write_bytes((seed/'image/NOTICE.txt').read_bytes())
 for filename in ['NOTICE.txt','NOTICE.csv','LICENSE']:
  p=seed/'emulator'/filename
  if p.exists():(app/'Contents/Resources/Notices'/('emulator-'+filename)).write_bytes(p.read_bytes())
(app/'Contents/Resources/runtime-manifest.json').write_text(json.dumps({
 'macdoraVersion':macdora_version, 'macdoraBuild':macdora_build,
 'bundlesAndroidRuntime':bundle_runtime,
 'emulatorVersion':'37.2.12','emulatorBuild':'16428233','adbVersion':'37.0.1',
 'image':expected, 'scrcpyServerVersion':'5.0.1',
 'scrcpyServerSHA256':server_digest, 'scrcpyAdaptation':ordered,
 'directInputHelperPackage':'local.androiduse.ime',
 'directInputHelperSHA256':hashlib.file_digest((seed/'android-use-ime.apk').open('rb'),'sha256').hexdigest(),
 'cameraSyncHelperSHA256':hashlib.file_digest((seed/'libmaccamera_frame_sync.dylib').open('rb'),'sha256').hexdigest(),
 'graphicsDriver':gpu_manifest,
 'buildCleanupRelativePaths':[str(path.relative_to(seed)) for path in pending_build_cleanup],
},indent=2)+'\n')
PY
python3 - "$APP" "$MACDORA_VERSION" "$MACDORA_BUILD" "$MACDORA_REPO" <<'PY'
import plistlib,sys
from pathlib import Path
p=Path(sys.argv[1])/'Contents'
version,build_num,repo=sys.argv[2],sys.argv[3],sys.argv[4]
info={
 'CFBundleIdentifier':'local.androiduse.app',
 'CFBundleName':'Macdora', 'CFBundleDisplayName':'Macdora',
 'CFBundleIconFile':'AppIcon', 'CFBundleIconName':'AppIcon',
 'CFBundleExecutable':'AndroidUse','CFBundlePackageType':'APPL',
 'CFBundleShortVersionString':version,'CFBundleVersion':build_num,
 'MacdoraGitHubRepository':repo,
 'LSMinimumSystemVersion':'15.0','NSHighResolutionCapable':True,
 'NSCameraUsageDescription':'仅在 Android 应用需要摄像头认证或拍摄时，将你允许的 Mac 摄像头提供给本地 Android 环境。',
 'NSMicrophoneUsageDescription':'仅在 Android 应用需要录音时，将你允许的 Mac 麦克风提供给本地 Android 环境。',
 'NSPrincipalClass':'NSApplication',
}
(p/'Info.plist').write_bytes(plistlib.dumps(info))
PY
SIGN_ID="${ANDROID_USE_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_ID" ]]; then
  SIGN_ID="$(security find-identity -v -p codesigning | sed -nE '/Developer ID Application:/s/.* ([A-F0-9]{40}) .*/\1/p')"
  if [[ -z "$SIGN_ID" || "$SIGN_ID" == *$'\n'* ]]; then
    printf 'Set ANDROID_USE_SIGN_IDENTITY to one available Developer ID Application identity.\n' >&2
    exit 1
  fi
fi
# Only remove extended attributes from our newly assembled local artifact.
xattr -cr "$APP"
if [[ "$SIGN_ID" == "-" ]]; then
  TIMESTAMP_ARGUMENT="--timestamp=none"
else
  TIMESTAMP_ARGUMENT="--timestamp"
fi

# Sign nested Mach-O helpers from the deepest path outwards. The main executable
# and app bundle are signed after the runtime manifest has its final distributions.
python3 - "$APP" "$SIGN_ID" "$TIMESTAMP_ARGUMENT" "$PROJECT_ROOT/Resources/AndroidUse.entitlements" <<'PY'
import hashlib,json,plistlib,re,subprocess,sys
from pathlib import Path
app=Path(sys.argv[1]);identity=sys.argv[2];timestamp=sys.argv[3]
entitlements=Path(sys.argv[4])
development=identity=='-'
magic={
 b'\xfe\xed\xfa\xce',b'\xce\xfa\xed\xfe',
 b'\xfe\xed\xfa\xcf',b'\xcf\xfa\xed\xfe',
 b'\xca\xfe\xba\xbe',
}
def is_macho(path):
 try:
  with path.open('rb') as stream:return stream.read(4) in magic
 except OSError:return False
main_dir=app/'Contents/MacOS'
if main_dir.is_symlink() or not main_dir.is_dir():
 raise SystemExit('Invalid app executable directory')
main_executables=sorted(path for path in main_dir.rglob('*') if path.is_file() and not path.is_symlink() and is_macho(path))
nested=sorted(
 (path for path in app.rglob('*') if path.is_file() and not path.is_symlink() and is_macho(path) and main_dir not in path.parents),
 key=lambda path:len(path.relative_to(app).parts),reverse=True)
if not main_executables or not nested:
 raise SystemExit('Expected app executable and nested Mach-O helpers')
for path in nested:
 subprocess.run(['/usr/bin/codesign','--force','--options','runtime',timestamp,
                 '--sign',identity,str(path)],check=True)
primary_executable=main_dir/plistlib.loads((app/'Contents/Info.plist').read_bytes())['CFBundleExecutable']
if primary_executable not in main_executables:
 raise SystemExit('Primary app executable is missing or not Mach-O')
for path in main_executables:
 if path==primary_executable:continue
 subprocess.run(['/usr/bin/codesign','--force','--options','runtime',timestamp,
                 '--entitlements',str(entitlements),'--sign',identity,str(path)],check=True)

manifest_path=app/'Contents/Resources/runtime-manifest.json'
manifest=json.loads(manifest_path.read_text())
seed=app/'Contents/Resources/RuntimeSeed'
camera=seed/'libmaccamera_frame_sync.dylib'
gpu=seed/'libMacdoraMoltenVK.dylib'
graphics=manifest.get('graphicsDriver')
if not isinstance(graphics,dict):
 raise SystemExit('runtime manifest graphicsDriver provenance missing')
provenance_hash=graphics.get('librarySHA256')
if not isinstance(provenance_hash,str) or re.fullmatch(r'[0-9a-f]{64}',provenance_hash) is None:
 raise SystemExit('runtime manifest original graphicsDriver SHA-256 missing')
manifest['cameraSyncHelperSHA256']=hashlib.file_digest(camera.open('rb'),'sha256').hexdigest()
graphics['distributionLibrarySHA256']=hashlib.file_digest(gpu.open('rb'),'sha256').hexdigest()
manifest_path.write_text(json.dumps(manifest,indent=2)+'\n')

# Sign the app exactly once after all nested signatures and sealed metadata are final.
subprocess.run(['/usr/bin/codesign','--force','--options','runtime',timestamp,
                '--entitlements',str(entitlements),'--sign',identity,str(app)],check=True)

def team_id(info):
 values=[line.split('=',1)[1].strip() for line in info.splitlines()
         if line.startswith('TeamIdentifier=')]
 return values[0] if len(values)==1 and re.fullmatch(r'[A-Z0-9]{10}',values[0]) else None

def verify_machos():
 infos={}
 for path in sorted(nested+main_executables+[app]):
  result=subprocess.run(['/usr/bin/codesign','--display','--verbose=4',str(path)],
                        capture_output=True,text=True,check=True)
  info=result.stdout+result.stderr
  relative=path.relative_to(app) if path!=app else Path(app.name)
  flags=re.search(r'\bflags=0x([0-9a-fA-F]+)',info)
  if not flags or not (int(flags.group(1),16)&0x10000):
   raise SystemExit('Mach-O missing hardened runtime: '+str(relative))
  if 'Signature=adhoc' in info:
   if not development:
    raise SystemExit('Formal build contains ad-hoc Mach-O: '+str(relative))
   if 'Timestamp=' in info:
    raise SystemExit('Development Mach-O unexpectedly has a secure timestamp: '+str(relative))
  else:
   if development:
    raise SystemExit('Development build unexpectedly has identity-signed Mach-O: '+str(relative))
   if 'Authority=Developer ID Application:' not in info:
    raise SystemExit('Mach-O is not signed by Developer ID Application: '+str(relative))
   if 'Timestamp=' not in info:
    raise SystemExit('Developer ID Mach-O is missing a secure timestamp: '+str(relative))
   if team_id(info) is None:
    raise SystemExit('Developer ID Mach-O is missing TeamIdentifier: '+str(relative))
  infos[path]=info
 teams={value for info in infos.values() if (value:=team_id(info)) is not None}
 if not development and len(teams)!=1:
  raise SystemExit('Mach-O TeamIdentifier values do not match')
 team=next(iter(teams)) if teams else None
 verify=['/usr/bin/codesign','--verify','--strict','--verbose=2']
 if not development and team:
  verify+=['-R',f'=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "{team}"']
 for path in infos:
  subprocess.run(verify+[str(path)],check=True)
 return teams

teams=verify_machos()
if not development and len(teams)!=1:
 raise SystemExit('Developer ID signing Team verification failed')
final_manifest=json.loads(manifest_path.read_text())
if (final_manifest.get('cameraSyncHelperSHA256')!=hashlib.file_digest(camera.open('rb'),'sha256').hexdigest()
    or final_manifest['graphicsDriver'].get('distributionLibrarySHA256')!=hashlib.file_digest(gpu.open('rb'),'sha256').hexdigest()
    or final_manifest['graphicsDriver'].get('librarySHA256')!=provenance_hash):
 raise SystemExit('Signed distribution hashes or original provenance do not match')
PY
printf 'Built and signed: %s\n' "$APP"
