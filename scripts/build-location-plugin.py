#!/usr/bin/env python3
"""Rebuild the helper, sign the location plugin, and emit a deterministic archive."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parent.parent
PLUGINS = ROOT / 'plugins'
PACKAGE = PLUGINS / 'builtin.developer.location.auplugin'
TEMPLATES = PLUGINS / 'templates'
BUILD = ROOT / '.build/location-plugin'
SIGNER_SOURCE = ROOT / 'scripts/build-location-plugin.swift'
HELPER = ROOT / '.build/gnss-keepwarm/au-gnss-keepwarm.apk'
GENERATED_HOOKS = ('on-enable.sh', 'on-runtime-ready.sh', 'on-app-launch.sh')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode()


def secure_key_path(raw):
    path = Path(os.path.abspath(Path(raw).expanduser()))
    for part in (path, *path.parents):
        if part.is_symlink():
            raise ValueError('Refusing a symlink in a signing path.')
    if path.is_relative_to(ROOT) and not path.is_relative_to(ROOT / '.build'):
        raise ValueError('Signing material must stay outside public sources or under ignored .build/.')
    return path


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise ValueError('Refusing to replace a symlink.')
    descriptor, name = tempfile.mkstemp(prefix='build-', dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, 'wb') as output:
            output.write(data)
        temporary.chmod(0o755 if path.suffix == '.sh' else 0o644)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def signer(operation, package, arguments):
    result = subprocess.run([
        'swift', '-module-cache-path', str(BUILD / 'module-cache'), str(SIGNER_SOURCE),
        operation, str(package), *arguments,
    ], check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def build(args):
    private_key = secure_key_path(args.private_key)
    helper_key = secure_key_path(args.helper_keystore)
    helper_command = ['bash', str(ROOT / 'scripts/build-gnss-keepwarm.sh'), '--keystore', str(helper_key)]
    if args.create_helper_keystore:
        helper_command.append('--create-keystore')
    subprocess.run(helper_command, check=True)

    permission_function = (TEMPLATES / 'app-permissions.sh.inc').read_text()
    setup = (TEMPLATES / 'location-setup.sh.in').read_text().replace(
        '@APP_PERMISSION_FUNCTION@', permission_function.rstrip())
    setup = setup.replace('@GNSS_KEEPWARM_APK_BASE64@', base64.encodebytes(HELPER.read_bytes()).decode().rstrip())
    on_launch = (TEMPLATES / 'location-app-launch.sh.in').read_text().replace(
        '@APP_PERMISSION_FUNCTION@', permission_function.rstrip())

    BUILD.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='work-', dir=BUILD) as scratch:
        staging = Path(scratch) / PACKAGE.name
        staging.mkdir()
        for source in sorted(PACKAGE.rglob('*')):
            if source.is_symlink():
                raise ValueError('Plugin source contains a symlink.')
            if not source.is_file():
                continue
            relative = source.relative_to(PACKAGE)
            if str(relative) == 'signature.json' or str(relative) in ('hooks/' + name for name in GENERATED_HOOKS):
                continue
            destination = staging / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(source.read_bytes())
        for name, content in zip(GENERATED_HOOKS, (setup, setup, on_launch)):
            output = staging / 'hooks' / name
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(content)
        for script in sorted((staging / 'hooks').glob('*.sh')):
            subprocess.run(['sh', '-n', str(script)], check=True)

        signing_arguments = ['--private-key', str(private_key), '--key-id', args.key_id, '--publisher', args.publisher]
        if args.generate_key:
            signing_arguments.append('--generate-key')
        result = signer('sign', staging, signing_arguments)
        signer('verify', staging, ['--public-key', result['publicKeyBase64']])
        signature = json.loads((staging / 'signature.json').read_bytes())
        manifest = json.loads((staging / 'manifest.json').read_bytes())
        archive_path = Path(scratch) / PACKAGE.name
        archive_path = archive_path.with_suffix('.zip')
        with zipfile.ZipFile(archive_path, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for file in sorted(staging.rglob('*')):
                if file.is_file():
                    name = str(file.relative_to(staging))
                    info = zipfile.ZipInfo(PACKAGE.name + '/' + name, (1980, 1, 1, 0, 0, 0))
                    info.create_system = 3
                    info.external_attr = (0o100755 if name.endswith('.sh') else 0o100644) << 16
                    info.compress_type = zipfile.ZIP_DEFLATED
                    archive.writestr(info, file.read_bytes())
        archive_data = archive_path.read_bytes()
        archive_hash = digest(archive_data)
        entry = {key: value for key, value in manifest.items() if key not in ('entrypoints', 'schemaVersion')}
        entry.update({
            'downloadURL': 'https://github.com/samwang0041-star/macdora/releases/download/' + args.release_tag + '/' + PACKAGE.name,
            'fallbackDownloadURL': 'https://raw.githubusercontent.com/samwang0041-star/macdora/main/plugins/dist/' + PACKAGE.name,
            'archiveSHA256': archive_hash,
            'manifestSHA256': signature['manifestSHA256'],
            'signatureKeyID': signature['keyID'],
            'signature': signature['signature'],
        })
        registry = {
            'schemaVersion': 1,
            'repository': 'https://github.com/samwang0041-star/macdora',
            'publicKeyID': signature['keyID'],
            'publicKeyEd25519': result['publicKeyBase64'],
            'plugins': [entry],
        }
        for name in (*('hooks/' + name for name in GENERATED_HOOKS), 'signature.json'):
            atomic_write(PACKAGE / name, (staging / name).read_bytes())
        atomic_write(PLUGINS / 'dist' / PACKAGE.name, archive_data)
        atomic_write(PLUGINS / 'dist' / (PACKAGE.name + '.sha256'), (archive_hash + '  ' + PACKAGE.name + '\n').encode())
        atomic_write(PLUGINS / 'registry.json', json_bytes(registry))
        sources = [*sorted((ROOT / 'Guest/GNSSKeepWarm').rglob('*')),
                   *sorted(TEMPLATES.glob('*')), SIGNER_SOURCE, Path(__file__).resolve(),
                   ROOT / 'scripts/build-gnss-keepwarm.sh']
        info = {
            'pluginID': manifest['id'], 'version': manifest['version'],
            'helperSHA256': digest(HELPER.read_bytes()), 'archiveSHA256': archive_hash,
            'sourceSHA256': {str(file.relative_to(ROOT)): digest(file.read_bytes()) for file in sources if file.is_file()},
        }
        atomic_write(PLUGINS / 'dist/build-info.json', json_bytes(info))
        print(json.dumps({**result, 'archiveSHA256': archive_hash, 'helperSHA256': info['helperSHA256']}, sort_keys=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--private-key', required=True, help='Your 32-byte raw Ed25519 signing key; no implicit official key.')
    parser.add_argument('--key-id', required=True)
    parser.add_argument('--publisher', required=True)
    parser.add_argument('--generate-key', action='store_true', help='Create the explicitly selected key only if it is missing.')
    parser.add_argument('--helper-keystore', required=True)
    parser.add_argument('--create-helper-keystore', action='store_true')
    parser.add_argument('--release-tag', default='v0.03')
    args = parser.parse_args()
    build(args)


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        # Compiler and crypto diagnostics contain no key material.
        if error.stderr:
            print(error.stderr, end='', file=__import__('sys').stderr)
        raise SystemExit('Plugin build failed; no publication was attempted.')
    except (OSError, ValueError) as error:
        raise SystemExit(str(error))
