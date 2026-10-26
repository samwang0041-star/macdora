#!/usr/bin/env python3
"""Compare main/background rendering using a fixed probe host and isolated VM.

Profiles A/B/C reproduce specific GPU feature combinations; A is not a native
AndroMeld benchmark. Reuse/cleanup require verified ownership of this VM.
The probe APK must be the same signed artifact across all cases.
"""
import argparse, subprocess, os, time, json, hashlib, socket, threading, math
from pathlib import Path
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('name')
p.add_argument('--profile', choices=['c', 'b', 'a', 'production', 'angle-safe'], default='production')
p.add_argument('--format', choices=['nv12', 'bgra'], default='nv12')
p.add_argument('--reuse', action='store_true')
p.add_argument('--keep', action='store_true')
p.add_argument('--codec', default='low-latency=1')
p.add_argument('--display', choices=['1080x1920/420', '1920x1200/240'], default='1080x1920/420')
p.add_argument('--display-sync', choices=['on', 'off'])
p.add_argument('--connection-delay', type=float, default=0, help='Allow up to 10 seconds to focus the host before the measured connection starts')
p.add_argument('--runtime-dir', type=Path, required=True)
p.add_argument('--evaluation-dir', type=Path, required=True)
p.add_argument('--probe-apk', type=Path, required=True)
p.add_argument('--output-root', type=Path, default=Path('.build/gpu-benchmark'))
p.add_argument('--state-dir', type=Path, default=Path('.build/gpu-benchmark'))
p.add_argument('--adb-port', type=int, default=5051)
p.add_argument('--emulator-port', type=int, default=5590)
p.add_argument('--avd', default='android17-evaluation')
a = p.parse_args()
a.connection_delay = min(10, max(0, a.connection_delay)) if math.isfinite(a.connection_delay) else 0
root = Path(__file__).resolve().parents[1]
a.output_root = a.output_root.resolve()
a.state_dir = a.state_dir.resolve()
a.probe_apk = a.probe_apk.resolve()
a.output_root.mkdir(parents=True, exist_ok=True)
a.state_dir.mkdir(parents=True, exist_ok=True)
out = a.output_root / a.name
out.mkdir(exist_ok=False)
runtime = a.runtime_dir.resolve()
gpu_library = runtime / 'emulator/lib64/vulkan/libMoltenVK.dylib'
gpu_driver_sha256 = hashlib.sha256(gpu_library.read_bytes()).hexdigest()
ev = a.evaluation_dir.resolve()
state_file = a.state_dir / 'owned-vm.json'
adb = [str(runtime / 'platform-tools/adb'), '-P', str(a.adb_port), '-s', f'emulator-{a.emulator_port}']

def call(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, timeout=kw.pop('timeout', 30), **kw)

def shell(s, **kw):
    return call(adb + ['shell', s], **kw)
env = os.environ.copy()
env.update({'ANDROID_EMULATOR_HOME': str(ev / 'emulator-home'), 'ANDROID_AVD_HOME': str(ev / 'avd'), 'ANDROID_USER_HOME': str(ev / 'user'), 'ANDROID_ADB_SERVER_PORT': str(a.adb_port), 'ANDROID_EMU_VK_ICD': 'moltenvk', 'MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS': '0', 'MVK_CONFIG_SHOULD_MAXIMIZE_CONCURRENT_COMPILATION': '1', 'MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS': '0', 'MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS': '0'})
features = ['Vulkan', 'GLDirectMem', 'GLESDynamicVersion', 'VirtioGpuNativeSync', 'VirtioGpuNext', 'HasSharedSlotsHostMemoryAllocator', 'VulkanQueueSubmitWithCommands', 'VulkanBatchedDescriptorSetUpdate', 'VulkanShaderFloat16Int8', 'VulkanAstcLdrEmulation', 'VulkanEtc2Emulation', '-GLPipeChecksum']
features += ['NoDelayCloseColorBuffer' if a.profile in ['a', 'b'] else '-NoDelayCloseColorBuffer']
features += ['VulkanVirtualQueue' if a.profile in ['a', 'b', 'production', 'angle-safe'] else '-VulkanVirtualQueue']
if a.profile in ['a', 'angle-safe']:
    features += ['GuestAngle']
