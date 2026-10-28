import CryptoKit
import Darwin
import Foundation
import Security

enum RuntimeError: LocalizedError, Equatable {
    case busy(String)
    case operationCancelled
    case invalidSeed(String)
    case installNotPrepared
    case installAPKMissing
    case installAPKUnsafe
    case installAPKHashMismatch
    case installCommandFailed
    case runtimeNotReady
    case portInUse(UInt16)
    case adbCommandFailed(String)
    case adbTimedOut(String)
    case emulatorExited
    case displayUnavailable
    case displayExited
    case serverTransferFailed
    case bootTimedOut
    case networkNotReady
    case insecurePath
    case stopUnconfirmed
    case uninstallUnconfirmed
    case upgradeRequiresStop
    case maxConcurrentDisplaysReached(Int)
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .busy(let operation): return "\(operation)正在进行，请稍候。"
        case .operationCancelled: return "操作已取消。"
        case .invalidSeed(let detail): return "本地运行资源不完整：\(detail)。"
        case .installNotPrepared: return "请先准备本地运行环境。"
        case .installAPKMissing: return "所选 APK 不可访问。"
        case .installAPKUnsafe: return "所选 APK 路径不安全。"
        case .installAPKHashMismatch: return "APK 校验失败，未安装。"
        case .installCommandFailed: return "APK 安装失败。"
        case .runtimeNotReady: return "Android 环境尚未就绪。"
        case .portInUse(let port): return "本地端口 \(port) 已被占用。"
        case .adbCommandFailed(let operation): return "\(operation)失败。"
        case .adbTimedOut(let operation): return "\(operation)超时。"
        case .emulatorExited: return "Android 环境进程已意外退出。"
        case .displayUnavailable: return "Android 显示服务未能建立。"
        case .displayExited: return "Android 显示服务已结束。"
        case .serverTransferFailed: return "无法准备本地显示组件。"
        case .bootTimedOut: return "Android 环境在 90 秒内未能启动。"
        case .networkNotReady: return "Android 已启动，但未能在启动期限内连接默认网络。请检查 Mac 网络后重试。"
        case .insecurePath: return "本地私有目录安全性检查失败。"
        case .stopUnconfirmed: return "尚未确认后台进程退出。请重试停止环境，当前会话会保留进程归属。"
        case .uninstallUnconfirmed: return "卸载命令已执行，但无法确认应用列表。请刷新应用列表核对，未确认前请勿重复操作。"
        case .upgradeRequiresStop: return "请先停止运行环境，再升级 Android 系统。"
        case .maxConcurrentDisplaysReached(let limit): return "最多可同时开启 \(limit) 个独立应用窗口，请先关闭一个窗口后再打开新应用。"
        case .unexpected(let detail): return "运行环境发生内部错误：\(detail)。"
        }
    }
}

struct RuntimePaths: Sendable {
    let rootURL: URL
    let runtimeURL: URL
    let avdHomeURL: URL
    let androidUserHomeURL: URL
    let androidEmulatorHomeURL: URL
    let appSupportURL: URL
    let androidRootURL: URL
    let adbKeysURL: URL

    init(rootURL: URL) {
        let absoluteRoot = rootURL.standardizedFileURL
        let canonicalRoot = RuntimePaths.canonicalPath(absoluteRoot)
        self.rootURL = canonicalRoot
        runtimeURL = canonicalRoot.appendingPathComponent("runtime", isDirectory: true)
        avdHomeURL = canonicalRoot.appendingPathComponent("avd", isDirectory: true)
        androidUserHomeURL = canonicalRoot.appendingPathComponent("android", isDirectory: true)
        androidEmulatorHomeURL = canonicalRoot.appendingPathComponent("android-emulator", isDirectory: true)
        appSupportURL = canonicalRoot.appendingPathComponent("private", isDirectory: true)
        androidRootURL = androidUserHomeURL.appendingPathComponent("adb", isDirectory: true)
        adbKeysURL = androidRootURL.appendingPathComponent("keys", isDirectory: true)
    }

    private static func canonicalPath(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        let fm = FileManager.default
        if fm.fileExists(atPath: standardized.path) {
            return standardized.resolvingSymlinksInPath().standardizedFileURL
        }
        var missingComponents = [String]()
        var parent = standardized.deletingLastPathComponent()
        missingComponents.append(standardized.lastPathComponent)
        while !fm.fileExists(atPath: parent.path),
              parent.path != parent.deletingLastPathComponent().path {
            missingComponents.insert(parent.lastPathComponent, at: 0)
            parent = parent.deletingLastPathComponent()
        }
        var result = parent.resolvingSymlinksInPath().standardizedFileURL
        for component in missingComponents {
            result.appendPathComponent(component, isDirectory: true)
        }
        return result.standardizedFileURL
    }

    var imageURL: URL { runtimeURL.appendingPathComponent("image", isDirectory: true) }
    var emulatorURL: URL { runtimeURL.appendingPathComponent("emulator/emulator") }
    var adbURL: URL { runtimeURL.appendingPathComponent("platform-tools/adb") }
    var avdURL: URL { avdHomeURL.appendingPathComponent("android-use.avd", isDirectory: true) }
    var avdIniURL: URL { avdHomeURL.appendingPathComponent("android-use.ini") }
    var scrcpyPrivateURL: URL {
        appSupportURL.appendingPathComponent("scrcpy-server-v5.0.1")
    }
    var apkPrivateURL: URL { appSupportURL.appendingPathComponent("imported-app.apk") }
    var inputHelperURL: URL { appSupportURL.appendingPathComponent("android-use-ime.apk") }
    var cameraSyncDylibURL: URL { appSupportURL.appendingPathComponent("libmaccamera_frame_sync.dylib") }
    var moltenVKDylibURL: URL { runtimeURL.appendingPathComponent("emulator/lib64/vulkan/libMoltenVK.dylib") }
    var appIconsDirectoryURL: URL { appSupportURL.appendingPathComponent("icons", isDirectory: true) }

    func appIconURL(for package: String) -> URL {
        appIconsDirectoryURL.appendingPathComponent("\(package).png")
    }
}

enum RuntimePathsFactory {
    static func defaultRoot(fileManager: FileManager = .default) throws -> URL {
        try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).appendingPathComponent("AndroidUse", isDirectory: true)
    }
}

struct RuntimeSeed: Sendable {
    let directoryURL: URL?
    let scrcpyServerURL: URL?
    let bundlesAndroidRuntime: Bool

    init(
        directoryURL: URL?,
        scrcpyServerURL: URL?,
        bundlesAndroidRuntime: Bool? = nil
    ) {
        self.directoryURL = directoryURL
        self.scrcpyServerURL = scrcpyServerURL
        self.bundlesAndroidRuntime = bundlesAndroidRuntime ?? Self.inferBundledRuntime(at: directoryURL)
    }

    static func bundle() -> RuntimeSeed {
        let resourceURL = Bundle.main.resourceURL
        let nestedSeed = resourceURL?.appendingPathComponent("RuntimeSeed", isDirectory: true)
        let directServer = resourceURL?.appendingPathComponent("scrcpy-server-v5.0.1")
        let serverInSeed = nestedSeed?.appendingPathComponent("scrcpy-server-v5.0.1")

        let seedDirectory = [nestedSeed, resourceURL]
            .compactMap { $0 }
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
        let server = [serverInSeed, directServer]
            .compactMap { $0 }
            .first(where: { FileManager.default.isReadableFile(atPath: $0.path) })
        let manifestURL = resourceURL?.appendingPathComponent("runtime-manifest.json")
        let manifestFlag = manifestURL.flatMap { url -> Bool? in
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = object["bundlesAndroidRuntime"] as? Bool else {
                return nil
            }
            return value
        }
        return RuntimeSeed(
            directoryURL: seedDirectory,
            scrcpyServerURL: server,
            bundlesAndroidRuntime: manifestFlag ?? true
        )
    }

    private static func inferBundledRuntime(at directoryURL: URL?) -> Bool {
        guard let directoryURL else { return true }
        let required = [
            "emulator/emulator",
            "platform-tools/adb",
            "image/system.img",
            "image/vendor.img",
            "image/kernel-ranchu",
            "image/ramdisk.img",
            "image/NOTICE.txt"
        ]
        return required.allSatisfy {
            FileManager.default.fileExists(
                atPath: directoryURL.appendingPathComponent($0).path
            )
        }
    }
}

struct RuntimePreparation: @unchecked Sendable {
    let paths: RuntimePaths
    let seed: RuntimeSeed
    let digester: any SecureDigesting
    let hooks: RuntimeControllerHooks
    private let operationFileManager: FileManager
    init(
        paths: RuntimePaths,
        seed: RuntimeSeed,
        fileManager: FileManager,
        digester: any SecureDigesting,
        hooks: RuntimeControllerHooks
    ) {
        self.paths = paths
        self.seed = seed
        operationFileManager = fileManager
        self.digester = digester
        self.hooks = hooks
    }

