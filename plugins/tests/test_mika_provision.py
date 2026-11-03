#!/usr/bin/env python3
"""Exercise the native assistant plugin payloads, manifest, and host-service contract."""

import json
import copy
import importlib.machinery
import importlib.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import socket
import stat
import shutil
import shlex
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest import mock

PACKAGE = Path(__file__).resolve().parent.parent / 'agent.mika.auplugin'
LEGACY_ENGINE = 'local.macdora.assistant'
INSTANCE = '11111111-2222-3333-4444-555555555555'

MOCK_COMMAND = r'''
import json, os, sys
from pathlib import Path
file = Path(os.environ['MIKA_TEST_STATE'])
state = json.loads(file.read_text())
command = Path(sys.argv[0]).name
args = sys.argv[1:]
state['calls'].append([command, *args])
reply, status = '', 0
if command == 'settings':
    action, namespace, key = args[0], args[1], args[2]
    slot = namespace + ':' + key
    if action == 'get':
        reply = state['settings'].get(slot, 'null')
    elif action == 'put':
        state['settings'][slot] = args[3]
    elif action == 'delete':
        state['settings'].pop(slot, None)
elif command == 'pm':
    if args[0] == 'uninstall':
        state['uninstalled'].append(args[1])
elif command == 'setprop':
    state.setdefault('props', {})[args[0]] = args[1]
elif command == 'getprop':
    reply = state.get('props', {}).get(args[0], '')
elif command == 'pkill':
    state.setdefault('pkill', []).append(args)
file.write_text(json.dumps(state))
if reply:
    print(reply)
sys.exit(status)
'''


class PayloadTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='macdora-assistant-')
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.guest = self.root / 'guest'
        self.guest.mkdir()
        bindir = self.root / 'bin'
        bindir.mkdir()
        for tool in ('settings', 'pm', 'setprop', 'getprop', 'pkill'):
            stub = bindir / tool
            stub.write_text('#!/usr/bin/env python3\n' + MOCK_COMMAND)
            stub.chmod(0o755)
        su = bindir / 'su'
        su.write_text('#!/bin/sh\n[ "$1" = "0" ] && shift\nexec "$@"\n')
        su.chmod(0o755)
        chown = bindir / 'chown'
        chown.write_text('#!/bin/sh\nexit 0\n')
        chown.chmod(0o755)
        self.state_file = self.root / 'state.json'
        self.env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ['PATH'],
                        MIKA_TEST_STATE=str(self.state_file))
        self.write_state({
            'calls': [],
            'settings': {'global:adb_wifi_enabled': '1'},
            'uninstalled': [],
            'props': {},
        })

    def write_state(self, state):
        self.state_file.write_text(json.dumps(state))

    def read_state(self):
        return json.loads(self.state_file.read_text())

    def run_payload(self, name):
        body = (PACKAGE / 'resources' / name).read_text().replace('/data/local/tmp', str(self.guest))
        script = self.root / (name + '.sh')
        script.write_text(body)
        return subprocess.run(['/bin/sh', str(script)], capture_output=True, text=True, env=self.env)

    def test_provision_prepares_native_mode(self):
        proc = self.run_payload('provision.sh')
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn('ASSISTANT_PROVISION_OK', proc.stdout)
        state = self.read_state()
        self.assertEqual(state['settings']['global:adb_wifi_enabled'], '0')
        self.assertEqual(state['props'].get('persist.adb.tls_server.enable'), '0')
        self.assertEqual(state['props'].get('sys.androiduse.assistant_mode'), 'native')
        self.assertTrue((self.guest / 'macdora-assistant-state').is_file())
        self.assertEqual(stat.S_IMODE((self.guest / 'macdora-assistant-state').stat().st_mode), 0o600)

    def test_provision_is_idempotent_and_restores_legacy_engine(self):
        legacy = self.guest / 'mika-assistant-state'
        legacy.write_text(
            "a11y_enabled_services='com.other/.S'\n"
            "a11y_enabled='1'\n"
            "perapp_override='0'\n"
        )
        proc = self.run_payload('provision.sh')
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        state = self.read_state()
        self.assertEqual(state['settings']['secure:enabled_accessibility_services'], 'com.other/.S')
        self.assertEqual(state['settings']['secure:accessibility_enabled'], '1')
        self.assertIn(LEGACY_ENGINE, state['uninstalled'])
        self.assertFalse(legacy.exists())
        self.assertTrue(any('local.macdora.assistant:helper' in ' '.join(call) for call in state.get('pkill', [])))

        second = self.run_payload('provision.sh')
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        state = self.read_state()
        self.assertEqual(state['settings']['global:adb_wifi_enabled'], '0')
        self.assertEqual(state['props'].get('persist.adb.tls_server.enable'), '0')

    def test_uninstall_restores_wifi_setting(self):
        self.run_payload('provision.sh')
        proc = self.run_payload('uninstall.sh')
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn('ASSISTANT_UNINSTALL_OK', proc.stdout)
        state = self.read_state()
        self.assertEqual(state['settings']['global:adb_wifi_enabled'], '1')
        self.assertEqual(state['props'].get('persist.adb.tls_server.enable'), '')
        self.assertFalse((self.guest / 'macdora-assistant-state').exists())
        self.assertFalse((self.guest / 'macdora-assistant-scrcpy.jar').exists())

    def test_manifest_and_resources(self):
        manifest = json.loads((PACKAGE / 'manifest.json').read_text())
        self.assertEqual(manifest['schemaVersion'], 1)
        self.assertEqual(manifest['id'], 'agent.mika')
        self.assertEqual(manifest['driverType'], 'host_service')
        for capability in ('host.service', 'guest.shell', 'ui.assistant.workspace'):
            self.assertIn(capability, manifest['capabilities'])
        self.assertEqual(manifest['entrypoints']['hostService'], 'bin/mika-host-service')
        self.assertEqual(manifest['entrypoints']['onDisable'], 'resources/uninstall.sh')
        self.assertNotIn('agentMCP', manifest['entrypoints'])
        service = PACKAGE / 'bin' / 'mika-host-service'
        self.assertTrue(os.access(service, os.X_OK))
        self.assertEqual(service.stat().st_mode & 0o022, 0)
        self.assertTrue((PACKAGE / 'resources' / 'scrcpy-server-assistant.jar').is_file())
        self.assertTrue((PACKAGE / 'resources' / 'knowledge' / 'wechat.md').is_file())
        self.assertFalse((PACKAGE / 'resources' / 'mika-release.json').exists())

    def test_provision_fails_without_success_marker(self):
        bindir = Path(self.env['PATH'].split(os.pathsep)[0])
        settings = bindir / 'settings'
        settings.write_text('#!/bin/sh\nexit 1\n')
        settings.chmod(0o755)
        proc = self.run_payload('provision.sh')
        self.assertNotEqual(proc.returncode, 0)
        self.assertNotIn('ASSISTANT_PROVISION_OK', proc.stdout)
        self.assertIn('AU_PLUGIN_HOOK_FAIL', proc.stdout)

    def test_uninstall_migrates_legacy_state_without_tls_value(self):
        self.run_payload('provision.sh')
        state_file = self.guest / 'macdora-assistant-state'
        state_file.write_text("adb_wifi_enabled='1'\n")
        proc = self.run_payload('uninstall.sh')
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        state = self.read_state()
        self.assertEqual(state['settings']['global:adb_wifi_enabled'], '1')
        self.assertEqual(state['props'].get('persist.adb.tls_server.enable'), '')


