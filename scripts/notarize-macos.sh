#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP="${MACDORA_APP_BUNDLE:-$PROJECT_ROOT/artifacts/Macdora.app}"
NOTARY_PROFILE="${MACDORA_NOTARY_PROFILE:-}"
NOTARIZATION_DIR="${MACDORA_NOTARIZATION_DIR:-$PROJECT_ROOT/artifacts/notarization}"
WAIT_SECONDS="${MACDORA_NOTARY_WAIT_SECONDS:-60}"
POLL_SECONDS="${MACDORA_NOTARY_POLL_SECONDS:-5}"
RESUME_ID=""

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resume)
      [[ $# -ge 2 ]] || die "--resume requires a submission UUID."
      RESUME_ID="$2"; shift 2 ;;
    --help)
      printf 'Usage: MACDORA_NOTARY_PROFILE=<keychain-profile> bash scripts/notarize-macos.sh [--resume <submission-uuid>]\n'
      exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done
if [[ -n "$RESUME_ID" && ! "$RESUME_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
  die "--resume requires a valid submission UUID."
fi

if [[ -z "$NOTARY_PROFILE" ]]; then
  die "Set MACDORA_NOTARY_PROFILE to a notarytool keychain profile."
fi
if [[ ! "$WAIT_SECONDS" =~ ^[0-9]+$ ]] || (( WAIT_SECONDS < 1 || WAIT_SECONDS > 60 )); then
  die "MACDORA_NOTARY_WAIT_SECONDS must be an integer from 1 through 60."
fi
if [[ ! "$POLL_SECONDS" =~ ^[0-9]+$ ]] || (( POLL_SECONDS < 1 || POLL_SECONDS > 60 )); then
  die "MACDORA_NOTARY_POLL_SECONDS must be an integer from 1 through 60."
fi
if [[ ! -d "$APP" || -L "$APP" ]]; then
  die "Macdora app bundle not found at a safe path: $APP"
fi
if [[ ! -f "$APP/Contents/Info.plist" ]]; then
  die "Macdora app bundle has no Info.plist: $APP"
fi
if [[ -L "$NOTARIZATION_DIR" ]]; then
  die "Refusing a symbolic-link notarization output directory."
fi

mkdir -p "$NOTARIZATION_DIR"
NOTARIZATION_DIR="$(cd "$NOTARIZATION_DIR" && pwd -P)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
NAME="Macdora-${VERSION}-build-${BUILD}-${STAMP}"
SUBMISSION_ZIP="$NOTARIZATION_DIR/${NAME}-submission.zip"
SUBMISSION_JSON="$NOTARIZATION_DIR/${NAME}-submit.json"
INFO_JSON="$NOTARIZATION_DIR/${NAME}-latest-info.json"
FINAL_INFO_JSON="$NOTARIZATION_DIR/${NAME}-accepted.json"
NOTARY_LOG="$NOTARIZATION_DIR/${NAME}-notary-log.json"
ACCEPTANCE_LOG="$NOTARIZATION_DIR/${NAME}-acceptance.log"
PREFLIGHT_LOG="$NOTARIZATION_DIR/${NAME}-preflight.log"
FINAL_ARCHIVE="$NOTARIZATION_DIR/${NAME}.zip"

log() {
  printf '%s\n' "$*" | tee -a "$ACCEPTANCE_LOG"
}

verify_release_signature() {
  python3 - "$APP" <<'PY'
import re,subprocess,sys
from pathlib import Path
app=Path(sys.argv[1])
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
def display(path):
  result=subprocess.run(['/usr/bin/codesign','--display','--verbose=4',str(path)],
                        capture_output=True,text=True,check=True)
  return result.stdout+result.stderr
entries=list(app.rglob('*'))
if any(path.is_symlink() for path in entries):
  raise SystemExit('Refusing to notarize a bundle containing symbolic links.')
paths=[path for path in entries if path.is_file() and is_macho(path)]
if not paths:
  raise SystemExit('No Mach-O code found in app bundle.')
infos={path:display(path) for path in paths}
def team_id(info):
 values=[line.split('=',1)[1].strip() for line in info.splitlines()
         if line.startswith('TeamIdentifier=')]
 return values[0] if len(values)==1 and re.fullmatch(r'[A-Z0-9]{10}',values[0]) else None
teams=set()
for path,info in infos.items():
  relative=path.relative_to(app)
  flags=re.search(r'\bflags=0x([0-9a-fA-F]+)',info)
  if not flags or not (int(flags.group(1),16)&0x10000):
   raise SystemExit(f'Missing hardened runtime: {relative}')
  if 'Signature=adhoc' in info or 'Authority=Developer ID Application:' not in info:
   raise SystemExit(f'Not Developer ID signed: {relative}')
  if not re.search(r'(?m)^Timestamp=\S',info):
   raise SystemExit(f'Missing secure signing timestamp: {relative}')
  team=team_id(info)
  if team is None:
   raise SystemExit(f'Missing TeamIdentifier: {relative}')
  teams.add(team)
if len(teams)!=1:
  raise SystemExit('Mach-O TeamIdentifier values do not match.')
team=teams.pop()
req='=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13]'
req+=f' and certificate leaf[subject.OU] = "{team}"'
subprocess.run(['/usr/bin/codesign','--verify','--strict','--verbose=2','-R',req,str(app)],check=True)
for path in paths:
  subprocess.run(['/usr/bin/codesign','--verify','--strict','--verbose=2','-R',req,str(path)],check=True)
print(f'Developer ID TeamIdentifier: {team}')
print(f'Verified {len(paths)} Developer ID-signed Mach-O files.')
PY
}

normalize_status() {
  python3 -c 'import sys; print(str(sys.argv[1]).strip().lower())' "$1"
}

extract_submission_id() {
  python3 - "$1" <<'PY'
import json,re,sys
from pathlib import Path
text=Path(sys.argv[1]).read_text()
try:
  value=json.loads(text).get('id')
except json.JSONDecodeError:
  raise SystemExit('notarytool submit did not return JSON.')
if not isinstance(value,str) or not re.fullmatch(r'[0-9A-Fa-f-]{36}',value):
  raise SystemExit('notarytool submit did not return a submission UUID.')
print(value)
PY
}

extract_status() {
  python3 - "$1" <<'PY'
import json,sys
from pathlib import Path
value=json.loads(Path(sys.argv[1]).read_text()).get('status')
if not isinstance(value,str) or not value.strip():
  raise SystemExit('notarytool info did not return a status.')
print(value)
PY
}

notary() {
  /usr/bin/xcrun notarytool "$@" --keychain-profile "$NOTARY_PROFILE" \
    --output-format json --no-progress
}

for output in "$SUBMISSION_ZIP" "$SUBMISSION_JSON" "$INFO_JSON" "$FINAL_INFO_JSON" \
  "$NOTARY_LOG" "$ACCEPTANCE_LOG" "$PREFLIGHT_LOG" "$FINAL_ARCHIVE"; do
  if [[ -e "$output" || -L "$output" ]]; then
    die "Refusing to overwrite an existing notarization output: $output"
  fi
done
printf 'Preflight Macdora notarization %s (Build %s)\n' "$VERSION" "$BUILD" | tee "$PREFLIGHT_LOG"
log "App: $APP"
log "Keychain profile source: MACDORA_NOTARY_PROFILE (value redacted)"
verify_release_signature 2>&1 | tee -a "$PREFLIGHT_LOG"
log "Developer ID, secure timestamp, hardened runtime, nested signature, and Team checks passed."
# Submit once. The service continues processing after a client timeout, so its
# returned UUID is always used for subsequent status checks.
GOT_SUBMISSION=0
if [[ -n "$RESUME_ID" ]]; then
  log "Resuming existing submission: $RESUME_ID"
  notary info "$RESUME_ID" >"$SUBMISSION_JSON"
  GOT_SUBMISSION=1
else
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$SUBMISSION_ZIP"
  log "Created fresh notarization ZIP: $SUBMISSION_ZIP"
  if /usr/bin/xcrun notarytool submit "$SUBMISSION_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" --output-format json --no-progress \
  >"$SUBMISSION_JSON"; then
    GOT_SUBMISSION=1
  else
    if python3 - "$SUBMISSION_JSON" <<'PY'
import json,sys
from pathlib import Path
try:
  value=json.loads(Path(sys.argv[1]).read_text()).get('id')
except Exception:
  raise SystemExit(1)
raise SystemExit(0 if isinstance(value,str) and value else 1)
PY
    then
      GOT_SUBMISSION=1
    fi
  fi
fi
if [[ "$GOT_SUBMISSION" != "1" ]]; then
  die "notarytool submit failed before returning a submission UUID. Inspect $SUBMISSION_JSON; do not resubmit blindly."
fi
SUBMISSION_ID="$(extract_submission_id "$SUBMISSION_JSON")"
log "Submission credentials: not echoed"
log "Submission UUID: $SUBMISSION_ID"

FINAL_STATUS="$(extract_status "$SUBMISSION_JSON" 2>/dev/null || true)"
if [[ -z "$FINAL_STATUS" ]]; then
  FINAL_STATUS="$(normalize_status "$(python3 - "$SUBMISSION_JSON" <<'PY'
import json,sys
from pathlib import Path
print(json.loads(Path(sys.argv[1]).read_text()).get('status',''))
PY
)")"
fi
WAITED=0
while [[ "$(normalize_status "$FINAL_STATUS")" != "accepted" ]]; do
  STATUS="$(normalize_status "$FINAL_STATUS")"
  if [[ "$STATUS" == "invalid" || "$STATUS" == "rejected" ]]; then
    notary log "$SUBMISSION_ID" "$NOTARY_LOG" || true
    die "Notarization status is ${FINAL_STATUS}. Inspect $INFO_JSON and $NOTARY_LOG."
  fi
  if (( WAITED >= WAIT_SECONDS )); then
    notary info "$SUBMISSION_ID" >"$INFO_JSON" || true
    die "Notarization is still ${FINAL_STATUS} after ${WAIT_SECONDS}s. Resume with: MACDORA_NOTARY_PROFILE='<keychain-profile>' bash scripts/notarize-macos.sh --resume ${SUBMISSION_ID}"
  fi
  SLEEP_SECONDS=$POLL_SECONDS
  if (( WAITED + SLEEP_SECONDS > WAIT_SECONDS )); then
    SLEEP_SECONDS=$((WAIT_SECONDS - WAITED))
  fi
  sleep "$SLEEP_SECONDS"
  WAITED=$((WAITED + SLEEP_SECONDS))
  if notary info "$SUBMISSION_ID" >"$INFO_JSON"; then
    FINAL_STATUS="$(extract_status "$INFO_JSON")"
    log "Notary status after ${WAITED}s: ${FINAL_STATUS}"
  else
    log "Notary status check failed after ${WAITED}s; polling will continue within the current script limit."
  fi
done

if [[ -f "$INFO_JSON" ]]; then
  /bin/cp -f "$INFO_JSON" "$FINAL_INFO_JSON"
else
  /bin/cp -f "$SUBMISSION_JSON" "$FINAL_INFO_JSON"
fi
notary log "$SUBMISSION_ID" "$NOTARY_LOG"
log "Notary status accepted."

/usr/bin/xcrun stapler staple "$APP"
/usr/bin/xcrun stapler validate "$APP"
/usr/sbin/spctl --assess --type execute --verbose=4 "$APP" 2>&1 | tee -a "$ACCEPTANCE_LOG" || \
  die "Gatekeeper execution assessment failed."
if [[ -x /usr/bin/syspolicy_check ]]; then
  /usr/bin/syspolicy_check distribution "$APP" --verbose 2>&1 | tee -a "$ACCEPTANCE_LOG" || \
    die "Distribution readiness assessment failed."
fi
log "Staple, Gatekeeper, and distribution checks passed."

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$FINAL_ARCHIVE"
log "Created post-staple distribution ZIP: $FINAL_ARCHIVE"
log "Submission JSON: $SUBMISSION_JSON"
log "Final status JSON: $FINAL_INFO_JSON"
log "Notary log: $NOTARY_LOG"

printf 'Notarization accepted and ticket stapled. Distribution ZIP: %s\n' "$FINAL_ARCHIVE"