    func perform() throws {
        try Task.checkCancellation()
        try verifySeed()
        try safelyCreateDirectory(paths.rootURL, mode: 0o700)

        // The lock lives outside the directory exchanged during an upgrade.
        let lockURL = paths.rootURL.deletingLastPathComponent()
            .appendingPathComponent(".\(paths.rootURL.lastPathComponent)-preparation.lock")
        let lock = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw RuntimeError.insecurePath }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock)
            throw RuntimeError.busy("环境准备")
        }
        defer { flock(lock, LOCK_UN); close(lock) }

        if !hasSuccessfulRuntime() {
            guard !hasPersistentGuestDisks(at: paths.rootURL) else {
                throw RuntimeError.invalidSeed("现有运行资源需要修复，已保留应用数据")
            }
            try publishRuntime()
        } else {
            try upgradeImageIfNeeded()
        }

        try safelyCreateDirectory(paths.avdHomeURL, mode: 0o700)
        try safelyCreateDirectory(paths.avdURL, mode: 0o700)
        try writeAVDConfigurationIfMissing()
        try safelyCreateDirectory(paths.appSupportURL, mode: 0o700)
        try safelyCreateDirectory(paths.appIconsDirectoryURL, mode: 0o700)
        try publishServer()
        try publishInputHelper()
        try publishCameraSync()
        try publishMoltenVK()
        try publishBundledAppIcons()
        try Task.checkCancellation()
    }

    private func verifySeed() throws {
        guard let seedDirectory = seed.directoryURL else {
            throw RuntimeError.invalidSeed("RuntimeSeed")
        }
        guard seed.scrcpyServerURL != nil else {
            throw RuntimeError.invalidSeed("RuntimeSeed 文件")
        }
        let identityFiles = [
            seedDirectory.appendingPathComponent("image/source.properties"),
            seedDirectory.appendingPathComponent("image/build.prop")
        ]
        guard identityFiles.allSatisfy({
            operationFileManager.fileExists(atPath: $0.path)
        }) else {
            throw RuntimeError.invalidSeed("RuntimeSeed 文件")
        }
        let seedImage = seedDirectory.appendingPathComponent("image")
        let seedIdentity = try RuntimeImageIdentity.read(from: seedImage)
        guard seed.bundlesAndroidRuntime else {
            try verifyLightweightSeed(seedDirectory: seedDirectory, identity: seedIdentity)
            return
        }
        let required = [
            seedDirectory.appendingPathComponent("emulator/emulator"),
            seedDirectory.appendingPathComponent("platform-tools/adb"),
            seedDirectory.appendingPathComponent("image/system.img"),
            seedDirectory.appendingPathComponent("image/vendor.img"),
            seedDirectory.appendingPathComponent("image/kernel-ranchu"),
            seedDirectory.appendingPathComponent("image/ramdisk.img"),
            seedDirectory.appendingPathComponent("image/NOTICE.txt")
        ]
        guard required.allSatisfy({
            operationFileManager.fileExists(atPath: $0.path)
        }) else {
            throw RuntimeError.invalidSeed("RuntimeSeed 文件")
        }
    }

    private func verifyLightweightSeed(
        seedDirectory: URL,
        identity: RuntimeImageIdentity
    ) throws {
        guard hasSuccessfulRuntime() else {
            throw RuntimeError.invalidSeed("轻量安装包需要已有的完整 Android 环境")
        }
        guard runtimeImageMatches(identity) else {
            throw RuntimeError.invalidSeed("轻量安装包需要与现有环境一致的 Android 镜像")
        }
        let requiredHelpers = [
            seedDirectory.appendingPathComponent("android-use-ime.apk"),
            seedDirectory.appendingPathComponent("libmaccamera_frame_sync.dylib"),
            seedDirectory.appendingPathComponent("libMacdoraMoltenVK.dylib")
        ]
        guard requiredHelpers.allSatisfy({
            operationFileManager.fileExists(atPath: $0.path)
                && !Self.isSymbolicLink($0)
        }) else {
            throw RuntimeError.invalidSeed("RuntimeSeed 文件")
        }
    }

    private func runtimeImageMatches(_ identity: RuntimeImageIdentity) -> Bool {
        guard hasSuccessfulRuntime(),
              let installed = try? RuntimeImageIdentity.read(from: paths.imageURL) else {
            return false
        }
        return identity == installed
    }

    private static let persistentDisks = [
        "userdata-qemu.img", "userdata-qemu.img.qcow2",
        "encryptionkey.img", "encryptionkey.img.qcow2"
    ]

    private func hasPersistentGuestDisks(at root: URL) -> Bool {
        Self.persistentDisks.contains {
            operationFileManager.fileExists(atPath: root.appendingPathComponent("avd/android-use.avd/\($0)").path)
        }
    }

    private func upgradeImageIfNeeded() throws {
        guard let seedDirectory = seed.directoryURL else { throw RuntimeError.invalidSeed("RuntimeSeed") }
        let sourceImage = seedDirectory.appendingPathComponent("image", isDirectory: true)
        let desired = try RuntimeImageIdentity.read(from: sourceImage)
        let installed = try RuntimeImageIdentity.read(from: paths.imageURL)
        guard seed.bundlesAndroidRuntime else {
            guard desired == installed else {
                throw RuntimeError.invalidSeed("轻量安装包需要与现有环境一致的 Android 镜像")
            }
            return
        }
        guard desired != installed else { return }
        guard installed.permitsUpgrade(to: desired) else {
            throw RuntimeError.invalidSeed("现有 Android 版本较新，已保留数据，请使用更新的应用版本")
        }
        let vmLock = paths.avdURL.appendingPathComponent("hardware-qemu.ini.lock")
        if operationFileManager.fileExists(atPath: vmLock.path) {
            guard let text = try? String(contentsOf: vmLock, encoding: .utf8),
                  let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else {
                throw RuntimeError.upgradeRequiresStop
            }
            if kill(pid, 0) == 0 || errno == EPERM { throw RuntimeError.upgradeRequiresStop }
        }

        let backups = paths.rootURL.deletingLastPathComponent()
            .appendingPathComponent(paths.rootURL.lastPathComponent + "-backups", isDirectory: true)
        try safelyCreateDirectory(backups, mode: 0o700)
        let rollback = backups.appendingPathComponent("android-\(installed.api)-\(UUID().uuidString)", isDirectory: true)
        // Prepare an entire replacement root. The atomic exchange commits image,
        // AVD metadata, cache marker and all Guest disks as one filesystem operation.
        try operationFileManager.copyItem(at: paths.rootURL, to: rollback)
        var published = false
        defer { if !published { try? operationFileManager.removeItem(at: rollback) } }
        try Task.checkCancellation()
        let stagedImage = rollback.appendingPathComponent("runtime/image", isDirectory: true)
        try operationFileManager.removeItem(at: stagedImage)
        try operationFileManager.copyItem(at: sourceImage, to: stagedImage)
        guard try RuntimeImageIdentity.read(from: stagedImage) == desired else {
            throw RuntimeError.invalidSeed("Android 镜像复制校验")
        }
        let stagedAVD = rollback.appendingPathComponent("avd/android-use.avd", isDirectory: true)
        for name in Self.persistentDisks {
            let original = paths.avdURL.appendingPathComponent(name)
            if operationFileManager.fileExists(atPath: original.path) {
                let copy = stagedAVD.appendingPathComponent(name)
                guard try digester.sha256(fileURL: original) == digester.sha256(fileURL: copy) else {
                    throw RuntimeError.invalidSeed("Android 数据备份校验")
                }
            }
        }
        // A changed incremental marker makes the SDK recreate *all* QCOW layers,
        // including userdata and encryption keys. Retain those layers and advance
        // the marker explicitly, invalidating only generated OS boot state.
        for name in ["initrd", "hardware-qemu.ini", "system.img.qcow2", "vendor.img.qcow2", "cache.img.qcow2", "cache.img"] {
            let generated = stagedAVD.appendingPathComponent(name)
            if operationFileManager.fileExists(atPath: generated.path) { try operationFileManager.removeItem(at: generated) }
        }
        try Data("\(desired.incremental)\n".utf8).write(to: stagedAVD.appendingPathComponent("version_num.cache"), options: .atomic)
        let stagedIni = rollback.appendingPathComponent("avd/android-use.ini")
        try Data("avd.ini.encoding=UTF-8\npath=\(paths.avdURL.path)\npath.rel=android-use.avd\ntarget=android-\(desired.api)\n".utf8).write(to: stagedIni, options: .atomic)
        let record: [String: Any] = [
            "fromAPI": installed.api, "toAPI": desired.api,
            "imageIncremental": desired.incremental, "rollbackRoot": rollback.path,
            "persistentDisksVerified": true, "completedAt": ISO8601DateFormatter().string(from: Date())
        ]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: rollback.appendingPathComponent("runtime-upgrade.json"), options: .atomic)
        try hooks.beforePublish(rollback, paths.rootURL)
        try Task.checkCancellation()
        guard renamex_np(rollback.path, paths.rootURL.path, UInt32(RENAME_SWAP)) == 0 else {
            throw RuntimeError.unexpected("无法完成系统升级，原数据已保留")
        }
        published = true // rollback now holds the complete, untouched old root.
    }

    private func publishRuntime() throws {
        guard let seedDirectory = seed.directoryURL else {
            throw RuntimeError.invalidSeed("RuntimeSeed")
        }
        if operationFileManager.fileExists(
            atPath: paths.runtimeURL.path,
            isDirectory: nil
        ) {
            if hasSuccessfulRuntime() {
                return
            }
            let quarantineURL = paths.rootURL.appendingPathComponent(
                ".runtime-incomplete-\(UUID().uuidString)",
                isDirectory: true
            )
            do {
                try operationFileManager.moveItem(
                    at: paths.runtimeURL,
                    to: quarantineURL
                )
            } catch {
                throw RuntimeError.invalidSeed("已存在的 runtime 不完整")
            }
        }
        let stagingURL = paths.rootURL.appendingPathComponent(
            ".runtime-\(UUID().uuidString)",
            isDirectory: true
        )
        try operationFileManager.copyItem(at: seedDirectory, to: stagingURL)
        do {
            try Task.checkCancellation()
            try hooks.beforePublish(stagingURL, paths.runtimeURL)
            guard !operationFileManager.fileExists(atPath: paths.runtimeURL.path) else {
                try? operationFileManager.removeItem(at: stagingURL)
                return
            }
            guard hasSuccessfulRuntime(at: stagingURL) else {
                throw RuntimeError.invalidSeed("复制的 RuntimeSeed")
            }
            try Task.checkCancellation()
            try operationFileManager.moveItem(at: stagingURL, to: paths.runtimeURL)
        } catch {
            try? operationFileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    private func hasSuccessfulRuntime() -> Bool {
        hasSuccessfulRuntime(at: paths.runtimeURL)
    }

    private func hasSuccessfulRuntime(at url: URL) -> Bool {
        [
            url.appendingPathComponent("emulator/emulator"),
            url.appendingPathComponent("platform-tools/adb"),
            url.appendingPathComponent("image/system.img"),
            url.appendingPathComponent("image/vendor.img"),
            url.appendingPathComponent("image/kernel-ranchu"),
            url.appendingPathComponent("image/ramdisk.img"),
            url.appendingPathComponent("image/source.properties"),
            url.appendingPathComponent("image/NOTICE.txt")
        ].allSatisfy { operationFileManager.fileExists(atPath: $0.path) }
    }

    private func writeAVDConfigurationIfMissing() throws {
        let image = try RuntimeImageIdentity.read(from: paths.imageURL)
        let configURL = paths.avdURL.appendingPathComponent("config.ini")
        let ini = """
        avd.ini.encoding=UTF-8
        path=\(paths.avdURL.path)
        path.rel=android-use.avd
        target=android-\(image.api)
        """
        let config = """
        avd.ini.encoding=UTF-8
        image.sysdir.1=\(paths.imageURL.path)
        tag.id=default
        tag.display=Default Android System Image
        PlayStore.enabled=false
        abi.type=arm64-v8a
        hw.cpu.arch=arm64
        hw.cpu.ncore=4
        hw.ramSize=6144
        hw.lcd.width=1080
        hw.lcd.height=1920
        hw.lcd.density=420
        hw.keyboard=yes
        hw.mainKeys=no
        showDeviceFrame=no
        fastboot.forceColdBoot=yes
        fastboot.forceFastBoot=no
        disk.dataPartition.size=8G
        hw.gpu.enabled=yes
        hw.gpu.mode=host
        hw.lcd.vsync=60
        hw.gltransport=virtio-gpu-asg
        hw.gltransport.asg.writeBufferSize=1048576
        hw.gltransport.asg.writeStepSize=262144
        hw.gltransport.asg.dataRingSize=524288
        hw.gltransport.drawFlushInterval=10000
        hw.camera.back=emulated
        hw.camera.front=webcam0
        hw.accelerometer=no
        hw.accelerometer_uncalibrated=no
        hw.sensors.accelerometer_uncalibrated=no
        hw.gyroscope=no
        hw.gyroscope_uncalibrated=no
        hw.sensors.gyroscope_uncalibrated=no
        hw.sensors.light=no
        hw.sensors.pressure=no
        hw.sensors.humidity=no
        hw.sensors.proximity=no
        hw.sensors.magnetic_field=no
        hw.sensors.magnetic_field_uncalibrated=no
        hw.sensors.orientation=no
        hw.sensors.temperature=no
        hw.gsmModem=no
        """

        let existingIni = try? String(contentsOf: paths.avdIniURL, encoding: .utf8)
        let iniMatches = existingIni.map {
            RuntimeController.hasRequiredAVDConfigurationValues(
                $0,
                required: [("target", "android-\(image.api)")]
            )
        } == true
        let existingConfig: String?
        if operationFileManager.fileExists(atPath: configURL.path) {
            existingConfig = try? String(contentsOf: configURL, encoding: .utf8)
        } else {
            existingConfig = nil
        }
        let baseConfigIsValid = existingConfig.map {
            RuntimeController.hasRequiredAVDConfigurationValues(
                $0,
                required: [
                    ("hw.camera.front", "webcam0"),
                    ("hw.camera.back", "emulated"),
                    ("hw.sensors.light", "no"),
                    ("hw.gsmModem", "no")
                ]
            )
        } == true

        if baseConfigIsValid {
            if !iniMatches {
                try Data(ini.utf8).write(to: paths.avdIniURL, options: .atomic)
                try operationFileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: paths.avdIniURL.path
                )
            }
            try RuntimeController.repairAVDGPUConfiguration(
                configURL: configURL,
                fileManager: operationFileManager
            )
            return
        }

        // Invalidate before publishing config so a cleanup failure remains
        // observable and is retried on the next preparation.
        try RuntimeController.invalidateAVDCache(
            at: paths.avdURL,
            fileManager: operationFileManager
        )
        try Data(ini.utf8).write(to: paths.avdIniURL, options: .atomic)
        try Data(config.utf8).write(to: configURL, options: .atomic)
        try operationFileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: paths.avdIniURL.path
        )
        try operationFileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configURL.path
        )
        let verified = try String(contentsOf: configURL, encoding: .utf8)
        guard RuntimeController.hasRequiredAVDGPUConfiguration(verified) else {
            throw RuntimeError.invalidSeed("AVD GPU 配置校验未通过")
        }
    }

    private func publishServer() throws {
        guard let source = seed.scrcpyServerURL else {
            throw RuntimeError.serverTransferFailed
        }
        let expected = try digester.sha256(fileURL: source)
        if operationFileManager.fileExists(atPath: paths.scrcpyPrivateURL.path),
           try digester.sha256(fileURL: paths.scrcpyPrivateURL) == expected { return }
        let staging = paths.appSupportURL.appendingPathComponent(".server-\(UUID().uuidString).jar")
        do {
            try operationFileManager.copyItem(at: source, to: staging)
            try operationFileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
            guard try digester.sha256(fileURL: staging) == expected else { throw RuntimeError.serverTransferFailed }
            try Task.checkCancellation()
            if operationFileManager.fileExists(atPath: paths.scrcpyPrivateURL.path) {
                _ = try operationFileManager.replaceItemAt(paths.scrcpyPrivateURL, withItemAt: staging)
            } else { try operationFileManager.moveItem(at: staging, to: paths.scrcpyPrivateURL) }
        } catch { try? operationFileManager.removeItem(at: staging); throw error }
    }

    private func publishInputHelper() throws {
        guard let source = seed.directoryURL?.appendingPathComponent("android-use-ime.apk"),
              operationFileManager.fileExists(atPath: source.path) else { return }
        let expected = try digester.sha256(fileURL: source)
        if operationFileManager.fileExists(atPath: paths.inputHelperURL.path),
           try digester.sha256(fileURL: paths.inputHelperURL) == expected { return }
        let staging = paths.appSupportURL.appendingPathComponent(".input-\(UUID().uuidString).apk")
        do {
            try operationFileManager.copyItem(at: source, to: staging)
            try operationFileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
            guard try digester.sha256(fileURL: staging) == expected else { throw RuntimeError.invalidSeed("输入组件校验") }
            try Task.checkCancellation()
            if operationFileManager.fileExists(atPath: paths.inputHelperURL.path) {
                _ = try operationFileManager.replaceItemAt(paths.inputHelperURL, withItemAt: staging)
            } else { try operationFileManager.moveItem(at: staging, to: paths.inputHelperURL) }
        } catch { try? operationFileManager.removeItem(at: staging); throw error }
    }

    private func publishCameraSync() throws {
        guard let source = seed.directoryURL?.appendingPathComponent("libmaccamera_frame_sync.dylib"),
              operationFileManager.fileExists(atPath: source.path) else { return }
        let expected = try digester.sha256(fileURL: source)
        if operationFileManager.fileExists(atPath: paths.cameraSyncDylibURL.path),
           try digester.sha256(fileURL: paths.cameraSyncDylibURL) == expected { return }
        let staging = paths.appSupportURL.appendingPathComponent(".camera-sync-\(UUID().uuidString).dylib")
        do {
            try operationFileManager.copyItem(at: source, to: staging)
            try operationFileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
            guard try digester.sha256(fileURL: staging) == expected else { throw RuntimeError.invalidSeed("摄像头同步组件校验") }
            try Task.checkCancellation()
            if operationFileManager.fileExists(atPath: paths.cameraSyncDylibURL.path) {
                _ = try operationFileManager.replaceItemAt(paths.cameraSyncDylibURL, withItemAt: staging)
            } else { try operationFileManager.moveItem(at: staging, to: paths.cameraSyncDylibURL) }
        } catch { try? operationFileManager.removeItem(at: staging); throw error }
    }

    private func publishMoltenVK() throws {
        guard let source = seed.directoryURL?.appendingPathComponent("libMacdoraMoltenVK.dylib"),
              operationFileManager.fileExists(atPath: source.path) else { return }
        guard !Self.isSymbolicLink(source), !Self.isSymbolicLink(paths.moltenVKDylibURL) else {
            throw RuntimeError.insecurePath
        }
        var directory = paths.runtimeURL
        for component in ["emulator", "lib64", "vulkan"] {
            directory.appendPathComponent(component, isDirectory: true)
            try safelyCreateDirectory(directory, mode: 0o755)
        }
        let expected = try digester.sha256(fileURL: source)
        if operationFileManager.fileExists(atPath: paths.moltenVKDylibURL.path),
           try digester.sha256(fileURL: paths.moltenVKDylibURL) == expected { return }
        let staging = directory.appendingPathComponent(".moltenvk-\(UUID().uuidString).dylib")
        do {
            try operationFileManager.copyItem(at: source, to: staging)
            try operationFileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
            guard try digester.sha256(fileURL: staging) == expected else {
                throw RuntimeError.invalidSeed("GPU 转换组件校验")
            }
            try Task.checkCancellation()
            try hooks.beforePublish(staging, paths.moltenVKDylibURL)
            try Task.checkCancellation()
            if operationFileManager.fileExists(atPath: paths.moltenVKDylibURL.path) {
                _ = try operationFileManager.replaceItemAt(paths.moltenVKDylibURL, withItemAt: staging)
            } else {
                try operationFileManager.moveItem(at: staging, to: paths.moltenVKDylibURL)
            }
        } catch {
            try? operationFileManager.removeItem(at: staging)
            throw error
        }
    }

    private func publishBundledAppIcons() throws {
        #if DEBUG
        let repoIconsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/AppIcons", isDirectory: true)
        #else
        let repoIconsDir: URL? = nil
        #endif
        let candidateDirs = [
            seed.directoryURL?.appendingPathComponent("icons", isDirectory: true),
            Bundle.main.resourceURL?.appendingPathComponent("AppIcons", isDirectory: true),
            repoIconsDir
        ].compactMap { $0 }

        for dir in candidateDirs {
            guard let items = try? operationFileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for item in items where item.pathExtension.lowercased() == "png" {
                let destination = paths.appIconsDirectoryURL.appendingPathComponent(item.lastPathComponent)
                guard !operationFileManager.fileExists(atPath: destination.path) else { continue }
                try? operationFileManager.copyItem(at: item, to: destination)
                try? operationFileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            }
        }
    }

    private func safelyCreateDirectory(_ url: URL, mode: Int) throws {
        var isDirectory: ObjCBool = false
        if operationFileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue, !Self.isSymbolicLink(url) else {
                throw RuntimeError.insecurePath
            }
        } else {
            try operationFileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: mode]
            )
        }
        try operationFileManager.setAttributes(
            [.posixPermissions: mode],
            ofItemAtPath: url.path
        )
    }

    nonisolated private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}

protocol SecureDigesting: Sendable {
    func sha256(fileURL: URL) throws -> String
    func sha256(data: Data) -> String
}

struct SHA256Digester: SecureDigesting {
    func sha256(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else {
                break
            }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func sha256(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct ForwardAllocation: Equatable, Sendable {
    let localPort: UInt16
    let serial: String
    let scid: UInt32
}

protocol ControllerEnvironment: Sendable {
    func environment() -> [String: String]
    func allocateForward(
        adbURL: URL,
        environment: [String: String],
        requestedPort: UInt16,
        scid: UInt32
    ) async throws -> ForwardAllocation
    func removeForward(
        adbURL: URL,
        environment: [String: String],
        allocation: ForwardAllocation
    ) async throws
    func secureCopy(
        adbURL: URL,
        localURL: URL,
        remotePath: String,
        environment: [String: String]
    ) async throws
    func portIsAvailable(_ port: UInt16) -> Bool
}

struct RuntimeConnectionPorts: Sendable {
    let adb: UInt16
    let emulator: UInt16

    static let `default` = RuntimeConnectionPorts(adb: 5043, emulator: 5584)
    var serial: String { "emulator-\(emulator)" }
}

struct SystemControllerEnvironment: ControllerEnvironment {
    private let runner: any ProcessExecuting
    private let ports: RuntimeConnectionPorts

    init(runner: any ProcessExecuting = ProcessRunner(), ports: RuntimeConnectionPorts = .default) {
        self.runner = runner
        self.ports = ports
    }

    func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let path = environment["PATH"], !path.split(separator: ":").contains("/usr/bin") {
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:" + path
        } else if environment["PATH"] == nil {
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        }
        return environment
    }

    func allocateForward(
        adbURL: URL,
        environment: [String: String],
        requestedPort: UInt16,
        scid: UInt32
    ) async throws -> ForwardAllocation {
        let socketName = RuntimePorts.socketName(scid: scid)
        let result = try await runner.run(ProcessInvocation(
            executableURL: adbURL,
            arguments: [
                "-H", "127.0.0.1", "-P", String(ports.adb), "-s", ports.serial,
                "forward", "--no-rebind", "tcp:\(requestedPort)", "localabstract:\(socketName)"
            ],
            environment: environment,
            timeout: 20,
            captureOutput: true
        ))
        guard result.exitCode == 0, !result.timedOut else {
            throw RuntimeError.adbCommandFailed("配置显示通道")
        }
        return ForwardAllocation(localPort: requestedPort, serial: ports.serial, scid: scid)
    }

    func removeForward(
        adbURL: URL,
        environment: [String: String],
        allocation: ForwardAllocation
    ) async throws {
        let result = try await runner.run(ProcessInvocation(
            executableURL: adbURL,
            arguments: [
                "-H", "127.0.0.1", "-P", String(ports.adb), "-s", ports.serial,
                "forward", "--remove", "tcp:\(allocation.localPort)"
            ],
            environment: environment,
            timeout: 15,
            captureOutput: false
        ))
        guard result.exitCode == 0, !result.timedOut else {
            throw RuntimeError.adbCommandFailed("移除显示通道")
        }
    }

    func secureCopy(
        adbURL: URL,
        localURL: URL,
        remotePath: String,
        environment: [String: String]
    ) async throws {
        let result = try await runner.run(ProcessInvocation(
            executableURL: adbURL,
            arguments: [
                "-H", "127.0.0.1", "-P", String(ports.adb), "-s", ports.serial,
                "push", localURL.path, remotePath
            ],
            environment: environment,
            timeout: 30,
            captureOutput: true,
            outputLimit: 16 * 1024
        ))
        guard result.exitCode == 0, !result.timedOut else {
            throw RuntimeError.serverTransferFailed
        }
    }

    func portIsAvailable(_ port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var reuse: Int32 = 1
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        return bound == 0
    }
}

struct RuntimeControllerHooks: Sendable {
    var freePort: @Sendable () throws -> UInt16
    var randomSCID: @Sendable () -> UInt32
    var executableAndSecure: @Sendable (URL, Bool) -> Bool
    var localHostPortAvailable: @Sendable (UInt16) -> Bool
    var beforePublish: @Sendable (URL, URL) throws -> Void
    var beforeStart: @Sendable () async throws -> Void
    var beforeOpenDisplay: @Sendable () async throws -> Void

    init(
        freePort: @escaping @Sendable () throws -> UInt16 = {
            try RuntimePorts.freeLocalPort()
        },
        randomSCID: @escaping @Sendable () -> UInt32 = {
            UInt32.random(in: 1...UInt32(Int32.max))
        },
        executableAndSecure: @escaping @Sendable (URL, Bool) -> Bool = {
            RuntimePermissionChecks.isExecutableAndSecure($0, privateOwnerOnly: $1)
        },
        localHostPortAvailable: @escaping @Sendable (UInt16) -> Bool = {
            SystemControllerEnvironment().portIsAvailable($0)
        },
        beforePublish: @escaping @Sendable (URL, URL) throws -> Void = { _, _ in },
        beforeStart: @escaping @Sendable () async throws -> Void = {},
        beforeOpenDisplay: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.freePort = freePort
        self.randomSCID = randomSCID
        self.executableAndSecure = executableAndSecure
        self.localHostPortAvailable = localHostPortAvailable
        self.beforePublish = beforePublish
        self.beforeStart = beforeStart
        self.beforeOpenDisplay = beforeOpenDisplay
    }
}

enum RuntimePorts {
    static func socketName(scid: UInt32) -> String {
        String(format: "scrcpy_%08x", scid)
    }

    static func packagePathPresent(_ data: Data) -> Bool {
        String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .contains { $0.hasPrefix("package:/") }
    }

    static func forwardPortIsReady(
        _ port: UInt16,
        localHostPortAvailable: (UInt16) -> Bool
    ) -> Bool {
        !localHostPortAvailable(port)
    }

    static func guestSocketIsListening(
        _ data: Data,
        scid: UInt32
    ) -> Bool {
        String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .contains { line in
                line.split(whereSeparator: \.isWhitespace)
                    .contains { $0 == "@\(socketName(scid: scid))" }
            }
    }

    static func freeLocalPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw RuntimeError.displayUnavailable }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let readAddress = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard bound == 0, readAddress == 0, address.sin_port != 0 else {
            throw RuntimeError.displayUnavailable
        }
        return UInt16(bigEndian: address.sin_port)
    }