class HostServiceTest(unittest.TestCase):
    def start_service(self, bundle, root, extra_env=None):
        socket_path = Path(root) / 'mika.sock'
        env = dict(os.environ,
                   MACDORA_PLUGIN_SOCKET_PATH=str(socket_path),
                   MACDORA_PLUGIN_STATE_DIR=root,
                   MACDORA_PLUGIN_BUNDLE_DIR=str(bundle),
                   MACDORA_PLUGIN_INSTANCE_ID=INSTANCE,
                   MACDORA_HOST_PID=str(os.getpid()))
        env.update(extra_env or {})
        env.pop('MACDORA_ADB_PATH', None)
        proc = subprocess.Popen([sys.executable, str(bundle / 'bin' / 'mika-host-service')],
                                env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(lambda: (proc.terminate(), proc.wait(timeout=10)))
        deadline = time.time() + 5
        while not socket_path.exists() and time.time() < deadline:
            time.sleep(0.05)
        self.assertTrue(socket_path.exists(), 'socket not written within 5s')
        return socket_path

    def start_gateway(self):
        payload = json.dumps({'data': [
            {
                'id': 'text/only',
                'display_name': 'Text Only',
                'tool_call': True,
                'modalities': {'input': ['text']},
            },
            {
                'id': 'other/vision',
                'display_name': 'Other Vision',
                'tool_call': True,
                'modalities': {'input': ['text', 'image']},
                'reasoning_levels': ['low', 'high'],
            },
            {
                'id': 'plain/vision',
                'display_name': 'Plain Vision',
                'tool_call': True,
                'modalities': {'input': ['text', 'image']},
            },
            {
                'id': 'auto/gemini-4-argon',
                'display_name': 'Gemini 4 Argon',
                'tool_call': True,
                'modalities': {'input': ['text', 'image']},
                'supported_reasoning_levels': [
                    {'effort': 'low'},
                    {'effort': 'medium'},
                    {'effort': 'high'},
                ],
            },
        ]}).encode()

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path != '/v1/models':
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, format, *args):
                pass

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f'http://127.0.0.1:{server.server_port}/v1'

    def rpc(self, reader, client, request_id, method, params=None):
        payload = {'jsonrpc': '2.0', 'id': request_id, 'method': method}
        if params is not None:
            payload['params'] = params
        client.sendall(json.dumps(payload).encode() + b'\n')
        return json.loads(reader.readline())

    def test_endpoint_health_and_model_config(self):
        with tempfile.TemporaryDirectory(prefix='macdora-assistant-service-') as root:
            bundle = Path(root) / 'bundle'
            shutil.copytree(PACKAGE, bundle)
            gateway = self.start_gateway()
            socket_path = self.start_service(bundle, root, {'MACDORA_MAGPIE_GATEWAY': gateway})

            endpoint = json.loads((Path(root) / 'endpoint.json').read_text())
            self.assertEqual(endpoint['pluginId'], 'agent.mika')
            self.assertEqual(endpoint['instanceId'], INSTANCE)
            self.assertEqual(endpoint['protocol'], 'json-rpc-2.0')
            self.assertEqual(stat.S_IMODE((Path(root) / 'endpoint.json').stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(socket_path.stat().st_mode), 0o600)

            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(10)
                client.connect(str(socket_path))
                reader = client.makefile('rb')

                ping = self.rpc(reader, client, 1, 'macdora.ping', {'instanceId': INSTANCE})
                self.assertEqual(ping['result'],
                                 {'pluginId': 'agent.mika', 'instanceId': INSTANCE, 'ready': True})

                config = self.rpc(reader, client, 2, 'mika.config.get')
                self.assertEqual(config['result']['base_url'], gateway)
                self.assertTrue(config['result']['gateway_ready'])
                self.assertEqual(config['result']['model'], 'auto/gemini-4-argon')
                self.assertEqual(
                    [item['id'] for item in config['result']['models']],
                    ['auto/gemini-4-argon', 'other/vision', 'plain/vision'],
                )
                self.assertEqual(
                    config['result']['models'][0]['reasoning_levels'],
                    ['low', 'medium', 'high'],
                )
                self.assertEqual(config['result']['reasoning_effort'], '')

                saved = self.rpc(reader, client, 3, 'mika.config.set', {
                    'model': 'other/vision',
                    'reasoning_effort': 'high',
                })
                self.assertEqual(saved['result']['model'], 'other/vision')
                self.assertEqual(saved['result']['reasoning_effort'], 'high')
                self.assertTrue(saved['result']['gateway_ready'])
                self.assertEqual(stat.S_IMODE((Path(root) / 'config.json').stat().st_mode), 0o600)
                stored = json.loads((Path(root) / 'config.json').read_text())
                self.assertEqual(
                    stored,
                    {'model': 'other/vision', 'reasoning_effort': 'high', 'max_steps': 25},
                )

                fallback = self.rpc(reader, client, 4, 'mika.config.set', {
                    'model': 'plain/vision',
                })
                self.assertEqual(fallback['result']['model'], 'plain/vision')
                self.assertEqual(fallback['result']['reasoning_effort'], '')
                stored = json.loads((Path(root) / 'config.json').read_text())
                self.assertNotIn('reasoning_effort', stored)

                status = self.rpc(reader, client, 5, 'mika.status')
                self.assertIn(status['result']['phase'], ('starting', 'degraded', 'ready', 'display', 'provisioning'))

                empty = self.rpc(reader, client, 6, 'mika.task.start', {'goal': '  '})
                self.assertIn('error', empty)


class LaunchToolTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory(prefix='macdora-assistant-launch-')
        cls.bundle = Path(cls.scratch.name) / 'bundle'
        shutil.copytree(PACKAGE, cls.bundle)
        env = {
            'MACDORA_PLUGIN_STATE_DIR': cls.scratch.name,
            'MACDORA_PLUGIN_BUNDLE_DIR': str(cls.bundle),
        }
        previous = {key: os.environ.get(key) for key in env}
        os.environ.update(env)
        try:
            service_path = cls.bundle / 'bin' / 'mika-host-service'
            loader = importlib.machinery.SourceFileLoader(
                'mika_host_service_launch_test', str(service_path)
            )
            spec = importlib.util.spec_from_loader(loader.name, loader)
            cls.service = importlib.util.module_from_spec(spec)
            loader.exec_module(cls.service)
        finally:
            for key, value in previous.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value

    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()

    def test_launch_resolves_component_and_reports_start_failure(self):
        commands = []

        def fake_adb_shell(command, timeout=60):
            commands.append(command)
            if command.startswith('cmd package resolve-activity'):
                return types.SimpleNamespace(
                    returncode=0,
                    stdout='priority=0 preferredOrder=0\ncom.tencent.mm/.ui.LauncherUI\n',
                    stderr='',
                )
            return types.SimpleNamespace(returncode=0, stdout='Starting: Intent { ... }\n', stderr='')

        with mock.patch.object(self.service, 'adb_shell', side_effect=fake_adb_shell):
            result = self.service.execute_tool(
                2, 'phone_launch_app', {'package': 'com.tencent.mm'}
            )

        self.assertEqual(result, '已启动 com.tencent.mm（com.tencent.mm/.ui.LauncherUI）')
        self.assertIn('--display 2', commands[-1])
        self.assertIn('-n com.tencent.mm/.ui.LauncherUI', commands[-1])

        def failed_start(command, timeout=60):
            if command.startswith('cmd package resolve-activity'):
                return types.SimpleNamespace(
                    returncode=0, stdout='com.tencent.mm/.ui.LauncherUI\n', stderr=''
                )
            return types.SimpleNamespace(
                returncode=0,
                stdout='Error: Activity not started, unable to resolve Intent\n',
                stderr='',
            )

        with mock.patch.object(self.service, 'adb_shell', side_effect=failed_start):
            result = self.service.execute_tool(
                2, 'phone_launch_app', {'package': 'com.tencent.mm'}
            )
        self.assertTrue(result.startswith('启动失败：'))

    def test_second_task_is_rejected_while_one_is_running(self):
        self.service.TASKS.clear()

    def test_answered_task_remains_active_until_it_resumes(self):
        self.service.TASKS.clear()
        task = self.service.Task('等待验证码')
        task.status = 'waiting_for_answer'
        self.service.TASKS[task.id] = task
        config = {
            'gateway_ready': True,
            'model': 'auto/gemini-4-argon',
            'base_url': 'http://127.0.0.1:3425/v1',
            'api_key': '',
            'models': [],
            'max_steps': 25,
        }
        with mock.patch.object(self.service, 'load_config', return_value=config), \
                mock.patch.object(self.service, 'start_assistant_display', return_value=None):
            with self.assertRaisesRegex(ValueError, '已有任务正在执行'):
                self.service.dispatch_method('mika.task.start', {'goal': '另一个任务'})
        self.service.TASKS.clear()

    def test_text_input_is_a_single_shell_argument(self):
        commands = []

        def fake_adb_shell(command, timeout=60):
            commands.append(command)
            return types.SimpleNamespace(returncode=0, stdout='', stderr='')

        text = 'hello; touch /tmp/pwned $(id) `id` \' " world'
        with mock.patch.object(self.service, 'adb_shell', side_effect=fake_adb_shell):
            self.service.input_text_ascii(3, text)

        tokens = shlex.split(commands[-1])
        self.assertEqual(tokens[:4], ['input', '-d', '3', 'text'])
        self.assertEqual(tokens[4:], [text.replace(' ', '%s')])

    def test_phone_key_rejects_arbitrary_keycodes(self):
        commands = []

        def fake_adb_shell(command, timeout=60):
            commands.append(command)
            return types.SimpleNamespace(returncode=0, stdout='', stderr='')

        with mock.patch.object(self.service, 'adb_shell', side_effect=fake_adb_shell):
            result = self.service.execute_tool(3, 'phone_key', {'key': 'BACK; id'})
            self.service.execute_tool(3, 'phone_key', {'key': 'KEYCODE_POWER'})

        self.assertTrue(result.startswith('操作失败：'))
        self.assertEqual(commands, [])

    def test_task_executes_every_tool_call_with_matching_results(self):
        task = self.service.Task('测试多工具')
        model_messages = []
        responses = [
            {
                'choices': [{'message': {
                    'content': '',
                    'tool_calls': [
                        {
                            'id': 'call-a',
                            'type': 'function',
                            'function': {'name': 'phone_tap', 'arguments': '{"x":1,"y":2}'},
                        },
                        {
                            'id': 'call-b',
                            'type': 'function',
                            'function': {'name': 'phone_wait', 'arguments': '{"seconds":0.2}'},
                        },
                    ],
                }}],
            },
            {'choices': [{'message': {'content': '完成', 'tool_calls': []}}]},
        ]

        def fake_model(_task, _config, messages):
            model_messages.append(copy.deepcopy(messages))
            return responses[len(model_messages) - 1], ''

        executed = []
        with mock.patch.object(self.service, 'ensure_display', return_value=4), \
                mock.patch.object(self.service, 'capture', return_value=b'png'), \
                mock.patch.object(self.service, 'png_to_jpeg_base64', return_value=('', 'image/png')), \
                mock.patch.object(self.service, 'call_model_while_active', side_effect=fake_model), \
                mock.patch.object(self.service, 'execute_tool', side_effect=lambda _d, name, _a: executed.append(name) or 'ok'), \
                mock.patch.object(self.service.time, 'sleep', return_value=None):
            self.service.task_thread(task, {'max_steps': 3})

        self.assertEqual(executed, ['phone_tap', 'phone_wait'])
        self.assertEqual(task.status, 'done')
        self.assertEqual(task.answer, '完成')
        tool_ids = [
            item.get('tool_call_id')
            for item in model_messages[1]
            if item.get('role') == 'tool'
        ]
        self.assertEqual(tool_ids, ['call-a', 'call-b'])

    def test_empty_model_response_fails_instead_of_completing(self):
        task = self.service.Task('测试空响应')
        response = {'choices': [{'message': {'content': '', 'tool_calls': []}}]}
        with mock.patch.object(self.service, 'ensure_display', return_value=4), \
                mock.patch.object(self.service, 'capture', return_value=b'png'), \
                mock.patch.object(self.service, 'png_to_jpeg_base64', return_value=('', 'image/png')), \
                mock.patch.object(self.service, 'call_model_while_active', return_value=(response, '')):
            self.service.task_thread(task, {'max_steps': 1})
        self.assertEqual(task.status, 'failed')
        self.assertIn('空响应', task.reason)

    def test_task_waits_for_an_answer_and_resumes(self):
        task = self.service.Task('测试回答')
        answer = []

        worker = threading.Thread(
            target=lambda: answer.append(self.service.wait_for_task_answer(task, '需要验证码')),
            daemon=True,
        )
        worker.start()
        deadline = time.time() + 2
        while task.status != 'waiting_for_answer' and time.time() < deadline:
            time.sleep(0.02)
        with task.lock:
            task.inbox.append('123456')
        worker.join(timeout=2)

        self.assertEqual(answer, ['123456'])
        self.assertEqual(task.status, 'running')
        self.assertIsNone(task.question)

    def test_cancelled_model_wait_returns_without_blocking(self):
        task = self.service.Task('测试取消')
        result = []

        def slow_model(_config, _messages):
            time.sleep(2)
            return {'choices': [{'message': {'content': 'late'}}]}, ''

        with mock.patch.object(self.service, 'call_model', side_effect=slow_model):
            worker = threading.Thread(
                target=lambda: result.append(
                    self.service.call_model_while_active(task, {}, [])
                ),
                daemon=True,
            )
            started = time.time()
            worker.start()
            time.sleep(0.1)
            task.cancelled = True
            worker.join(timeout=1)

        self.assertFalse(worker.is_alive())
        self.assertLess(time.time() - started, 1)
        self.assertEqual(result, [(None, '用户已停止')])

    def test_idle_snapshot_does_not_recreate_the_display(self):
        old_state = dict(self.service.DISPLAY_STATE)
        self.service.DISPLAY_STATE.update({
            'displayId': -1, 'sfId': None, 'server': None,
            'drain': None, 'forwardPort': None, 'scid': None,
        })
        try:
            with mock.patch.object(
                self.service, 'ensure_display', side_effect=AssertionError('must not recreate')
            ):
                result = self.service.dispatch_method('mika.display.snapshot', {})
        finally:
            self.service.DISPLAY_STATE.update(old_state)
        self.assertFalse(result['active'])
        self.assertEqual(result['display_id'], -1)

    def test_surfaceflinger_display_is_selected_by_id(self):
        with mock.patch.object(
            self.service,
            'surfaceflinger_displays',
            return_value={
                115: ('scrcpy', 'virtual:one'),
                116: ('scrcpy', 'virtual:two'),
            },
        ), mock.patch.object(
            self.service,
            'display_unique_id',
            side_effect=lambda display_id: {7: 'virtual:one', 8: 'virtual:two'}.get(display_id),
        ):
            self.assertEqual(self.service.resolve_sf_display(7), 115)
            self.assertEqual(self.service.resolve_sf_display(8), 116)
            self.assertIsNone(self.service.resolve_sf_display(9))

    def test_background_provision_requires_success_marker(self):
        statuses = []
        config = {
            'gateway_ready': False,
            'model': '',
        }
        failed = types.SimpleNamespace(
            returncode=1,
            stdout='',
            stderr='AU_PLUGIN_HOOK_FAIL DISABLE_ADB_WIFI',
        )
        with mock.patch.object(self.service, 'load_config', return_value=config), \
                mock.patch.object(self.service, 'run_payload', return_value=failed), \
                mock.patch.object(self.service, 'set_status', side_effect=lambda *a, **k: statuses.append((a, k))):
            self.service.background_work()
        self.assertEqual(statuses[-1][0][0], 'degraded')

        missing_marker = types.SimpleNamespace(returncode=0, stdout='', stderr='')
        statuses.clear()
        with mock.patch.object(self.service, 'load_config', return_value=config), \
                mock.patch.object(self.service, 'run_payload', return_value=missing_marker), \
                mock.patch.object(self.service, 'set_status', side_effect=lambda *a, **k: statuses.append((a, k))):
            self.service.background_work()
        self.assertEqual(statuses[-1][0][0], 'degraded')

        statuses.clear()
        success = types.SimpleNamespace(
            returncode=0,
            stdout='ASSISTANT_PROVISION_OK\n',
            stderr='',
        )
        with mock.patch.object(self.service, 'load_config', return_value=config), \
                mock.patch.object(self.service, 'run_payload', return_value=success), \
                mock.patch.object(self.service, 'set_status', side_effect=lambda *a, **k: statuses.append((a, k))):
            self.service.background_work()
        self.assertEqual(statuses[-1][0][0], 'ready')
        self.service.TASKS['existing'] = self.service.Task('已有任务')
        config = {
            'gateway_ready': True,
            'model': 'auto/gemini-4-argon',
            'base_url': 'http://127.0.0.1:3425/v1',
            'api_key': '',
            'models': [],
            'max_steps': 25,
        }
        with mock.patch.object(self.service, 'load_config', return_value=config), \
                mock.patch.object(self.service, 'start_assistant_display', return_value=None):
            with self.assertRaisesRegex(ValueError, '已有任务正在执行'):
                self.service.dispatch_method('mika.task.start', {'goal': '新任务'})
        self.service.TASKS.clear()


if __name__ == '__main__':
    unittest.main(verbosity=2)
