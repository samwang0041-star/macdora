import XCTest
@testable import AndroidUse

@MainActor
final class RuntimeLifecycleTests: XCTestCase {
    func testOfficeKeepAwakeDefaultsOffAndNeverRunsGuestCommandsWithoutOptIn() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        XCTAssertEqual(fixture.controller.officeKeepAwakeStatus, .off)
        try await fixture.controller.prepare()
        try await fixture.controller.start()
        _ = await fixture.controller.stop()
        XCTAssertEqual(fixture.registry.officeCommands, [])
        XCTAssertFalse(fixture.controller.isOfficeKeepAwakeActivityHeld)
    }

    func testOfficeKeepAwakeSavedWhileStoppedAppliesBeforeReadyAndSurvivesDisplayClose() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        var prefs = fixture.controller.containerPreferences
        prefs.keepWarmInBackground = false
        fixture.controller.containerPreferences = prefs
        XCTAssertFalse(fixture.controller.shouldKeepRuntimeInBackground)
        let saved = await fixture.controller.setOfficeKeepAwakeEnabled(true)
        XCTAssertTrue(saved)
        XCTAssertEqual(fixture.controller.officeKeepAwakeStatus.phase, .waitingForRuntime)
        XCTAssertTrue(fixture.controller.shouldKeepRuntimeInBackground)
        XCTAssertEqual(fixture.registry.officeCommands, [])
        var phaseAtReady: OfficeKeepAwakePhase?
        fixture.controller.onState = { state in
            if state == .ready { phaseAtReady = fixture.controller.officeKeepAwakeStatus.phase }
        }
        try await fixture.controller.prepare()
        try await fixture.controller.start()
        XCTAssertEqual(phaseAtReady, .active)
        XCTAssertEqual(fixture.registry.officeCommands, ["inspect", "apply"])
        XCTAssertEqual(fixture.registry.freezerSetting, "disabled")
        XCTAssertTrue(fixture.controller.isOfficeKeepAwakeActivityHeld)
        _ = try await fixture.controller.openDisplay()
        await fixture.controller.closeDisplay()
        XCTAssertEqual(fixture.controller.state, .ready)
        XCTAssertEqual(fixture.controller.officeKeepAwakeStatus.phase, .active)
        XCTAssertTrue(fixture.controller.isOfficeKeepAwakeActivityHeld)
        XCTAssertEqual(fixture.registry.emulatorArguments.count, 1)
        _ = await fixture.controller.stop()
        XCTAssertEqual(fixture.registry.freezerSetting, "null")
        XCTAssertFalse(fixture.controller.isOfficeKeepAwakeActivityHeld)
        XCTAssertFalse(fixture.officePreferences.hasOriginal)
        XCTAssertTrue(fixture.controller.officeKeepAwakeStatus.enabled, "Stopping must preserve the user's opt-in.")
    }

    func testOfficeKeepAwakeLiveToggleRestoresOriginalSettingAndReleasesHostActivity() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        fixture.registry.freezerSetting = "enabled"
        try await fixture.controller.prepare()
        try await fixture.controller.start()
        let enabled = await fixture.controller.setOfficeKeepAwakeEnabled(true)
        XCTAssertTrue(enabled)
        XCTAssertEqual(fixture.officePreferences.original, OfficeFreezerSnapshot(setting: .enabled, inUse: true))
        let disabled = await fixture.controller.setOfficeKeepAwakeEnabled(false)
        XCTAssertTrue(disabled)
        XCTAssertEqual(fixture.registry.freezerSetting, "enabled")
        XCTAssertEqual(fixture.controller.officeKeepAwakeStatus, .off)
        XCTAssertFalse(fixture.controller.isOfficeKeepAwakeActivityHeld)
        XCTAssertFalse(fixture.officePreferences.hasOriginal)
        _ = await fixture.controller.stop()
    }

    func testOfficeKeepAwakeFailureRollsBackAndUnconfirmedRestoreRetainsLease() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        try await fixture.controller.prepare()
        try await fixture.controller.start()
        fixture.registry.failOfficeApply = true
        let applied = await fixture.controller.setOfficeKeepAwakeEnabled(true)
        XCTAssertFalse(applied)
        XCTAssertEqual(fixture.controller.officeKeepAwakeStatus.phase, .failed)
        XCTAssertEqual(fixture.registry.freezerSetting, "null", "Partial guest changes must roll back.")
        XCTAssertFalse(fixture.controller.isOfficeKeepAwakeActivityHeld)
        fixture.registry.failOfficeApply = false
        let retried = await fixture.controller.setOfficeKeepAwakeEnabled(true)
        XCTAssertTrue(retried)
        fixture.registry.failOfficeRestore = true
        let restored = await fixture.controller.setOfficeKeepAwakeEnabled(false)
        XCTAssertFalse(restored)
        XCTAssertEqual(fixture.controller.officeKeepAwakeStatus.phase, .failed)
        XCTAssertTrue(fixture.officePreferences.hasOriginal)
        XCTAssertFalse(fixture.controller.isOfficeKeepAwakeActivityHeld)
        _ = await fixture.controller.stop()
        XCTAssertTrue(fixture.officePreferences.hasOriginal)
        fixture.registry.failOfficeRestore = false
        try await fixture.controller.start()
        XCTAssertEqual(fixture.registry.freezerSetting, "null")
        XCTAssertFalse(fixture.officePreferences.hasOriginal)
        XCTAssertEqual(fixture.controller.officeKeepAwakeStatus, .off)
        _ = await fixture.controller.stop()
    }

    func testOfficeKeepAwakeCrashRecoveryAndExternalChangePreservation() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        fixture.officePreferences.original = OfficeFreezerSnapshot(setting: .absent, inUse: true)
        fixture.registry.freezerSetting = "disabled"
        try await fixture.controller.prepare()
        try await fixture.controller.start()
        XCTAssertEqual(fixture.registry.officeCommands, ["restore"])
        XCTAssertFalse(fixture.officePreferences.hasOriginal)
        _ = await fixture.controller.setOfficeKeepAwakeEnabled(true)
        fixture.registry.freezerSetting = "device_default"
        let restored = await fixture.controller.setOfficeKeepAwakeEnabled(false)
        XCTAssertTrue(restored)
        XCTAssertEqual(fixture.registry.freezerSetting, "device_default", "Do not overwrite a later external policy change.")
        XCTAssertFalse(fixture.officePreferences.hasOriginal)
        _ = await fixture.controller.stop()
    }

    func testOfficeKeepAwakeRejectsUnknownGuestStateAndCorruptRecoveryRecordWithoutWrites() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        fixture.registry.freezerSetting = "unknown_value"
        try await fixture.controller.prepare()
        try await fixture.controller.start()
        let enabled = await fixture.controller.setOfficeKeepAwakeEnabled(true)
        XCTAssertFalse(enabled)
        XCTAssertEqual(fixture.registry.officeCommands, ["inspect"])
        XCTAssertEqual(fixture.registry.freezerSetting, "unknown_value")
        XCTAssertFalse(fixture.officePreferences.hasOriginal)
        _ = await fixture.controller.setOfficeKeepAwakeEnabled(false)
        let preferences = fixture.officePreferences
        preferences.defaults.set(Data("invalid record".utf8), forKey: preferences.key + ".original")
        let corrupted = await fixture.controller.setOfficeKeepAwakeEnabled(true)
        XCTAssertFalse(corrupted)
        XCTAssertEqual(fixture.registry.officeCommands, ["inspect"])
        XCTAssertTrue(preferences.hasOriginal)
        XCTAssertNil(preferences.original)
        _ = await fixture.controller.stop()
    }

    func testOfficeKeepAwakeStopDrainsCancelledApplyBeforeRestoreAndCannotReapply() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        let gate = LifecycleGate()
        fixture.registry.officeApplyGate = gate
        try await fixture.controller.prepare()
        try await fixture.controller.start()
        let enabling = Task { await fixture.controller.setOfficeKeepAwakeEnabled(true) }
        await gate.waitUntilEntered()
        let stopping = Task { await fixture.controller.stop() }
        while fixture.controller.state != .stopping { await Task.yield() }
        let rejected = await fixture.controller.setOfficeKeepAwakeEnabled(false)
        XCTAssertFalse(rejected)
        await gate.release()
        let enabled = await enabling.value
        let stopped = await stopping.value
        XCTAssertFalse(enabled)
        XCTAssertTrue(stopped)
        XCTAssertEqual(fixture.registry.officeCommands, ["inspect", "apply", "restore"])
        XCTAssertEqual(fixture.registry.freezerSetting, "null")
        XCTAssertFalse(fixture.controller.isOfficeKeepAwakeActivityHeld)
        XCTAssertFalse(fixture.officePreferences.hasOriginal)
    }

    func testOfficeKeepAwakeReleasesHostActivityOnUnexpectedEmulatorExit() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        _ = await fixture.controller.setOfficeKeepAwakeEnabled(true)
        try await fixture.controller.prepare()
        try await fixture.controller.start()
        fixture.registry.emulator?.finish()
        while fixture.controller.isOfficeKeepAwakeActivityHeld { await Task.yield() }
        XCTAssertTrue(fixture.officePreferences.hasOriginal, "A dead transport cannot confirm restoration.")
        XCTAssertEqual(fixture.controller.officeKeepAwakeStatus.phase, .waitingForRuntime)
        _ = await fixture.controller.stop()
    }

    func testOfficeKeepAwakeCameraRestartDrainsApplyBeforeRestoreAndNewStartup() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        let gate = LifecycleGate()
        fixture.registry.officeApplyGate = gate
        try await fixture.controller.prepare()
        try await fixture.controller.start()
        let enabling = Task { await fixture.controller.setOfficeKeepAwakeEnabled(true) }
        await gate.waitUntilEntered()
        let cleanupEntered = expectation(description: "camera restart entered keep-awake cleanup")
        fixture.controller.onOfficeKeepAwakeChanged = { cleanupEntered.fulfill() }
        fixture.controller.cameraEnabled.toggle()
        let restart = Task { try await fixture.controller.start() }
        await fulfillment(of: [cleanupEntered], timeout: 2)
        fixture.controller.onOfficeKeepAwakeChanged = nil
        fixture.registry.officeApplyGate = nil
        await gate.release()
        let enabled = await enabling.value
        XCTAssertFalse(enabled)
        try await restart.value
        XCTAssertEqual(fixture.registry.officeCommands, ["inspect", "apply", "restore", "inspect", "apply"])
        XCTAssertEqual(fixture.registry.emulatorArguments.count, 2)
        XCTAssertEqual(fixture.controller.officeKeepAwakeStatus.phase, .active)
        XCTAssertTrue(fixture.controller.isOfficeKeepAwakeActivityHeld)
        _ = await fixture.controller.stop()
    }

    func testDisplayLayoutPreferenceDefaultsToHorizontalAndPreservesLegacyVertical() throws {
        let legacyVertical = Data(#"{"resolutionPreset":"1080p","targetFPS":60,"keepWarmInBackground":true,"clipboardSyncEnabled":true,"directIMEEnabled":true,"cameraEnabled":true,"tabletMode":false}"#.utf8)
        let decodedVertical = try JSONDecoder().decode(ContainerPreferences.self, from: legacyVertical)
        XCTAssertFalse(decodedVertical.tabletMode)
        XCTAssertEqual(decodedVertical.preferredPixelSize, CGSize(width: 1200, height: 1920))
        XCTAssertEqual(decodedVertical.resolutionDisplayLabel, "1200 × 1920 · 竖屏布局")

        let missing = try JSONDecoder().decode(
            ContainerPreferences.self,
            from: Data(#"{"resolutionPreset":"1080p"}"#.utf8)
        )
        XCTAssertTrue(missing.tabletMode)
        XCTAssertEqual(missing.preferredPixelSize, CGSize(width: 1920, height: 1200))
        XCTAssertEqual(missing.resolutionDisplayLabel, "1920 × 1200 · 横屏布局")
    }

    func testSoftwareDisplayDefaultsSurviveFreshBootLayoutChangesAndReopenOnEitherImage() async throws {
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
                fixture.registry.assertLatestGuestEnvironmentUsesTabletIdentity(for: tabletMode)
                _ = try await fixture.controller.openDisplay()
                XCTAssertEqual(fixture.registry.displayDefaultsAtLaunch.last, true, "Opening an app must preserve defaults before starting its display.")
                await fixture.controller.closeDisplay()
            }
            XCTAssertEqual(
                fixture.registry.zygoteRestartCommands,
                1,
                "API \(api) must restart zygote for the initial Tablet identity migration only."
            )
            _ = await fixture.controller.stop()
            fixture.registry.secureContentVisible = false
            try await fixture.controller.start()
            XCTAssertTrue(fixture.registry.secureContentVisible, "A subsequent cold boot must restore defaults.")
            _ = await fixture.controller.stop()
        }
    }

    func testDeviceIdentitySetupPreservesApplicationDataAndFailsClosed() async throws {
        let tabletB64 = RuntimeSoftwareDefaults.propertyRecordBase64("SM-F926U")
        let tabletBytes = try XCTUnwrap(Data(base64Encoded: tabletB64))
        XCTAssertEqual(tabletBytes.count, 96)
        XCTAssertEqual(Array(tabletBytes[0..<4]), [0, 0, 0, 8])
        XCTAssertEqual(String(decoding: tabletBytes[4..<12], as: UTF8.self), "SM-F926U")
        XCTAssertTrue(tabletBytes[12..<96].allSatisfy { $0 == 0 })

        let tabletScript = RuntimeSoftwareDefaults.guestDeviceIdentityScript()
        XCTAssertTrue(tabletScript.contains("target_model=\"SM-F926U\""))
        XCTAssertTrue(tabletScript.contains("target_chars=\"tablet\""))
        XCTAssertTrue(tabletScript.contains("target_density=\"240\""))
        XCTAssertTrue(tabletScript.contains("u:object_r:build_prop:s0"))
        XCTAssertTrue(tabletScript.contains("u:object_r:build_vendor_prop:s0"))
        XCTAssertTrue(tabletScript.contains("u:object_r:build_odm_prop:s0"))
        XCTAssertTrue(tabletScript.contains("u:object_r:fingerprint_prop:s0"))
        XCTAssertTrue(tabletScript.contains("u:object_r:qemu_sf_lcd_density_prop:s0"))
        XCTAssertTrue(tabletScript.contains("sys.androiduse.winext_patch"))
        XCTAssertTrue(tabletScript.contains("/system_ext/framework/androidx.window.extensions.jar"))
        XCTAssertTrue(tabletScript.contains("setprop ctl.restart zygote"))
        XCTAssertTrue(tabletScript.contains("disable_slirp_ipv6"))
        XCTAssertTrue(tabletScript.contains("ip6tables -w -I OUTPUT -d 2000::/3 -j REJECT"))
        XCTAssertTrue(tabletScript.contains("/proc/sys/net/ipv6/conf/$iface/disable_ipv6"))

        XCTAssertFalse(tabletScript.contains(".auth_cache"))
        XCTAssertFalse(tabletScript.contains("/data/data/"), "Generic guest setup must not inspect or mutate application-private data.")
        XCTAssertFalse(tabletScript.contains("am force-stop"), "Shared environment setup must not force-stop individual applications.")

        // Zygote model state must be marked pending before restart and committed only after readiness.
        let pendingIndex = try XCTUnwrap(tabletScript.range(of: "setprop sys.androiduse.zygote_model \"pending\"")?.lowerBound)
        let patchFnIndex = try XCTUnwrap(tabletScript.range(of: "patch_prop() {")?.lowerBound)
        let restartIndex = try XCTUnwrap(tabletScript.range(of: "setprop ctl.restart zygote")?.lowerBound)
        let readyCheckIndex = try XCTUnwrap(tabletScript.range(of: "[ \"$ready\" = \"1\" ] || exit 1")?.lowerBound)
        let commitIndex = try XCTUnwrap(tabletScript.range(of: "setprop sys.androiduse.zygote_model \"$target_model\" >/dev/null 2>&1 || exit 1")?.lowerBound)
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
        XCTAssertTrue(setupScripts.contains("settings put system min_refresh_rate 60.0"))
        XCTAssertTrue(setupScripts.contains("settings put system peak_refresh_rate 60.0"))
        XCTAssertTrue(setupScripts.contains("setprop debug.sf.vsync_reactor_ignore_present_fences true"))
        XCTAssertTrue(setupScripts.contains("setprop debug.sf.latch_unsignaled 1"))
        let stopped = await fixture.controller.stop()
        XCTAssertTrue(stopped)
    }

    func testInputHelperDowngradeOnStderrUninstallsStaleHelperAndOpensMultipleApps() async throws {
        let stderrProbe = try await ProcessRunner().run(
            ProcessInvocation(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "printf 'Performing Streamed Install\\n'; printf 'adb: failed to install: Failure [INSTALL_FAILED_VERSION_DOWNGRADE: Downgrade detected: Update version code 2 is older than current 3]\\n' >&2; exit 1"
                ],
                environment: [:],
                timeout: 5,
                captureOutput: true
            )
        )
        XCTAssertEqual(stderrProbe.exitCode, 1)
        XCTAssertEqual(String(decoding: stderrProbe.stdout, as: UTF8.self), "Performing Streamed Install\n")
        XCTAssertTrue(stderrProbe.combinedOutputUTF8.contains("INSTALL_FAILED_VERSION_DOWNGRADE"))

        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        fixture.registry.installedPackages = [
            "local.androiduse.ime",
            "com.example.office",
            "com.tencent.mm"
        ]
        fixture.registry.inputHelperRequiresUninstallBeforeInstall = true

        try await fixture.controller.prepare()
        try await fixture.controller.start()

        let firstEndpoint = try await fixture.controller.openDisplay(package: "com.example.office")
        XCTAssertEqual(firstEndpoint.package, "com.example.office")
        XCTAssertEqual(fixture.registry.uninstalledPackages, ["local.androiduse.ime"])
        XCTAssertTrue(fixture.registry.installedPackages.contains("local.androiduse.ime"))

        let secondEndpoint = try await fixture.controller.openDisplay(package: "com.tencent.mm")
        XCTAssertEqual(secondEndpoint.package, "com.tencent.mm")
        XCTAssertEqual(fixture.registry.uninstalledPackages, ["local.androiduse.ime"])

        let stopped = await fixture.controller.stop()
        XCTAssertTrue(stopped)
    }

    func testMergedCatalogExcludesInternalPluginHelperPackages() {
        XCTAssertTrue(ContainerApp.isInternalPackage("local.androiduse.plugin.gnss"))
        XCTAssertTrue(ContainerApp.isInternalPackage("local.androiduse.ime"))
        let catalog = RuntimeController.mergedContainerCatalog(
            installedPackages: ["local.androiduse.plugin.gnss", "local.androiduse.ime", "com.example.office"],
            existing: []
        )
        XCTAssertFalse(catalog.contains(where: { $0.package == "local.androiduse.plugin.gnss" }))
        XCTAssertFalse(catalog.contains(where: { $0.package == "local.androiduse.ime" }))
        XCTAssertTrue(catalog.contains(where: { $0.package == "com.example.office" }))
    }

    func testConfirmedDisplayUpdateKeepsOwnedServerAndRejectsRetiredEndpoint() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        try await fixture.controller.prepare()
        try await fixture.controller.start()
        let first = try await fixture.controller.openDisplay(package: "dev.example.notes", replaceExisting: false)
        let second = try await fixture.controller.openDisplay(package: "dev.example.calendar", replaceExisting: false)
        let serversBefore = fixture.registry.servers
        let updated = AppDisplayPreference(resolutionPreset: "720p", tabletMode: false, interfaceScale: .large)

        XCTAssertTrue(fixture.controller.confirmDisplayConfiguration(package: first.package, endpoint: first, preference: updated, targetFPS: 30))
        let actual = try XCTUnwrap(fixture.controller.displaySessionConfig(for: first.package))
        XCTAssertEqual(actual.resolutionPreset, "720p")
        XCTAssertEqual(actual.interfaceScale, .large)
        XCTAssertFalse(actual.tabletMode)
        XCTAssertEqual(actual.targetFPS, 30)
        XCTAssertEqual(fixture.controller.displayEndpoint(for: first.package)?.port, first.port)
        XCTAssertEqual(fixture.controller.displayEndpoint(for: second.package)?.port, second.port)
        XCTAssertEqual(fixture.controller.displaySessionConfig(for: second.package)?.targetFPS, 60)
        XCTAssertEqual(fixture.registry.servers.count, serversBefore.count)
        XCTAssertTrue(serversBefore.allSatisfy(\.isRunning))

        let retired = DisplayEndpoint(port: first.port &+ 1, package: first.package, imePort: first.imePort)
        XCTAssertFalse(fixture.controller.confirmDisplayConfiguration(package: first.package, endpoint: retired, preference: .init(resolutionPreset: "1440p", tabletMode: true), targetFPS: 45))
        await fixture.controller.closeDisplay(package: first.package)
        XCTAssertFalse(fixture.controller.confirmDisplayConfiguration(package: first.package, endpoint: first, preference: updated, targetFPS: 30))
        XCTAssertEqual(fixture.controller.displayEndpoint(for: second.package)?.port, second.port)
        _ = await fixture.controller.stop()
    }

    func testFourConcurrentAppsOpenAndCloseIndependentlyInUnityMode() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        let packages = [
            "dev.example.notes",
            "dev.example.calendar",
            "dev.example.tasks",
            "dev.example.scratch"
        ]
        fixture.registry.installedPackages = Set(packages + ["local.androiduse.ime"])

        try await fixture.controller.prepare()
        try await fixture.controller.start()

        var endpoints: [String: DisplayEndpoint] = [:]
        let presets = ["720p", "1080p", "1440p", "1080p"]
        let scales: [DisplayInterfaceScale] = [.large, .standard, .small, .large]
        for (idx, pkg) in packages.enumerated() {
            let ep = try await fixture.controller.openDisplay(
                package: pkg,
                resolutionPreset: presets[idx],
                tabletMode: idx % 2 == 0,
                interfaceScale: scales[idx],
                replaceExisting: false
            )
            endpoints[pkg] = ep
        }

        XCTAssertEqual(fixture.controller.activeDisplayPackages.count, 4)
        XCTAssertEqual(Set(fixture.controller.activeDisplayPackages), Set(packages))
        XCTAssertEqual(Set(endpoints.values.map(\.port)).count, 4, "Each app window must have its own dedicated scrcpy video/control port.")
        XCTAssertEqual(Set(endpoints.values.compactMap(\.imePort)).count, 1, "All concurrent app windows share the single direct-IME forward port.")
        XCTAssertEqual(fixture.registry.servers.filter(\.isRunning).count, 4)

        // Verify per-app launch scripts do not mutate display 0 wm size/density (only initial boot script does)
        let appLaunchScripts = Array(fixture.registry.guestEnvironmentScripts.dropFirst())
        XCTAssertEqual(appLaunchScripts.count, 4)
        for script in appLaunchScripts {
            XCTAssertFalse(script.contains("wm size "), "Per-app virtual display setup must not mutate default display 0 size.")
            XCTAssertFalse(script.contains("wm density "), "Per-app virtual display setup must not mutate default display 0 density.")
        }

        // 调整一个窗口的大小与方向，只替换该应用的显示会话。
        let reconfiguredCalendar = try await fixture.controller.openDisplay(
            package: "dev.example.calendar",
            resolutionPreset: "1080p",
            tabletMode: true,
            interfaceScale: .large,
            replaceExisting: false
        )
        XCTAssertNotEqual(reconfiguredCalendar.port, endpoints["dev.example.calendar"]?.port)
        XCTAssertEqual(fixture.controller.displayEndpoint(for: "dev.example.notes")?.port, endpoints["dev.example.notes"]?.port)
        XCTAssertEqual(fixture.controller.displayEndpoint(for: "dev.example.tasks")?.port, endpoints["dev.example.tasks"]?.port)
        XCTAssertEqual(fixture.controller.displayEndpoint(for: "dev.example.scratch")?.port, endpoints["dev.example.scratch"]?.port)
        XCTAssertEqual(fixture.controller.displaySessionConfig(for: "dev.example.calendar")?.resolutionPreset, "1080p")
        XCTAssertEqual(fixture.controller.displaySessionConfig(for: "dev.example.calendar")?.tabletMode, true)
        XCTAssertEqual(fixture.controller.displaySessionConfig(for: "dev.example.notes")?.resolutionPreset, "720p")
        XCTAssertEqual(fixture.controller.displaySessionConfig(for: "dev.example.notes")?.tabletMode, true)
        XCTAssertEqual(fixture.registry.servers.filter(\.isRunning).count, 4)

        let firstPackage = "dev.example.notes"
        let same = try await fixture.controller.openDisplay(package: firstPackage, resolutionPreset: "720p", tabletMode: true, interfaceScale: .large, replaceExisting: false)
        XCTAssertEqual(same.port, endpoints[firstPackage]?.port, "相同显示参数应复用已有会话。")
        let resized = try await fixture.controller.openDisplay(package: firstPackage, resolutionPreset: "720p", tabletMode: true, interfaceScale: .small, replaceExisting: false)
        XCTAssertNotEqual(resized.port, same.port, "只调整界面大小也必须更新 Android 显示。")
        XCTAssertEqual(fixture.controller.displaySessionConfig(for: firstPackage)?.interfaceScale, .small)
        XCTAssertEqual(fixture.controller.displayEndpoint(for: "dev.example.calendar")?.port, reconfiguredCalendar.port)
        XCTAssertTrue(try XCTUnwrap(fixture.registry.displayCommands.last).contains("new_display=3200x2000/320 max_size=1280"))
        XCTAssertEqual(fixture.registry.servers.filter(\.isRunning).count, 4)

        // Opening a 5th concurrent app must fail with maxConcurrentDisplaysReached(4)
        do {
            _ = try await fixture.controller.openDisplay(
                package: "com.android.settings",
                replaceExisting: false
            )
            XCTFail("Expected 5th concurrent display to be rejected at maxConcurrentDisplays = 4.")
        } catch {
            XCTAssertEqual(error as? RuntimeError, .maxConcurrentDisplaysReached(4))
        }

        // Closing one app keeps the remaining 3 running
        await fixture.controller.closeDisplay(package: "dev.example.calendar")
        XCTAssertNil(fixture.controller.displayEndpoint(for: "dev.example.calendar"))
        XCTAssertEqual(fixture.controller.activeDisplayPackages.count, 3)
        XCTAssertEqual(fixture.controller.state, .running)
        XCTAssertEqual(fixture.registry.servers.filter(\.isRunning).count, 3)

        // Closing the remaining 3 apps transitions the runtime back to .ready
        for pkg in ["dev.example.notes", "dev.example.tasks", "dev.example.scratch"] {
            await fixture.controller.closeDisplay(package: pkg)
        }
        XCTAssertTrue(fixture.controller.activeDisplayPackages.isEmpty)
        XCTAssertEqual(fixture.controller.state, .ready)
        XCTAssertTrue(fixture.registry.forwardPorts.isEmpty)

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
    var nextSCID: UInt32 = 0x20
    var adbStopCalls = 0
    var connectivityCalls = 0
    var connectivityReplies: [String] = []
    var emulatorArguments: [[String]] = []
    var emulatorEnvironments: [[String: String]] = []
    var secureContentVisible = false
    var displayDefaultsAtLaunch: [Bool] = []
    var displayCommands: [String] = []
    var guestEnvironmentScripts: [String] = []
    var zygoteRestartCommands = 0
    var guestZygoteModel: String?
    var installedPackages = Set<String>()
    var uninstalledPackages: [String] = []
    var failNextCatalogRefresh = false
    var failNextGuestEnvironmentSetup = false
    var inputHelperRequiresUninstallBeforeInstall = false
    var officeCommands: [String] = []
    var freezerSetting = "null"
    var failOfficeApply = false
    var failOfficeRestore = false
    var officeApplyGate: LifecycleGate?
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
                registry.guestZygoteModel = nil
                registry.emulatorArguments.append(invocation.arguments)
                registry.emulatorEnvironments.append(invocation.environment)
            case .display:
                registry.displayCommands.append(invocation.arguments.joined(separator: " "))
                registry.servers.append(handle)
                registry.displayDefaultsAtLaunch.append(registry.secureContentVisible)
            }
        }
        return handle
    }
    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        let args = invocation.arguments
        if let script = args.last, script.contains("# macdora-office-awake:") {
            if script.contains("# macdora-office-awake:apply"), let gate = registry.officeApplyGate {
                await gate.pause()
            }
            return registry.withLock {
                var output = ""
                var status: Int32 = 0
                if script.contains("# macdora-office-awake:inspect") {
                    registry.officeCommands.append("inspect")
                    output = "\(registry.freezerSetting)\n\(registry.freezerSetting == "disabled" ? "false" : "true")\n"
                } else if script.contains("# macdora-office-awake:apply") {
                    registry.officeCommands.append("apply")
                    registry.freezerSetting = "disabled"
                    status = registry.failOfficeApply ? 1 : 0
                    output = "MACDORA_OFFICE_AWAKE_APPLIED\n"
                } else {
                    registry.officeCommands.append("restore")
                    if registry.failOfficeRestore {
                        status = 1
                    } else if registry.freezerSetting != "disabled" {
                        output = "MACDORA_OFFICE_AWAKE_EXTERNAL\n"
                    } else {
                        if script.contains("settings delete global cached_apps_freezer") {
                            registry.freezerSetting = "null"
                        } else if script.contains("settings put global cached_apps_freezer enabled") {
                            registry.freezerSetting = "enabled"
                        } else if script.contains("settings put global cached_apps_freezer device_default") {
                            registry.freezerSetting = "device_default"
                        }
                        output = "MACDORA_OFFICE_AWAKE_RESTORED\n"
                    }
                }
                return ProcessResult(exitCode: status, stdout: Data(output.utf8), timedOut: false)
            }
        }
        if args.contains("uninstall"), let package = args.last {
            registry.withLock {
                _ = registry.installedPackages.remove(package)
                registry.uninstalledPackages.append(package)
                if package == "local.androiduse.ime" {
                    registry.inputHelperRequiresUninstallBeforeInstall = false
                }
            }
            return ProcessResult(exitCode: 0, stdout: Data("Success\n".utf8), timedOut: false)
        }
        if args.contains("install"), let apkPath = args.last, apkPath.hasSuffix("android-use-ime.apk") {
            let requiresUninstall = registry.withLock { registry.inputHelperRequiresUninstallBeforeInstall }
            if requiresUninstall {
                let proc = try await ProcessRunner().run(
                    ProcessInvocation(
                        executableURL: URL(fileURLWithPath: "/bin/sh"),
                        arguments: ["-c", "printf 'Performing Streamed Install\\n'; printf 'adb: failed to install: Failure [INSTALL_FAILED_VERSION_DOWNGRADE: Downgrade detected: Update version code 2 is older than current 3]\\n' >&2; exit 1"],
                        environment: [:],
                        timeout: 5,
                        captureOutput: true
                    )
                )
                return proc
            }
            _ = registry.withLock { registry.installedPackages.insert("local.androiduse.ime") }
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
                if script.contains("patch_prop()"),
                   let targetLine = script.split(separator: "\n").first(where: {
                       $0.hasPrefix("target_model=\"")
                   }),
                   let target = targetLine.split(separator: "\"").dropFirst().first {
                    if registry.guestZygoteModel != String(target) {
                        registry.zygoteRestartCommands += 1
                        registry.guestZygoteModel = String(target)
                    }
                    registry.guestEnvironmentScripts.append(script)
                }
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
        else if args.last == "/proc/net/unix" { reply = "@scrcpy_00000021\n@scrcpy_00000022\n@scrcpy_00000023\n@scrcpy_00000024\n@scrcpy_00000025\n@scrcpy_00000026\n" }
        else { reply = "Success\n" }
        return ProcessResult(exitCode: 0, stdout: Data(reply.utf8), timedOut: false)
    }
}

