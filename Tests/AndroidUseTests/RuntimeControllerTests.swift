import Foundation
import XCTest
@testable import AndroidUse

final class RuntimeControllerTests: XCTestCase {
    func testPinnedServerArgumentsDoNotStartAppInsideScrcpy() {
        let command = RuntimePorts.commandLine(scid: 73)

        XCTAssertTrue(command.hasPrefix("CLASSPATH=/data/local/tmp/android-use-scrcpy.jar "))
        XCTAssertTrue(command.contains("com.genymobile.scrcpy.Server 5.0.1"))
        XCTAssertTrue(command.contains("tunnel_forward=true"))
        XCTAssertTrue(command.contains("audio=false"))
        XCTAssertTrue(command.contains("control=true"))
        XCTAssertTrue(command.contains("video_codec=h264"))
        XCTAssertTrue(command.contains("video_bit_rate=24000000"))
        XCTAssertTrue(command.contains("max_fps=60"))
        XCTAssertTrue(command.contains("video_codec_options=low-latency=1"))
        XCTAssertTrue(command.contains("new_display=1920x1200/240"))
        XCTAssertTrue(command.contains("send_device_meta=false"))
        XCTAssertTrue(command.contains("send_dummy_byte=false"))
        XCTAssertTrue(command.contains("send_frame_meta=true"))
        XCTAssertTrue(command.contains("send_stream_meta=true"))
        XCTAssertTrue(command.contains("clipboard_autosync=false"))
        XCTAssertTrue(command.contains("keep_active=true"))
        XCTAssertTrue(command.contains("scid=00000049"))
        XCTAssertEqual(RuntimePorts.socketName(scid: 73), "scrcpy_00000049")
        XCTAssertTrue(RuntimePorts.guestSocketIsListening(
            Data("Num RefCount Protocol Flags Type St Inode Path\n0000: 00000002 00000000 00010000 0001 01 123 @scrcpy_00000049\n".utf8),
            scid: 73
        ))
        XCTAssertFalse(RuntimePorts.guestSocketIsListening(
            Data("0000: 00000002 00000000 00010000 0001 01 123 @scrcpy_000000490\n".utf8),
            scid: 73
        ))
        XCTAssertTrue(command.contains("vd_destroy_content=true"))
        XCTAssertFalse(command.contains("start_app="))
    }

    func testRuntimeInstallAndForwardChecksMatchAndroidContracts() {
        XCTAssertTrue(RuntimePorts.packagePathPresent(
            Data("package:/data/app/~~hash/base.apk\n".utf8)
        ))
        XCTAssertFalse(RuntimePorts.packagePathPresent(Data()))
        XCTAssertFalse(RuntimePorts.packagePathPresent(
            Data("package:com.example\n".utf8)
        ))
        XCTAssertTrue(RuntimePorts.forwardPortIsReady(
            45678,
            localHostPortAvailable: { _ in false }
        ))
        XCTAssertFalse(RuntimePorts.forwardPortIsReady(
            45678,
            localHostPortAvailable: { _ in true }
        ))
    }

    @MainActor
    func testReadyRuntimeWithOwnedEmulatorIsReused() {
        XCTAssertTrue(RuntimeController.canReuseReadyRuntime(
            state: .ready,
            emulatorRunning: true
        ))
        XCTAssertFalse(RuntimeController.canReuseReadyRuntime(
            state: .ready,
            emulatorRunning: false
        ))
        XCTAssertFalse(RuntimeController.canReuseReadyRuntime(
            state: .failed("offline"),
            emulatorRunning: true
        ))
    }

    func testRuntimePathsStayUnderOwnedRoot() {
        let root = URL(fileURLWithPath: "/tmp/android-use-root", isDirectory: true)
        let paths = RuntimePaths(rootURL: root)

        XCTAssertEqual(paths.runtimeURL.path, "/tmp/android-use-root/runtime")
        XCTAssertEqual(paths.imageURL.path, "/tmp/android-use-root/runtime/image")
        XCTAssertEqual(paths.avdHomeURL.path, "/tmp/android-use-root/avd")
        XCTAssertEqual(paths.androidUserHomeURL.path, "/tmp/android-use-root/android")
        XCTAssertEqual(paths.androidEmulatorHomeURL.path, "/tmp/android-use-root/android-emulator")
        XCTAssertTrue(paths.avdIniURL.lastPathComponent == "android-use.ini")
        XCTAssertFalse(paths.runtimeURL.path.contains("AndroMeld"))
    }

    @MainActor
    func testGraphicsDriverUpgradePreservesGuestDisksAndRetriesPublicationFailure() async throws {
        let fixture = try SeedFixture()
        defer { fixture.remove() }
        try await makeController(root: fixture.root, seed: fixture.seed).prepare()
        let paths = RuntimePaths(rootURL: fixture.root)
        let disk = paths.avdURL.appendingPathComponent("userdata-qemu.img")
        let userData = Data("existing guest data".utf8)
        try userData.write(to: disk)
        try FileManager.default.createDirectory(at: paths.moltenVKDylibURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original driver".utf8).write(to: paths.moltenVKDylibURL)
        let source = try XCTUnwrap(fixture.seed.directoryURL).appendingPathComponent("libMacdoraMoltenVK.dylib")
        let patched = Data("patched driver".utf8)
        try patched.write(to: source)
        let blocked = makeController(root: fixture.root, seed: fixture.seed, hooks: RuntimeControllerHooks(
            beforePublish: { _, destination in
                if destination.lastPathComponent == "libMoltenVK.dylib" {
                    throw RuntimeError.unexpected("injected driver publication failure")
                }
            }
        ))
        do {
            try await blocked.prepare()
            XCTFail("Driver publication should fail")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: paths.moltenVKDylibURL), Data("original driver".utf8))
        XCTAssertEqual(try Data(contentsOf: disk), userData)

        try await makeController(root: fixture.root, seed: fixture.seed).prepare()
        XCTAssertEqual(try Data(contentsOf: paths.moltenVKDylibURL), patched)
        XCTAssertEqual(try Data(contentsOf: disk), userData)
        let files = try FileManager.default.contentsOfDirectory(atPath: paths.moltenVKDylibURL.deletingLastPathComponent().path)
        XCTAssertFalse(files.contains { $0.hasPrefix(".moltenvk-") })
    }