    static func commandLine(
        scid: UInt32,
        resolutionPreset: String = "1080p",
        targetFPS: Int = 60,
        tabletMode: Bool = true,
        interfaceScale: DisplayInterfaceScale = .standard
    ) -> String {
        let scidHex = String(format: "%08x", scid)
        let displaySpec = ContainerPreferences.scrcpyNewDisplaySpec(
            tabletMode: tabletMode,
            interfaceScale: interfaceScale
        )
        let pixelSize = ContainerPreferences.pixelSize(
            for: resolutionPreset,
            tabletMode: tabletMode
        )
        let maxAxis = max(pixelSize.width, pixelSize.height)
        let bitRate: Int
        if resolutionPreset == "1440p" || maxAxis >= 2400 {
            bitRate = 36_000_000
        } else if resolutionPreset == "720p" || maxAxis <= 1280 {
            bitRate = 14_000_000
        } else if maxAxis <= 1600 {
            bitRate = 18_000_000
        } else {
            bitRate = 24_000_000
        }
        let clampedFPS = [30, 45, 60].contains(targetFPS) ? targetFPS : 60
        return "CLASSPATH=/data/local/tmp/android-use-scrcpy.jar"
            + " app_process / com.genymobile.scrcpy.Server 5.0.1"
            + " tunnel_forward=true audio=false control=true"
            + " video_codec=h264 video_bit_rate=\(bitRate) max_fps=\(clampedFPS)"
            + " video_codec_options=low-latency=1"
            + " new_display=\(displaySpec) max_size=\(Int(maxAxis)) vd_system_decorations=false"
            + " display_ime_policy=local clipboard_autosync=false"
            + " send_device_meta=false send_dummy_byte=false"
            + " send_frame_meta=true send_stream_meta=true keep_active=true"
            + " log_level=warn scid=\(scidHex)"
            + " vd_destroy_content=true"
    }
}

enum RuntimePermissionChecks {
    static func isExecutableAndSecure(
        _ url: URL,
        privateOwnerOnly: Bool
    ) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: url.path),
              !hasExtendedACL(url),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber else {
            return false
        }
        let mode = permissions.intValue
        if privateOwnerOnly {
            return mode & 0o077 == 0
        }
        return mode & 0o022 == 0
    }

    static func hasExtendedACL(_ url: URL) -> Bool {
        let path = url.path
        return path.withCString { pointer in
            acl_get_file(pointer, ACL_TYPE_EXTENDED) != nil
        }
    }
}

struct PreparedRuntime: Sendable {
    let paths: RuntimePaths
    let environment: [String: String]
    let runID: UUID
}

@MainActor
final class RuntimeController: SystemPluginHostBridge {
    static let maxConcurrentDisplays = 4

    let rootURL: URL
    let pluginManager: SystemPluginManager
    private(set) var state: RuntimeState = .stopped
    var onState: ((RuntimeState) -> Void)?
    var onDisplayTerminated: (() -> Void)?
    var onPackageDisplayTerminated: ((String) -> Void)?
    var onPluginBanner: ((String) -> Void)?
    var onPluginStateChanged: (() -> Void)?
    var onOfficeKeepAwakeChanged: (() -> Void)?
    var cameraEnabled: Bool {
        get {
            if let stored = defaults.object(forKey: Self.cameraDefaultsKey) as? Bool {
                return stored
            }
            return true
        }
        set {
            guard !state.isBusy else {
                return
            }
            defaults.set(newValue, forKey: Self.cameraDefaultsKey)
        }
    }
    private func runtimeFilesExist() -> Bool {
        let checks = [
            paths.runtimeURL,
            paths.imageURL,
            paths.avdURL,
            paths.avdIniURL,
            paths.scrcpyPrivateURL
        ]
        return checks.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    var isPrepared: Bool {
        runtimeFilesExist()
            && isValidRuntimeMetadata(requiringGPUConfiguration: true)
            && runtimeImageMatchesSeed()
    }

    private func canRepairGPUConfiguration() -> Bool {
        runtimeFilesExist()
            && isValidRuntimeMetadata(requiringGPUConfiguration: false)
            && runtimeImageMatchesSeed()
    }

    private func runtimeImageMatchesSeed() -> Bool {
        guard let directory = seed.directoryURL,
              let desired = try? RuntimeImageIdentity.read(from: directory.appendingPathComponent("image")),
              let installed = try? RuntimeImageIdentity.read(from: paths.imageURL) else { return false }
        return desired == installed
    }

    private static let cameraDefaultsKey = "AndroidUse.RuntimeController.cameraEnabled"
    private static let preferencesDefaultsKey = "AndroidUse.RuntimeController.containerPreferences"
    private let connectionPorts: RuntimeConnectionPorts
    private var adbPort: UInt16 { connectionPorts.adb }
    private var emulatorPort: UInt16 { connectionPorts.emulator }

    let paths: RuntimePaths

    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let runner: any ProcessExecuting
    private let processTerminator: any OwnedProcessTerminating
    private let digester: any SecureDigesting
    private let environmentProvider: any ControllerEnvironment
    private let seed: RuntimeSeed
    private let dependencyInstaller: RuntimeDependencyInstaller?
    private var environmentDownloadOperation: UUID?

    var onEnvironmentDownloadProgress: ((RuntimeEnvironmentDownloadProgress?) -> Void)?

    var needsEnvironmentDownload: Bool {
        !seed.bundlesAndroidRuntime && !RuntimeDependencyInstaller.canReuseEnvironment(seed: seed, paths: paths)
    }
    private let hooks: RuntimeControllerHooks
    private var generation: UInt64 = 0
    private var activeOperations: Set<UUID> = []
    private var preparingTask: Task<Void, Error>?
    private var startingTask: Task<Void, Error>?
    private var installingTask: Task<Void, Error>?
    private var openingTask: Task<DisplayEndpoint, Error>?
    private var openingDisplayPackage: String?
    private var closingTask: Task<Void, Never>?
    private var stoppingTask: Task<Bool, Never>?
    private var runtimeCleanupTask: Task<Bool, Never>?
    private var guestEnvironmentTask: Task<Void, Error>?
    private var officeKeepAwakeTask: Task<Bool, Never>?
    private var officeKeepAwakePhase: OfficeKeepAwakePhase = .off
    private var officeKeepAwakeActivity: NSObjectProtocol?
    private var unreapedProcesses: [any OwnedProcessHandle] = []
    private var isOpeningDisplay = false
    private var adbServerProcess: (any OwnedProcessHandle)?
    private var adbServerSerial: UInt64 = 0
    private var emulatorProcess: (any OwnedProcessHandle)?
    private var emulatorSerial: UInt64 = 0
    private var bootedCameraEnabled: Bool?
    private struct ActiveDisplaySession {
        let package: String
        let endpoint: DisplayEndpoint
        let allocation: ForwardAllocation
        let serverProcess: any OwnedProcessHandle
        let serverSerial: UInt64
        var tabletMode: Bool
        var resolutionPreset: String
        var interfaceScale: DisplayInterfaceScale
        var targetFPS: Int
        let openedOrder: UInt64
    }
    private var displaySessions: [String: ActiveDisplaySession] = [:]
    private var displaySessionOrderCounter: UInt64 = 0
    private var serverSerial: UInt64 = 0
    private var inputForwardPort: UInt16?
    private var inputHelperInstalled = false
    private var inputHelperInstallTask: Task<Void, Error>?
    private var isStopping = false
    private var cpuSampleTimes: [Int32: (totalNs: UInt64, wallTime: TimeInterval)] = [:]
    private var cachedDiskUsageGB: (value: Double, timestamp: TimeInterval)?
    private var diskUsageRefreshInFlight = false

    private var mostRecentDisplaySession: ActiveDisplaySession? {
        displaySessions.values.max(by: { $0.openedOrder < $1.openedOrder })
    }

    private var serverProcess: (any OwnedProcessHandle)? {
        mostRecentDisplaySession?.serverProcess
    }

    private var displayEndpoint: DisplayEndpoint? {
        mostRecentDisplaySession?.endpoint
    }

    private var isDisplayOpen: Bool {
        !displaySessions.isEmpty
    }

    var activeDisplayPackage: String? {
        mostRecentDisplaySession?.package
    }

    var activeDisplayPackages: [String] {
        displaySessions.values
            .sorted(by: { $0.openedOrder < $1.openedOrder })
            .map(\.package)
    }

    func displayEndpoint(for package: String) -> DisplayEndpoint? {
        displaySessions[package]?.endpoint
    }

    func displaySessionConfig(for package: String) -> (resolutionPreset: String, tabletMode: Bool, interfaceScale: DisplayInterfaceScale, targetFPS: Int)? {
        guard let session = displaySessions[package] else { return nil }
        return (session.resolutionPreset, session.tabletMode, session.interfaceScale, session.targetFPS)
    }

    func confirmDisplayConfiguration(package: String, endpoint: DisplayEndpoint, preference: AppDisplayPreference, targetFPS: Int) -> Bool {
        guard var session = displaySessions[package], session.endpoint.port == endpoint.port,
              session.serverProcess.isRunning, state == .running else { return false }
        session.resolutionPreset = preference.resolutionPreset
        session.tabletMode = preference.tabletMode
        session.interfaceScale = preference.interfaceScale
        session.targetFPS = targetFPS
        displaySessions[package] = session
        return true
    }

    func ensureDirectInputEnabled() async throws {
        guard state == .ready || state == .running else { return }
        let operationGeneration = generation
        _ = try await prepareDirectInput(operationGeneration: operationGeneration)
        guard isOperationCurrent(operationGeneration), adbServerProcess?.isRunning == true else { throw CancellationError() }
        try await requireADB(["shell", "ime", "enable", "local.androiduse.ime/.DirectCommitImeService"], operation: "启用中文输入组件")
        guard isOperationCurrent(operationGeneration), adbServerProcess?.isRunning == true else { throw CancellationError() }
        try await requireADB(["shell", "ime", "set", "local.androiduse.ime/.DirectCommitImeService"], operation: "选择中文输入组件")
        guard isOperationCurrent(operationGeneration) else { throw CancellationError() }
    }

    private var officeKeepAwakePreferences: OfficeKeepAwakePreferences {
        OfficeKeepAwakePreferences(rootURL: paths.rootURL, defaults: defaults)
    }

    var officeKeepAwakeStatus: OfficeKeepAwakeStatus {
        let enabled = officeKeepAwakePreferences.enabled
        let needsRuntime = enabled || officeKeepAwakePreferences.hasOriginal
        let phase = needsRuntime && officeKeepAwakePhase == .off ? .waitingForRuntime : officeKeepAwakePhase
        return OfficeKeepAwakeStatus(enabled: enabled, phase: phase)
    }

    var shouldKeepRuntimeInBackground: Bool {
        containerPreferences.keepWarmInBackground || officeKeepAwakePreferences.enabled
    }

    var isOfficeKeepAwakeActivityHeld: Bool { officeKeepAwakeActivity != nil }

    @discardableResult
    func setOfficeKeepAwakeEnabled(_ enabled: Bool) async -> Bool {
        guard !state.isBusy, !isStopping, runtimeCleanupTask == nil, officeKeepAwakeTask == nil else { return false }
        officeKeepAwakePreferences.enabled = enabled
        guard state == .ready || state == .running else {
            setOfficeKeepAwakePhase(enabled || officeKeepAwakePreferences.hasOriginal ? .waitingForRuntime : .off)
            return true
        }
        return await reconcileOfficeKeepAwake()
    }

    private func setOfficeKeepAwakePhase(_ phase: OfficeKeepAwakePhase) {
        officeKeepAwakePhase = phase
        onOfficeKeepAwakeChanged?()
    }

    private func holdOfficeKeepAwakeActivity(_ hold: Bool) {
        if hold, officeKeepAwakeActivity == nil {
            officeKeepAwakeActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Keep the selected office environment responsive in the background"
            )
        } else if !hold, let activity = officeKeepAwakeActivity {
            ProcessInfo.processInfo.endActivity(activity)
            officeKeepAwakeActivity = nil
        }
    }

    private func officeKeepAwakeCommand(
        _ script: String, generation operationGeneration: UInt64, allowStopping: Bool = false
    ) async throws -> Data {
        func validateOwnership() throws {
            guard generation == operationGeneration,
                  allowStopping || !isStopping,
                  adbServerProcess?.isRunning == true,
                  emulatorProcess?.isRunning == true else { throw CancellationError() }
        }
        try Task.checkCancellation()
        try validateOwnership()
        let result = try await runADB(
            OfficeKeepAwakeCommands.arguments(script), operation: "配置办公环境唤醒策略",
            timeout: 60, outputLimit: 1024
        )
        try Task.checkCancellation()
        try validateOwnership()
        guard result.exitCode == 0 else { throw RuntimeError.adbCommandFailed("配置办公环境唤醒策略") }
        return result.stdout
    }

    private func reconcileOfficeKeepAwake() async -> Bool {
        if let task = officeKeepAwakeTask { return await task.value }
        guard officeKeepAwakePreferences.enabled || officeKeepAwakePreferences.hasOriginal else {
            holdOfficeKeepAwakeActivity(false)
            setOfficeKeepAwakePhase(.off)
            return true
        }
        let operationGeneration = generation
        let task = Task { [self] in
            setOfficeKeepAwakePhase(.applying)
            do {
                if officeKeepAwakePreferences.enabled {
                    if !officeKeepAwakePreferences.hasOriginal {
                        let output = try await officeKeepAwakeCommand(
                            OfficeKeepAwakeCommands.inspect, generation: operationGeneration
                        )
                        guard let snapshot = OfficeFreezerSnapshot(output: output) else {
                            throw RuntimeError.adbCommandFailed("识别 Android 冻结策略")
                        }
                        // Persist the recovery lease BEFORE any guest mutation.
                        officeKeepAwakePreferences.original = snapshot
                    }
                    guard officeKeepAwakePreferences.original != nil else {
                        throw RuntimeError.adbCommandFailed("读取唤醒策略恢复记录")
                    }
                    let output = try await officeKeepAwakeCommand(
                        OfficeKeepAwakeCommands.apply, generation: operationGeneration
                    )
                    guard String(decoding: output, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines) == "MACDORA_OFFICE_AWAKE_APPLIED" else {
                        throw RuntimeError.adbCommandFailed("确认 Android 已解除冻结")
                    }
                    holdOfficeKeepAwakeActivity(true)
                    setOfficeKeepAwakePhase(.active)
                } else {
                    try await restoreOfficeKeepAwake(generation: operationGeneration)
                    holdOfficeKeepAwakeActivity(false)
                    setOfficeKeepAwakePhase(.off)
                }
                return true
            } catch {
                if generation == operationGeneration, !isStopping {
                    if officeKeepAwakePreferences.enabled, !Task.isCancelled {
                        try? await restoreOfficeKeepAwake(generation: operationGeneration)
                    }
                    guard generation == operationGeneration, !isStopping else { return false }
                    holdOfficeKeepAwakeActivity(false)
                    // Keep the lease on partial failure, including cancelled ADB writes.
                    setOfficeKeepAwakePhase(.failed)
                }
                return false
            }
        }
        officeKeepAwakeTask = task
        let result = await task.value
        officeKeepAwakeTask = nil
        return result
    }

