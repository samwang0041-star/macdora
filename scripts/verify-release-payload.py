"""Keep installed plugins and personal runtime state out of public installers."""

import argparse
import json
from pathlib import Path


def verify(app, registry=None):
    app = Path(app)
    if app.is_symlink() or not (app / 'Contents').is_dir():
        raise ValueError('RELEASE_APP_INVALID')
    forbidden = {'plugins', 'plugin-state', 'agent-control', 'private', 'userdata'}
    files = 0
    for path in app.rglob('*'):
        parts = [part.casefold() for part in path.relative_to(app).parts]
        if path.is_symlink():
            raise ValueError('RELEASE_SYMLINK_FORBIDDEN')
        if any(part in forbidden or part.endswith('.auplugin') for part in parts):
            raise ValueError('RELEASE_INSTALLED_PLUGIN_OR_STATE_FORBIDDEN')
        if path.name.casefold() in {'endpoint.json', 'control.json'}:
            raise ValueError('RELEASE_INSTALLED_PLUGIN_OR_STATE_FORBIDDEN')
        if path.suffix.casefold() == '.apk' and path.name != 'android-use-ime.apk':
            raise ValueError('RELEASE_THIRD_PARTY_APP_FORBIDDEN')
        files += int(path.is_file())
    plugin_count = 0
    if registry is not None:
        value = json.loads(Path(registry).read_text())
        if not isinstance(value, dict) or not isinstance(value.get('plugins'), list):
            raise ValueError('RELEASE_REGISTRY_INVALID')
        seen = set()
        for plugin in value['plugins']:
            identifier = plugin.get('id') if isinstance(plugin, dict) else None
            if not isinstance(identifier, str) or not identifier.startswith('builtin.'):
                raise ValueError('RELEASE_NON_BUILTIN_PLUGIN_FORBIDDEN')
            if identifier in seen:
                raise ValueError('RELEASE_REGISTRY_INVALID')
            seen.add(identifier)
        plugin_count = len(seen)
    return {'publicPayloadVerified': True, 'appFileCount': files,
            'builtinPluginCount': plugin_count, 'bundledInstalledPluginCount': 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--registry', type=Path)
    args = parser.parse_args()
    try:
        result = verify(args.app, args.registry)
    except (OSError, ValueError) as error:
        code = str(error) if type(error) is ValueError else ''
        if not code.startswith('RELEASE_'):
            code = 'RELEASE_PAYLOAD_INVALID'
        print(json.dumps({'publicPayloadVerified': False, 'errorCode': code}))
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