    @MainActor
    func testLightweightSeedUpdatesHelpersAgainstExistingAndroid17RuntimeWithoutTouchingGuestData() async throws {
        let fixture = try SeedFixture()
        defer { fixture.remove() }
        try fixture.setImage(api: "37.0", revision: 6, incremental: "16571990")
        let initial = makeController(root: fixture.root, seed: fixture.seed)
        try await initial.prepare()
        XCTAssertTrue(initial.isPrepared)

        let disk = initial.paths.avdURL.appendingPathComponent("userdata-qemu.img.qcow2")
        let guestData = Data("existing Android 17 guest data".utf8)
        try guestData.write(to: disk)
        let configURL = initial.paths.avdURL.appendingPathComponent("config.ini")
        let customizedConfig = try String(contentsOf: configURL, encoding: .utf8) + "\nuser.keep=lightweight-upgrade\n"
        try Data(customizedConfig.utf8).write(to: configURL, options: .atomic)
        try FileManager.default.createDirectory(
            at: initial.paths.moltenVKDylibURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old graphics driver".utf8).write(to: initial.paths.moltenVKDylibURL)

        let thinSeed = try fixture.lightweightSeed(gpuDriver: "updated graphics driver")
        let upgraded = makeController(root: fixture.root, seed: thinSeed)
        try await upgraded.prepare()

        XCTAssertTrue(upgraded.isPrepared)
        XCTAssertEqual(try Data(contentsOf: disk), guestData)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), customizedConfig)
        XCTAssertEqual(try Data(contentsOf: upgraded.paths.moltenVKDylibURL), Data("updated graphics driver".utf8))
        XCTAssertEqual(try Data(contentsOf: upgraded.paths.inputHelperURL), SeedFixture.lightweightInputHelper)
        XCTAssertEqual(try Data(contentsOf: upgraded.paths.cameraSyncDylibURL), SeedFixture.lightweightCameraHelper)
        XCTAssertTrue(FileManager.default.fileExists(atPath: upgraded.paths.imageURL.appendingPathComponent("system.img").path))
        XCTAssertTrue(try String(
            contentsOf: upgraded.paths.imageURL.appendingPathComponent("source.properties"),
            encoding: .utf8
        ).contains("AndroidVersion.ApiLevel=37.0"))
        let runtimeFiles = try FileManager.default.contentsOfDirectory(
            at: upgraded.paths.moltenVKDylibURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(runtimeFiles.contains { $0.lastPathComponent.hasPrefix(".moltenvk-") })
    }

