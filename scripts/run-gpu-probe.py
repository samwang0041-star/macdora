#!/usr/bin/env python3
"""Run the dedicated GPU probe on an explicitly selected local test device.

The run ID must match before a result is accepted. Existing app data and other
packages are preserved; a signature mismatch aborts the installation.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adb', type=Path, required=True)
    parser.add_argument('--adb-port', type=int, required=True)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--display', type=int, default=0)
    parser.add_argument('--apk', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--include-large-indirect', action='store_true')
    args = parser.parse_args()
    apk = args.apk.resolve(strict=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    run_id = str(uuid.uuid4())
    adb = [str(args.adb.resolve(strict=True)), '-P', str(args.adb_port), '-s', args.serial]

    def run(*command, timeout=30):
        return subprocess.run(adb + list(command), capture_output=True, text=True,
                              timeout=timeout)

    def require(result):
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        return result

    manifest = {'runId': run_id, 'apkSHA256': hashlib.sha256(apk.read_bytes()).hexdigest(),
                'targetSerial': args.serial, 'adbPort': args.adb_port,
                'display': args.display, 'includeLargeIndirect': args.include_large_indirect,
                'startedEpoch': time.time(),
                'kind': 'functional verification; duration is not a benchmark'}
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    try:
        require(run('get-state'))
        require(run('shell', 'am force-stop local.androiduse.gpuprobe'))
        install = run('install', '--no-incremental', '-r', str(apk), timeout=90)
        (output / 'install.txt').write_text(install.stdout + install.stderr)
        require(install)
        require(run('shell', 'am force-stop local.androiduse.gpuprobe'))
        extra_flags = ' --ez include_large_indirect true' if args.include_large_indirect else ''
        launch = require(run('shell', 'am start -W -S --activity-clear-task --display ' + str(args.display)
                             + ' --es run_id ' + run_id
                             + extra_flags
                             + ' -n local.androiduse.gpuprobe/.MainActivity'))
        (output / 'launch.txt').write_text(launch.stdout + launch.stderr)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            response = run('shell', 'run-as local.androiduse.gpuprobe cat files/result.json', timeout=5)
            try:
                result = json.loads(response.stdout) if response.returncode == 0 else {}
            except ValueError:
                result = {}
            if result.get('runId') == run_id:
                (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
                verified = (result.get('passed') is True
                            and result.get('compute', {}).get('verified') is True
                            and result.get('compute', {}).get('mismatchCount') == 0
                            and result.get('pixels', {}).get('verified') is True
                            and result.get('raster', {}).get('verified') is True)
                print(json.dumps({'passed': verified, 'runId': run_id,
                                  'gl': result.get('gl'), 'failure': result.get('failure')}))
                return 0 if verified else 1
            time.sleep(.2)
        raise RuntimeError('No result matching the current run ID within 30 seconds')
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        (output / 'error.txt').write_text(str(error) + '\n')
        raise


if __name__ == '__main__':
    raise SystemExit(main())