    private func restoreOfficeKeepAwake(generation operationGeneration: UInt64, allowStopping: Bool = false) async throws {
        guard officeKeepAwakePreferences.hasOriginal else { return }
        guard let original = officeKeepAwakePreferences.original else {
            throw RuntimeError.adbCommandFailed("读取唤醒策略恢复记录")
        }
        let output = try await officeKeepAwakeCommand(
            OfficeKeepAwakeCommands.restore(original), generation: operationGeneration, allowStopping: allowStopping
        )
        let marker = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard marker == "MACDORA_OFFICE_AWAKE_RESTORED" || marker == "MACDORA_OFFICE_AWAKE_EXTERNAL" else {
            throw RuntimeError.adbCommandFailed("确认 Android 冻结策略已恢复")
        }
        officeKeepAwakePreferences.original = nil
    }

    var containerPreferences: ContainerPreferences {
        get {
            guard let data = defaults.data(forKey: Self.preferencesDefaultsKey),
                  var decoded = try? JSONDecoder().decode(ContainerPreferences.self, from: data) else {
                var fallback = ContainerPreferences.default
                fallback.cameraEnabled = cameraEnabled
                return fallback
            }
            decoded.cameraEnabled = cameraEnabled
            return decoded
        }
        set {
            var updated = newValue
            if !state.isBusy {
                defaults.set(updated.cameraEnabled, forKey: Self.cameraDefaultsKey)
            } else {
                updated.cameraEnabled = cameraEnabled
            }
            if let data = try? JSONEncoder().encode(updated) {
                defaults.set(data, forKey: Self.preferencesDefaultsKey)
            }
        }
    }

    func evaluateReadinessChecks(metalAvailable: Bool = true) -> [ReadinessCheckItem] {
        let prepared = isPrepared
        let apps = cachedContainerApps()
        let installedCount = apps.filter(\.isInstalled).count
        let prefs = containerPreferences

        let vmCheck = ReadinessCheckItem(
            id: "vm-hypervisor",
            area: "核心引擎",
            title: "运行环境引擎",
            detail: prepared
                ? "Apple Silicon 硬件加速已就绪，系统数据校验通过。"
                : "首次打开应用时将自动完成本地初始化。",
            status: prepared ? .ready : .review,
            actionTitle: nil
        )

        let adbReady = fileManager.isExecutableFile(atPath: paths.adbURL.path)
        let portCheck = ReadinessCheckItem(
            id: "private-ports",
            area: "连接隔离",
            title: "独立通信通道",
            detail: adbReady
                ? "专属本地通信通道已就绪，与其他应用互不干扰。"
                : "等待初始化本地通信服务。",
            status: adbReady ? .ready : .review,
            actionTitle: nil
        )

        let scrcpyReady = fileManager.fileExists(atPath: paths.scrcpyPrivateURL.path)
        let displayCheck = ReadinessCheckItem(
            id: "metal-display",
            area: "图形显示",
            title: "高清画面与平滑缩放",
            detail: (metalAvailable && scrcpyReady)
                ? "\(prefs.resolutionDisplayLabel) · \(prefs.targetFPS)Hz 硬件加速渲染。"
                : (metalAvailable ? "显示服务将在启动时自动就绪。" : "未检测到可用的图形加速设备。"),
            status: metalAvailable ? .ready : .blocked,
            actionTitle: nil
        )

        let imeCheck = ReadinessCheckItem(
            id: "direct-ime",
            area: "输入体验",
            title: "原生中文输入与安全键盘",
            detail: prefs.directIMEEnabled
                ? "支持使用 Mac 输入法直接输入中文，密码输入自动启用系统级保护。"
                : "当前仅使用基础键盘输入。",
            status: prefs.directIMEEnabled ? .ready : .review,
            actionTitle: prefs.directIMEEnabled ? nil : "开启中文输入"
        )

        let sandboxCheck = ReadinessCheckItem(
            id: "app-sandbox",
            area: "数据存储",
            title: "应用数据与登录状态持久化",
            detail: "已安装 \(installedCount) 个应用，账号登录态与本地数据独立保存。",
            status: .ready,
            actionTitle: nil
        )

        let camCheck = ReadinessCheckItem(
            id: "camera-passthrough",
            area: "外设权限",
            title: "摄像头调用支持",
            detail: prefs.cameraEnabled
                ? "已允许应用按需使用 Mac 摄像头进行扫码、拍照与人脸识别。"
                : "已关闭摄像头权限，可在设置中随时开启。",
            status: .ready,
            actionTitle: nil
        )

        let installedPluginsCount = pluginManager.installedCount
        let enabledPluginsCount = pluginManager.enabledCount
        var checks = [vmCheck, portCheck, displayCheck, imeCheck, sandboxCheck, camCheck]
        if installedPluginsCount > 0 {
            let degradedPlugins = pluginManager.installedCatalogItems.filter { item in
                pluginManager.isPluginEnabled(item.id) && pluginManager.pluginHealthStatus(for: item.id).isDegraded
            }
            let detailText: String
            let checkStatus: ReadinessCheckStatus
            if let firstDegraded = degradedPlugins.first {
                detailText = "插件「\(firstDegraded.name)」状态异常：\(pluginManager.pluginStatusText(for: firstDegraded.id))"
                checkStatus = .review
            } else if enabledPluginsCount > 0 {
                detailText = "已安装 \(installedPluginsCount) 个插件，当前已启用 \(enabledPluginsCount) 个系统级插件。"
                checkStatus = .ready
            } else {
                detailText = "已安装 \(installedPluginsCount) 个插件，可在插件中心按需启用。"
                checkStatus = .ready
            }
            checks.append(
                ReadinessCheckItem(
                    id: "system-plugins",
                    area: "扩展框架",
                    title: "系统级热插拔插件引擎",
                    detail: detailText,
                    status: checkStatus,
                    actionTitle: nil
                )
            )
        }
        return checks
    }

    func clearTemporaryLogsAndStaging() -> Int64 {
        var freed: Int64 = 0
        let candidates = [
            paths.appSupportURL.appendingPathComponent("target-install.apk.tmp")
        ]
        for url in candidates where fileManager.fileExists(atPath: url.path) {
            if let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value {
                freed += size
            }
            try? fileManager.removeItem(at: url)
        }
        cachedDiskUsageGB = nil
        return freed
    }

    convenience init() {
        let root: URL
        do {
            root = try RuntimePathsFactory.defaultRoot()
        } catch {
            root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support/AndroidUse", isDirectory: true)
        }
        self.init(rootURL: root, dependencyInstaller: RuntimeDependencyInstaller())
    }

    init(
        rootURL: URL,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        runner: any ProcessExecuting = ProcessRunner(),
        processTerminator: any OwnedProcessTerminating = ProcessRunner(),
        digester: any SecureDigesting = SHA256Digester(),
        environment: (any ControllerEnvironment)? = nil,
        connectionPorts: RuntimeConnectionPorts = .default,
        seed: RuntimeSeed = .bundle(),
        dependencyInstaller: RuntimeDependencyInstaller? = nil,
        hooks: RuntimeControllerHooks = RuntimeControllerHooks(),
        pluginFetcher: any SystemPluginPackageFetching = DefaultSystemPluginPackageFetcher(),
        locationConsoleTransport: (any LocationConsoleTransport)? = nil
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.paths = RuntimePaths(rootURL: rootURL)
        self.fileManager = fileManager
        self.defaults = defaults
        self.runner = runner
        self.processTerminator = processTerminator
        self.digester = digester
        self.connectionPorts = connectionPorts
        self.environmentProvider = environment ?? SystemControllerEnvironment(ports: connectionPorts)
        self.seed = seed
        self.dependencyInstaller = dependencyInstaller
        self.hooks = hooks
        self.pluginManager = SystemPluginManager(
            rootURL: rootURL,
            fileManager: fileManager,
            defaults: defaults,
            packageFetcher: pluginFetcher,
            locationConsoleTransport: locationConsoleTransport
        )
        self.pluginManager.hostBridge = self
    }

    // MARK: - SystemPluginHostBridge

    var currentRuntimeState: RuntimeState { state }
    var currentActivePackage: String? { activeDisplayPackage }
    var emulatorConsolePort: UInt16 { emulatorPort }

    var emulatorAuthTokenURLs: [URL] {
        [
            paths.androidEmulatorHomeURL.appendingPathComponent(".emulator_console_auth_token"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".emulator_console_auth_token")
        ]
    }

    var hostServiceEnvironment: [String: String] {
        [
            "MACDORA_ADB_PATH": paths.adbURL.path,
            "MACDORA_ADB_SERIAL": "emulator-\(emulatorPort)",
            "ANDROID_ADB_SERVER_PORT": String(adbPort),
            "ADB_SERVER_SOCKET": "tcp:127.0.0.1:\(adbPort)"
        ]
    }

    func executeGuestShell(_ script: String, operation: String, timeout: TimeInterval) async -> Bool {
        guard (state == .ready || state == .running || state == .starting),
              adbServerProcess?.isRunning == true else {
            return false
        }
        guard let result = try? await runADB(["shell", script], operation: operation, timeout: timeout) else {
            return false
        }
        let combinedOutput = result.combinedOutputUTF8
        if combinedOutput.contains("AU_PLUGIN_HOOK_FAIL") {
            return false
        }
        return result.exitCode == 0 && !result.timedOut
    }

    func sendEmulatorGeoFix(
        longitude: Double,
        latitude: Double,
        altitude: Double,
        satellites: Int,
        velocityKnots: Double
    ) async -> Bool {
        guard (state == .ready || state == .running || state == .starting),
              adbServerProcess?.isRunning == true else {
            return false
        }
        let posix = Locale(identifier: "en_US_POSIX")
        let args = [
            "emu", "geo", "fix",
            String(format: "%.7f", locale: posix, longitude),
            String(format: "%.7f", locale: posix, latitude),
            String(format: "%.1f", locale: posix, altitude),
            String(satellites),
            String(format: "%.2f", locale: posix, velocityKnots)
        ]
        guard let result = try? await runADB(args, operation: "硬件级 GPS 位置注入", timeout: 2.0) else {
            return false
        }
        return result.exitCode == 0 && !result.timedOut
    }

    func notifyPluginBanner(_ message: String) {
        onPluginBanner?(message)
    }

    func notifyPluginStateDidChange() {
        onPluginStateChanged?()
    }

    func prepare() async throws {
        switch state {
        case .preparing, .starting, .stopping:
            throw RuntimeError.busy("环境准备")
        case .ready, .running:
            if isPrepared { return }
            throw RuntimeError.upgradeRequiresStop
        case .stopped, .failed:
            break
        }

        let operation = UUID()
        let operationGeneration = generation
        activeOperations.insert(operation)
        updateState(.preparing("正在准备本地 Android 环境"))
        let task = Task {
            try await self.performPrepare()
        }
        preparingTask = task

        do {
            try await task.value
            if generation == operationGeneration, !isStopping {
                updateState(.stopped)
            }
            activeOperations.remove(operation)
            preparingTask = nil
        } catch {
            activeOperations.remove(operation)
            preparingTask = nil
            if isStopping || generation != operationGeneration {
                throw CancellationError()
            }
            updateState(.failed(Self.safeMessage(error)))
            throw error
        }
    }

    func start() async throws {
        switch state {
        case .running:
            return
        case .preparing, .starting, .stopping:
            throw RuntimeError.busy("Android 环境启动")
        case .ready, .stopped, .failed:
            break
        }

        if Self.canReuseReadyRuntime(
            state: state,
            emulatorRunning: emulatorProcess?.isRunning == true,
            bootedCameraEnabled: bootedCameraEnabled,
            desiredCameraEnabled: cameraEnabled
        ) {
            return
        }
        if state == .ready, emulatorProcess?.isRunning == true, bootedCameraEnabled != cameraEnabled {
            _ = await cleanUpOwnedRuntime()
            updateState(.stopped)
        }
        if !isPrepared {
            guard canRepairGPUConfiguration() else {
                throw RuntimeError.installNotPrepared
            }
            try ensureAVDGPUConfiguration()
        }
        guard isPrepared else { throw RuntimeError.installNotPrepared }
        let operationGeneration = generation
        try await hooks.beforeStart()
        guard generation == operationGeneration,
              !isStopping,
              Self.canStart(from: state) else {
            throw CancellationError()
        }
        guard RuntimePermissionChecks.isExecutableAndSecure(paths.adbURL, privateOwnerOnly: false),
              RuntimePermissionChecks.isExecutableAndSecure(paths.emulatorURL, privateOwnerOnly: false) else {
            throw RuntimeError.insecurePath
        }
        let ownedProcesses: [any OwnedProcessHandle] =
            displaySessions.values.map(\.serverProcess) + [emulatorProcess].compactMap { $0 }
        await waitForOwnedProcessesToExit(ownedProcesses)
        guard generation == operationGeneration,
              !isStopping,
              Self.canStart(from: state) else {
            throw CancellationError()
        }
        if !environmentProvider.portIsAvailable(emulatorPort),
           environmentProvider is SystemControllerEnvironment {
            await reclaimStaleOwnedEmulatorIfNeeded()
        }
        guard environmentProvider.portIsAvailable(emulatorPort) else {
            throw RuntimeError.portInUse(emulatorPort)
        }
        let operation = UUID()
        let prepared = try makePreparedRuntime()
        activeOperations.insert(operation)
        updateState(.starting)
        let task = Task {
            try await self.performStart(
                prepared: prepared,
                operationGeneration: operationGeneration
            )
        }
        startingTask = task

        do {
            try await task.value
            activeOperations.remove(operation)
            startingTask = nil
        } catch {
            activeOperations.remove(operation)
            startingTask = nil
            if isStopping || generation != operationGeneration {
                throw CancellationError()
            }
            await cleanUpOwnedRuntime()
            guard !isStopping, generation == operationGeneration else { throw CancellationError() }
            updateState(.failed(Self.safeMessage(error)))
            throw error
        }
    }

    func installAPK(_ url: URL) async throws {
        guard !state.isBusy else { throw RuntimeError.busy("安装 APK") }
        guard isPrepared else { throw RuntimeError.installNotPrepared }
        guard state == .stopped || state == .ready || state == .running else {
            throw RuntimeError.busy("安装 APK")
        }
        let operation = UUID()
        let operationGeneration = generation
        activeOperations.insert(operation)
        let task = Task {
            try await self.validateAndPersistTargetAPK(
                url,
                operationGeneration: operationGeneration
            )
        }
        installingTask = task
        do {
            try await task.value
        } catch {
            activeOperations.remove(operation)
            installingTask = nil
            throw error
        }
        activeOperations.remove(operation)
        installingTask = nil
        guard generation == operationGeneration, !isStopping else {
            throw CancellationError()
        }
        guard !state.isBusy else { throw RuntimeError.busy("安装 APK") }
        if (state == .ready || state == .running) && emulatorProcess?.isRunning == true {
            try await requireADB(adbInstallArguments(), operation: "安装 APK")
            guard generation == operationGeneration, !isStopping else {
                throw CancellationError()
            }
            _ = await refreshContainerApps()
        }
    }

    func isPackageInstalled(_ package: String) async throws -> Bool {
        guard ContainerApp.isValidPackageIdentifier(package) else { return false }
        guard isPrepared else { throw RuntimeError.installNotPrepared }
        guard state == .ready || state == .running else { throw RuntimeError.runtimeNotReady }
        let operationGeneration = generation
        let result = try await runADB(
            ["shell", "pm", "path", package],
            operation: "检查目标应用",
            timeout: 20
        )
        guard generation == operationGeneration, !isStopping else {
            throw CancellationError()
        }
        guard result.exitCode == 0 else {
            throw RuntimeError.adbCommandFailed("检查目标应用")
        }
        guard result.stdout.count <= 16 * 1024 else {
            return false
        }
        return result.exitCode == 0
            && RuntimePorts.packagePathPresent(result.stdout)
    }

    struct ProbedAppMetadata: Equatable, Sendable {
        let package: String
        let label: String
        let version: String
        let iconPNGData: Data
    }

    func cachedContainerApps() -> [ContainerApp] {
        let catalogURL = paths.appSupportURL.appendingPathComponent("container-apps.json")
        if let data = try? Data(contentsOf: catalogURL),
           let decoded = (try? JSONDecoder().decode([ContainerApp].self, from: data))?.filter({ !ContainerApp.isInternalPackage($0.package) }),
           !decoded.isEmpty {
            return Self.mergedContainerCatalog(
                installedPackages: Set(decoded.filter(\.isInstalled).map(\.package)),
                existing: decoded,
                iconsDirectoryURL: paths.appIconsDirectoryURL
            )
        }
        return Self.mergedContainerCatalog(
            installedPackages: [],
            existing: [],
            iconsDirectoryURL: paths.appIconsDirectoryURL
        )
    }

