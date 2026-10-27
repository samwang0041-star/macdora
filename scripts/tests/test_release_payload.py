import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    'release_payload', Path(__file__).resolve().parents[1] / 'verify-release-payload.py')
payload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(payload)


class ReleasePayloadTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.app = self.root / 'Example.app'
        self.resources = self.app / 'Contents/Resources'
        self.resources.mkdir(parents=True)

    def test_only_the_host_and_public_builtin_registry_are_allowed(self):
        (self.resources / 'android-use-ime.apk').write_bytes(b'neutral helper')
        registry = self.root / 'registry.json'
        registry.write_text(json.dumps({'plugins': [{'id': 'builtin.example'}]}))
        result = payload.verify(self.app, registry)
        self.assertEqual(result['builtinPluginCount'], 1)
        self.assertEqual(result['bundledInstalledPluginCount'], 0)

    def test_installed_plugin_directories_and_archives_are_rejected(self):
        for name in ['plugins', 'Plugins', 'private', 'agent-control', 'plugin-state', 'userdata']:
            with self.subTest(name=name):
                directory = self.resources / name
                directory.mkdir()
                with self.assertRaisesRegex(ValueError, 'PLUGIN_OR_STATE_FORBIDDEN'):
                    payload.verify(self.app)
                directory.rmdir()
        archive = self.resources / 'private.example.auplugin'
        archive.write_bytes(b'neutral example')
        with self.assertRaisesRegex(ValueError, 'PLUGIN_OR_STATE_FORBIDDEN'):
            payload.verify(self.app)

    def test_runtime_endpoints_and_third_party_apps_are_rejected(self):
        for name in ['endpoint.json', 'control.json', 'example.apk']:
            with self.subTest(name=name):
                path = self.resources / name
                path.write_text('{}')
                with self.assertRaises(ValueError):
                    payload.verify(self.app)
                path.unlink()

    def test_non_builtin_and_duplicate_registry_entries_are_rejected(self):
        registry = self.root / 'registry.json'
        for plugins in [[{'id': 'private.example.agent'}], [{'id': 'builtin.example'}] * 2, [None]]:
            registry.write_text(json.dumps({'plugins': plugins}))
            with self.assertRaises(ValueError):
                payload.verify(self.app, registry)

    def test_symlinks_cannot_hide_plugin_or_state_payloads(self):
        (self.resources / 'ordinary.txt').symlink_to(self.root)
        with self.assertRaisesRegex(ValueError, 'SYMLINK_FORBIDDEN'):
            payload.verify(self.app)


if __name__ == '__main__':
    unittest.main()
