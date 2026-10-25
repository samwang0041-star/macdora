#!/usr/bin/env python3
"""Measure only explicitly selected local test process IDs. Never capture argv or environment."""
import argparse
import json
import subprocess
import time
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--pid", type=int, action="append", required=True)
p.add_argument("--seconds", type=int, default=35)
p.add_argument("--output", type=Path, required=True)
a = p.parse_args()
samples = []
start = time.monotonic()
while time.monotonic() - start < a.seconds:
    observed = subprocess.run(["/bin/ps", "-p", ",".join(map(str, a.pid)), "-o", "pid=,%cpu=,rss="], capture_output=True, text=True, check=False)
    processes = []
    for line in observed.stdout.splitlines():
        pid, cpu, rss = line.split()
        processes.append({"pid": int(pid), "cpuPercent": float(cpu), "residentMiB": int(rss) / 1024})
    samples.append({"timeSeconds": time.monotonic() - start, "processes": processes})
    time.sleep(1)
report = {"durationSeconds": time.monotonic() - start, "samples": samples, "method": "ps %cpu (per-process moving average; 100% means one core), rss; no argv, device identifiers or environment captured."}
a.output.write_text(json.dumps(report, indent=2) + "\n")
print(f"Recorded {len(samples)} resource samples.")
