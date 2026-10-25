#!/usr/bin/env python3
"""Prepare the pinned AOSP Android 17 arm64-v8a system image."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import sys
import tempfile
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath


ARCHIVE_NAME = "aosp-arm64-v8a-37.0_r06.zip"
ARCHIVE_URL = (
    "https://dl.google.com/android/repository/sys-img/android/"
    "arm64-v8a-37.0_r06.zip"
)
ARCHIVE_SIZE = 865_756_849
ARCHIVE_SHA1 = "f94cb780748169b5944b7c2e5c0693e5077ec8c4"
ARCHIVE_SHA256 = (
    "ffccd67f6e26b1f4911854ba4e8510b2990ab6c71af33f71864d38bf5d80c57e"
)
IMAGE_ABI = "arm64-v8a"
IMAGE_ROOT = PurePosixPath(".runtime/images/aosp-api37-r6") / IMAGE_ABI
METADATA_PATH = PurePosixPath("evidence/research/android17-aosp-image-files.json")
EXPECTED_PROPERTIES = {
    "AndroidVersion.ApiLevel": "37.0",
    "Pkg.Revision": "6",
    "SystemImage.Abi": IMAGE_ABI,
    "SystemImage.TagId": "default",
}
EXPECTED_BUILD_PROPERTIES = {
    "ro.build.id": "CE2A.260420.051.A3",
    "ro.build.version.incremental": "16571990",
    "ro.build.version.release": "17",
    "ro.build.version.sdk": "37",
    "ro.build.version.sdk_full": "37.0",
    "ro.product.cpu.abi": IMAGE_ABI,
}
METADATA_FILENAMES = (
    "system.img",
    "vendor.img",
    "kernel-ranchu",
    "ramdisk.img",
    "source.properties",
    "build.prop",
    "NOTICE.txt",
)
CHUNK_SIZE = 1024 * 1024


class PreparationError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(CHUNK_SIZE), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_archive(path: Path) -> None:
    if not path.is_file() or path.is_symlink():
        raise PreparationError(f"Archive is not a regular file: {path}")
    size = path.stat().st_size
    if size != ARCHIVE_SIZE:
        raise PreparationError(
            f"Archive size mismatch: expected {ARCHIVE_SIZE}, found {size}"
        )
    sha1 = hashlib.sha1()
    sha256 = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(CHUNK_SIZE), b""):
            sha1.update(chunk)
            sha256.update(chunk)
    actual_sha1 = sha1.hexdigest()
    actual_sha256 = sha256.hexdigest()
    if actual_sha1 != ARCHIVE_SHA1:
        raise PreparationError(
            f"Archive SHA1 mismatch: expected {ARCHIVE_SHA1}, found {actual_sha1}"
        )
    if actual_sha256 != ARCHIVE_SHA256:
        raise PreparationError(
            f"Archive SHA256 mismatch: expected {ARCHIVE_SHA256}, "
            f"found {actual_sha256}"
        )


def content_by_member(archive: Path) -> dict[str, int]:
    members: dict[str, int] = {}
    with zipfile.ZipFile(archive) as package:
        for info in package.infolist():
            name = info.filename
            member = PurePosixPath(name)
            if (
                not name
                or "\\" in name
                or member.is_absolute()
                or ".." in member.parts
            ):
                raise PreparationError(f"Unsafe ZIP member path: {name!r}")
            if len(member.parts) < 2 or member.parts[0] != IMAGE_ABI:
                raise PreparationError(
                    f"ZIP member is outside the pinned ABI root: {name!r}"
                )
            if name in members:
                raise PreparationError(f"Duplicate ZIP member: {name!r}")
            mode = info.external_attr >> 16
            file_type = stat.S_IFMT(mode)
            if info.is_dir() or file_type == stat.S_IFLNK:
                raise PreparationError(
                    f"ZIP directories and links are not accepted: {name!r}"
                )
            if file_type not in (0, stat.S_IFREG):
                raise PreparationError(
                    f"ZIP member is not a regular file: {name!r}"
                )
            if info.flag_bits & 0x1:
                raise PreparationError(f"Encrypted ZIP member: {name!r}")
            members[name] = info.file_size
    for required in METADATA_FILENAMES:
        if f"{IMAGE_ABI}/{required}" not in members:
            raise PreparationError(f"Archive is missing {IMAGE_ABI}/{required}")
    return members


def parse_properties(path: Path, expected: dict[str, str]) -> dict[str, str]:
    properties: dict[str, str] = {}
    for line_number, raw_line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        line = raw_line.strip()
        if not line or line.startswith(("#", "!")):
            continue
        separator = "=" if "=" in line else ":" if ":" in line else None
        if separator is None:
            raise PreparationError(
                f"Invalid source.properties line {line_number}"
            )
        key, value = line.split(separator, 1)
        properties[key.strip()] = value.strip()
    for key, wanted in expected.items():
        actual = properties.get(key)
        if actual != wanted:
            raise PreparationError(
                f"{path.name} mismatch for {key}: "
                f"expected {wanted!r}, found {actual!r}"
            )
    return properties


def files_for(destination: Path) -> dict[str, dict[str, object]]:
    if not destination.is_dir() or destination.is_symlink():
        raise PreparationError(f"Image root is not a safe directory: {destination}")
    files: dict[str, dict[str, object]] = {}
    for path in sorted(destination.rglob("*")):
        if path.is_symlink():
            raise PreparationError(f"Image contains a symbolic link: {path}")
        if path.is_dir():
            continue
        if not path.is_file():
            raise PreparationError(f"Image contains a non-regular entry: {path}")
        relative = path.relative_to(destination).as_posix()
        files[relative] = {
            "size": path.stat().st_size,
            "sha256": sha256_file(path),
        }
    for filename in METADATA_FILENAMES:
        if filename not in files:
            raise PreparationError(f"Missing regular image file: {filename}")
    return files


def metadata_for(destination: Path) -> dict[str, object]:
    return {
        "imageBuild": "CE2A.260420.051.A3 / 16571990",
        "androidVersion": "17",
        "apiLevel": 37,
        "abi": IMAGE_ABI,
        "revision": 6,
        "tag": "default",
        "source": ARCHIVE_URL,
        "files": files_for(destination),
    }


def read_metadata(path: Path) -> dict[str, object]:
    try:
        metadata = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PreparationError(f"Cannot read metadata {path}: {error}") from error
    expected = {
        "imageBuild": "CE2A.260420.051.A3 / 16571990",
        "androidVersion": "17",
        "apiLevel": 37,
        "abi": IMAGE_ABI,
        "revision": 6,
        "tag": "default",
        "source": ARCHIVE_URL,
    }
    for key, value in expected.items():
        if metadata.get(key) != value:
            raise PreparationError(
                f"Metadata mismatch for {key}: "
                f"expected {value!r}, found {metadata.get(key)!r}"
            )
    files = metadata.get("files")
    if not isinstance(files, dict):
        raise PreparationError("Metadata files must be an object")
    for filename in METADATA_FILENAMES:
        entry = files.get(filename)
        if not isinstance(entry, dict):
            raise PreparationError(f"Metadata is missing files.{filename}")
        if not isinstance(entry.get("size"), int) or not isinstance(
            entry.get("sha256"), str
        ):
            raise PreparationError(f"Invalid metadata for files.{filename}")
    return metadata


def verify_image(destination: Path, metadata: dict[str, object]) -> None:
    actual = metadata_for(destination)
    if actual != metadata:
        raise PreparationError(f"Extracted image does not match metadata: {destination}")
    parse_properties(destination / "source.properties", EXPECTED_PROPERTIES)
    parse_properties(destination / "build.prop", EXPECTED_BUILD_PROPERTIES)


def make_tree_writable(root: Path) -> None:
    for path in root.rglob("*"):
        if path.is_dir() and not path.is_symlink():
            path.chmod(path.stat().st_mode | stat.S_IWUSR)
    root.chmod(root.stat().st_mode | stat.S_IWUSR)


def remove_recoverable(path: Path) -> bool:
    try:
        if path.is_symlink() or path.is_file():
            path.unlink()
        elif path.is_dir():
            make_tree_writable(path)
            shutil.rmtree(path)
        else:
            raise OSError("not a regular file, directory, or symlink")
        return True
    except OSError as error:
        print(f"Could not remove stale staging directory {path}: {error}", file=sys.stderr)
        return False


def move_into_place(source: Path, destination: Path) -> None:
    parent = destination.parent
    parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() or destination.is_symlink():
        raise PreparationError(
            f"Refusing to replace an existing image directory: {destination}"
        )
    os.replace(source, destination)


def download_archive(archive: Path) -> None:
    archive.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(ARCHIVE_URL, headers={"User-Agent": "Android-Use"})
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{ARCHIVE_NAME}.", suffix=".download", dir=archive.parent
    )
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        with temporary.open("wb") as stream:
            with urllib.request.urlopen(request, timeout=30) as response:
                response_url = urllib.parse.urlsplit(response.geturl())
                if response_url.scheme != "https" or response_url.hostname != "dl.google.com":
                    raise PreparationError(
                        f"Archive response uses an unexpected origin: {response.geturl()}"
                    )
                declared_length = response.headers.get("Content-Length")
                if declared_length is not None and declared_length != str(ARCHIVE_SIZE):
                    raise PreparationError(
                        f"Archive Content-Length mismatch: expected {ARCHIVE_SIZE}, "
                        f"found {declared_length}"
                    )
                while True:
                    chunk = response.read(CHUNK_SIZE)
                    if not chunk:
                        break
                    if stream.tell() + len(chunk) > ARCHIVE_SIZE:
                        raise PreparationError(
                            f"Archive response exceeds {ARCHIVE_SIZE} bytes"
                        )
                    stream.write(chunk)
            stream.flush()
            os.fsync(stream.fileno())
        verify_archive(temporary)
        os.replace(temporary, archive)
    finally:
        temporary.unlink(missing_ok=True)


def extract_archive(archive: Path, destination: Path) -> None:
    members = content_by_member(archive)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.mkdir()
    try:
        with zipfile.ZipFile(archive) as package:
            for info in package.infolist():
                member = PurePosixPath(info.filename)
                relative = PurePosixPath(*member.parts[1:])
                target = destination.joinpath(*relative.parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                with package.open(info) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output, CHUNK_SIZE)
                if target.stat().st_size != members[info.filename]:
                    raise PreparationError(
                        f"Extracted size mismatch for {info.filename}"
                    )
    except BaseException:
        remove_recoverable(destination)
        raise


def prepare_image(project: Path) -> Path:
    archive = project / ".cache/downloads" / ARCHIVE_NAME
    metadata_path = project / METADATA_PATH
    destination = project / IMAGE_ROOT
    staging = destination.parent / (destination.name + ".preparing")
    if not archive.exists():
        print(f"Downloading pinned AOSP archive: {ARCHIVE_URL}")
        download_archive(archive)
    else:
        print(f"Verifying cached AOSP archive: {archive}")
        verify_archive(archive)
    content_by_member(archive)
    if not metadata_path.is_file():
        raise PreparationError(f"Missing image metadata: {metadata_path}")
    metadata = read_metadata(metadata_path)
    if staging.exists() or staging.is_symlink():
        if not remove_recoverable(staging):
            raise PreparationError(
                f"Unsafe stale staging directory remains: {staging}"
            )
    if destination.exists() or destination.is_symlink():
        if not destination.is_dir() or destination.is_symlink():
            raise PreparationError(
                f"Existing image is not a safe directory: {destination}"
            )
        verify_image(destination, metadata)
        print(f"Verified Android 17 image already prepared: {destination}")
        return destination
    extract_archive(archive, staging)
    try:
        verify_image(staging, metadata)
        move_into_place(staging, destination)
    except BaseException:
        remove_recoverable(staging)
        raise
    print(f"Verified Android 17 image ready: {destination}")
    return destination


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--project-root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
    )
    args = parser.parse_args()
    project = args.project_root.resolve()
    try:
        prepare_image(project)
    except (OSError, ValueError, zipfile.BadZipFile, PreparationError) as error:
        print(f"Android 17 image preparation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
