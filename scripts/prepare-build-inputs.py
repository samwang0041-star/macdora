#!/usr/bin/env python3
"""Fetch fixed public build inputs into the ignored project cache."""

import argparse
import hashlib
import json
import shutil
import stat
import tarfile
import tempfile
import urllib.request
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
COMMIT = "a60891aea193d92e7e5c3942700eca63f9d19a5f"
BUILD_INPUTS = [
    (".cache/upstream/scrcpy-v5.0.1-commit.tar.gz",
     f"https://codeload.github.com/Genymobile/scrcpy/tar.gz/{COMMIT}",
     "a0d699fc7388b8252416c49e6293639de39ab76a03e7302ddced56c284d45200"),
    (".cache/upstream/scrcpy-server-v5.0.1",
     "https://github.com/Genymobile/scrcpy/releases/download/v5.0.1/scrcpy-server-v5.0.1",
     "764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536"),
    (".cache/downloads/platform-36_r02.zip",
     "https://dl.google.com/android/repository/platform-36_r02.zip",
     "37607369a28c5b640b3a7998868d45898ebcb777565a0e85f9acf36f29631d2e"),
    (".cache/downloads/build-tools_r36_macosx.zip",
     "https://dl.google.com/android/repository/build-tools_r36_macosx.zip",
     "04e7f3a72044de4926fa038fa0e251a37bba1e1c3fb8beab6f8401bfd9eb4bf3"),
]


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def fetch(relative, url, expected):
    path = ROOT / relative
    if path.is_symlink():
        raise SystemExit("Unsafe cache path: " + relative)
    if path.exists():
        if digest(path) != expected:
            raise SystemExit("Unexpected cached input; inspect it before retrying: " + relative)
        return path
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".downloading")
    request = urllib.request.Request(url, headers={"User-Agent": "Macdora-build"})
    print("Downloading " + path.name, flush=True)
    try:
        with urllib.request.urlopen(request, timeout=60) as source, temporary.open("wb") as target:
            shutil.copyfileobj(source, target, length=1024 * 1024)
        if digest(temporary) != expected:
            raise SystemExit("Downloaded input checksum mismatch: " + path.name)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)
    return path


def prepare_scrcpy(archive):
    destination = ROOT / ".cache/upstream/scrcpy-5.0.1"
    if (destination / "server/src").is_dir():
        return
    with tempfile.TemporaryDirectory(prefix="scrcpy-", dir=archive.parent) as temporary:
        with tarfile.open(archive) as package:
            prefix = "scrcpy-" + COMMIT
            for member in package.getmembers():
                parts = Path(member.name).parts
                if not parts or parts[0] != prefix or ".." in parts or member.issym() or member.islnk():
                    raise SystemExit("Unsafe upstream source archive member")
            package.extractall(temporary, filter="data")
        extracted = Path(temporary) / prefix
        if destination.exists():
            raise SystemExit("Incomplete upstream source directory; inspect before retrying")
        extracted.rename(destination)


def prepare_runtime():
    metadata = json.loads((ROOT / "evidence/research/android-tools-downloads.json").read_text())
    target = ROOT / ".cache/verified-runtime"
    target.mkdir(parents=True, exist_ok=True)
    for item in metadata:
        destination = target / item["package"]
        if destination.is_dir() and not destination.is_symlink():
            continue
        archive = fetch(".cache/downloads/" + item["url"].rsplit("/", 1)[-1], item["url"], item["sha256"])
        with tempfile.TemporaryDirectory(prefix="runtime-", dir=target) as temporary:
            with zipfile.ZipFile(archive) as package:
                for member in package.infolist():
                    parts = Path(member.filename).parts
                    if not parts or parts[0] != item["package"] or ".." in parts or stat.S_ISLNK(member.external_attr >> 16):
                        raise SystemExit("Unsafe official runtime archive member")
                package.extractall(temporary)
                for member in package.infolist():
                    permissions = (member.external_attr >> 16) & 0o777
                    if permissions:
                        (Path(temporary) / member.filename).chmod(permissions)
            (Path(temporary) / item["package"]).rename(destination)


def prepare_sdk():
    for archive_name, relative, required in [
        ("platform-36_r02.zip", ".cache/android-sdk/platforms", "android-36/android.jar"),
        ("build-tools_r36_macosx.zip", ".cache/android-sdk/build-tools", "android-16/d8"),
    ]:
        destination = ROOT / relative
        if (destination / required).is_file():
            continue
        destination.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(ROOT / ".cache/downloads" / archive_name) as package:
            for member in package.infolist():
                if Path(member.filename).is_absolute() or ".." in Path(member.filename).parts or stat.S_ISLNK(member.external_attr >> 16):
                    raise SystemExit("Unsafe SDK archive member")
            package.extractall(destination)
            for member in package.infolist():
                permissions = (member.external_attr >> 16) & 0o777
                if permissions:
                    (destination / member.filename).chmod(permissions)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", action="store_true", help="Also prepare runtime inputs for an offline development build")
    args = parser.parse_args()
    for relative, url, expected in BUILD_INPUTS:
        fetch(relative, url, expected)
    prepare_scrcpy(ROOT / BUILD_INPUTS[0][0])
    prepare_sdk()
    if args.runtime:
        prepare_runtime()
    print("Verified public build inputs.")


if __name__ == "__main__":
    main()
