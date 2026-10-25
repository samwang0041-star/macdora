import XCTest
@testable import AndroidUse

@MainActor
final class RuntimeLifecycleTests: XCTestCase {
    func testSoftwareDisplayDefaultsSurviveFreshBootModeChangesAndReopenOnEitherImage() async throws {
        for api in [35, 37] {
            let fixture = try LifecycleFixture(androidAPI: api)
            defer { fixture.remove() }
            try await fixture.controller.prepare()
            try await fixture.controller.start()
            XCTAssertTrue(fixture.registry.secureContentVisible, "Fresh API \(api) must receive software defaults before ready.")

            for tabletMode in [true, false, true, false] {
                var preferences = fixture.controller.containerPreferences
                preferences.tabletMode = tabletMode
                fixture.controller.containerPreferences = preferences
                fixture.registry.secureContentVisible = false
                await fixture.controller.applyGuestDeviceFormFactor(tabletMode: tabletMode)
                XCTAssertTrue(fixture.registry.secureContentVisible, "Mode changes must reapply display defaults.")
                _ = try await fixture.controller.openDisplay()
                XCTAssertEqual(fixture.registry.displayDefaultsAtLaunch.last, true, "Opening an app must preserve defaults before starting its display.")
                await fixture.controller.closeDisplay()
            }
            _ = await fixture.controller.stop()
            fixture.registry.secureContentVisible = false
            try await fixture.controller.start()
            XCTAssertTrue(fixture.registry.secureContentVisible, "A subsequent cold boot must restore defaults.")
            _ = await fixture.controller.stop()
        }
    }

    func testTabletModeAppliesMuMuDeviceIdentityAndWeChatAuthCacheReset() async throws {
        let tabletB64 = RuntimeSoftwareDefaults.propertyRecordBase64("SM-F926U")
        let tabletBytes = try XCTUnwrap(Data(base64Encoded: tabletB64))
        XCTAssertEqual(tabletBytes.count, 96)
        XCTAssertEqual(Array(tabletBytes[0..<4]), [0, 0, 0, 8])
        XCTAssertEqual(String(decoding: tabletBytes[4..<12], as: UTF8.self), "SM-F926U")
        XCTAssertTrue(tabletBytes[12..<96].allSatisfy { $0 == 0 })

        let tabletScript = RuntimeSoftwareDefaults.guestDeviceIdentityScript(tabletMode: true)
        XCTAssertTrue(tabletScript.contains("target_model=\"SM-F926U\""))
        XCTAssertTrue(tabletScript.contains("target_chars=\"tablet\""))
        XCTAssertTrue(tabletScript.contains("target_density=\"240\""))
        XCTAssertTrue(tabletScript.contains("u:object_r:build_prop:s0"))
        XCTAssertTrue(tabletScript.contains("u:object_r:build_vendor_prop:s0"))
        XCTAssertTrue(tabletScript.contains("u:object_r:build_odm_prop:s0"))
        XCTAssertTrue(tabletScript.contains("u:object_r:fingerprint_prop:s0"))
        XCTAssertTrue(tabletScript.contains("u:object_r:qemu_sf_lcd_density_prop:s0"))
        XCTAssertTrue(tabletScript.contains("7a03bac2-692f-3d17-a2cd-a1b0721ffd0e"))
        XCTAssertTrue(tabletScript.contains("8fa14cdd-754f-31cc-a554-c9e71929cce7"))
        XCTAssertTrue(tabletScript.contains("setprop ctl.restart zygote"))

        let phoneScript = RuntimeSoftwareDefaults.guestDeviceIdentityScript(tabletMode: false)
        XCTAssertTrue(phoneScript.contains("target_model=\"Android SDK built for arm64\""))
        XCTAssertTrue(phoneScript.contains("target_chars=\"default\""))
        XCTAssertTrue(phoneScript.contains("target_density=\"420\""))

        // Force-stop must precede .auth_cache deletion, and Zygote model state must be marked pending before restart.
        let stopIndex = try XCTUnwrap(tabletScript.range(of: "am force-stop com.tencent.mm")?.lowerBound)
        let rmIndex = try XCTUnwrap(tabletScript.range(of: "rm -rf /data/data/com.tencent.mm/.auth_cache/7a03bac2-692f-3d17-a2cd-a1b0721ffd0e")?.lowerBound)
        let pendingIndex = try XCTUnwrap(tabletScript.range(of: "setprop sys.androiduse.zygote_model \"pending\"")?.lowerBound)
        let patchFnIndex = try XCTUnwrap(tabletScript.range(of: "patch_prop() {")?.lowerBound)
        let restartIndex = try XCTUnwrap(tabletScript.range(of: "setprop ctl.restart zygote")?.lowerBound)
        let readyCheckIndex = try XCTUnwrap(tabletScript.range(of: "[ \"$ready\" = \"1\" ] || exit 1")?.lowerBound)
        let commitIndex = try XCTUnwrap(tabletScript.range(of: "setprop sys.androiduse.zygote_model \"$target_model\" >/dev/null 2>&1 || exit 1")?.lowerBound)
        XCTAssertLessThan(stopIndex, rmIndex)
        XCTAssertLessThan(pendingIndex, patchFnIndex)
        XCTAssertLessThan(pendingIndex, restartIndex)
        XCTAssertLessThan(restartIndex, readyCheckIndex)
        XCTAssertLessThan(readyCheckIndex, commitIndex)

        // Verify guest environment setup fails closed when the identity/setup script exits non-zero.
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        try await fixture.controller.prepare()
        fixture.registry.failNextGuestEnvironmentSetup = true
        do {
            try await fixture.controller.start()
            XCTFail("start() must fail closed when guest device identity setup fails.")
        } catch {
            XCTAssertEqual(error as? RuntimeError, .adbCommandFailed("配置应用运行环境"))
        }

        try await fixture.controller.start()
        fixture.registry.failNextGuestEnvironmentSetup = true
        let applied = await fixture.controller.applyGuestDeviceFormFactor(tabletMode: true)
        XCTAssertFalse(applied)

        fixture.registry.failNextGuestEnvironmentSetup = true
        do {
            _ = try await fixture.controller.openDisplay()
            XCTFail("openDisplay must fail closed when guest device identity setup fails.")
        } catch {
            XCTAssertEqual(error as? RuntimeError, .adbCommandFailed("配置应用运行环境"))
        }
        XCTAssertTrue(fixture.registry.servers.isEmpty)
        _ = await fixture.controller.stop()
    }