cmd = [str(runtime / 'emulator/emulator'), '-avd', a.avd, '-port', str(a.emulator_port), '-no-window', '-gpu', 'host', '-no-metrics', '-no-snapshot', '-no-boot-anim', '-no-audio', '-camera-front', 'none', '-camera-back', 'emulated']
for feature in features:
    cmd += ['-feature', feature]
if a.profile in ['a', 'angle-safe']:
    cmd += ['-prop', 'androidboot.hardware.egl=angle']
vm = None
server = None
host = None
monitor = None
owns_vm = False
background = []
monitoring = threading.Event()

def observe_background():
    while not monitoring.is_set():
        rows = subprocess.run(['/bin/ps', '-axo', 'pid=,pcpu=,comm='], capture_output=True, text=True).stdout.splitlines()
        background.append({'time': time.time(), 'processes': [r.strip() for r in rows if 'qemu-system' in r or 'swift-frontend' in r]})
        monitoring.wait(1)
observer = threading.Thread(target=observe_background, daemon=True)
observer.start()
try:
    if a.reuse:
        owned = json.loads(state_file.read_text())
        if owned['profile'] != a.profile:
            raise RuntimeError('Owned VM profile differs from requested profile')
        os.kill(owned['pid'], 0)
        actual = call(['/bin/ps', '-p', str(owned['pid']), '-o', 'command=']).stdout.strip()
        expected = str(runtime / 'emulator/qemu/darwin-aarch64/qemu-system-aarch64-headless')
        if not actual.startswith(expected + ' ') or f' -port {a.emulator_port} ' not in actual or f' -avd {a.avd} ' not in actual:
            raise RuntimeError('Owned VM identity does not match the running process')
        owns_vm = True
    if not a.reuse:
        with socket.socket() as s:
            if s.connect_ex(('127.0.0.1', a.emulator_port)) == 0:
                raise RuntimeError('Evaluation VM port already occupied; use --reuse only for known owned VM')
        call([str(runtime / 'platform-tools/adb'), '-P', str(a.adb_port), 'start-server'], check=True)
        vm = subprocess.Popen(cmd, env=env, start_new_session=True, stdout=(out / 'emulator.log').open('w'), stderr=subprocess.STDOUT)
        state_file.write_text(json.dumps({'pid': vm.pid, 'command': cmd, 'profile': a.profile}))
        owns_vm = True
        for i in range(120):
            if vm.poll() is not None:
                raise RuntimeError('emulator exited')
            if call(adb + ['get-state']).returncode == 0 and shell('getprop sys.boot_completed').stdout.strip() == '1':
                break
            time.sleep(1)
        else:
            raise RuntimeError('boot timeout')
        print('BOOTED', a.profile, flush=True)
        script = (root / 'Sources/AndroidUse/RuntimeSoftwareDefaults.swift').read_text().split('static let guestSetupScript = """')[1].split('"""')[0]
        shell(script, check=True)
        install = call(adb + ['install', '-r', str(a.probe_apk)], timeout=60)
        (out / 'install.log').write_text(install.stdout + install.stderr)
        if install.returncode:
            raise RuntimeError('install failed: ' + install.stdout + install.stderr)
    call(adb + ['push', str(root / '.build/scrcpy-ordered/scrcpy-server'), '/data/local/tmp/android-use-scrcpy.jar'], check=True)
    scid = '00004a11'
    servercmd = 'CLASSPATH=/data/local/tmp/android-use-scrcpy.jar app_process / com.genymobile.scrcpy.Server 5.0.1 tunnel_forward=true audio=false control=true video_codec=h264 video_bit_rate=24000000 max_fps=60 new_display=' + a.display + ' vd_system_decorations=false display_ime_policy=local clipboard_autosync=false send_device_meta=false send_dummy_byte=false send_frame_meta=true send_stream_meta=true keep_active=true log_level=info vd_destroy_content=true scid=' + scid
    if a.codec:
        servercmd += ' video_codec_options=' + a.codec
    server = subprocess.Popen(adb + ['shell', servercmd], stdout=(out / 'server.log').open('w'), stderr=subprocess.STDOUT)
    call(adb + ['forward', 'tcp:27184', 'localabstract:scrcpy_' + scid], check=True)
    time.sleep(1)
    binary = root / '.build/AndroidUseProbe.app/Contents/MacOS/AndroidUse'
    hostenv = os.environ.copy()
    hostenv['ANDROID_USE_DECODE_FORMAT'] = a.format
    if a.display_sync is not None:
        hostenv['ANDROID_USE_DISPLAY_SYNC'] = '1' if a.display_sync == 'on' else '0'
    host = subprocess.Popen([str(binary), '--probe', '--benchmark', '--connection-delay', str(a.connection_delay), '--port', '27184', '--app', 'local.androiduse.probe', '--report', str(out / 'performance.json'), '--exit-after-report'], env=hostenv, stdout=(out / 'host.log').open('w'), stderr=subprocess.STDOUT)
    vmpid = vm.pid if vm else json.loads(state_file.read_text())['pid']
    monitor = subprocess.Popen(['python3', str(root / 'scripts/measure-resources.py'), '--pid', str(host.pid), '--pid', str(vmpid), '--seconds', str(38 + math.ceil(a.connection_delay)), '--output', str(out / 'resources.json')], stdout=(out / 'resources.log').open('w'), stderr=subprocess.STDOUT)
    props = {k: shell('getprop ' + k).stdout.strip() for k in ['ro.hardware.egl', 'ro.hardware.vulkan', 'ro.hardware.gltransport', 'ro.boot.hardware.gltransport', 'ro.opengles.version', 'debug.hwui.renderer', 'debug.renderengine.backend']}
    (out / 'properties.json').write_text(json.dumps(props, indent=2) + '\n')
    (out / 'manifest.json').write_text(json.dumps({'profile': a.profile, 'format': a.format, 'gpuDriverSHA256': gpu_driver_sha256, 'probeAPK_SHA256': hashlib.sha256(a.probe_apk.read_bytes()).hexdigest(), 'hostSHA256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'hostEnvironment': {k: v for k, v in hostenv.items() if k.startswith('ANDROID_USE_')}, 'serverSHA256': hashlib.sha256((root / '.build/scrcpy-ordered/scrcpy-server').read_bytes()).hexdigest(), 'emulatorCommand': owned['command'] if a.reuse else cmd, 'serverCommand': servercmd, 'vmPID': vmpid, 'hostPID': host.pid}, indent=2) + '\n')
    print('HOST_STARTED', a.name, host.pid, flush=True)
    try:
        host.wait(timeout=55)
    except subprocess.TimeoutExpired:
        (out / 'performance.json').write_text(json.dumps({'schemaVersion': 3, 'passed': False, 'completionReason': 'host_timeout', 'newPresentedFPS': None, 'measurementUnavailable': True}, indent=2) + '\n')
        raise
    if not (out / 'performance.json').exists():
        raise RuntimeError('host ended without report')
    d = json.loads((out / 'performance.json').read_text())
    print(json.dumps({k: d.get(k) for k in ['passed', 'completionReason', 'newPresentedFPS', 'inputLatencyMs', 'invalidPresentationTimestamps', 'gates', 'hostPipelineMs']}), flush=True)
    monitor.wait(timeout=40)
finally:
    monitoring.set()
    observer.join(timeout=3)
    (out / 'background-processes.json').write_text(json.dumps(background, indent=2) + '\n')
    if host and host.poll() is None:
        host.terminate()
        host.wait(timeout=5)
    if server and server.poll() is None:
        server.terminate()
        server.wait(timeout=5)
    if owns_vm:
        call(adb + ['forward', '--remove', 'tcp:27184'])
    if monitor and monitor.poll() is None:
        monitor.terminate()
        monitor.wait(timeout=5)
    if owns_vm and (not a.keep):
        call(adb + ['emu', 'kill'])