    @MainActor
    func testLightweightSeedWithoutExistingRuntimeFailsBeforePublishingOrClaimingReadiness() async throws {
        let fixture = try SeedFixture()
        defer { fixture.remove() }
        let sentinel = fixture.root.appendingPathComponent("preserve")
        try Data("keep".utf8).write(to: sentinel)
        let controller = makeController(root: fixture.root, seed: try fixture.lightweightSeed())

        do {
            try await controller.prepare()
            XCTFail("A lightweight seed cannot replace the missing Android runtime.")
        } catch {
            XCTAssertEqual(
                error as? RuntimeError,
                .invalidSeed("轻量安装包需要已有的完整 Android 环境")
            )
        }

        XCTAssertFalse(controller.isPrepared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: controller.paths.runtimeURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: controller.paths.avdHomeURL.path))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }

    @MainActor
    func testLightweightSeedCannotOverwriteAnOlderInstalledImage() async throws {
        let fixture = try SeedFixture()
        defer { fixture.remove() }
        let initial = makeController(root: fixture.root, seed: fixture.seed)
        try await initial.prepare()

        let disk = initial.paths.avdURL.appendingPathComponent("userdata-qemu.img")
        let guestData = Data("Android 15 user data".utf8)
        try guestData.write(to: disk)
        let configURL = initial.paths.avdURL.appendingPathComponent("config.ini")
        let config = try String(contentsOf: configURL, encoding: .utf8) + "\nuser.keep=android-15\n"
        try Data(config.utf8).write(to: configURL, options: .atomic)
        try FileManager.default.createDirectory(
            at: initial.paths.moltenVKDylibURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("Android 15 graphics driver".utf8).write(to: initial.paths.moltenVKDylibURL)

        let thinSeed = try fixture.lightweightSeed(gpuDriver: "Android 17 graphics driver")
        try fixture.setImage(for: thinSeed, api: "37.0", revision: 6, incremental: "16571990")
        let incompatible = makeController(root: fixture.root, seed: thinSeed)
        do {
            try await incompatible.prepare()
            XCTFail("A lightweight seed must not overwrite an older complete Android runtime.")
        } catch {
            XCTAssertEqual(
                error as? RuntimeError,
                .invalidSeed("轻量安装包需要与现有环境一致的 Android 镜像")
            )
        }

        XCTAssertFalse(incompatible.isPrepared)
        XCTAssertEqual(try Data(contentsOf: disk), guestData)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), config)
        XCTAssertEqual(try Data(contentsOf: incompatible.paths.moltenVKDylibURL), Data("Android 15 graphics driver".utf8))
        XCTAssertTrue(try String(
            contentsOf: incompatible.paths.imageURL.appendingPathComponent("source.properties"),
            encoding: .utf8
        ).contains("AndroidVersion.ApiLevel=35"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: incompatible.paths.inputHelperURL.path))
    }

    @MainActor
    func testCameraPreferenceIsPersistedAndLockedWhileRunning() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let controller = makeController(defaults: defaults)
        XCTAssertTrue(controller.cameraEnabled)
        controller.cameraEnabled = false
        XCTAssertFalse(defaults.bool(forKey: "AndroidUse.RuntimeController.cameraEnabled"))
        controller.cameraEnabled = true
        XCTAssertTrue(defaults.bool(forKey: "AndroidUse.RuntimeController.cameraEnabled"))
    }

    func testPresenceParserRejectsLauncherOnDisplayZero() {
        let launcher = """
        Display #0
          mResumedActivity: ActivityRecord{1 u0 com.android.launcher3/.Launcher t1}
        """
        let target = """
        Display #2
          * Hist #0: ActivityRecord{2 u0 \(DemoApp.package)/.MainActivity t8}
            state=RESUMED
        """
        let interaction = """
        Display #2
          Window #4 Window{9 u0 com.android.permissioncontroller/com.android.permissioncontroller.permission.ui.GrantPermissionsActivity visible=true}
            mOwnerUid=123
        """
        let resumedTarget = """
        Display #2
          * Hist #0: ActivityRecord{2 u0 \(DemoApp.package)/.MainActivity t8}
            state=RESUMED
          Window #4 Window{9 u0 com.android.permissioncontroller/com.android.permissioncontroller.permission.ui.GrantPermissionsActivity visible=true}
        """
        let unrelatedInteraction = """
        Display #0
          Window #3 Window{8 u0 com.android.permissioncontroller/com.android.permissioncontroller.permission.ui.GrantPermissionsActivity visible=true}
        Display #2
          Window #4 Window{9 u0 \(DemoApp.package)/.MainActivity}
        """

        XCTAssertEqual(RuntimePresenceParser.resolve(Data(launcher.utf8), window: nil, package: DemoApp.package), .notRunning)
        XCTAssertEqual(RuntimePresenceParser.resolve(Data(target.utf8), window: nil, package: DemoApp.package), .visible)
        XCTAssertEqual(
            RuntimePresenceParser.resolve(
                Data(resumedTarget.utf8),
                window: Data(interaction.utf8),
                package: DemoApp.package
            ),
            .systemInteraction
        )
        XCTAssertEqual(
            RuntimePresenceParser.resolve(
                Data(launcher.utf8),
                window: Data(unrelatedInteraction.utf8),
                package: DemoApp.package
            ),
            .notRunning
        )
        XCTAssertEqual(
            RuntimePresenceParser.resolve(
                Data(target.utf8),
                window: Data(unrelatedInteraction.utf8),
                package: DemoApp.package
            ),
            .visible
        )
    }

    @MainActor
    func testPreparePublishesCompleteRuntimeAndKeepsExistingSuccess() async throws {
        let fixture = try SeedFixture()
        defer { fixture.remove() }
        let controller = makeController(root: fixture.root, seed: fixture.seed)

        try await controller.prepare()

        XCTAssertEqual(controller.state, .stopped)
        let canonicalRoot = controller.rootURL
        let notice = canonicalRoot.appendingPathComponent("runtime/image/NOTICE.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: notice.path))
        let ini = try String(
            contentsOf: canonicalRoot.appendingPathComponent("avd/android-use.ini"),
            encoding: .utf8
        )
        let config = try String(
            contentsOf: canonicalRoot.appendingPathComponent("avd/android-use.avd/config.ini"),
            encoding: .utf8
        )
        XCTAssertTrue(ini.contains("path=\(canonicalRoot.path)/avd/android-use.avd"))
        XCTAssertTrue(config.contains("image.sysdir.1=\(canonicalRoot.path)/runtime/image"))
        XCTAssertTrue(config.contains("hw.cpu.ncore=4"))
        XCTAssertTrue(config.contains("hw.ramSize=6144"))
        XCTAssertTrue(config.contains("hw.lcd.width=1080"))
        XCTAssertTrue(config.contains("hw.lcd.height=1920"))
        XCTAssertTrue(config.contains("hw.lcd.density=420"))
        XCTAssertTrue(config.contains("abi.type=arm64-v8a"))
        XCTAssertTrue(config.contains("hw.cpu.arch=arm64"))
        XCTAssertTrue(config.contains("hw.keyboard=yes"))
        XCTAssertTrue(config.contains("hw.mainKeys=no"))
        XCTAssertTrue(config.contains("showDeviceFrame=no"))
        XCTAssertTrue(config.contains("fastboot.forceColdBoot=yes"))
        XCTAssertTrue(config.contains("fastboot.forceFastBoot=no"))
        XCTAssertTrue(config.contains("disk.dataPartition.size=8G"))
        XCTAssertTrue(config.contains("hw.gpu.mode=host"))
        XCTAssertTrue(config.contains("hw.lcd.vsync=60"))
        XCTAssertTrue(config.contains("hw.gltransport=virtio-gpu-asg"))
        XCTAssertTrue(config.contains("hw.gltransport.asg.writeBufferSize=1048576"))
        XCTAssertTrue(config.contains("hw.gltransport.asg.writeStepSize=262144"))
        XCTAssertTrue(config.contains("hw.gltransport.asg.dataRingSize=524288"))
        XCTAssertTrue(config.contains("hw.gltransport.drawFlushInterval=10000"))
        XCTAssertTrue(config.contains("hw.camera.front=webcam0"))
        XCTAssertTrue(config.contains("hw.sensors.light=no"))
        XCTAssertTrue(config.contains("hw.gsmModem=no"))

        let marker = canonicalRoot.appendingPathComponent("existing-success-marker")
        try Data("keep".utf8).write(to: marker)
        try await controller.prepare()
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep")
    }

    func testAVDGPUConfigurationParserNormalizesWhitespaceCommentsAndDuplicates() {
        let valid = """
        # User configuration
        hw.lcd.vsync = 60
        hw.gltransport = virtio-gpu-asg
        hw.gltransport.asg.writeBufferSize = 1048576
        hw.gltransport.asg.writeStepSize = 262144
        hw.gltransport.asg.dataRingSize = 524288
        hw.gltransport.drawFlushInterval = 10000
        user.keep=yes
        """
        XCTAssertTrue(RuntimeController.hasRequiredAVDGPUConfiguration(valid))
        XCTAssertTrue(RuntimeController.hasRequiredAVDGPUConfiguration(valid + "\n; hw.lcd.vsync=999"))
        XCTAssertFalse(
            RuntimeController.hasRequiredAVDGPUConfiguration(
                valid + "\nhw.lcd.vsync = 60"
            ),
            "Duplicate active keys are ambiguous even when their values match."
        )
        XCTAssertFalse(
            RuntimeController.hasRequiredAVDGPUConfiguration(
                valid.replacingOccurrences(
                    of: "hw.gltransport = virtio-gpu-asg",
                    with: "hw.gltransport = virtio-gpu-pipe"
                )
            )
        )

        let normalized = RuntimeController.normalizedAVDGPUConfiguration(
            valid
                .replacingOccurrences(
                    of: "hw.gltransport = virtio-gpu-asg",
                    with: "  hw.gltransport = virtio-gpu-pipe"
                )
                + "\n hw.gltransport = virtio-gpu-pipe"
        )
        XCTAssertTrue(RuntimeController.hasRequiredAVDGPUConfiguration(normalized))
        XCTAssertTrue(normalized.contains("# User configuration"))
        XCTAssertTrue(normalized.contains("user.keep=yes"))
        XCTAssertTrue(normalized.contains("hw.gltransport=virtio-gpu-asg"))
        XCTAssertEqual(
            normalized.components(separatedBy: .newlines)
                .filter { $0.trimmingCharacters(in: .whitespaces) == "hw.gltransport=virtio-gpu-asg" }
                .count,
            1
        )
        XCTAssertEqual(RuntimeController.normalizedAVDGPUConfiguration(normalized), normalized)
    }

    @MainActor
    func testRepeatedPreparationPreservesValidAVDConfigurationAndCache() async throws {
        let fixture = try SeedFixture()
        defer { fixture.remove() }
        let controller = makeController(root: fixture.root, seed: fixture.seed)
        try await controller.prepare()

        let configURL = controller.paths.avdURL.appendingPathComponent("config.ini")
        let config = try String(contentsOf: configURL, encoding: .utf8)
        let customized = config + "\nuser.keep=untouched\n"
        try Data(customized.utf8).write(to: configURL, options: .atomic)
        let cache = controller.paths.avdURL.appendingPathComponent("hardware-qemu.ini")
        try Data("valid-cache".utf8).write(to: cache)

        try await controller.prepare()

        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), customized)
        XCTAssertEqual(try String(contentsOf: cache, encoding: .utf8), "valid-cache")
        XCTAssertTrue(controller.isPrepared)
    }

    @MainActor
    func testPreparationRepairsStaleGPUValuesWithoutDroppingUnrelatedConfiguration() async throws {
        let fixture = try SeedFixture()
        defer { fixture.remove() }
        let controller = makeController(root: fixture.root, seed: fixture.seed)
        try await controller.prepare()

        let configURL = controller.paths.avdURL.appendingPathComponent("config.ini")
        let valid = try String(contentsOf: configURL, encoding: .utf8)
        let stale = valid
            .replacingOccurrences(
                of: "hw.gltransport=virtio-gpu-asg\n",
                with: "  hw.gltransport = virtio-gpu-pipe\n"
            )
            .replacingOccurrences(
                of: "hw.gltransport.asg.dataRingSize=524288\n",
                with: ""
            )
            + "\nhw.gltransport = virtio-gpu-pipe\nuser.keep=untouched\n"
        try Data(stale.utf8).write(to: configURL, options: .atomic)
        let staleFiles = ["hardware-qemu.ini", "initrd", "bootconfig.ini"]
        for name in staleFiles {
            try Data("stale".utf8).write(
                to: controller.paths.avdURL.appendingPathComponent(name)
            )
        }
        XCTAssertFalse(controller.isPrepared)

        try await controller.prepare()

        let repaired = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(RuntimeController.hasRequiredAVDGPUConfiguration(repaired))
        XCTAssertTrue(repaired.contains("user.keep=untouched"))
        XCTAssertEqual(
            repaired.components(separatedBy: .newlines)
                .filter { $0.trimmingCharacters(in: .whitespaces) == "hw.gltransport = virtio-gpu-pipe" }
                .count,
            0
        )
        for name in staleFiles {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: controller.paths.avdURL.appendingPathComponent(name).path
                )
            )
        }
        XCTAssertTrue(controller.isPrepared)
    }

    @MainActor
    func testPreparationFailsClosedWhenStaleCacheCannotBeRemoved() async throws {
        let fixture = try SeedFixture()
        defer { fixture.remove() }
        let fileManager = FailingAVDCacheRemovalFileManager()
        let controller = makeController(
            root: fixture.root,
            fileManager: fileManager,
            seed: fixture.seed
        )
        try await controller.prepare()

        let configURL = controller.paths.avdURL.appendingPathComponent("config.ini")
        let stale = try String(contentsOf: configURL, encoding: .utf8)
            .replacingOccurrences(
                of: "hw.gltransport=virtio-gpu-asg",
                with: "hw.gltransport = virtio-gpu-pipe"
            )
        try Data(stale.utf8).write(to: configURL, options: .atomic)
        try Data("stale".utf8).write(
            to: controller.paths.avdURL.appendingPathComponent("initrd")
        )

        do {
            try await controller.prepare()
            XCTFail("Cache cleanup failures must not be reported as a successful repair.")
        } catch {
            XCTAssertEqual(
                error as? RuntimeError,
                .invalidSeed("AVD GPU 缓存清理失败")
            )
        }
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), stale)
        XCTAssertFalse(controller.isPrepared)
    }

    @MainActor
    func testImageUpgradePreservesGuestDisksAndAdvancesEmulatorCacheTogether() async throws {
        let fixture = try SeedFixture(); defer { fixture.remove() }
        let initial = makeController(root: fixture.root, seed: fixture.seed)
        try await initial.prepare()
        let disks = ["userdata-qemu.img", "userdata-qemu.img.qcow2", "encryptionkey.img", "encryptionkey.img.qcow2"]
        for disk in disks {
            try Data("retained-\(disk)".utf8).write(to: initial.paths.avdURL.appendingPathComponent(disk))
        }
        try Data("12368160\n".utf8).write(to: initial.paths.avdURL.appendingPathComponent("version_num.cache"))
        try fixture.setImage(api: "37.0", revision: 6, incremental: "16571990")
        let upgraded = makeController(root: fixture.root, seed: fixture.seed)
        XCTAssertFalse(upgraded.isPrepared, "A valid older environment still needs the image upgrade.")

        try await upgraded.prepare()

        let properties = try String(contentsOf: upgraded.paths.imageURL.appendingPathComponent("source.properties"), encoding: .utf8)
        XCTAssertTrue(properties.contains("AndroidVersion.ApiLevel=37.0"))
        XCTAssertEqual(try String(contentsOf: upgraded.paths.avdURL.appendingPathComponent("version_num.cache"), encoding: .utf8), "16571990\n", "The SDK must not recreate persistent QCOW overlays on the next boot.")
        XCTAssertTrue(try String(contentsOf: upgraded.paths.avdIniURL, encoding: .utf8).contains("target=android-37.0"))
        for disk in disks {
            XCTAssertEqual(try Data(contentsOf: upgraded.paths.avdURL.appendingPathComponent(disk)), Data("retained-\(disk)".utf8))
        }
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.root.appendingPathComponent("runtime-upgrade.json"))) as? [String: Any])
        let backup = URL(fileURLWithPath: try XCTUnwrap(record["rollbackRoot"] as? String))
        XCTAssertTrue(try String(contentsOf: backup.appendingPathComponent("runtime/image/source.properties"), encoding: .utf8).contains("AndroidVersion.ApiLevel=35"))
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("avd/android-use.avd/version_num.cache"), encoding: .utf8), "12368160\n")
        for disk in disks {
            XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("avd/android-use.avd/\(disk)")), Data("retained-\(disk)".utf8))
        }
        let recordBeforeRetry = try Data(contentsOf: fixture.root.appendingPathComponent("runtime-upgrade.json"))
        try await upgraded.prepare()
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("runtime-upgrade.json")), recordBeforeRetry)
    }

    @MainActor
    func testFailedImageUpgradeLeavesOldImageCacheAndGuestDisksIntact() async throws {
        let fixture = try SeedFixture(); defer { fixture.remove() }
        let initial = makeController(root: fixture.root, seed: fixture.seed)
        try await initial.prepare()
        let data = initial.paths.avdURL.appendingPathComponent("userdata-qemu.img.qcow2")
        try Data("keep-existing-apps".utf8).write(to: data)
        let cache = initial.paths.avdURL.appendingPathComponent("version_num.cache")
        try Data("12368160\n".utf8).write(to: cache)
        try fixture.setImage(api: "37.0", revision: 6, incremental: "16571990")
        let upgraded = makeController(root: fixture.root, seed: fixture.seed, hooks: RuntimeControllerHooks(
            executableAndSecure: { _, _ in true }, localHostPortAvailable: { _ in false },
            beforePublish: { _, _ in throw RuntimeError.unexpected("injected upgrade publication failure") }
        ))
        do { try await upgraded.prepare(); XCTFail("The injected publication failure must propagate.") }
        catch { }
        XCTAssertEqual(try Data(contentsOf: data), Data("keep-existing-apps".utf8))
        XCTAssertEqual(try String(contentsOf: cache, encoding: .utf8), "12368160\n")
        XCTAssertTrue(try String(contentsOf: initial.paths.imageURL.appendingPathComponent("source.properties"), encoding: .utf8).contains("AndroidVersion.ApiLevel=35"))
    }

    @MainActor
    func testImageUpgradeRefusesAnActiveGuestAndIncompleteRuntimeKeepsUserdata() async throws {
        let fixture = try SeedFixture(); defer { fixture.remove() }
        let initial = makeController(root: fixture.root, seed: fixture.seed)
        try await initial.prepare()
        let disk = initial.paths.avdURL.appendingPathComponent("userdata-qemu.img.qcow2")
        try Data("keep-app-data".utf8).write(to: disk)
        let lock = initial.paths.avdURL.appendingPathComponent("hardware-qemu.ini.lock")
        try Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8).write(to: lock)
        try fixture.setImage(api: "37.0", revision: 6, incremental: "16571990")
        let running = makeController(root: fixture.root, seed: fixture.seed)
        do { try await running.prepare(); XCTFail("An active VM must prevent the data directory exchange.") }
        catch { XCTAssertEqual(error as? RuntimeError, .upgradeRequiresStop) }
        XCTAssertEqual(try Data(contentsOf: disk), Data("keep-app-data".utf8))
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.removeItem(at: initial.paths.imageURL.appendingPathComponent("system.img"))
        let incomplete = makeController(root: fixture.root, seed: fixture.seed)
        do { try await incomplete.prepare(); XCTFail("An incomplete runtime with existing data must require repair.") }
        catch { }
        XCTAssertEqual(try Data(contentsOf: disk), Data("keep-app-data".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: initial.paths.imageURL.appendingPathComponent("system.img").path))
    }

    @MainActor
    func testNewEnvironmentUsesSeedAPITargetAndDowngradeCannotOpenNewerUserdata() async throws {
        let fixture = try SeedFixture(); defer { fixture.remove() }
        try fixture.setImage(api: "37.0", revision: 6, incremental: "16571990")
        let current = makeController(root: fixture.root, seed: fixture.seed)
        try await current.prepare()
        XCTAssertTrue(try String(contentsOf: current.paths.avdIniURL, encoding: .utf8).contains("target=android-37.0"))
        let disk = current.paths.avdURL.appendingPathComponent("userdata-qemu.img.qcow2")
        try Data("newer-system-data".utf8).write(to: disk)
        try fixture.setImage(api: "35", revision: 2, incremental: "12368160")
        let older = makeController(root: fixture.root, seed: fixture.seed)
        do { try await older.prepare(); XCTFail("An older application must not downgrade an existing data environment.") }
        catch { }
        XCTAssertEqual(try Data(contentsOf: disk), Data("newer-system-data".utf8))
        XCTAssertTrue(try String(contentsOf: current.paths.imageURL.appendingPathComponent("source.properties"), encoding: .utf8).contains("AndroidVersion.ApiLevel=37.0"))
    }

    @MainActor
    func testNewServerReplacesOldPrivateCopyWithoutReplacingGuestData() async throws {
        let fixture = try SeedFixture(); defer { fixture.remove() }
        let first = makeController(root: fixture.root, seed: fixture.seed)
        try await first.prepare()
        let userData = first.paths.avdURL.appendingPathComponent("retained-user-data")
        try Data("preserve".utf8).write(to: userData)
        let source = try XCTUnwrap(fixture.seed.scrcpyServerURL)
        try Data("derived-server-v2".utf8).write(to: source)
        let upgraded = makeController(root: fixture.root, seed: fixture.seed)
        try await upgraded.prepare()
        XCTAssertEqual(try Data(contentsOf: upgraded.paths.scrcpyPrivateURL), Data("derived-server-v2".utf8))
        XCTAssertEqual(try Data(contentsOf: userData), Data("preserve".utf8))
    }

    @MainActor
    func testIncompleteRuntimeIsQuarantinedAndRepublished() async throws {
        let fixture = try SeedFixture()
        defer { fixture.remove() }
        let controller = makeController(root: fixture.root, seed: fixture.seed)
        let incomplete = controller.paths.runtimeURL
        try FileManager.default.createDirectory(
            at: incomplete,
            withIntermediateDirectories: true
        )
        try Data("partial".utf8).write(
            to: incomplete.appendingPathComponent("partial")
        )
        try FileManager.default.createDirectory(
            at: controller.paths.avdURL,
            withIntermediateDirectories: true
        )
        let avdMarker = controller.paths.avdURL.appendingPathComponent("state")
        try Data("keep-user-state".utf8).write(to: avdMarker)

        try await controller.prepare()

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: controller.paths.imageURL
                .appendingPathComponent("NOTICE.txt").path
        ))
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: controller.paths.rootURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".runtime-incomplete-") }
        XCTAssertEqual(quarantined.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: quarantined[0].appendingPathComponent("partial").path
        ))
        XCTAssertEqual(try String(contentsOf: avdMarker, encoding: .utf8), "keep-user-state")
    }

    @MainActor
    func testStopCancelsLatePrepareAndKeepsStoppedState() async throws {
        let fixture = try SeedFixture()
        defer { fixture.remove() }
        let gate = AsyncGate()
        let controller = makeController(
            root: fixture.root,
            seed: fixture.seed,
            hooks: RuntimeControllerHooks(
                executableAndSecure: { _, _ in true },
                localHostPortAvailable: { _ in false },
                beforePublish: { _, _ in gate.block() }
            )
        )

        let preparation = Task { @MainActor in
            try await controller.prepare()
        }
        await gate.waitUntilEntered()
        let stopping = Task { await controller.stop() }
        await Task.yield()
        XCTAssertEqual(controller.state, .stopping)
        gate.open()
        let stopped = await stopping.value
        XCTAssertTrue(stopped)

        do {
            try await preparation.value
            XCTFail("Late prepare should be cancelled")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: controller.paths.runtimeURL.path
        ))
    }

    @MainActor
    func testStopDuringStartPrecheckDoesNotEnterStarting() async throws {
        let fixture = try SeedFixture()
        defer { fixture.remove() }
        let controller = makeController(root: fixture.root, seed: fixture.seed)
        try await controller.prepare()

        let gate = AsyncGate()
        let hookedController = makeController(
            root: fixture.root,
            seed: fixture.seed,
            hooks: RuntimeControllerHooks(
                executableAndSecure: { _, _ in true },
                localHostPortAvailable: { _ in false },
                beforeStart: { gate.block() }
            )
        )
        let starting = Task { @MainActor in
            try await hookedController.start()
        }
        await gate.waitUntilEntered()
        await hookedController.stop()
        gate.open()

        do {
            try await starting.value
            XCTFail("Late start should be cancelled")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(hookedController.state, .stopped)
    }

    @MainActor
    func testPreparedRuntimeDoesNotRequireAPK() async throws {
        let fixture = try SeedFixture()
        defer { fixture.remove() }
        let controller = makeController(root: fixture.root, seed: fixture.seed)

        try await controller.prepare()

        XCTAssertTrue(controller.isPrepared)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: controller.paths.apkPrivateURL.path
        ))
        let catalog = controller.cachedContainerApps()
        XCTAssertEqual(catalog.map(\.package), [DefaultApp.package])
        XCTAssertEqual(catalog.first?.isInstalled, true)
        XCTAssertFalse(catalog.contains(where: {
            $0.package == DemoApp.package || $0.package == "com.sankuai.meituan.takeoutnew"
        }))
    }

    @MainActor
    func testMultiAppContainerMetadataAndAPKStagingSupportArbitraryValidAPK() async throws {
        let fixture = try SeedFixture()
        defer { fixture.remove() }
        let controller = makeController(root: fixture.root, seed: fixture.seed)
        try await controller.prepare()

        let demo = ContainerApp.metadata(for: DemoApp.package, isInstalled: false)
        XCTAssertEqual(demo.title, "演示应用")
        XCTAssertTrue(ContainerApp.isValidPackageIdentifier("com.sankuai.meituan.takeoutnew"))
        XCTAssertFalse(ContainerApp.isValidPackageIdentifier("invalid-package"))

        let validAPK = fixture.root.appendingPathComponent("sample.apk")
        try Data([0x50, 0x4B, 0x03, 0x04, 0x01, 0x02]).write(to: validAPK)
        try await controller.installAPK(validAPK)
        XCTAssertTrue(FileManager.default.fileExists(atPath: controller.paths.apkPrivateURL.path))
        XCTAssertEqual(controller.paths.apkPrivateURL.lastPathComponent, "imported-app.apk")
        XCTAssertFalse(controller.cachedContainerApps().contains(where: {
            $0.package == DemoApp.package && $0.isInstalled
        }), "A persisted APK is not proof that its guest package is installed.")

        let activityDump = Data("""
        Display #2 (activities from top to bottom):
          topResumedActivity=ActivityRecord{123 u0 com.sankuai.meituan.takeoutnew/.ui.page.MainActivity t9}
        """.utf8)
        XCTAssertTrue(RuntimePresenceParser.hasTargetVisible(activityDump, package: "com.sankuai.meituan.takeoutnew"))
        XCTAssertEqual(
            RuntimePresenceParser.resolve(activityDump, window: nil, package: "com.sankuai.meituan.takeoutnew"),
            .visible
        )

        let beforeUninstall = RuntimeController.mergedContainerCatalog(
            installedPackages: ["com.sankuai.meituan.takeoutnew", DemoApp.package, "com.tencent.mm"],
            existing: []
        )
        XCTAssertTrue(beforeUninstall.first(where: { $0.package == "com.sankuai.meituan.takeoutnew" })?.isInstalled == true)
        XCTAssertTrue(beforeUninstall.first(where: { $0.package == "com.tencent.mm" })?.isInstalled == true)

        let afterUninstall = RuntimeController.mergedContainerCatalog(
            installedPackages: [DemoApp.package],
            existing: beforeUninstall
        )
        XCTAssertNil(afterUninstall.first(where: { $0.package == "com.sankuai.meituan.takeoutnew" }))
        XCTAssertNil(afterUninstall.first(where: { $0.package == "com.tencent.mm" }))

        let pngSample = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01])
        let probeStdout = Data("META\tcom.example.custom\t自定义应用\t2.3.1\t\(pngSample.base64EncodedString())\n".utf8)
        let parsedProbe = RuntimeController.parsePackageCatalogProbeOutput(probeStdout)
        XCTAssertEqual(parsedProbe["com.example.custom"]?.label, "自定义应用")
        XCTAssertEqual(parsedProbe["com.example.custom"]?.version, "2.3.1")
        XCTAssertEqual(parsedProbe["com.example.custom"]?.iconPNGData, pngSample)

        let mergedCustom = RuntimeController.mergedContainerCatalog(
            installedPackages: ["com.example.custom"],
            existing: [],
            probed: parsedProbe
        )
        XCTAssertEqual(mergedCustom.first(where: { $0.package == "com.example.custom" })?.title, "自定义应用")
        XCTAssertEqual(mergedCustom.first(where: { $0.package == "com.example.custom" })?.version, "2.3.1")
    }

    @MainActor
    func testContainerPreferencesPersistenceAndReadinessDoctorChecks() async throws {
        let fixture = try SeedFixture()
        defer { fixture.remove() }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let controller = makeController(root: fixture.root, defaults: defaults, seed: fixture.seed)

        let initialChecks = controller.evaluateReadinessChecks(metalAvailable: true)
        XCTAssertEqual(initialChecks.count, 6)
        XCTAssertEqual(initialChecks.first(where: { $0.id == "vm-hypervisor" })?.status, .review)

        var prefs = controller.containerPreferences
        prefs.resolutionPreset = "1440p"
        prefs.targetFPS = 45
        prefs.keepWarmInBackground = false
        prefs.directIMEEnabled = false
        prefs.clipboardSyncEnabled = false
        prefs.cameraEnabled = true
        controller.containerPreferences = prefs

        let reloaded = controller.containerPreferences
        XCTAssertEqual(reloaded.resolutionPreset, "1440p")
        XCTAssertEqual(reloaded.targetFPS, 45)
        XCTAssertFalse(reloaded.keepWarmInBackground)
        XCTAssertFalse(reloaded.directIMEEnabled)
        XCTAssertFalse(reloaded.clipboardSyncEnabled)
        XCTAssertTrue(reloaded.cameraEnabled)

        try await controller.prepare()
        let preparedChecks = controller.evaluateReadinessChecks(metalAvailable: true)
        XCTAssertEqual(preparedChecks.first(where: { $0.id == "vm-hypervisor" })?.status, .ready)
        XCTAssertEqual(preparedChecks.first(where: { $0.id == "direct-ime" })?.status, .review)

        let cmd720 = RuntimePorts.commandLine(scid: 73, resolutionPreset: "720p", targetFPS: 30)
        XCTAssertTrue(cmd720.contains("new_display=1280x800/160"))
        XCTAssertTrue(cmd720.contains("video_bit_rate=14000000"))
        XCTAssertTrue(cmd720.contains("max_fps=30"))

        let cmd1440 = RuntimePorts.commandLine(scid: 73, resolutionPreset: "1440p", targetFPS: 45)
        XCTAssertTrue(cmd1440.contains("new_display=2560x1600/320"))
        XCTAssertTrue(cmd1440.contains("video_bit_rate=36000000"))
        XCTAssertTrue(cmd1440.contains("max_fps=45"))
    }

    @MainActor
    private func makeController(
        root: URL? = nil,
        fileManager: FileManager = .default,
        defaults: UserDefaults = UserDefaults(suiteName: UUID().uuidString)!,
        seed: RuntimeSeed = RuntimeSeed(directoryURL: nil, scrcpyServerURL: nil),
        hooks: RuntimeControllerHooks = RuntimeControllerHooks(
            executableAndSecure: { _, _ in true },
            localHostPortAvailable: { _ in false }
        )
    ) -> RuntimeController {
        let root = root ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("android-use-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return RuntimeController(
            rootURL: root,
            fileManager: fileManager,
            defaults: defaults,
            environment: TestEnvironment(),
            seed: seed,
            hooks: hooks
        )
    }
}

private final class FailingAVDCacheRemovalFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        if URL.lastPathComponent == "initrd", fileExists(atPath: URL.path) {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        }
        try super.removeItem(at: URL)
    }
}

private final class AsyncGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func block() {
        entered.signal()
        release.wait()
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                self.entered.wait()
                continuation.resume()
            }
        }
    }

    func open() {
        release.signal()
    }
}

private final class TestEnvironment: ControllerEnvironment, @unchecked Sendable {
    func environment() -> [String: String] { ["PATH": "/usr/bin:/bin"] }

    func allocateForward(
        adbURL: URL,
        environment: [String: String],
        requestedPort: UInt16,
        scid: UInt32
    ) async throws -> ForwardAllocation {
        ForwardAllocation(localPort: requestedPort, serial: "emulator-5584", scid: scid)
    }

    func removeForward(
        adbURL: URL,
        environment: [String: String],
        allocation: ForwardAllocation
    ) async throws {}

    func secureCopy(
        adbURL: URL,
        localURL: URL,
        remotePath: String,
        environment: [String: String]
    ) async throws {}

    func portIsAvailable(_ port: UInt16) -> Bool { true }
}

private struct SeedFixture {
    let root: URL
    let seed: RuntimeSeed

    static let lightweightInputHelper = Data("lightweight input helper".utf8)
    static let lightweightCameraHelper = Data("lightweight camera helper".utf8)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-use-seed-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let source = workspace.appendingPathComponent("RuntimeSeed", isDirectory: true)
        for relative in [
            "emulator/emulator",
            "platform-tools/adb",
            "image/system.img",
            "image/vendor.img",
            "image/kernel-ranchu",
            "image/ramdisk.img",
            "image/source.properties",
            "image/NOTICE.txt"
        ] {
            let url = source.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(relative.utf8).write(to: url)
        }
        let server = workspace.appendingPathComponent("scrcpy-server-v5.0.1")
        try Data("server".utf8).write(to: server)
        seed = RuntimeSeed(
            directoryURL: source,
            scrcpyServerURL: server
        )
        try setImage(api: "35", revision: 2, incremental: "12368160")
    }

    func setImage(api: String, revision: Int, incremental: String) throws {
        try setImage(for: seed, api: api, revision: revision, incremental: incremental)
    }

    func setImage(
        for seed: RuntimeSeed,
        api: String,
        revision: Int,
        incremental: String
    ) throws {
        let image = seed.directoryURL!.appendingPathComponent("image")
        try Data("AndroidVersion.ApiLevel=\(api)\nPkg.Revision=\(revision)\nSystemImage.Abi=arm64-v8a\nSystemImage.TagId=default\n".utf8).write(to: image.appendingPathComponent("source.properties"))
        try Data("ro.build.version.incremental=\(incremental)\n".utf8).write(to: image.appendingPathComponent("build.prop"))
    }

    func lightweightSeed(gpuDriver: String = "lightweight graphics driver") throws -> RuntimeSeed {
        let source = root.appendingPathComponent(
            "workspace/lightweight-\(UUID().uuidString)",
            isDirectory: true
        )
        let image = source.appendingPathComponent("image", isDirectory: true)
        try FileManager.default.createDirectory(at: image, withIntermediateDirectories: true)
        for name in ["source.properties", "build.prop"] {
            try FileManager.default.copyItem(
                at: seed.directoryURL!.appendingPathComponent("image/\(name)"),
                to: image.appendingPathComponent(name)
            )
        }
        try Self.lightweightInputHelper.write(to: source.appendingPathComponent("android-use-ime.apk"))
        try Self.lightweightCameraHelper.write(to: source.appendingPathComponent("libmaccamera_frame_sync.dylib"))
        try Data(gpuDriver.utf8).write(to: source.appendingPathComponent("libMacdoraMoltenVK.dylib"))
        return RuntimeSeed(
            directoryURL: source,
            scrcpyServerURL: seed.scrcpyServerURL,
            bundlesAndroidRuntime: false
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-backups"))
    }
}