    func testConcurrentStopCallersWaitForTheSameCleanup() async throws {
        let gate = LifecycleGate()
        let fixture = try LifecycleFixture(stopGate: gate)
        defer { fixture.remove() }
        try await fixture.controller.prepare(); try await fixture.controller.start()
        let first = Task { await fixture.controller.stop() }
        await gate.waitUntilEntered()
        var secondReturned = false
        let second = Task { let result = await fixture.controller.stop(); secondReturned = true; return result }
        await Task.yield()
        XCTAssertFalse(secondReturned)
        XCTAssertEqual(fixture.controller.state, .stopping)
        await gate.release()
        let firstResult = await first.value; let secondResult = await second.value
        XCTAssertTrue(firstResult); XCTAssertTrue(secondResult)
        XCTAssertEqual(fixture.registry.adbStopCalls, 1)
        XCTAssertEqual(fixture.controller.state, .stopped)
        XCTAssertFalse(fixture.registry.adb?.isRunning ?? true)
    }

    func testUnconfirmedOwnedProcessPreventsStoppedStateAndCanBeRetried() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        try await fixture.controller.prepare(); try await fixture.controller.start()
        fixture.terminator.leaveADBRunning = true
        let first = await fixture.controller.stop()
        XCTAssertFalse(first)
        if case .failed = fixture.controller.state {} else { XCTFail("An unconfirmed exit must remain failed.") }
        XCTAssertTrue(fixture.registry.adb?.isRunning ?? false)
        fixture.terminator.leaveADBRunning = false
        let retry = await fixture.controller.stop()
        XCTAssertTrue(retry)
        XCTAssertEqual(fixture.controller.state, .stopped)
    }

    func testOldCloseAndReopenCannotConsumeTheNewSession() async throws {
        let gate = LifecycleGate()
        let fixture = try LifecycleFixture(closeGate: gate)
        defer { fixture.remove() }
        try await fixture.controller.prepare(); try await fixture.controller.start()
        let old = try await fixture.controller.openDisplay()
        let firstClose = Task { await fixture.controller.closeDisplay() }
        await gate.waitUntilEntered()
        var secondClosed = false
        let secondClose = Task { await fixture.controller.closeDisplay(); secondClosed = true }
        let reopened = Task { try await fixture.controller.openDisplay() }
        await Task.yield()
        XCTAssertFalse(secondClosed)
        XCTAssertEqual(fixture.registry.servers.count, 1, "A new server waits for the detached old session cleanup.")
        await gate.release()
        await firstClose.value; await secondClose.value
        let current = try await reopened.value
        XCTAssertNotEqual(current.port, old.port)
        XCTAssertEqual(fixture.controller.state, .running)
        XCTAssertEqual(fixture.registry.forwardPorts, Set([current.port, try XCTUnwrap(current.imePort)]))
        XCTAssertTrue(try XCTUnwrap(fixture.registry.servers.last).isRunning)
        let stopped = await fixture.controller.stop()
        XCTAssertTrue(stopped)
    }

    func testStartWaitsUntilDefaultNetworkBecomesConnected() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        fixture.registry.connectivityReplies = [
            "Active default network: none\n",
            "Active default network: 100\nNetworkAgentInfo{network{100} ni{MOBILE[HSPA] CONNECTED} nc{[ Capabilities: INTERNET&NOT_RESTRICTED ]}}\n"
        ]
        try await fixture.controller.prepare()
        try await fixture.controller.start()
        XCTAssertEqual(fixture.controller.state, .ready)
        XCTAssertEqual(fixture.registry.connectivityCalls, 2)
        let stopped = await fixture.controller.stop()
        XCTAssertTrue(stopped)
    }

    func testStartConfiguresWebcamFrontCameraAndRestartsWhenCameraPreferenceChanges() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        fixture.controller.cameraEnabled = true
        try await fixture.controller.prepare()
        try await fixture.controller.start()
        XCTAssertEqual(fixture.registry.emulatorArguments.count, 1)
        XCTAssertEqual(
            Array(fixture.registry.emulatorArguments[0].suffix(4)),
            ["-camera-back", "emulated", "-camera-front", "webcam0"]
        )
        XCTAssertEqual(
            fixture.registry.emulatorEnvironments[0]["DYLD_INSERT_LIBRARIES"],
            fixture.controller.paths.cameraSyncDylibURL.path
        )

        // Re-starting without changing cameraEnabled reuses the running emulator.
        try await fixture.controller.start()
        XCTAssertEqual(fixture.registry.emulatorArguments.count, 1)

        // Toggling cameraEnabled forces start() to replace the emulator with the new camera flags.
        fixture.controller.cameraEnabled = false
        try await fixture.controller.start()
        XCTAssertEqual(fixture.registry.emulatorArguments.count, 2)
        XCTAssertEqual(
            Array(fixture.registry.emulatorArguments[1].suffix(4)),
            ["-camera-back", "none", "-camera-front", "none"]
        )
        XCTAssertNil(fixture.registry.emulatorEnvironments[1]["DYLD_INSERT_LIBRARIES"])
        let stopped = await fixture.controller.stop()
        XCTAssertTrue(stopped)
    }

    func testUninstallRequiresVerifiedPackageRemovalAndRefreshedCatalog() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        fixture.registry.installedPackages = [DemoApp.package, "com.tencent.mm"]
        try await fixture.controller.prepare()
        try await fixture.controller.start()
        _ = await fixture.controller.refreshContainerApps()

        try await fixture.controller.uninstallApp(package: "com.tencent.mm")
        XCTAssertNil(fixture.controller.cachedContainerApps().first(where: { $0.package == "com.tencent.mm" }))

        fixture.registry.installedPackages = [DemoApp.package, "com.tencent.mm"]
        _ = await fixture.controller.refreshContainerApps()
        fixture.registry.failNextCatalogRefresh = true
        do {
            try await fixture.controller.uninstallApp(package: "com.tencent.mm")
            XCTFail("A failed device-list refresh must not report a confirmed catalog.")
        } catch {
            XCTAssertEqual(error as? RuntimeError, .uninstallUnconfirmed)
        }
        XCTAssertTrue(fixture.controller.cachedContainerApps().contains(where: {
            $0.package == "com.tencent.mm" && $0.isInstalled
        }), "Keep the last known catalog instead of fabricating a removal.")

        try await fixture.controller.uninstallApp(package: DemoApp.package)
        XCTAssertNil(fixture.controller.cachedContainerApps().first(where: { $0.package == DemoApp.package }))
        let stopped = await fixture.controller.stop()
        XCTAssertTrue(stopped)
    }

    func testStartConfiguresVirtioGPUAndMoltenVKPicturesAndUpgradesLegacyConfig() async throws {
        let fixture = try LifecycleFixture(androidAPI: 37)
        defer { fixture.remove() }
        try await fixture.controller.prepare()
        let configURL = fixture.controller.paths.avdURL.appendingPathComponent("config.ini")
        let legacy = try String(contentsOf: configURL, encoding: .utf8)
            .replacingOccurrences(of: "hw.gltransport.asg.dataRingSize=524288\n", with: "")
            + "\nhw.gltransport=virtio-gpu-pipe\n"
        XCTAssertFalse(RuntimeController.hasRequiredAVDGPUConfiguration(legacy))
        try Data(legacy.utf8).write(to: configURL, options: .atomic)

        try await fixture.controller.start()

        let upgraded = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(RuntimeController.hasRequiredAVDGPUConfiguration(upgraded))
        let args = try XCTUnwrap(fixture.registry.emulatorArguments.first)
        for feature in [
            "Vulkan", "GLDirectMem", "GLESDynamicVersion",
            "VirtioGpuNativeSync", "VirtioGpuNext", "HasSharedSlotsHostMemoryAllocator",
            "VulkanQueueSubmitWithCommands", "VulkanBatchedDescriptorSetUpdate",
            "VulkanShaderFloat16Int8",
            "VulkanAstcLdrEmulation", "VulkanEtc2Emulation", "-GLPipeChecksum"
        ] {
            XCTAssertTrue(args.contains(feature), "Missing GPU feature flag \(feature)")
        }
        XCTAssertFalse(args.contains("NoDelayCloseColorBuffer"))
        XCTAssertTrue(args.contains("-NoDelayCloseColorBuffer"))
        XCTAssertTrue(args.contains("VulkanVirtualQueue"))
        XCTAssertFalse(args.contains("GuestAngle"))
        XCTAssertTrue(args.contains("-GuestAngle"))
        XCTAssertTrue(args.contains("androidboot.hardware.egl=emulation"))
        let env = try XCTUnwrap(fixture.registry.emulatorEnvironments.first)
        XCTAssertEqual(env["ANDROID_EMU_VK_ICD"], "moltenvk")
        XCTAssertEqual(env["MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS"], "0")
        XCTAssertEqual(env["MVK_CONFIG_SHOULD_MAXIMIZE_CONCURRENT_COMPILATION"], "1")
        XCTAssertEqual(env["MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS"], "0")
        XCTAssertEqual(env["MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS"], "0")
        let setupScripts = RuntimeSoftwareDefaults.guestSetupScript
        XCTAssertTrue(setupScripts.contains("cmd power set-fixed-performance-mode-enabled true"))
        XCTAssertTrue(setupScripts.contains("setprop debug.sf.vsync_reactor_ignore_present_fences true"))
        XCTAssertTrue(setupScripts.contains("setprop debug.sf.latch_unsignaled 1"))
        let stopped = await fixture.controller.stop()
        XCTAssertTrue(stopped)
    }
}