    func refreshContainerApps() async -> [ContainerApp] {
        do {
            return try await readContainerAppsFromGuest()
        } catch {
            return cachedContainerApps()
        }
    }

    private func readContainerAppsFromGuest() async throws -> [ContainerApp] {
        guard isPrepared, state == .ready || state == .running, emulatorProcess?.isRunning == true else {
            throw RuntimeError.runtimeNotReady
        }
        let operationGeneration = generation
        let result = try await runADB(
            ["shell", "pm", "list", "packages", "-3"],
            operation: "读取容器应用列表",
            timeout: 10
        )
        guard result.exitCode == 0, !result.timedOut else {
            throw RuntimeError.adbCommandFailed("读取容器应用列表")
        }
        guard generation == operationGeneration, !isStopping else {
            throw CancellationError()
        }
        let text = String(decoding: result.stdout, as: UTF8.self)
        var installed = Set<String>()
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("package:") else { continue }
            let pkg = String(trimmed.dropFirst("package:".count))
            guard ContainerApp.isValidPackageIdentifier(pkg),
                  !ContainerApp.isInternalPackage(pkg) else { continue }
            installed.insert(pkg)
        }
        try Task.checkCancellation()
        let packagesToProbe = Array(installed.union(["com.android.settings"])).sorted()
        let probed = await probeGuestApplications(packages: packagesToProbe)
        let apps = Self.mergedContainerCatalog(
            installedPackages: installed,
            existing: cachedContainerApps(),
            probed: probed,
            iconsDirectoryURL: paths.appIconsDirectoryURL
        )
        persistContainerCatalog(apps)
        return apps
    }

    private func persistContainerCatalog(_ apps: [ContainerApp]) {
        guard let encoded = try? JSONEncoder().encode(apps) else { return }
        try? safelyCreateDirectory(paths.appSupportURL, mode: 0o700)
        let catalogURL = paths.appSupportURL.appendingPathComponent("container-apps.json")
        try? encoded.write(to: catalogURL, options: .atomic)
    }

    private func probeGuestApplications(packages: [String]) async -> [String: ProbedAppMetadata] {
        guard !packages.isEmpty,
              fileManager.isReadableFile(atPath: paths.inputHelperURL.path),
              let prepared = try? makePreparedRuntime() else {
            return [:]
        }
        let remoteHelperPath = "/data/local/tmp/android-use-ime.apk"
        do {
            try await environmentProvider.secureCopy(
                adbURL: paths.adbURL,
                localURL: paths.inputHelperURL,
                remotePath: remoteHelperPath,
                environment: prepared.environment
            )
            let command = "CLASSPATH=\(remoteHelperPath) app_process / local.androiduse.ime.PackageCatalogProbe "
                + packages.joined(separator: " ")
            let result = try await runADB(
                ["shell", command],
                operation: "读取应用图标与信息",
                timeout: 15,
                outputLimit: 2 * 1024 * 1024
            )
            guard result.exitCode == 0, !result.timedOut else { return [:] }
            let parsed = Self.parsePackageCatalogProbeOutput(result.stdout)
            if !parsed.isEmpty {
                try? safelyCreateDirectory(paths.appIconsDirectoryURL, mode: 0o700)
                for (pkg, meta) in parsed where !meta.iconPNGData.isEmpty {
                    let iconURL = paths.appIconURL(for: pkg)
                    try? meta.iconPNGData.write(to: iconURL, options: .atomic)
                    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: iconURL.path)
                }
            }
            return parsed
        } catch {
            return [:]
        }
    }

    nonisolated static func parsePackageCatalogProbeOutput(_ data: Data) -> [String: ProbedAppMetadata] {
        let text = String(decoding: data, as: UTF8.self)
        var out: [String: ProbedAppMetadata] = [:]
        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("META\t") else { continue }
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 5 else { continue }
            let pkg = parts[1]
            guard ContainerApp.isValidPackageIdentifier(pkg) else { continue }
            let label = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
            let version = parts[3].trimmingCharacters(in: .whitespacesAndNewlines)
            let b64 = parts[4].trimmingCharacters(in: .whitespacesAndNewlines)
            let iconData: Data
            if !b64.isEmpty,
               let decoded = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
               decoded.starts(with: pngHeader) {
                iconData = decoded
            } else {
                iconData = Data()
            }
            out[pkg] = ProbedAppMetadata(
                package: pkg,
                label: label,
                version: version,
                iconPNGData: iconData
            )
        }
        return out
    }

    func forceStopApp(package: String) async throws {
        guard ContainerApp.isValidPackageIdentifier(package) else { return }
        guard isPrepared, state == .ready || state == .running else { throw RuntimeError.runtimeNotReady }
        try await requireADB(["shell", "am", "force-stop", package], operation: "停止应用进程")
        if package == "com.android.settings" {
            _ = try? await runADB(["shell", "am", "force-stop", "com.android.settings.intelligence"], operation: "停止设置搜索进程", timeout: 5)
        }
    }

    func uninstallApp(package: String) async throws {
        guard ContainerApp.isValidPackageIdentifier(package), package != "com.android.settings" else { return }
        guard isPrepared, state == .ready || state == .running else { throw RuntimeError.runtimeNotReady }
        let installedInGuest = try await isPackageInstalled(package)
        if installedInGuest {
            try await requireADB(["uninstall", package], operation: "卸载应用")
        }
        guard try await isPackageInstalled(package) == false else {
            throw RuntimeError.adbCommandFailed("卸载应用")
        }
        do {
            _ = try await readContainerAppsFromGuest()
        } catch {
            if error is CancellationError { throw error }
            throw RuntimeError.uninstallUnconfirmed
        }
    }

    static func mergedContainerCatalog(
        installedPackages: Set<String>,
        existing: [ContainerApp],
        probed: [String: ProbedAppMetadata] = [:],
        iconsDirectoryURL: URL? = nil
    ) -> [ContainerApp] {
        let existingByPackage = Dictionary(uniqueKeysWithValues: existing.map { ($0.package, $0) })
        var seen = Set<String>()
        var result: [ContainerApp] = []

        func buildEntry(for pkg: String, isInstalled: Bool) -> ContainerApp {
            let previous = existingByPackage[pkg]
            let probe = probed[pkg]
            let resolvedVersion: String?
            if let probeVer = probe?.version, !probeVer.isEmpty {
                resolvedVersion = probeVer
            } else if let prevVer = previous?.version, !prevVer.isEmpty {
                resolvedVersion = prevVer
            } else {
                resolvedVersion = nil
            }
            let iconPath = ContainerApp.resolveDefaultIconPath(
                for: pkg,
                iconsDirectoryURL: iconsDirectoryURL
            ) ?? previous?.iconPath
            var entry = ContainerApp.metadata(
                for: pkg,
                version: resolvedVersion,
                isInstalled: isInstalled,
                iconPath: iconPath
            )
            if !ContainerApp.hasCuratedDisplayName(for: pkg) {
                if let probeLabel = probe?.label, !probeLabel.isEmpty {
                    entry.name = probeLabel
                } else if let prevName = previous?.name, !prevName.isEmpty {
                    entry.name = prevName
                }
            }
            return entry
        }

        for pkg in installedPackages.sorted() where !seen.contains(pkg) && !ContainerApp.isInternalPackage(pkg) {
            result.append(buildEntry(for: pkg, isInstalled: true))
            seen.insert(pkg)
        }
        if !seen.contains("com.android.settings") {
            result.append(buildEntry(for: "com.android.settings", isInstalled: true))
        }
        return result
    }

    func openDisplay(
        package: String = DefaultApp.package,
        resolutionPreset: String? = nil,
        tabletMode: Bool? = nil,
        interfaceScale: DisplayInterfaceScale? = nil,
        replaceExisting: Bool = true
    ) async throws -> DisplayEndpoint {
        guard ContainerApp.isValidPackageIdentifier(package) else { throw RuntimeError.displayUnavailable }
        if let closingTask { await closingTask.value }
        if let openingTask {
            if !openingTask.isCancelled, openingDisplayPackage == package, resolutionPreset == nil, tabletMode == nil, interfaceScale == nil {
                return try await openingTask.value
            }
            if replaceExisting || openingDisplayPackage == package {
                openingTask.cancel()
            }
            _ = try? await openingTask.value
            if let closingTask { await closingTask.value }
        }
        openingDisplayPackage = package
        let task = Task { [self] in
            do {
                let result = try await performOpenDisplay(
                    package: package,
                    resolutionPreset: resolutionPreset,
                    tabletMode: tabletMode,
                    interfaceScale: interfaceScale,
                    replaceExisting: replaceExisting
                )
                openingTask = nil
                openingDisplayPackage = nil
                return result
            } catch {
                openingTask = nil
                openingDisplayPackage = nil
                throw error
            }
        }
        openingTask = task
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private func performOpenDisplay(
        package: String,
        resolutionPreset: String?,
        tabletMode: Bool?,
        interfaceScale: DisplayInterfaceScale?,
        replaceExisting: Bool
    ) async throws -> DisplayEndpoint {
        guard state == .ready || state == .running else {
            throw RuntimeError.runtimeNotReady
        }
        let desiredAppPref = containerPreferences.displayPreference(for: package)
        let targetPreset = ContainerPreferences.canonicalResolutionPreset(resolutionPreset ?? desiredAppPref.resolutionPreset)
        let targetTabletMode = tabletMode ?? desiredAppPref.tabletMode
        let targetInterfaceScale = interfaceScale ?? desiredAppPref.interfaceScale

        if replaceExisting {
            if displaySessions.count == 1,
               let existing = displaySessions[package],
               existing.tabletMode == targetTabletMode,
               existing.resolutionPreset == targetPreset,
               existing.interfaceScale == targetInterfaceScale {
                return existing.endpoint
            }
            if !displaySessions.isEmpty {
                await closeDisplayResources()
            }
        } else {
            if let existing = displaySessions[package] {
                if existing.tabletMode == targetTabletMode,
                   existing.resolutionPreset == targetPreset,
                   existing.interfaceScale == targetInterfaceScale {
                    return existing.endpoint
                }
                await closeDisplayResources(forPackage: package)
            } else if displaySessions.count >= Self.maxConcurrentDisplays {
                throw RuntimeError.maxConcurrentDisplaysReached(Self.maxConcurrentDisplays)
            }
        }
        guard !isOpeningDisplay else {
            throw RuntimeError.busy("显示连接")
        }
        isOpeningDisplay = true
        defer { isOpeningDisplay = false }
        try await hooks.beforeOpenDisplay()
        guard state == .ready || state == .running else {
            throw RuntimeError.runtimeNotReady
        }

        let operationGeneration = generation
        let prepared = try makePreparedRuntime()
        let localPort = try hooks.freePort()
        let usedSCIDs = Set(displaySessions.values.map { $0.allocation.scid })
        var scid = hooks.randomSCID()
        for _ in 0..<8 where usedSCIDs.contains(scid) || scid == 0 {
            scid = hooks.randomSCID()
        }
        guard scid != 0 else { throw RuntimeError.displayUnavailable }

        let allocation = try await environmentProvider.allocateForward(
            adbURL: paths.adbURL,
            environment: prepared.environment,
            requestedPort: localPort,
            scid: scid
        )
        guard allocation.serial == connectionPorts.serial,
              RuntimePorts.forwardPortIsReady(
                  allocation.localPort,
                  localHostPortAvailable: hooks.localHostPortAvailable
              ) else {
            try? await environmentProvider.removeForward(
                adbURL: paths.adbURL,
                environment: prepared.environment,
                allocation: allocation
            )
            throw RuntimeError.displayUnavailable
        }

        var launchedHandle: (any OwnedProcessHandle)?
        do {
            guard isOperationCurrent(operationGeneration) else {
                throw CancellationError()
            }
            try await prepareGuestEnvironmentForApp(
                package: package,
                tabletMode: targetTabletMode,
                interfaceScale: targetInterfaceScale,
                operationGeneration: operationGeneration
            )
            guard isOperationCurrent(operationGeneration) else { throw CancellationError() }
            await pluginManager.handleAppLaunching(package: package)
            guard isOperationCurrent(operationGeneration) else { throw CancellationError() }
            if cameraEnabled, package != "com.android.settings" {
                _ = try? await runADB(
                    ["shell", "pm", "grant", package, "android.permission.CAMERA"],
                    operation: "授予应用摄像头权限",
                    timeout: 5
                )
            }
            let imePort = try await prepareDirectInput(operationGeneration: operationGeneration)
            guard isOperationCurrent(operationGeneration) else { throw CancellationError() }
            try await environmentProvider.secureCopy(
                adbURL: paths.adbURL,
                localURL: paths.scrcpyPrivateURL,
                remotePath: "/data/local/tmp/android-use-scrcpy.jar",
                environment: prepared.environment
            )
            try await requireADB(
                ["shell", "chmod", "600", "/data/local/tmp/android-use-scrcpy.jar"],
                operation: "保护显示组件"
            )

            let serverSerial = self.serverSerial + 1
            self.serverSerial = serverSerial
            let prefs = containerPreferences
            let serverCommand = RuntimePorts.commandLine(
                scid: scid,
                resolutionPreset: targetPreset,
                targetFPS: prefs.targetFPS,
                tabletMode: targetTabletMode,
                interfaceScale: targetInterfaceScale
            )
            let handle = try await runner.launch(
                ProcessInvocation(
                    executableURL: paths.adbURL,
                    arguments: adbPrefix() + ["shell", serverCommand],
                    environment: prepared.environment,
                    timeout: 90 * 60,
                    captureOutput: true,
                    outputLimit: 16 * 1024
                ),
                operation: "Android 显示服务"
            ) { [weak self] exit in
                Task { @MainActor in
                    self?.handleServerExit(serial: serverSerial, exit: exit)
                }
            }
            guard isOperationCurrent(operationGeneration),
                  state == .ready || state == .running else {
                await stopProcessesWithoutBlockingMainActor([handle])
                throw CancellationError()
            }
            launchedHandle = handle

            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                try Task.checkCancellation()
                guard isOperationCurrent(operationGeneration) else {
                    throw CancellationError()
                }
                guard handle.isRunning else {
                    throw RuntimeError.displayExited
                }

                do {
                    let listeners = try await runADB(
                        ["shell", "cat", "/proc/net/unix"],
                        operation: "检查显示组件",
                        timeout: 2
                    )
                    if listeners.exitCode == 0,
                       !listeners.timedOut,
                       RuntimePorts.guestSocketIsListening(
                           listeners.stdout,
                           scid: scid
                       ) {
                        guard isOperationCurrent(operationGeneration),
                              handle.isRunning else {
                            throw CancellationError()
                        }
                        await configureVirtualDisplayOrientation(
                            tabletMode: targetTabletMode,
                            operationGeneration: operationGeneration
                        )
                        let endpoint = DisplayEndpoint(
                            port: allocation.localPort,
                            package: package,
                            imePort: imePort
                        )
                        displaySessionOrderCounter &+= 1
                        displaySessions[package] = ActiveDisplaySession(
                            package: package,
                            endpoint: endpoint,
                            allocation: allocation,
                            serverProcess: handle,
                            serverSerial: serverSerial,
                            tabletMode: targetTabletMode,
                            resolutionPreset: targetPreset,
                            interfaceScale: targetInterfaceScale,
                            targetFPS: prefs.targetFPS,
                            openedOrder: displaySessionOrderCounter
                        )
                        updateState(.running)
                        return endpoint
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A transient query failure is retried until the 8-second deadline.
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw RuntimeError.displayUnavailable
        } catch {
            if let launchedHandle {
                await stopProcessesWithoutBlockingMainActor([launchedHandle])
            }
            try? await environmentProvider.removeForward(
                adbURL: paths.adbURL,
                environment: runtimeEnvironment(),
                allocation: allocation
            )
            if displaySessions.isEmpty, let port = inputForwardPort {
                inputForwardPort = nil
                _ = try? await runADB(["forward", "--remove", "tcp:\(port)"], operation: "关闭文字输入通道", timeout: 3)
            }
            throw error
        }
    }

    func closeDisplay(package: String? = nil) async {
        if let closingTask {
            await closingTask.value
            if package == nil || displaySessions[package!] == nil {
                return
            }
        }
        let opening = (package == nil || openingDisplayPackage == package) ? openingTask : nil
        opening?.cancel()
        let task = Task { [self] in
            _ = try? await opening?.value
            if let package {
                await closeDisplayResources(forPackage: package)
            } else {
                await closeDisplayResources()
            }
            closingTask = nil
            if state == .running, displaySessions.isEmpty, openingTask == nil {
                updateState(.ready)
            }
        }
        closingTask = task
        await task.value
    }

    @discardableResult
    func stop() async -> Bool {
        if let stoppingTask { return await stoppingTask.value }
        isStopping = true
        generation &+= 1
        activeOperations.removeAll()
        let preparing = preparingTask; let starting = startingTask
        let installing = installingTask; let opening = openingTask
        let officeKeepAwake = officeKeepAwakeTask
        preparing?.cancel(); starting?.cancel(); installing?.cancel(); opening?.cancel()
        officeKeepAwake?.cancel()
        updateState(.stopping)
        let task = Task { [self] in
            _ = try? await preparing?.value
            _ = try? await starting?.value
            _ = try? await installing?.value
            _ = try? await opening?.value
            _ = await officeKeepAwake?.value
            preparingTask = nil; startingTask = nil; installingTask = nil
            let completed = await cleanUpOwnedRuntime()
            isStopping = false
            updateState(completed ? .stopped : .failed(RuntimeError.stopUnconfirmed.localizedDescription))
            stoppingTask = nil
            return completed
        }
        stoppingTask = task
        return await task.value
    }

    private func validateAndPersistTargetAPK(
        _ url: URL,
        operationGeneration: UInt64
    ) async throws {
        guard state == .stopped || state == .ready || state == .running else {
            throw RuntimeError.busy("APK 安装")
        }
        let paths = paths
        let digester = digester
        let task = Task.detached(priority: .utility) {
            try Self.validateAndPersistTargetAPKFromBackground(
                url,
                paths: paths,
                digester: digester
            )
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        guard generation == operationGeneration, !isStopping else {
            throw CancellationError()
        }
    }

    nonisolated private static func validateAndPersistTargetAPKFromBackground(
        _ url: URL,
        paths: RuntimePaths,
        digester: any SecureDigesting
    ) throws {
        let source = url.standardizedFileURL
        guard source.isFileURL,
              !Self.containsUnresolvedPathComponents(source),
              FileManager.default.isReadableFile(atPath: source.path),
              !Self.isSymbolicLink(source) else {
            throw RuntimeError.installAPKMissing
        }
        guard Self.hasValidZipMagic(at: source) else {
            throw RuntimeError.installAPKHashMismatch
        }
        let sourceDigest = try digester.sha256(fileURL: source)
        let operationFileManager = FileManager()
        let supportDirectory = paths.appSupportURL
        if !operationFileManager.fileExists(atPath: supportDirectory.path) {
            try operationFileManager.createDirectory(
                at: supportDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try operationFileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: supportDirectory.path
        )
        let temporaryDestination = supportDirectory.appendingPathComponent(
            ".imported-app-\(UUID().uuidString).apk"
        )
        do {
            try Task.checkCancellation()
            try operationFileManager.copyItem(at: source, to: temporaryDestination)
            try operationFileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporaryDestination.path
            )
            guard try digester.sha256(fileURL: temporaryDestination) == sourceDigest else {
                throw RuntimeError.installAPKHashMismatch
            }
            try Task.checkCancellation()
            if operationFileManager.fileExists(atPath: paths.apkPrivateURL.path) {
                _ = try operationFileManager.replaceItemAt(
                    paths.apkPrivateURL,
                    withItemAt: temporaryDestination
                )
            } else {
                try operationFileManager.moveItem(
                    at: temporaryDestination,
                    to: paths.apkPrivateURL
                )
            }
            try operationFileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: paths.apkPrivateURL.path
            )
        } catch {
            try? operationFileManager.removeItem(at: temporaryDestination)
            throw error
        }
    }

    nonisolated private static func hasValidZipMagic(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4), header.count == 4 else { return false }
        return header == Data([0x50, 0x4B, 0x03, 0x04])
    }

    func targetPresence(package: String = DefaultApp.package) async -> TargetPresence {
        guard isPrepared, state == .ready || state == .running else {
            return .unavailable
        }
        do {
            let activity = try await runADB(
                ["shell", "dumpsys", "activity", "activities"],
                operation: "检查应用任务",
                timeout: 20
            )
            guard activity.exitCode == 0, !activity.timedOut else {
                return .unavailable
            }
            if !RuntimePresenceParser.hasUnavailableMarker(activity.stdout),
               RuntimePresenceParser.hasTargetVisible(activity.stdout, package: package) {
                return .visible
            }

            let window = try await runADB(
                ["shell", "dumpsys", "window", "displays"],
                operation: "检查系统交互",
                timeout: 20
            )
            return RuntimePresenceParser.resolve(
                activity.stdout,
                window: window.exitCode == 0 && !window.timedOut ? window.stdout : nil,
                package: package
            )
        } catch {
            return .unavailable
        }
    }

    func sampleTelemetry(
        presentedFPS: Double = 0,
        frameIntervalP95Ms: Double = 0,
        hardwareDecoder: Bool = true,
        activeAppName: String? = nil,
        activePackage: String? = nil
    ) -> ContainerTelemetry {
        let now = ProcessInfo.processInfo.systemUptime
        let hostPID = getpid()
        let hostMetric = sampleProcessMetric(
            pid: hostPID,
            name: "应用窗口服务",
            role: "桌面窗口与图形加速渲染",
            now: now
        )
        let adbPID = adbServerProcess?.processIdentifier
        let adbMetric = sampleProcessMetric(
            pid: adbPID,
            name: "本地连接服务",
            role: "应用状态与指令同步",
            now: now
        )
        let emuPID = resolveOwnedQEMUPID() ?? emulatorProcess?.processIdentifier
        let emuMetric = sampleProcessMetric(
            pid: emuPID,
            name: "核心运行引擎",
            role: "Apple Silicon 硬件加速环境",
            now: now
        )
        let scrcpyPID = serverProcess?.processIdentifier
        let scrcpyMetric = sampleProcessMetric(
            pid: scrcpyPID,
            name: "画面与触控服务",
            role: "高帧率画面传输与输入响应",
            now: now
        )
        let processes = [emuMetric, hostMetric, adbMetric, scrcpyMetric]
        let totalCPU = processes.reduce(0) { $0 + $1.cpuPercent }
        let totalRSS = processes.reduce(0) { $0 + $1.rssMiB }
        return ContainerTelemetry(
            totalCPUPercent: totalCPU,
            emulatorCPUPercent: emuMetric.cpuPercent,
            hostClientCPUPercent: hostMetric.cpuPercent,
            totalRSSMiB: totalRSS,
            emulatorRSSMiB: emuMetric.rssMiB,
            hostClientRSSMiB: hostMetric.rssMiB,
            guestMemoryBudgetMiB: 6144,
            diskUsedGB: sampleDiskUsageGB(now: now),
            presentedFPS: presentedFPS,
            frameIntervalP95Ms: frameIntervalP95Ms,
            hardwareDecoder: hardwareDecoder,
            activeAppName: activeAppName,
            activePackage: activePackage,
            processes: processes
        )
    }

    private func resolveOwnedQEMUPID() -> Int32? {
        if let pid = emulatorProcess?.processIdentifier, pid > 0 {
            return pid
        }
        for (pid, path) in findOwnedRuntimeProcesses() where path.contains("qemu-system") || path.hasSuffix("/emulator") {
            return pid
        }
        return nil
    }

    private func findOwnedRuntimeProcesses() -> [(pid: Int32, path: String)] {
        let runtimePrefix = paths.runtimeURL.standardizedFileURL.path + "/"
        var byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(byteCount) / MemoryLayout<Int32>.stride + 32)
        byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<Int32>.stride))
        guard byteCount > 0 else { return [] }
        let count = Int(byteCount) / MemoryLayout<Int32>.stride
        var results: [(Int32, String)] = []
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for index in 0..<count {
            let pid = pids[index]
            guard pid > 0, pid != getpid() else { continue }
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }
            let path = String(cString: buffer)
            if path.hasPrefix(runtimePrefix) {
                results.append((pid, path))
            }
        }
        return results
    }

    private func reclaimStaleOwnedEmulatorIfNeeded() async {
        let stale = findOwnedRuntimeProcesses().filter {
            $0.path.contains("qemu-system") || $0.path.hasSuffix("/emulator") || $0.path.hasSuffix("/netsimd")
        }
        guard !stale.isEmpty else { return }
        for item in stale {
            _ = Darwin.kill(item.pid, SIGTERM)
        }
        for _ in 0..<25 {
            if environmentProvider.portIsAvailable(emulatorPort) { return }
            try? await Task.sleep(for: .milliseconds(120))
        }
        for item in stale {
            _ = Darwin.kill(item.pid, SIGKILL)
        }
        for _ in 0..<15 {
            if environmentProvider.portIsAvailable(emulatorPort) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func reclaimStaleOwnedADBIfNeeded() async {
        let stale = findOwnedRuntimeProcesses().filter {
            $0.path.hasSuffix("/adb")
        }
        guard !stale.isEmpty else { return }
        for item in stale {
            _ = Darwin.kill(item.pid, SIGTERM)
        }
        for _ in 0..<20 {
            if environmentProvider.portIsAvailable(adbPort) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        for item in stale {
            _ = Darwin.kill(item.pid, SIGKILL)
        }
        for _ in 0..<15 {
            if environmentProvider.portIsAvailable(adbPort) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func sampleProcessMetric(
        pid: Int32?,
        name: String,
        role: String,
        now: TimeInterval
    ) -> ContainerProcessMetric {
        guard let pid, pid > 0 else {
            return ContainerProcessMetric(name: name, role: role, pid: nil, cpuPercent: 0, rssMiB: 0, status: "未运行")
        }
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        let ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        guard ret == size else {
            return ContainerProcessMetric(name: name, role: role, pid: nil, cpuPercent: 0, rssMiB: 0, status: "未运行")
        }
        let rssMiB = Double(info.pti_resident_size) / (1024.0 * 1024.0)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = info.pti_total_user &+ info.pti_total_system
        let totalNs = ticks &* UInt64(max(1, timebase.numer)) / UInt64(max(1, timebase.denom))
        var cpuPercent = 0.0
        if let previous = cpuSampleTimes[pid], now > previous.wallTime + 0.05, totalNs >= previous.totalNs {
            let deltaSeconds = Double(totalNs - previous.totalNs) / 1_000_000_000.0
            let wallDelta = now - previous.wallTime
            cpuPercent = min(800.0, max(0.0, (deltaSeconds / wallDelta) * 100.0))
        }
        cpuSampleTimes[pid] = (totalNs: totalNs, wallTime: now)
        return ContainerProcessMetric(name: name, role: role, pid: pid, cpuPercent: cpuPercent, rssMiB: rssMiB, status: "运行中")
    }

    private func sampleDiskUsageGB(now: TimeInterval) -> Double {
        if let cached = cachedDiskUsageGB, now - cached.timestamp < 30.0 {
            return cached.value
        }
        if !diskUsageRefreshInFlight {
            diskUsageRefreshInFlight = true
            let rootURL = paths.rootURL
            Task { @MainActor [weak self] in
                let gb = await Task.detached(priority: .utility) {
                    Self.computeDirectorySizeGB(at: rootURL)
                }.value
                self?.cachedDiskUsageGB = (value: gb, timestamp: ProcessInfo.processInfo.systemUptime)
                self?.diskUsageRefreshInFlight = false
            }
        }
        return cachedDiskUsageGB?.value ?? (isPrepared ? 5.38 : 0.0)
    }

    nonisolated private static func computeDirectorySizeGB(at rootURL: URL) -> Double {
        var totalBytes: UInt64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        if let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) {
            while let item = enumerator.nextObject() as? URL {
                if let values = try? item.resourceValues(forKeys: Set(keys)) {
                    let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
                    totalBytes &+= UInt64(max(0, size))
                }
            }
        }
        return Double(totalBytes) / 1_000_000_000.0
    }

    private func performPrepare() async throws {
        let downloadOperation = UUID()
        environmentDownloadOperation = downloadOperation
        var resolution = RuntimeDependencyResolution(seed: seed, temporaryDirectory: nil)
        defer {
            environmentDownloadOperation = nil
            resolution.cleanup()
            onEnvironmentDownloadProgress?(nil)
        }
        if let dependencyInstaller {
            let currentGeneration = generation
            resolution = try await dependencyInstaller.resolve(seed: seed, paths: paths) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == currentGeneration,
                          self.environmentDownloadOperation == downloadOperation,
                          case .preparing = self.state else { return }
                    self.onEnvironmentDownloadProgress?(progress)
                }
            }
        }
        let preparation = RuntimePreparation(
            paths: paths,
            seed: resolution.seed,
            fileManager: fileManager,
            digester: digester,
            hooks: hooks
        )
        let task = Task.detached(priority: .utility) {
            try preparation.perform()
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performStart(
        prepared: PreparedRuntime,
        operationGeneration: UInt64
    ) async throws {
        try await launchOwnedADBServer(environment: prepared.environment)
        guard isOperationCurrent(operationGeneration), !isStopping else {
            throw CancellationError()
        }
        try ensureAVDGPUConfiguration()

        let launchSerial = emulatorSerial + 1
        emulatorSerial = launchSerial
        let launchCameraEnabled = cameraEnabled
        bootedCameraEnabled = launchCameraEnabled
        var emulatorEnvironment = prepared.environment
        if launchCameraEnabled, fileManager.fileExists(atPath: paths.cameraSyncDylibURL.path) {
            emulatorEnvironment["DYLD_INSERT_LIBRARIES"] = paths.cameraSyncDylibURL.path
        }
        emulatorEnvironment["ANDROID_EMU_VK_ICD"] = "moltenvk"
        emulatorEnvironment["MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS"] = "0"
        emulatorEnvironment["MVK_CONFIG_SHOULD_MAXIMIZE_CONCURRENT_COMPILATION"] = "1"
        emulatorEnvironment["MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS"] = "0"
        emulatorEnvironment["MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS"] = "0"
        var launchArguments = [
            "-avd", "android-use",
            "-port", String(emulatorPort),
            "-no-window",
            "-gpu", "host",
            "-no-metrics",
            "-no-snapshot",
            "-no-boot-anim",
            "-no-audio",
            "-feature", "Vulkan",
            "-feature", "GLDirectMem",
            "-feature", "GLESDynamicVersion",
            "-feature", "VirtioGpuNativeSync",
            "-feature", "VirtioGpuNext",
            "-feature", "HasSharedSlotsHostMemoryAllocator",
            "-feature", "VulkanQueueSubmitWithCommands",
            "-feature", "VulkanBatchedDescriptorSetUpdate",
            "-feature", "VulkanShaderFloat16Int8",
            "-feature", "VulkanAstcLdrEmulation",
            "-feature", "VulkanEtc2Emulation",
            "-feature", "VulkanVirtualQueue",
            "-feature", "-NoDelayCloseColorBuffer",
            "-feature", "-GLPipeChecksum"
        ]
        let disablesGuestAngle = emulatorEnvironment["ANDROID_USE_FORCE_GUEST_ANGLE"] == "0"
            || emulatorEnvironment["ANDROID_USE_GUEST_GL_BACKEND"] == "translator"
        let enablesGuestAngle = emulatorEnvironment["ANDROID_USE_FORCE_GUEST_ANGLE"] == "1"
            || emulatorEnvironment["ANDROID_USE_GUEST_GL_BACKEND"] == "angle"
        if enablesGuestAngle && !disablesGuestAngle {
            launchArguments += [
                "-feature", "GuestAngle",
                "-prop", "androidboot.hardware.egl=angle"
            ]
        } else {
            launchArguments += ["-feature", "-GuestAngle", "-prop", "androidboot.hardware.egl=emulation"]
        }
        launchArguments += [
            "-camera-back",
            launchCameraEnabled ? "emulated" : "none",
            "-camera-front",
            launchCameraEnabled ? "webcam0" : "none"
        ]
        let launched = try await runner.launch(
            ProcessInvocation(
                executableURL: emitterPath(),
                arguments: launchArguments,
                environment: emulatorEnvironment,
                timeout: 90 * 60,
                captureOutput: true,
                outputLimit: 16 * 1024
            ),
            operation: "Android 环境"
        ) { [weak self] exit in
            Task { @MainActor in
                self?.handleEmulatorExit(serial: launchSerial, exit: exit)
            }
        }
        emulatorProcess = launched

        let deadline = Date().addingTimeInterval(90)
        var observedBootComplete = false
        var observedNetworkReady = false
        while Date() < deadline {
            try Task.checkCancellation()
            guard isOperationCurrent(operationGeneration), !isStopping else {
                throw CancellationError()
            }
            guard self.liveEmulatorProcess(for: launchSerial)?.isRunning == true else {
                throw RuntimeError.emulatorExited
            }
            guard adbServerProcess?.isRunning == true else { throw RuntimeError.adbCommandFailed("私有 ADB") }
            do {
                let result = try await runADB(
                    ["get-state"],
                    operation: "检查 Android 设备",
                    timeout: 3
                )
                if result.exitCode == 0, !result.timedOut,
                   String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "device" {
                    let boot = try await runADB(
                        ["shell", "getprop", "sys.boot_completed"],
                        operation: "检查 Android 启动",
                        timeout: 3
                    )
                    if boot.exitCode == 0,
                       String(decoding: boot.stdout, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                        observedBootComplete = true
                        // Boot completion precedes the first connected default network.
                        // Prepare the guest while both boot and connectivity are ready.
                        let network = try await runADB(
                            ["shell", "dumpsys", "connectivity"],
                            operation: "检查 Android 网络",
                            timeout: 3
                        )
                        if network.exitCode == 0, !network.timedOut,
                           RuntimeNetworkParser.hasConnectedInternetDefaultNetwork(network.stdout) {
                            observedNetworkReady = true
                            guard isOperationCurrent(operationGeneration), !isStopping else {
                                throw CancellationError()
                            }
                            try await prepareGuestEnvironmentForApp(
                                package: DefaultApp.package,
                                updateDefaultDisplayGeometry: true,
                                operationGeneration: operationGeneration
                            )
                            guard isOperationCurrent(operationGeneration), !isStopping else {
                                throw CancellationError()
                            }
                            _ = await reconcileOfficeKeepAwake()
                            guard isOperationCurrent(operationGeneration), !isStopping else {
                                throw CancellationError()
                            }
                            updateState(.ready)
                            await pluginManager.handleRuntimeBecameReady()
                            return
                        }
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                if observedNetworkReady {
                    throw error
                }
                // Transport registration and first-boot setup are transient within
                // the one 90-second boot deadline, rather than a separate 10s failure.
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw observedBootComplete ? RuntimeError.networkNotReady : RuntimeError.bootTimedOut
    }

    nonisolated static let requiredAVDGPUConfigLines = [
        "hw.lcd.vsync=60",
        "hw.gltransport=virtio-gpu-asg",
        "hw.gltransport.asg.writeBufferSize=1048576",
        "hw.gltransport.asg.writeStepSize=262144",
        "hw.gltransport.asg.dataRingSize=524288",
        "hw.gltransport.drawFlushInterval=10000"
    ]

    nonisolated static func hasRequiredAVDGPUConfiguration(_ configText: String) -> Bool {
        hasRequiredAVDConfigurationValues(
            configText,
            required: requiredAVDGPUConfiguration
        )
    }

    nonisolated static func hasRequiredAVDConfigurationValues(
        _ configText: String,
        required: [(key: String, value: String)]
    ) -> Bool {
        var valuesByKey: [String: [String]] = [:]
        for line in configText.components(separatedBy: "\n") {
            guard let entry = activeAVDConfigurationEntry(in: line) else { continue }
            valuesByKey[entry.key, default: []].append(entry.value)
        }
        return required.allSatisfy {
            valuesByKey[$0.key] == [$0.value]
        }
    }

    nonisolated static func normalizedAVDConfiguration(
        _ configText: String,
        required: [(key: String, value: String)]
    ) -> String {
        let requiredByKey = Dictionary(uniqueKeysWithValues: required.map { ($0.key, $0.value) })
        let newline = configText.contains("\r\n") ? "\r\n" : "\n"
        var lines = configText.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }
        var output: [String] = []
        var emitted = Set<String>()
        for rawLine in lines {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if let entry = activeAVDConfigurationEntry(in: line),
               let requiredValue = requiredByKey[entry.key] {
                if emitted.insert(entry.key).inserted {
                    output.append("\(entry.key)=\(requiredValue)")
                }
            } else {
                output.append(line)
            }
        }
        for item in required where !emitted.contains(item.key) {
            output.append("\(item.key)=\(item.value)")
        }
        return output.joined(separator: newline) + newline
    }

    nonisolated static func normalizedAVDGPUConfiguration(_ configText: String) -> String {
        normalizedAVDConfiguration(
            configText,
            required: requiredAVDGPUConfiguration
        )
    }

    nonisolated static func repairAVDGPUConfiguration(
        configURL: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: configURL.path) else { return }
        let existing = try String(contentsOf: configURL, encoding: .utf8)
        guard !hasRequiredAVDGPUConfiguration(existing) else { return }

        let normalized = normalizedAVDGPUConfiguration(existing)
        guard hasRequiredAVDGPUConfiguration(normalized), normalized != existing else {
            throw RuntimeError.invalidSeed("AVD GPU 配置规范化未通过")
        }

        // Keep the invalid config until cache invalidation succeeds. Otherwise a
        // later readiness check could accept a config whose stale cache survived.
        try invalidateAVDCache(
            at: configURL.deletingLastPathComponent(),
            fileManager: fileManager
        )
        try Data(normalized.utf8).write(to: configURL, options: .atomic)
        let verified = try String(contentsOf: configURL, encoding: .utf8)
        guard hasRequiredAVDGPUConfiguration(verified) else {
            throw RuntimeError.invalidSeed("AVD GPU 配置校验未通过")
        }
    }

    nonisolated static func invalidateAVDCache(
        at avdURL: URL,
        fileManager: FileManager
    ) throws {
        for stale in ["hardware-qemu.ini", "initrd", "bootconfig.ini"] {
            let staleURL = avdURL.appendingPathComponent(stale)
            do {
                try fileManager.removeItem(at: staleURL)
            } catch {
                guard isMissingFileError(error as NSError) else {
                    throw RuntimeError.invalidSeed("AVD GPU 缓存清理失败")
                }
            }
            guard !fileManager.fileExists(atPath: staleURL.path) else {
                throw RuntimeError.invalidSeed("AVD GPU 缓存清理失败")
            }
        }
    }

    nonisolated private static var requiredAVDGPUConfiguration: [(key: String, value: String)] {
        requiredAVDGPUConfigLines.compactMap { line in
            guard let entry = activeAVDConfigurationEntry(in: line) else { return nil }
            return (entry.key, entry.value)
        }
    }

    nonisolated private static func activeAVDConfigurationEntry(
        in line: String
    ) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("#"),
              !trimmed.hasPrefix(";"),
              let separator = trimmed.firstIndex(of: "=") else {
            return nil
        }
        let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
        let value = trimmed[trimmed.index(after: separator)...]
            .trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    nonisolated private static func isMissingFileError(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain,
           error.code == CocoaError.fileNoSuchFile.rawValue {
            return true
        }
        if error.domain == NSPOSIXErrorDomain,
           error.code == Int(ENOENT) {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isMissingFileError(underlying)
        }
        return false
    }

    private func ensureAVDGPUConfiguration() throws {
        let configURL = paths.avdURL.appendingPathComponent("config.ini")
        try Self.repairAVDGPUConfiguration(
            configURL: configURL,
            fileManager: fileManager
        )
    }

    private func launchOwnedADBServer(
        environment: [String: String]
    ) async throws {
        if let adbServerProcess,
           await processTerminator.terminateAndWait(
               adbServerProcess,
               timeout: 2
           ) {
            self.adbServerProcess = nil
        }
        if !environmentProvider.portIsAvailable(adbPort),
           environmentProvider is SystemControllerEnvironment {
            await reclaimStaleOwnedADBIfNeeded()
        }
        guard environmentProvider.portIsAvailable(adbPort) else {
            throw RuntimeError.portInUse(adbPort)
        }
        let serial = adbServerSerial + 1
        adbServerSerial = serial
        let handle = try await runner.launch(
            ProcessInvocation(
                executableURL: paths.adbURL,
                arguments: [
                    "-L", "tcp:\(adbPort)",
                    "server", "nodaemon"
                ],
                environment: environment,
                timeout: 90 * 60,
                captureOutput: true,
                outputLimit: 16 * 1024
            ),
            operation: "私有 ADB"
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      self.adbServerSerial == serial,
                      self.adbServerProcess?.isRunning != true else {
                    return
                }
                self.adbServerProcess = nil
            }
        }
        adbServerProcess = handle

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            try Task.checkCancellation()
            guard handle.isRunning else {
                adbServerProcess = nil
                throw RuntimeError.adbCommandFailed("启动私有 ADB")
            }
            if !environmentProvider.portIsAvailable(adbPort) {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        adbServerProcess = nil
        await stopProcessesWithoutBlockingMainActor([handle])
        throw RuntimeError.adbCommandFailed("启动私有 ADB")
    }

    private func makePreparedRuntime() throws -> PreparedRuntime {
        try ensurePrivateDirectory(paths.rootURL)
        try ensurePrivateDirectory(paths.androidUserHomeURL)
        try ensurePrivateDirectory(paths.androidEmulatorHomeURL)
        try ensurePrivateDirectory(paths.avdHomeURL)
        try ensurePrivateDirectory(paths.appSupportURL)
        try ensurePrivateDirectory(paths.androidRootURL)
        try ensurePrivateDirectory(paths.adbKeysURL)
        return PreparedRuntime(
            paths: paths,
            environment: runtimeEnvironment(),
            runID: UUID()
        )
    }

    private func runtimeEnvironment() -> [String: String] {
        var environment = environmentProvider.environment()
        environment["ANDROID_USER_HOME"] = paths.androidUserHomeURL.path
        environment["ANDROID_EMULATOR_HOME"] = paths.androidEmulatorHomeURL.path
        environment["ANDROID_AVD_HOME"] = paths.avdHomeURL.path
        environment["ADB_SERVER_SOCKET"] = "tcp:127.0.0.1:\(adbPort)"
        environment["ANDROID_ADB_SERVER_PORT"] = String(adbPort)
        return environment
    }

    func adbPrefix() -> [String] {
        // An explicit host makes the client fail if the owned server is gone,
        // instead of auto-starting an unowned daemon during cancellation/exit.
        ["-H", "127.0.0.1", "-P", String(adbPort), "-s", connectionPorts.serial]
    }

    private func prepareDirectInput(operationGeneration: UInt64) async throws -> UInt16 {
        func checkOperation() throws {
            guard isOperationCurrent(operationGeneration), adbServerProcess?.isRunning == true else { throw CancellationError() }
        }
        try checkOperation()
        if !inputHelperInstalled {
            guard fileManager.isReadableFile(atPath: paths.inputHelperURL.path) else { throw RuntimeError.invalidSeed("输入组件") }
            try await installAndEnableInputHelperAPK(
                selectAsDefaultIME: containerPreferences.directIMEEnabled,
                operationGeneration: operationGeneration
            )
            try checkOperation()
        }
        if let existingPort = inputForwardPort,
           RuntimePorts.forwardPortIsReady(existingPort, localHostPortAvailable: hooks.localHostPortAvailable) {
            try checkOperation()
            return existingPort
        }
        let port = try hooks.freePort()
        try await requireADB(["forward", "--no-rebind", "tcp:\(port)", "localabstract:androiduse_ime_v1"], operation: "连接本地文字输入")
        inputForwardPort = port
        try checkOperation()
        return port
    }

    private func installAndEnableInputHelperAPK(
        selectAsDefaultIME: Bool? = nil,
        operationGeneration: UInt64? = nil
    ) async throws {
        let shouldSelectIME = selectAsDefaultIME ?? containerPreferences.directIMEEnabled
        if let existingTask = inputHelperInstallTask {
            try await existingTask.value
            if shouldSelectIME {
                try await requireADB(["shell", "ime", "set", "local.androiduse.ime/.DirectCommitImeService"], operation: "选择本地输入组件")
            }
            return
        }
        let gen = operationGeneration ?? generation
        let task = Task { @MainActor [self] in
            defer { self.inputHelperInstallTask = nil }
            guard self.isOperationCurrent(gen), self.adbServerProcess?.isRunning == true else {
                throw CancellationError()
            }
            let firstInstall: ProcessResult?
            do {
                firstInstall = try await self.runADB(["install", "-r", self.paths.inputHelperURL.path], operation: "准备本地输入组件", timeout: 30)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                firstInstall = nil
            }
            try Task.checkCancellation()
            guard self.isOperationCurrent(gen), self.adbServerProcess?.isRunning == true else {
                throw CancellationError()
            }
            if firstInstall?.exitCode != 0 || firstInstall?.timedOut == true {
                let combinedError = firstInstall?.combinedOutputUTF8 ?? ""
                let isSignatureOrDowngradeConflict =
                    combinedError.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") ||
                    combinedError.contains("INSTALL_PARSE_FAILED_INCONSISTENT_CERTIFICATES") ||
                    combinedError.contains("INSTALL_FAILED_VERSION_DOWNGRADE")
                if isSignatureOrDowngradeConflict || firstInstall?.exitCode != 0 {
                    _ = try? await self.runADB(["uninstall", "local.androiduse.ime"], operation: "重置本地输入组件", timeout: 10)
                    try Task.checkCancellation()
                    guard self.isOperationCurrent(gen), self.adbServerProcess?.isRunning == true else {
                        throw CancellationError()
                    }
                }
                try await self.requireADB(["install", "-r", self.paths.inputHelperURL.path], operation: "准备本地输入组件")
            }
            try Task.checkCancellation()
            guard self.isOperationCurrent(gen), self.adbServerProcess?.isRunning == true else {
                throw CancellationError()
            }
            try await self.requireADB(["shell", "ime", "enable", "local.androiduse.ime/.DirectCommitImeService"], operation: "启用本地输入组件")
            if shouldSelectIME {
                try Task.checkCancellation()
                guard self.isOperationCurrent(gen), self.adbServerProcess?.isRunning == true else {
                    throw CancellationError()
                }
                try await self.requireADB(["shell", "ime", "set", "local.androiduse.ime/.DirectCommitImeService"], operation: "选择本地输入组件")
            }
            self.inputHelperInstalled = true
        }
        inputHelperInstallTask = task
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func prepareGuestEnvironmentForApp(
        package: String,
        tabletMode: Bool? = nil,
        interfaceScale: DisplayInterfaceScale? = nil,
        updateDefaultDisplayGeometry: Bool = false,
        operationGeneration: UInt64
    ) async throws {
        if let existingTask = guestEnvironmentTask {
            _ = try? await existingTask.value
        }
        guard isOperationCurrent(operationGeneration), adbServerProcess?.isRunning == true else {
            throw CancellationError()
        }
        let globalPref = containerPreferences
        let desiredPref = globalPref.displayPreference(for: package)
        let isHorizontal = tabletMode ?? (updateDefaultDisplayGeometry ? globalPref.tabletMode : desiredPref.tabletMode)
        let ignoreOrientation = "true"
        let compatAction = "enable"
        let resolvedScale = interfaceScale ?? (updateDefaultDisplayGeometry ? globalPref.interfaceScale : desiredPref.interfaceScale)
        let pixelSize = resolvedScale.nativePixelSize(tabletMode: isHorizontal)
        let dpi = resolvedScale.nativeDPI
        let d0Size = "\(Int(pixelSize.width))x\(Int(pixelSize.height))"
        let d0Density = "\(dpi)"
        let d0Commands = updateDefaultDisplayGeometry
            ? """
            wm size \(d0Size) -d 0 >/dev/null 2>&1 || true
            wm density \(d0Density) -d 0 >/dev/null 2>&1 || true
            """
            : ""
        let identityScript = RuntimeSoftwareDefaults.guestDeviceIdentityScript()
        let script = """
        \(identityScript)
        \(RuntimeSoftwareDefaults.guestSetupScript)
        wm dismiss-keyguard >/dev/null 2>&1 || true
        wm set-ignore-orientation-request \(ignoreOrientation) >/dev/null 2>&1 || true
        \(d0Commands)
        am compat \(compatAction) --no-kill FORCE_RESIZE_APP \(package) >/dev/null 2>&1 || true
        am compat \(compatAction) --no-kill OVERRIDE_ANY_ORIENTATION \(package) >/dev/null 2>&1 || true
        am compat \(compatAction) --no-kill OVERRIDE_ANY_ORIENTATION_TO_USER \(package) >/dev/null 2>&1 || true
        if [ "\(package)" = "com.android.settings" ]; then
          am compat \(compatAction) --no-kill FORCE_RESIZE_APP com.android.settings.intelligence >/dev/null 2>&1 || true
          am compat \(compatAction) --no-kill OVERRIDE_ANY_ORIENTATION com.android.settings.intelligence >/dev/null 2>&1 || true
          am compat \(compatAction) --no-kill OVERRIDE_ANY_ORIENTATION_TO_USER com.android.settings.intelligence >/dev/null 2>&1 || true
        fi
        pm grant \(package) android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
        pm grant \(package) android.permission.CAMERA >/dev/null 2>&1 || true
        if pm path local.androiduse.ime >/dev/null 2>&1; then
          ime enable local.androiduse.ime/.DirectCommitImeService >/dev/null 2>&1 || true
          ime set local.androiduse.ime/.DirectCommitImeService >/dev/null 2>&1 || true
        fi
        """
        let task = Task<Void, Error> { [self] in
            let result = try await self.runADB(["shell", script], operation: "配置应用运行环境", timeout: 25)
            guard result.exitCode == 0, !result.timedOut else {
                throw RuntimeError.adbCommandFailed("配置应用运行环境")
            }
        }
        guestEnvironmentTask = task
        defer {
            if guestEnvironmentTask == task {
                guestEnvironmentTask = nil
            }
        }
        try await task.value
    }

    @discardableResult
    func applyGuestDeviceFormFactor(tabletMode: Bool) async -> Bool {
        guard isPrepared, state == .ready || state == .running, adbServerProcess?.isRunning == true else { return false }
        let pkg = activeDisplayPackage ?? DefaultApp.package
        do {
            try await prepareGuestEnvironmentForApp(
                package: pkg,
                tabletMode: tabletMode,
                updateDefaultDisplayGeometry: displaySessions.isEmpty,
                operationGeneration: generation
            )
            return true
        } catch {
            return false
        }
    }

    func configureVirtualDisplayOrientation(
        tabletMode: Bool,
        operationGeneration: UInt64? = nil
    ) async {
        let gen = operationGeneration ?? generation
        guard isOperationCurrent(gen), adbServerProcess?.isRunning == true else { return }
        let ignoreFlag = "true"
        let fixedRotation = "enabled"
        let script = """
        for d in $(dumpsys window displays 2>/dev/null | sed -n 's/.*mDisplayId=\\([0-9][0-9]*\\).*/\\1/p'); do
          if [ "$d" != "0" ]; then
            wm fixed-to-user-rotation -d "$d" \(fixedRotation) >/dev/null 2>&1 || true
            wm set-ignore-orientation-request -d "$d" \(ignoreFlag) >/dev/null 2>&1 || true
            wm user-rotation -d "$d" lock 0 >/dev/null 2>&1 || true
          fi
        done
        """
        _ = try? await runADB(["shell", script], operation: "配置显示方向", timeout: 3)
    }

    private func adbInstallArguments() -> [String] {
        ["install", "-r", paths.apkPrivateURL.path]
    }

    private func runADB(
        _ subcommand: [String],
        operation: String,
        timeout: TimeInterval,
        outputLimit: Int = 128 * 1024
    ) async throws -> ProcessResult {
        let invocation = ProcessInvocation(
            executableURL: paths.adbURL,
            arguments: adbPrefix() + subcommand,
            environment: runtimeEnvironment(),
            timeout: timeout,
            captureOutput: true,
            outputLimit: outputLimit
        )
        let result = try await runner.run(invocation)
        guard !result.timedOut else { throw RuntimeError.adbTimedOut(operation) }
        return result
    }

    private func requireADB(_ arguments: [String], operation: String) async throws {
        let result = try await runADB(arguments, operation: operation, timeout: 30)
        guard result.exitCode == 0, !result.timedOut else {
            throw RuntimeError.adbCommandFailed(operation)
        }
    }

    private func emitterPath() -> URL {
        paths.runtimeURL.appendingPathComponent("emulator/emulator")
    }

    private func handleEmulatorExit(
        serial: UInt64,
        exit: ProcessExit
    ) {
        guard serial == emulatorSerial,
              emulatorProcess?.isRunning != true else {
            return
        }
        emulatorProcess = nil
        holdOfficeKeepAwakeActivity(false)
        setOfficeKeepAwakePhase(officeKeepAwakePreferences.enabled ? .waitingForRuntime : .off)
        bootedCameraEnabled = nil
        inputHelperInstalled = false
        inputHelperInstallTask?.cancel()
        inputHelperInstallTask = nil
        Task { @MainActor [weak self] in
            await self?.pluginManager.handleRuntimeStopping()
        }
        guard !isStopping, state != .stopped else { return }
        if state == .ready || state == .running {
            if displayEndpoint != nil {
                onDisplayTerminated?()
            }
            updateState(.failed(RuntimeError.emulatorExited.errorDescription ?? "Android 环境已结束。"))
        }
    }

    private func liveEmulatorProcess(
        for serial: UInt64
    ) -> (any OwnedProcessHandle)? {
        guard serial == emulatorSerial,
              emulatorProcess?.isRunning == true else {
            return nil
        }
        return emulatorProcess
    }

    private func handleServerExit(serial: UInt64, exit: ProcessExit) {
        guard let matched = displaySessions.values.first(where: { $0.serverSerial == serial }) else {
            return
        }
        displaySessions.removeValue(forKey: matched.package)
        let allocation = matched.allocation
        let remainingEmpty = displaySessions.isEmpty
        let imePortToRemove: UInt16? = remainingEmpty ? inputForwardPort : nil
        if remainingEmpty {
            inputForwardPort = nil
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let imePortToRemove {
                _ = try? await self.runADB(["forward", "--remove", "tcp:\(imePortToRemove)"], operation: "关闭文字输入通道", timeout: 3)
            }
            try? await self.environmentProvider.removeForward(
                adbURL: self.paths.adbURL,
                environment: self.runtimeEnvironment(),
                allocation: allocation
            )
        }
        onPackageDisplayTerminated?(matched.package)
        onDisplayTerminated?()
        if displaySessions.isEmpty {
            if state == .running {
                updateState(.ready)
            } else if state == .starting {
                updateState(.failed(RuntimeError.displayExited.errorDescription ?? "Android 显示服务已结束。"))
            }
        }
    }

    private func closeDisplayResources(forPackage package: String? = nil) async {
        // Detach the requested session(s) before the first suspension. A later session
        // never becomes the resource set of a previously requested close.
        let sessionsToClose: [ActiveDisplaySession]
        if let package {
            if let removed = displaySessions.removeValue(forKey: package) {
                sessionsToClose = [removed]
            } else {
                sessionsToClose = []
            }
        } else {
            sessionsToClose = Array(displaySessions.values)
            displaySessions.removeAll()
        }
        let portToRemove: UInt16?
        if displaySessions.isEmpty {
            portToRemove = inputForwardPort
            inputForwardPort = nil
        } else {
            portToRemove = nil
        }
        serverSerial &+= 1
        if let port = portToRemove {
            _ = try? await runADB(["forward", "--remove", "tcp:\(port)"], operation: "关闭文字输入通道", timeout: 3)
        }
        let servers = sessionsToClose.map(\.serverProcess)
        if !servers.isEmpty {
            await stopProcessesWithoutBlockingMainActor(servers)
        }
        for session in sessionsToClose {
            do {
                try await environmentProvider.removeForward(
                    adbURL: paths.adbURL,
                    environment: runtimeEnvironment(),
                    allocation: session.allocation
                )
            } catch {
                // The server is already gone if the private ADB forward could not be removed.
            }
        }
    }

    @discardableResult
    private func stopProcessesWithoutBlockingMainActor(
        _ handles: [any OwnedProcessHandle]
    ) async -> Bool {
        var complete = true
        for handle in handles {
            let exited = await processTerminator.terminateAndWait(handle, timeout: 2)
            if !exited && handle.isRunning {
                complete = false
                if !unreapedProcesses.contains(where: { $0 === handle }) { unreapedProcesses.append(handle) }
            }
        }
        return complete
    }

    private func waitForOwnedProcessesToExit(
        _ handles: [any OwnedProcessHandle]
    ) async {
        guard !handles.isEmpty else { return }
        await Task.detached(priority: .utility) {
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline,
                  handles.contains(where: { $0.isRunning }) {
                try? await Task.sleep(for: .milliseconds(50))
            }
            for handle in handles where handle.isRunning {
                handle.kill()
            }
        }.value
    }

    @discardableResult
    private func cleanUpOwnedRuntime() async -> Bool {
        if let runtimeCleanupTask { return await runtimeCleanupTask.value }
        let task = Task { [self] in
            let result = await performRuntimeCleanup()
            runtimeCleanupTask = nil
            return result
        }
        runtimeCleanupTask = task
        return await task.value
    }

    private func performRuntimeCleanup() async -> Bool {
        // Cleanup also occurs on a camera configuration restart, outside stop().
        // Close this entry point to new toggles and drain any old guest mutation.
        let officeKeepAwake = officeKeepAwakeTask
        officeKeepAwake?.cancel()
        if officeKeepAwakePreferences.hasOriginal { setOfficeKeepAwakePhase(.applying) }
        _ = await officeKeepAwake?.value
        inputHelperInstalled = false
        inputHelperInstallTask?.cancel()
        inputHelperInstallTask = nil
        await pluginManager.handleRuntimeStopping()
        await closeDisplay()
        // Only restore through the still-owned, live transport, before stopping it.
        // A failed restore retains its recovery lease for the next owned startup.
        if emulatorProcess?.isRunning == true, adbServerProcess?.isRunning == true {
            do {
                try await restoreOfficeKeepAwake(generation: generation, allowStopping: true)
            } catch {
                setOfficeKeepAwakePhase(.failed)
            }
        }
        holdOfficeKeepAwakeActivity(false)
        if officeKeepAwakePhase != .failed {
            setOfficeKeepAwakePhase(officeKeepAwakePreferences.enabled ? .waitingForRuntime : .off)
        }
        let pending = unreapedProcesses
        unreapedProcesses.removeAll()
        _ = await stopProcessesWithoutBlockingMainActor(pending)
        if let emulator = emulatorProcess {
            _ = try? await runADB(
                ["emu", "kill"],
                operation: "关闭 Android 环境",
                timeout: 10
            )
            let deadline = Date().addingTimeInterval(8)
            while emulator.isRunning, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            let confirmsOwnedExit = await processTerminator.terminateAndWait(
                emulator,
                timeout: 2
            )
            if !confirmsOwnedExit {
                emulatorProcess = emulator
                return false
            }
            emulatorProcess = nil
            bootedCameraEnabled = nil
        }
        if let adb = adbServerProcess {
            let exited = await processTerminator.terminateAndWait(adb, timeout: 2)
            if !exited && adb.isRunning { return false }
            adbServerProcess = nil
        }
        return !unreapedProcesses.contains { $0.isRunning }
    }

    private func isValidRuntimeMetadata(
        requiringGPUConfiguration: Bool = true
    ) -> Bool {
        guard let image = try? RuntimeImageIdentity.read(from: paths.imageURL),
              let ini = try? String(contentsOf: paths.avdIniURL, encoding: .utf8),
              let config = try? String(
                  contentsOf: paths.avdURL.appendingPathComponent("config.ini"),
                  encoding: .utf8
              ) else {
            return false
        }
        return ini.contains("path=\(paths.avdURL.path)")
            && ini.components(separatedBy: .newlines).contains("target=android-\(image.api)")
            && config.contains("image.sysdir.1=\(paths.imageURL.path)")
            && config.contains("abi.type=arm64-v8a")
            && config.contains("hw.cpu.arch=arm64")
            && config.contains("hw.ramSize=6144")
            && config.contains("hw.lcd.width=1080")
            && config.contains("hw.lcd.height=1920")
            && config.contains("hw.lcd.density=420")
            && config.contains("disk.dataPartition.size=8G")
            && config.contains("hw.gpu.mode=host")
            && config.contains("hw.camera.front=webcam0")
            && config.contains("hw.camera.back=emulated")
            && config.contains("hw.sensors.light=no")
            && config.contains("hw.gsmModem=no")
            && (!requiringGPUConfiguration
                || Self.hasRequiredAVDGPUConfiguration(config))
    }

    private func safelyCreateDirectory(_ url: URL, mode: Int) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue, !Self.isSymbolicLink(url) else {
                throw RuntimeError.insecurePath
            }
        } else {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: mode]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: mode],
            ofItemAtPath: url.path
        )
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        try safelyCreateDirectory(url, mode: 0o700)
    }

    private func updateState(_ newState: RuntimeState) {
        state = newState
        onState?(newState)
    }

    private func isOperationCurrent(_ operationGeneration: UInt64) -> Bool {
        generation == operationGeneration && !isStopping
    }

    private static func canStart(from state: RuntimeState) -> Bool {
        switch state {
        case .stopped, .ready, .failed:
            return true
        case .preparing, .starting, .running, .stopping:
            return false
        }
    }

    static func canReuseReadyRuntime(
        state: RuntimeState,
        emulatorRunning: Bool,
        bootedCameraEnabled: Bool? = nil,
        desiredCameraEnabled: Bool? = nil
    ) -> Bool {
        if let bootedCameraEnabled, let desiredCameraEnabled, bootedCameraEnabled != desiredCameraEnabled {
            return false
        }
        return state == .ready && emulatorRunning
    }

    private static func safeMessage(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        if error is CancellationError {
            return RuntimeError.operationCancelled.errorDescription!
        }
        return RuntimeError.unexpected("运行环境操作失败").errorDescription!
    }

    nonisolated private static func containsUnresolvedPathComponents(_ url: URL) -> Bool {
        url.pathComponents.contains(".") || url.pathComponents.contains("..")
    }

    nonisolated private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}

enum RuntimePresenceParser {
    static func hasUnavailableMarker(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        return text.contains("Permission Denial")
            || text.contains("unknown command")
            || text.contains("Can't find service")
    }

    private static func matchesTargetComponent(_ line: String, package: String) -> Bool {
        if line.contains(package + "/") {
            return true
        }
        if package == "com.android.settings", line.contains("com.android.settings.intelligence/") {
            return true
        }
        return false
    }

    private static func matchesTargetHistoryContext(_ line: String, package: String, launchedFromPattern: String) -> Bool {
        if line.range(of: launchedFromPattern, options: .regularExpression) != nil {
            return true
        }
        if package == "com.android.settings" {
            if line.range(of: #"launchedFromPackage=com\.android\.settings\.intelligence(?:\s|$)"#, options: .regularExpression) != nil {
                return true
            }
            if line.contains("task=Task{") && line.contains("com.android.settings.root") {
                return true
            }
        }
        return false
    }

    private static func matchesTargetRecord(_ line: String, package: String) -> Bool {
        if matchesTargetComponent(line, package: package) {
            return true
        }
        for marker in ["ActivityRecord{", "Window{"] {
            var remainder = line[...]
            while let record = remainder.range(of: marker) {
                let component = remainder[record.upperBound...]
                if let slash = component.firstIndex(of: "/") {
                    let candidate = component[..<slash]
                        .split(whereSeparator: \.isWhitespace)
                        .last
                    if candidate == Substring(package) {
                        return true
                    }
                }
                remainder = remainder[record.upperBound...]
            }
        }
        return false
    }

    static func hasTargetVisible(_ data: Data, package: String = DefaultApp.package) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        let launchedFromPattern = #"launchedFromPackage=\#(NSRegularExpression.escapedPattern(for: package))(?:\s|$)"#
        var display: Int?
        var targetRecord = false
        var inHistoryRecord = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let value = String(line)
            if let number = displayNumber(in: value) {
                display = number
                targetRecord = false
                inHistoryRecord = false
            }
            guard let display, display > 0 else { continue }
            let isTarget = matchesTargetRecord(value, package: package)
            if isTarget && ["mResumedActivity:", "topResumedActivity=", "mFocusedApp="].contains(where: value.contains) { return true }
            if value.range(of: #"\*\s*Hist\s+#\d+:\s*ActivityRecord"#, options: .regularExpression) != nil {
                inHistoryRecord = true
                targetRecord = isTarget
            } else if value.range(of: #"^\s*\*\s*Task\{"#, options: .regularExpression) != nil {
                inHistoryRecord = false
                targetRecord = false
            } else if inHistoryRecord,
                      !targetRecord,
                      matchesTargetHistoryContext(value, package: package, launchedFromPattern: launchedFromPattern) {
                targetRecord = true
            }
            if targetRecord,
               value.range(of: #"\b(state=RESUMED|mVisible=true)\b"#, options: .regularExpression) != nil { return true }
            if isTarget, value.range(of: #"\b(state=RESUMED|visible=true)\b"#, options: .regularExpression) != nil { return true }
        }
        return false
    }

    static func targetDisplay(in activity: Data, package: String = DefaultApp.package) -> Int? {
        let lines = String(decoding: activity, as: UTF8.self).split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        var display: Int?
        for line in lines {
            let value = String(line)
            if let parsed = displayNumber(in: value) {
                display = parsed
                continue
            }
            if let display, display > 0, value.contains(package) {
                return display
            }
        }
        return nil
    }

    static func hasSystemInteraction(_ data: Data, display targetDisplay: Int) -> Bool {
        let text = section(
            String(decoding: data, as: UTF8.self),
            display: targetDisplay
        )
        guard !text.isEmpty else { return false }
        let permissions = [
            "com.android.permissioncontroller",
            "com.google.android.permissioncontroller",
            "com.android.packageinstaller",
            "com.android.documentsui",
            "com.android.settings.intelligence"
        ]
        for line in text.split(separator: "\n") {
            let value = String(line)
            if permissions.contains(where: { value.contains($0) }),
               (value.contains("mCurrentFocus=") || value.contains("mFocusedApp=") || value.range(
                   of: #"(visible=true|isVisible=true|mViewVisibility=0x0)"#,
                   options: .regularExpression
               ) != nil) {
                return true
            }
        }
        return false
    }

    static func resolve(_ activity: Data, window: Data?, package: String = DefaultApp.package) -> TargetPresence {
        if hasUnavailableMarker(activity) {
            return .unavailable
        }
        if let window,
           let display = targetDisplay(in: activity, package: package), display > 0 {
            if hasUnavailableMarker(window) {
                return .unavailable
            }
            if hasSystemInteraction(window, display: display) {
                return .systemInteraction
            }
        }
        if hasTargetVisible(activity, package: package) {
            return .visible
        }
        return .notRunning
    }

    private static func section(_ text: String, display: Int) -> String {
        var collecting = false
        var result: [Substring] = []
        for line in text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            if let parsed = displayNumber(in: String(line)) {
                if collecting { break }
                collecting = parsed == display
            }
            if collecting {
                result.append(line)
            }
        }
        return result.joined(separator: "\n")
    }

    private static func displayNumber(in line: String) -> Int? {
        guard let marker = line.range(
            of: #"^\s*Display(?:\s+#|:\s*mDisplayId=)"#,
            options: .regularExpression
        ) else {
            return nil
        }
        let digits = line[marker.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }
}