private extension LifecycleRegistry {
    func assertLatestGuestEnvironmentUsesTabletIdentity(
        for tabletMode: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let script = withLock { guestEnvironmentScripts.last }
        guard let script else {
            XCTFail("Expected a guest environment configuration script.", file: file, line: line)
            return
        }
        XCTAssertTrue(script.contains("target_model=\"SM-F926U\""), file: file, line: line)
        XCTAssertTrue(script.contains("target_chars=\"tablet\""), file: file, line: line)
        XCTAssertTrue(script.contains("target_density=\"240\""), file: file, line: line)
        XCTAssertFalse(script.contains("target_model=\"Android SDK built for arm64\""), file: file, line: line)
        XCTAssertTrue(
            script.contains("wm set-ignore-orientation-request true"),
            file: file,
            line: line
        )
        XCTAssertTrue(
            script.contains("wm size \(tabletMode ? "2560x1600" : "1600x2560") -d 0"),
            file: file,
            line: line
        )
        XCTAssertTrue(
            script.contains("wm density 320 -d 0"),
            file: file,
            line: line
        )
        XCTAssertTrue(
            script.contains("am compat enable --no-kill FORCE_RESIZE_APP"),
            file: file,
            line: line
        )
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
    var officePreferences: OfficeKeepAwakePreferences {
        OfficeKeepAwakePreferences(rootURL: controller.paths.rootURL, defaults: UserDefaults(suiteName: defaultsName)!)
    }
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
                freePort: { fixtureRegistry.withLock { fixtureRegistry.nextPort += 1; return fixtureRegistry.nextPort } }, randomSCID: { fixtureRegistry.withLock { fixtureRegistry.nextSCID += 1; return fixtureRegistry.nextSCID } },
                localHostPortAvailable: { _ in false }))
    }
    func remove() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
    }
}