private actor LifecycleGate {
    private var entered = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true; observers.forEach { $0.resume() }; observers.removeAll()
        await withCheckedContinuation { blocked = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { blocked?.resume(); blocked = nil }
}

private final class LifecycleHandle: OwnedProcessHandle, @unchecked Sendable {
    enum Kind { case adb, emulator, display }
    let kind: Kind
    private let lock = NSLock()
    private var running = true
    private let onExit: @Sendable (ProcessExit) -> Void
    init(_ kind: Kind, onExit: @escaping @Sendable (ProcessExit) -> Void) { self.kind = kind; self.onExit = onExit }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    var processIdentifier: Int32 { -1 } // Synthetic handle; never an OS process.
    func terminate() { finish() }
    func kill() { finish() }
    func finish() {
        lock.lock(); let notify = running; running = false; lock.unlock()
        if notify { onExit(ProcessExit(status: 0)) }
    }
}

private final class LifecycleRegistry: @unchecked Sendable {
    let lock = NSLock()
    var adb: LifecycleHandle?
    var emulator: LifecycleHandle?
    var servers: [LifecycleHandle] = []
    var forwardPorts = Set<UInt16>()
    var nextPort: UInt16 = 55000
    var adbStopCalls = 0
    var connectivityCalls = 0
    var connectivityReplies: [String] = []
    var emulatorArguments: [[String]] = []
    var emulatorEnvironments: [[String: String]] = []
    var secureContentVisible = false
    var displayDefaultsAtLaunch: [Bool] = []
    var installedPackages = Set<String>()
    var failNextCatalogRefresh = false
    var failNextGuestEnvironmentSetup = false
    func withLock<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}

private final class LifecycleRunner: ProcessExecuting, @unchecked Sendable {
    let registry: LifecycleRegistry
    init(_ registry: LifecycleRegistry) { self.registry = registry }
    func launch(_ invocation: ProcessInvocation, operation: String, onExit: @escaping @Sendable (ProcessExit) -> Void) async throws -> any OwnedProcessHandle {
        let kind: LifecycleHandle.Kind = invocation.arguments.contains("nodaemon") ? .adb : (invocation.executableURL.lastPathComponent == "emulator" ? .emulator : .display)
        let handle = LifecycleHandle(kind, onExit: onExit)
        registry.withLock {
            switch kind {
            case .adb:
                registry.adb = handle
            case .emulator:
                registry.emulator = handle
                registry.emulatorArguments.append(invocation.arguments)
                registry.emulatorEnvironments.append(invocation.environment)
            case .display:
                registry.servers.append(handle)
                registry.displayDefaultsAtLaunch.append(registry.secureContentVisible)
            }
        }
        return handle
    }
    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        let args = invocation.arguments
        if args.contains("uninstall"), let package = args.last {
            _ = registry.withLock { registry.installedPackages.remove(package) }
            return ProcessResult(exitCode: 0, stdout: Data("Success\n".utf8), timedOut: false)
        }
        if args.contains("path"), args.contains("pm"), let package = args.last {
            let installed = registry.withLock { registry.installedPackages.contains(package) }
            let reply = installed ? "package:/data/app/\(package)/base.apk\n" : ""
            return ProcessResult(exitCode: 0, stdout: Data(reply.utf8), timedOut: false)
        }
        if args.contains("list"), args.contains("packages"), args.contains("-3") {
            let response = registry.withLock { () -> ProcessResult in
                if registry.failNextCatalogRefresh {
                    registry.failNextCatalogRefresh = false
                    return ProcessResult(exitCode: 1, stdout: Data(), timedOut: false)
                }
                let reply = registry.installedPackages.sorted().map { "package:\($0)\n" }.joined()
                return ProcessResult(exitCode: 0, stdout: Data(reply.utf8), timedOut: false)
            }
            return response
        }
        if args.contains("shell"), let script = args.last {
            let shouldFail = registry.withLock { () -> Bool in
                if script.contains("patch_prop()"), registry.failNextGuestEnvironmentSetup {
                    registry.failNextGuestEnvironmentSetup = false
                    return true
                }
                return false
            }
            if shouldFail {
                return ProcessResult(exitCode: 1, stdout: Data(), timedOut: false)
            }
            registry.withLock {
                for line in script.split(separator: "\n") {
                    if line.contains("settings put secure disable_secure_windows 1") { registry.secureContentVisible = true }
                    if line.contains("settings delete secure disable_secure_windows") { registry.secureContentVisible = false }
                }
            }
        }
        if args.suffix(2) == ["emu", "kill"] { registry.emulator?.finish() }
        if args.contains("forward"), let value = args.first(where: { $0.hasPrefix("tcp:") }), let port = UInt16(value.dropFirst(4)) {
            registry.withLock {
                if args.contains("--remove") { registry.forwardPorts.remove(port) }
                else { registry.forwardPorts.insert(port) }
            }
        }
        let reply: String
        if args.last == "get-state" { reply = "device\n" }
        else if args.last == "sys.boot_completed" { reply = "1\n" }
        else if args.last == "connectivity" {
            reply = registry.withLock {
                registry.connectivityCalls += 1
                if !registry.connectivityReplies.isEmpty {
                    return registry.connectivityReplies.removeFirst()
                }
                return "Active default network: 100\nNetworkAgentInfo{network{100} ni{MOBILE[HSPA] CONNECTED} nc{[ Capabilities: INTERNET&NOT_RESTRICTED ]}}\n"
            }
        }
        else if args.last == "/proc/net/unix" { reply = "@scrcpy_00000021\n" }
        else { reply = "Success\n" }
        return ProcessResult(exitCode: 0, stdout: Data(reply.utf8), timedOut: false)
    }
}

