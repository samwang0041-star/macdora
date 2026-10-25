#!/usr/bin/env python3
"""Exercise the real generated hooks with an isolated, mocked Android shell."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


PACKAGE = Path(__file__).resolve().parent.parent / 'builtin.developer.location.auplugin'
HELPER = 'local.androiduse.plugin.gnss'
PERMISSIONS = ('ACCESS_FINE_LOCATION', 'ACCESS_COARSE_LOCATION', 'ACCESS_BACKGROUND_LOCATION')
OPS = ('FINE_LOCATION', 'COARSE_LOCATION', 'MONITOR_LOCATION', 'MONITOR_HIGH_POWER_LOCATION', 'MOCK_LOCATION')

MOCK_COMMAND = r'''
import json, os, sys
from pathlib import Path
file = Path(os.environ['GNSS_TEST_STATE'])
state = json.loads(file.read_text())
command = Path(sys.argv[0]).name
args = sys.argv[1:]
state['calls'].append([command, *args])
reply, status = '', 0
if command == 'settings':
    key = args[1] + ':' + args[2]
    if args[0] == 'get': reply = state['settings'].get(key, 'null')
    elif args[0] == 'put': state['settings'][key] = args[3]
    elif args[0] == 'delete': state['settings'].pop(key, None)
elif command == 'pm':
    if args[:3] == ['list', 'packages', '-3']:
        reply = '\n'.join('package:' + p for p in state['installed'])
    elif args[0] == 'path':
        if args[1] in state['installed']: reply = 'package:/data/app/' + args[1] + '/base.apk'
        else: status = 1
    elif args[0] == 'install':
        if state.get('conflict', False):
            state['conflict'] = False
            reply, status = 'Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]', 1
        elif state.get('installFailure', False):
            reply, status = 'Failure [INSTALL_FAILED_INVALID_APK]', 1
        else:
            if 'local.androiduse.plugin.gnss' not in state['installed']:
                state['installed'].append('local.androiduse.plugin.gnss')
            reply = 'Success'
    elif args[0] == 'uninstall':
        if args[1] in state['installed']: state['installed'].remove(args[1])
        state['permissions'].pop(args[1], None)
        state['ops'].pop(args[1], None)
        reply = 'Success'
    elif args[0] in ('grant', 'revoke'):
        state['permissions'].setdefault(args[1], {})[args[2]] = args[0] == 'grant'
elif command == 'dumpsys':
    permissions = state['permissions'].get(args[1], {})
    reply = '\n'.join(p + ': granted=' + str(permissions.get(p, False)).lower()
                      for p in ('android.permission.ACCESS_FINE_LOCATION',
                                'android.permission.ACCESS_COARSE_LOCATION',
                                'android.permission.ACCESS_BACKGROUND_LOCATION'))
elif command == 'appops':
    if args[0] == 'get': reply = args[2] + ': ' + state['ops'].get(args[1], {}).get(args[2], 'default')
    elif args[0] == 'set': state['ops'].setdefault(args[1], {})[args[2]] = args[3]
elif command == 'am':
    state['serviceRunning'] = args[0] == 'startservice' and 'STOP' not in args
elif command == 'cmd':
    if args[:2] == ['deviceidle', 'whitelist']:
        state['helperExempt'] = args[2].startswith('+')
file.write_text(json.dumps(state))
if reply: print(reply)
sys.exit(status)
'''


class LocationHookTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='macdora-gnss-hooks-')
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.state_file = self.root / 'state.json'
        self.guest = self.root / 'guest'
        self.guest.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for name in ('settings', 'pm', 'dumpsys', 'appops', 'cmd', 'am'):
            executable = self.bin / name
            executable.write_text('#!' + sys.executable + '\n' + MOCK_COMMAND)
            executable.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        GNSS_TEST_STATE=str(self.state_file))
        packages = ['local.macdora.demo', 'com.example.maps', 'local.androiduse.ime']
        self.original = {
            'settings': {'secure:location_mode': '0', 'secure:mock_location': '0',
                         'global:location_background_throttle_interval_ms': '1800000',
                         'global:location_background_throttle_package_whitelist': 'com.example.original'},
            'installed': packages,
            'permissions': {p: {'android.permission.' + perm: perm == 'ACCESS_COARSE_LOCATION'
                                for perm in PERMISSIONS} for p in packages},
            'ops': {p: dict(zip(OPS, ('foreground', 'deny', 'default', 'ignore', 'ignore')))
                    for p in packages},
            'calls': [], 'serviceRunning': False, 'helperExempt': False,
        }
        self.save(self.original)

    def save(self, state):
        self.state_file.write_text(json.dumps(state))

    def read(self):
        return json.loads(self.state_file.read_text())

    def hook(self, name, active=None, success=True):
        # The host sends hooks as shell text; map only fixed guest paths into scratch.
        script = (PACKAGE / 'hooks' / name).read_text().replace('/data/local/tmp', str(self.guest))
        script = script.replace('/system/bin/sh', '/bin/sh')
        env = dict(self.env)
        if active is not None:
            env['ANDROID_USE_ACTIVE_PACKAGE'] = active
        result = subprocess.run(['/bin/sh'], input=script, env=env, capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('AU_PLUGIN_HOOK_OK', result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('AU_PLUGIN_HOOK_FAIL', result.stdout)
        return result

    def assert_restored(self):
        state = self.read()
        self.assertEqual(state['settings'], self.original['settings'])
        for pkg in self.original['installed']:
            self.assertEqual(state['permissions'][pkg], self.original['permissions'][pkg])
            self.assertEqual(state['ops'][pkg], self.original['ops'][pkg])
        self.assertFalse(state['serviceRunning'])
        self.assertFalse(state['helperExempt'])
        self.assertNotIn(HELPER, state['installed'])
        self.assertFalse((self.guest / 'au-location-plugin-state.sh').exists())
        self.assertFalse((self.guest / 'au-gnss-keepwarm.apk').exists())

    def test_enable_runtime_ready_disable_restores_original_state(self):
        self.hook('on-enable.sh')
        state = self.read()
        whitelist = state['settings']['global:location_background_throttle_package_whitelist'].split(',')
        self.assertEqual(set(whitelist), {HELPER, 'local.macdora.demo', 'com.example.maps'})
        self.assertTrue(state['serviceRunning'])
        self.assertTrue(state['helperExempt'])
        for package in ('local.macdora.demo', 'com.example.maps'):
            self.assertTrue(all(state['permissions'][package].values()))
        self.assertEqual((self.guest / 'au-gnss-keepwarm.apk').read_bytes()[:4], b'PK\x03\x04')
        restore_before = (self.guest / 'au-location-plugin-state.sh').read_bytes()
        self.hook('on-runtime-ready.sh')
        self.assertEqual((self.guest / 'au-location-plugin-state.sh').read_bytes(), restore_before)
        self.hook('on-disable.sh')
        self.assert_restored()

    def test_new_real_application_is_added_and_its_permissions_restored(self):
        self.hook('on-enable.sh')
        state = self.read()
        package = 'com.example.newapp'
        state['installed'].append(package)
        state['permissions'][package] = {'android.permission.' + perm: False for perm in PERMISSIONS}
        state['ops'][package] = {op: 'foreground' for op in OPS}
        self.save(state)
        self.hook('on-app-launch.sh', package)
        self.hook('on-app-launch.sh', package)
        state = self.read()
        whitelist = state['settings']['global:location_background_throttle_package_whitelist'].split(',')
        self.assertEqual(whitelist.count(package), 1)
        self.assertTrue(all(state['permissions'][package].values()))
        self.hook('on-disable.sh')
        self.assertTrue(all(not granted for granted in self.read()['permissions'][package].values()))
        self.assertEqual(self.read()['ops'][package], {op: 'foreground' for op in OPS})
        self.assert_restored()

    def test_missing_or_unsafe_active_package_cannot_change_permissions(self):
        self.hook('on-enable.sh')
        before = self.read()
        for active in ('com.example.missing', 'com.example.maps;touch INVALID'):
            self.hook('on-app-launch.sh', active)
            state = self.read()
            self.assertEqual(state['permissions'], before['permissions'])
            self.assertEqual(state['settings'], before['settings'])
        self.hook('on-disable.sh')

    def test_certificate_conflict_replaces_only_stateless_helper(self):
        state = self.read()
        state['installed'].append(HELPER)
        state['conflict'] = True
        self.save(state)
        self.hook('on-enable.sh')
        state = self.read()
        removed = [call[2] for call in state['calls'] if call[:2] == ['pm', 'uninstall']]
        self.assertEqual(removed, [HELPER])
        self.assertTrue(state['serviceRunning'])
        self.assertIn('local.macdora.demo', state['installed'])
        self.hook('on-disable.sh')

    def test_other_install_failure_reports_failure_and_remains_reversible(self):
        state = self.read()
        state['installFailure'] = True
        self.save(state)
        self.hook('on-enable.sh', success=False)
        self.assertFalse(self.read()['serviceRunning'])
        self.assertFalse(any(call[:2] == ['pm', 'uninstall'] for call in self.read()['calls']))
        self.hook('on-disable.sh')
        self.assert_restored()


if __name__ == '__main__':
    unittest.main(verbosity=2)
