#!/usr/bin/env python3
"""Start the pinned server in our isolated development emulator; no business actions."""
import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess
import time

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--adb", default="/opt/homebrew/share/android-commandlinetools/platform-tools/adb")
parser.add_argument("--adb-port", type=int, default=5041)
parser.add_argument("--serial", default="emulator-5580")
parser.add_argument("--port", type=int, default=27184)
args = parser.parse_args()
runtime = root / ".runtime"
env = os.environ | {"ANDROID_USER_HOME": str(runtime / "android"), "ADB_SERVER_SOCKET": f"tcp:127.0.0.1:{args.adb_port}"}
adb = [args.adb, "-H", "127.0.0.1", "-P", str(args.adb_port), "-s", args.serial]
server = root / ".build/scrcpy-ordered/scrcpy-server"
manifest = json.loads((server.parent / 'BUILD-MANIFEST.json').read_text())
import hashlib
if hashlib.file_digest(server.open('rb'), 'sha256').hexdigest() != manifest['serverSHA256']:
    raise SystemExit('Derived display server digest mismatch')
subprocess.run(adb + ["push", str(server), "/data/local/tmp/android-use-scrcpy.jar"], env=env, check=True, capture_output=True)
scid = secrets.randbelow(0x7fffffff)
socket = f"scrcpy_{scid:08x}"
subprocess.run(adb + ["forward", "--no-rebind", f"tcp:{args.port}", "localabstract:" + socket], env=env, check=True)
options = [
    f"scid={scid:08x}", "log_level=warn", "tunnel_forward=true", "audio=false", "control=true",
    "video_codec=h264", "video_bit_rate=24000000", "max_fps=60", "new_display=1080x1920/420",
    "vd_system_decorations=false", "display_ime_policy=local", "clipboard_autosync=false",
    "send_device_meta=false", "send_dummy_byte=false", "send_frame_meta=true", "send_stream_meta=true",
    "keep_active=true",
]
log = (runtime / "logs/native-display-server.log").open("ab")
command = adb + ["shell", "CLASSPATH=/data/local/tmp/android-use-scrcpy.jar", "app_process", "/", "com.genymobile.scrcpy.Server", "5.0.1"] + options
process = subprocess.Popen(command, env=env, stdout=log, stderr=log, start_new_session=True)
(runtime / "native-probe-process.json").write_text(json.dumps({"pid": process.pid, "createdAt": time.time(), "port": args.port, "scid": scid}, indent=2) + "\n")
print(f"Display probe server started; local port {args.port}, protocol 5.0.1.")