private final class LifecycleTerminator: OwnedProcessTerminating, @unchecked Sendable {
    let registry: LifecycleRegistry
    let gate: LifecycleGate?
    var leaveADBRunning = false
    init(_ registry: LifecycleRegistry, gate: LifecycleGate?) { self.registry = registry; self.gate = gate }
    func terminateAndWait(_ handle: any OwnedProcessHandle, timeout: TimeInterval) async -> Bool {
        if let synthetic = handle as? LifecycleHandle, synthetic.kind == .adb, handle.isRunning {
            registry.withLock { registry.adbStopCalls += 1 }
            if let gate { await gate.pause() }
            if leaveADBRunning { return false }
        }
        handle.terminate(); return !handle.isRunning
    }
}

private final class LifecycleEnvironment: ControllerEnvironment, @unchecked Sendable {
    let registry: LifecycleRegistry
    let gate: LifecycleGate?
    private var blocked = false
    init(_ registry: LifecycleRegistry, gate: LifecycleGate?) { self.registry = registry; self.gate = gate }
    func environment() -> [String: String] { ["PATH": "/usr/bin:/bin"] }
    func allocateForward(adbURL: URL, environment: [String: String], requestedPort: UInt16, scid: UInt32) async throws -> ForwardAllocation {
        _ = registry.withLock { registry.forwardPorts.insert(requestedPort) }
        return ForwardAllocation(localPort: requestedPort, serial: "emulator-5584", scid: scid)
    }
    func removeForward(adbURL: URL, environment: [String: String], allocation: ForwardAllocation) async throws {
        let shouldBlock = registry.withLock { let value = !blocked; blocked = true; return value }
        if shouldBlock, let gate { await gate.pause() }
        _ = registry.withLock { registry.forwardPorts.remove(allocation.localPort) }
    }
    func secureCopy(adbURL: URL, localURL: URL, remotePath: String, environment: [String: String]) async throws {}
    func portIsAvailable(_ port: UInt16) -> Bool {
        registry.withLock {
            if port == 5043 { return registry.adb?.isRunning != true }
            if port == 5584 { return registry.emulator?.isRunning != true }
            return !registry.forwardPorts.contains(port)
        }
    }
}

@MainActor
private struct LifecycleFixture {
    let root: URL
    let defaultsName: String
    let registry = LifecycleRegistry()
    let terminator: LifecycleTerminator
    let controller: RuntimeController
    init(stopGate: LifecycleGate? = nil, closeGate: LifecycleGate? = nil, androidAPI: Int = 35) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("android-use-lifecycle-\(UUID().uuidString)")
        defaultsName = "android-use-lifecycle-\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: defaultsName)!
        let source = root.appendingPathComponent("seed")
        for relative in ["emulator/emulator", "platform-tools/adb", "image/system.img", "image/vendor.img", "image/kernel-ranchu", "image/ramdisk.img", "image/source.properties", "image/NOTICE.txt", "android-use-ime.apk", "libmaccamera_frame_sync.dylib"] {
            let url = source.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("isolated fixture".utf8).write(to: url)
            if relative.hasSuffix("/adb") || relative.hasSuffix("/emulator") { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        try Data("AndroidVersion.ApiLevel=\(androidAPI)\nPkg.Revision=2\nSystemImage.Abi=arm64-v8a\nSystemImage.TagId=default\n".utf8)
            .write(to: source.appendingPathComponent("image/source.properties"))
        try Data("ro.build.version.incremental=12368160\n".utf8).write(to: source.appendingPathComponent("image/build.prop"))
        let jar = root.appendingPathComponent("scrcpy.jar"); try Data("fixture".utf8).write(to: jar)
        let environment = LifecycleEnvironment(registry, gate: closeGate)
        terminator = LifecycleTerminator(registry, gate: stopGate)
        let fixtureRegistry = registry
        controller = RuntimeController(rootURL: root.appendingPathComponent("data"), defaults: isolatedDefaults, runner: LifecycleRunner(registry), processTerminator: terminator,
            environment: environment, seed: RuntimeSeed(directoryURL: source, scrcpyServerURL: jar), hooks: RuntimeControllerHooks(
                freePort: { fixtureRegistry.withLock { fixtureRegistry.nextPort += 1; return fixtureRegistry.nextPort } }, randomSCID: { 0x21 },
                localHostPortAvailable: { _ in false }))
    }
    func remove() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
    }
}
