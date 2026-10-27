import CryptoKit
import Foundation

// MARK: - System Plugin Contracts & Manifest

struct SystemPluginEntrypoints: Codable, Equatable, Sendable {
    var onEnable: String?
    var onDisable: String?
    var onRuntimeReady: String?
    var onAppLaunch: String?
    var onLocationUpdate: String?
    var onTick: String?
    var tickIntervalMs: Int?
    var presetsFile: String?
    var configFile: String?
    var hostService: String?

    init(
        onEnable: String? = nil,
        onDisable: String? = nil,
        onRuntimeReady: String? = nil,
        onAppLaunch: String? = nil,
        onLocationUpdate: String? = nil,
        onTick: String? = nil,
        tickIntervalMs: Int? = nil,
        presetsFile: String? = nil,
        configFile: String? = nil,
        hostService: String? = nil
    ) {
        self.onEnable = onEnable
        self.onDisable = onDisable
        self.onRuntimeReady = onRuntimeReady
        self.onAppLaunch = onAppLaunch
        self.onLocationUpdate = onLocationUpdate
        self.onTick = onTick
        self.tickIntervalMs = tickIntervalMs
        self.presetsFile = presetsFile
        self.configFile = configFile
        self.hostService = hostService
    }

    var allRelativePaths: [String] {
        [onEnable, onDisable, onRuntimeReady, onAppLaunch, onLocationUpdate, onTick, presetsFile, configFile, hostService]
            .compactMap { $0 }
    }

    var hasGuestShellHooks: Bool {
        [onEnable, onDisable, onRuntimeReady, onAppLaunch, onLocationUpdate, onTick]
            .contains { $0 != nil }
    }
}

struct SystemPluginManifest: Codable, Equatable, Identifiable, Sendable {
    static let supportedSchemaVersion = 1
    static let currentHostVersion = "0.2.0"
    static let supportedDriverTypes: Set<String> = [
        "hardware_gnss_location",
        "external_script",
        "host_service"
    ]
    static let supportedCapabilities: Set<String> = [
        "hardware.gnss",
        "qemu.console",
        "guest.location.bridge",
        "ui.map.workspace",
        "guest.shell",
        "lifecycle.hooks",
        "host.service"
    ]
    static let exclusiveCapabilities: Set<String> = [
        "hardware.gnss",
        "qemu.console"
    ]

    var schemaVersion: Int
    var id: String
    var name: String
    var subtitle: String
    var version: String
    var author: String
    var category: String
    var iconSymbol: String
    var accentHex: UInt32
    var minHostVersion: String
    var capabilities: [String]
    var driverType: String
    var entrypoints: SystemPluginEntrypoints

    static func isValidPluginIdentifier(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$"#, options: .regularExpression) != nil
            && !id.contains("..")
    }

    static func parseSemanticVersion(_ version: String) -> [Int]? {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let core = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? trimmed
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var nums: [Int] = []
        for p in parts {
            guard let v = Int(p), v >= 0 else { return nil }
            nums.append(v)
        }
        while nums.count < 3 { nums.append(0) }
        return nums
    }

    static func compareSemanticVersion(_ lhs: String, _ rhs: String) -> Int? {
        guard let a = parseSemanticVersion(lhs), let b = parseSemanticVersion(rhs) else {
            return nil
        }
        let count = max(a.count, b.count)
        for idx in 0..<count {
            let av = idx < a.count ? a[idx] : 0
            let bv = idx < b.count ? b[idx] : 0
            if av != bv { return av < bv ? -1 : 1 }
        }
        return 0
    }

    static func isHostVersionCompatible(minHostVersion: String, hostVersion: String = currentHostVersion) -> Bool {
        guard let cmp = compareSemanticVersion(minHostVersion, hostVersion) else {
            return false
        }
        return cmp <= 0
    }
}

struct SystemPluginPackageSignature: Codable, Equatable, Sendable {
    var pluginID: String
    var version: String
    var algorithm: String
    var keyID: String
    var publisher: String
    var manifestSHA256: String
    var files: [String: String]
    var signature: String

    init(
        pluginID: String,
        version: String,
        algorithm: String = "ed25519-sha256",
        keyID: String = SystemPluginTrustConfig.officialKeyID,
        publisher: String = SystemPluginTrustConfig.officialPublisher,
        manifestSHA256: String,
        files: [String: String],
        signature: String
    ) {
        self.pluginID = pluginID
        self.version = version
        self.algorithm = algorithm
        self.keyID = keyID
        self.publisher = publisher
        self.manifestSHA256 = manifestSHA256
        self.files = files
        self.signature = signature
    }
}

enum SystemPluginTrustPolicy: Equatable, Sendable {
    case officialRepository
    case developerLocalImport
}

enum SystemPluginTrustConfig {
    static let officialKeyID = "official-ed25519-v2"
    static let officialPublisher = "samwang0041-star"
    static let officialPublicKeyBase64 = "6SQBB58dPiVa++10GKdGP5D4bHgGfWDWUbizVNwVw6w="
    static let officialRegistryURL = URL(string: "https://raw.githubusercontent.com/samwang0041-star/macdora/main/plugins/registry.json")!
    static let fallbackRegistryURL = URL(string: "https://github.com/samwang0041-star/macdora/releases/download/v0.03/registry.json")!

    static let trustedPublicKeys: [String: String] = [
        officialKeyID: officialPublicKeyBase64,
        "official-ed25519-v1": "7J9rXT8Kx9EKUkCiKlXQ/qLsztOm9EzGfgwDl9kUVwo="
    ]

    static func canonicalSigningPayload(
        algorithm: String,
        keyID: String,
        pluginID: String,
        version: String,
        manifestSHA256: String,
        files: [String: String]
    ) -> Data {
        var lines: [String] = [
            algorithm,
            keyID,
            pluginID,
            version,
            manifestSHA256
        ]
        for key in files.keys.sorted() {
            if let digest = files[key] {
                lines.append("\(key):\(digest)")
            }
        }
        return Data(lines.joined(separator: "\n").utf8)
    }
}

struct SystemPluginRemoteCatalogEntry: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var subtitle: String
    var version: String
    var author: String
    var category: String
    var iconSymbol: String
    var accentHex: UInt32
    var minHostVersion: String
    var capabilities: [String]
    var driverType: String
    var downloadURL: String
    var fallbackDownloadURL: String?
    var archiveSHA256: String
    var manifestSHA256: String
    var signatureKeyID: String
    var signature: String
}

struct SystemPluginRemoteRegistry: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var repository: String
    var publicKeyID: String
    var publicKeyEd25519: String
    var plugins: [SystemPluginRemoteCatalogEntry]
}

enum SystemPluginHealthState: Equatable, Sendable {
    case inactive
    case waitingForRuntime
    case healthy
    case degraded(String)

    var isDegraded: Bool {
        if case .degraded = self { return true }
        return false
    }
}

enum SystemPluginInstallState: Equatable, Sendable {
    case notInstalled
    case downloading(Double)
    case installed(isEnabled: Bool)
    case failed(String)

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }

    var isEnabled: Bool {
        if case .installed(let enabled) = self { return enabled }
        return false
    }

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

struct SystemPluginCatalogItem: Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var subtitle: String
    var version: String
    var availableUpdateVersion: String?
    var author: String
    var category: String
    var iconSymbol: String
    var accentHex: UInt32
    var isOfficialPreset: Bool
    var packageSizeLabel: String
    var capabilities: [String]
    var driverType: String
    var state: SystemPluginInstallState
    var healthState: SystemPluginHealthState
    var statusDetail: String
    var lastErrorDetail: String?
    var downloadSourceDescription: String

    var hasDedicatedWorkspace: Bool {
        driverType == "hardware_gnss_location" || driverType == "external_script"
    }

    static let developerLocationID = "builtin.developer.location"

    static let defaultPresetCatalog: [SystemPluginCatalogItem] = [
        SystemPluginCatalogItem(
            id: developerLocationID,
            name: "开发者虚拟定位",
            subtitle: "系统级 GPS 虚拟定位，支持地图搜索选点与 10 米自动漂移",
            version: "1.0.0",
            availableUpdateVersion: nil,
            author: "官方插件仓库",
            category: "开发者",
            iconSymbol: "location.fill.viewfinder",
            accentHex: 0x0F97FF,
            isOfficialPreset: true,
            packageSizeLabel: "21 KB",
            capabilities: [
                "hardware.gnss",
                "qemu.console",
                "guest.location.bridge",
                "ui.map.workspace"
            ],
            driverType: "hardware_gnss_location",
            state: .notInstalled,
            healthState: .inactive,
            statusDetail: "未下载 · 点击从 GitHub 独立插件仓库获取",
            lastErrorDetail: nil,
            downloadSourceDescription: "github.com/samwang0041-star/macdora"
        )
    ]
}

// MARK: - Host Context Provided to Hot-Plugged Plugins

@MainActor
protocol SystemPluginHostBridge: AnyObject {
    var currentRuntimeState: RuntimeState { get }
    var currentActivePackage: String? { get }
    var emulatorConsolePort: UInt16 { get }
    var emulatorAuthTokenURLs: [URL] { get }
    var hostServiceEnvironment: [String: String] { get }
    func executeGuestShell(_ script: String, operation: String, timeout: TimeInterval) async -> Bool
    func sendEmulatorGeoFix(
        longitude: Double,
        latitude: Double,
        altitude: Double,
        satellites: Int,
        velocityKnots: Double
    ) async -> Bool
    func notifyPluginBanner(_ message: String)
    func notifyPluginStateDidChange()
}

extension SystemPluginHostBridge {
    var hostServiceEnvironment: [String: String] { [:] }
}

@MainActor
protocol HotPluggableSystemPlugin: AnyObject {
    var manifest: SystemPluginManifest { get }
    var bundleDirectoryURL: URL { get }
    var isEnabled: Bool { get }
    var healthState: SystemPluginHealthState { get }
    var runtimeStatusSummary: String { get }
    func setEnabledWithoutBridge(_ enabled: Bool) async
    func activate(bridge: SystemPluginHostBridge) async
    @discardableResult func deactivate(bridge: SystemPluginHostBridge) async -> Bool
    func retire()
    func deletePersistentData()
    func onRuntimeBecameReady(bridge: SystemPluginHostBridge) async
    func onAppLaunching(package: String, bridge: SystemPluginHostBridge) async
    func onRuntimeStopping(bridge: SystemPluginHostBridge) async
}

// A stopped plugin must finish outstanding guest work before cleanup can run.
@MainActor
final class SystemPluginActivity {
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func begin() { count += 1 }

    func end() {
        count -= 1
        if count == 0 {
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    func waitUntilIdle() async {
        guard count > 0 else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

// MARK: - External Developer Script/Hook Plugin Driver

@MainActor
final class ExternalDeveloperSystemPlugin: HotPluggableSystemPlugin {
    let manifest: SystemPluginManifest
    let bundleDirectoryURL: URL
    private(set) var isEnabled: Bool = false
    private(set) var healthState: SystemPluginHealthState = .inactive
    private(set) var runtimeStatusSummary: String = "未启用"
    private(set) var lastHookExecutionDate: Date?
    private(set) var executedHookCount: UInt64 = 0
    private var tickTask: Task<Void, Never>?
    private var lifecycleGeneration: UInt64 = 0
    private var needsDeferredEnableHook: Bool = false
    private var isDeleted = false
    private let activity = SystemPluginActivity()

    init(manifest: SystemPluginManifest, bundleDirectoryURL: URL) {
        self.manifest = manifest
        self.bundleDirectoryURL = bundleDirectoryURL
    }

    func setEnabledWithoutBridge(_ enabled: Bool) async {
        guard !isDeleted else { return }
        lifecycleGeneration &+= 1
        isEnabled = enabled
        if !enabled {
            tickTask?.cancel()
            tickTask = nil
            await activity.waitUntilIdle()
            needsDeferredEnableHook = false
            healthState = .inactive
            runtimeStatusSummary = "未启用"
        } else {
            needsDeferredEnableHook = manifest.entrypoints.hasGuestShellHooks
            healthState = manifest.entrypoints.hasGuestShellHooks ? .waitingForRuntime : .healthy
            runtimeStatusSummary = manifest.entrypoints.hasGuestShellHooks
                ? "已启用 · 等待安卓容器就绪"
                : "已启用 · 系统级扩展生效中"
        }
    }

    func activate(bridge: SystemPluginHostBridge) async {
        guard !isDeleted else { return }
        lifecycleGeneration &+= 1
        let capturedGen = lifecycleGeneration
        isEnabled = true

        let state = bridge.currentRuntimeState
        guard state == .ready || state == .running else {
            needsDeferredEnableHook = true
            healthState = .waitingForRuntime
            runtimeStatusSummary = "已启用 · 等待安卓容器就绪"
            return
        }

        needsDeferredEnableHook = false
        var allSucceeded = true
        if let hook = manifest.entrypoints.onEnable {
            let ok = await runHookScript(relativePath: hook, bridge: bridge, extraEnv: [:])
            guard isEnabled, lifecycleGeneration == capturedGen else { return }
            allSucceeded = allSucceeded && ok
        }
        if allSucceeded, let readyHook = manifest.entrypoints.onRuntimeReady {
            let ok = await runHookScript(relativePath: readyHook, bridge: bridge, extraEnv: [:])
            guard isEnabled, lifecycleGeneration == capturedGen else { return }
            allSucceeded = allSucceeded && ok
        }
        if allSucceeded, let pkg = bridge.currentActivePackage, let appHook = manifest.entrypoints.onAppLaunch {
            let ok = await runHookScript(
                relativePath: appHook,
                bridge: bridge,
                extraEnv: ["ANDROID_USE_ACTIVE_PACKAGE": pkg]
            )
            guard isEnabled, lifecycleGeneration == capturedGen else { return }
            allSucceeded = allSucceeded && ok
        }
        if allSucceeded {
            healthState = .healthy
            runtimeStatusSummary = "已启用 · 系统级扩展生效中"
            startTickIfNeeded(bridge: bridge, capturedGeneration: capturedGen)
        } else {
            needsDeferredEnableHook = true
            healthState = .degraded("初始化钩子执行失败")
            runtimeStatusSummary = "钩子执行异常 · 请检查容器状态"
        }
    }

    @discardableResult
    func deactivate(bridge: SystemPluginHostBridge) async -> Bool {
        lifecycleGeneration &+= 1
        let wasEnabled = isEnabled
        isEnabled = false
        needsDeferredEnableHook = false
        tickTask?.cancel()
        tickTask = nil
        await activity.waitUntilIdle()
        let state = bridge.currentRuntimeState
        if (state == .ready || state == .running), let hook = manifest.entrypoints.onDisable {
            guard await runHookScript(relativePath: hook, bridge: bridge, extraEnv: [:]) else {
                isEnabled = wasEnabled
                healthState = .degraded("停用失败，请重试")
                runtimeStatusSummary = "停用失败，请重试"
                startTickIfNeeded(bridge: bridge, capturedGeneration: lifecycleGeneration)
                return false
            }
        }
        healthState = .inactive
        runtimeStatusSummary = "未启用"
        return true
    }

    func deletePersistentData() {
        // This driver stores its files in the bundle and has no host preferences.
        retire()
        lastHookExecutionDate = nil
        executedHookCount = 0
    }

    func retire() {
        isDeleted = true
        isEnabled = false
        lifecycleGeneration &+= 1
        tickTask?.cancel()
        tickTask = nil
    }

    func onRuntimeBecameReady(bridge: SystemPluginHostBridge) async {
        guard isEnabled else { return }
        let capturedGen = lifecycleGeneration
        var allSucceeded = true
        if needsDeferredEnableHook, let enableHook = manifest.entrypoints.onEnable {
            let ok = await runHookScript(relativePath: enableHook, bridge: bridge, extraEnv: [:])
            guard isEnabled, lifecycleGeneration == capturedGen else { return }
            allSucceeded = allSucceeded && ok
        }
        if allSucceeded, let readyHook = manifest.entrypoints.onRuntimeReady {
            let ok = await runHookScript(relativePath: readyHook, bridge: bridge, extraEnv: [:])
            guard isEnabled, lifecycleGeneration == capturedGen else { return }
            allSucceeded = allSucceeded && ok
        }
        needsDeferredEnableHook = !allSucceeded
        if allSucceeded {
            healthState = .healthy
            runtimeStatusSummary = "已启用 · 系统级扩展生效中"
            startTickIfNeeded(bridge: bridge, capturedGeneration: capturedGen)
        } else {
            healthState = .degraded("容器就绪钩子执行失败")
            runtimeStatusSummary = "钩子执行异常 · 请检查脚本"
        }
    }

    func onAppLaunching(package: String, bridge: SystemPluginHostBridge) async {
        guard isEnabled else { return }
        let capturedGen = lifecycleGeneration
        if let hook = manifest.entrypoints.onAppLaunch {
            let ok = await runHookScript(
                relativePath: hook,
                bridge: bridge,
                extraEnv: ["ANDROID_USE_ACTIVE_PACKAGE": package]
            )
            guard isEnabled, lifecycleGeneration == capturedGen else { return }
            if !ok {
                healthState = .degraded("应用启动钩子执行失败")
                runtimeStatusSummary = "应用启动钩子异常"
            }
        }
    }

    func onRuntimeStopping(bridge: SystemPluginHostBridge) async {
        lifecycleGeneration &+= 1
        tickTask?.cancel()
        tickTask = nil
        await activity.waitUntilIdle()
        if isEnabled {
            needsDeferredEnableHook = true
            healthState = .waitingForRuntime
            runtimeStatusSummary = "已启用 · 等待安卓容器就绪"
        }
    }

    func triggerManualHookCheck(bridge: SystemPluginHostBridge?) async -> Bool {
        guard isEnabled, !isDeleted, let bridge else { return false }
        let capturedGen = lifecycleGeneration
        let state = bridge.currentRuntimeState
        guard state == .ready || state == .running else { return false }
        if case .degraded = healthState {
            await activate(bridge: bridge)
            return isEnabled && healthState == .healthy
        }
        if let hook = manifest.entrypoints.onRuntimeReady ?? manifest.entrypoints.onEnable {
            let ok = await runHookScript(relativePath: hook, bridge: bridge, extraEnv: [:])
            guard isEnabled, lifecycleGeneration == capturedGen else { return false }
            if ok {
                healthState = .healthy
                runtimeStatusSummary = "已启用 · 系统级扩展生效中"
            } else {
                healthState = .degraded("手动执行钩子失败")
                runtimeStatusSummary = "钩子执行异常"
            }
            return ok
        }
        return true
    }

    private func startTickIfNeeded(bridge: SystemPluginHostBridge, capturedGeneration: UInt64) {
        tickTask?.cancel()
        tickTask = nil
        guard isEnabled,
              lifecycleGeneration == capturedGeneration,
              let tickHook = manifest.entrypoints.onTick,
              let intervalMs = manifest.entrypoints.tickIntervalMs,
              intervalMs >= 50 else {
            return
        }
        tickTask = Task { @MainActor [weak self, weak bridge] in
            let clock = ContinuousClock()
            var nextDeadline = clock.now
            while !Task.isCancelled {
                guard let self, let bridge, self.isEnabled, self.lifecycleGeneration == capturedGeneration else { break }
                nextDeadline += .milliseconds(intervalMs)
                let now = clock.now
                if nextDeadline > now {
                    try? await clock.sleep(until: nextDeadline, tolerance: .milliseconds(5))
                } else {
                    nextDeadline = now
                }
                guard !Task.isCancelled, self.isEnabled, self.lifecycleGeneration == capturedGeneration else { break }
                if bridge.currentRuntimeState == .ready || bridge.currentRuntimeState == .running {
                    _ = await self.runHookScript(relativePath: tickHook, bridge: bridge, extraEnv: [:])
                }
            }
        }
    }

    private func runHookScript(
        relativePath: String,
        bridge: SystemPluginHostBridge,
        extraEnv: [String: String]
    ) async -> Bool {
        guard manifest.capabilities.contains("guest.shell") || manifest.capabilities.contains("lifecycle.hooks") else {
            return false
        }
        guard !relativePath.contains(".."),
              !relativePath.hasPrefix("."),
              !relativePath.contains("/.") else {
            return false
        }
        let rootPath = bundleDirectoryURL.standardizedFileURL.path
        let fileURL = bundleDirectoryURL.appendingPathComponent(relativePath).standardizedFileURL
        guard fileURL.path.hasPrefix(rootPath + "/"),
              FileManager.default.isReadableFile(atPath: fileURL.path),
              let script = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return false
        }
        let state = bridge.currentRuntimeState
        guard state == .ready || state == .running else {
            return false
        }
        var header = ""
        for (k, v) in extraEnv where k.range(of: #"^[A-Z0-9_]+$"#, options: .regularExpression) != nil {
            let sanitized = v.replacingOccurrences(of: "'", with: "")
            header += "export \(k)='\(sanitized)'\n"
        }
        activity.begin()
        defer { activity.end() }
        let ok = await bridge.executeGuestShell(
            header + script,
            operation: "执行插件 \(manifest.name) 钩子",
            timeout: 12
        )
        if ok {
            executedHookCount &+= 1
            lastHookExecutionDate = Date()
        }
        return ok
    }
}

// MARK: - Plugin Package Verifier & Developer Template Builder (.auplugin)

enum SystemPluginPackageError: LocalizedError, Equatable {
    case invalidPluginID
    case packageNotFound(String)
    case manifestMissingOrInvalid
    case incompatibleManifest(String)
    case signatureMismatch(String)
    case untrustedPublisher(String)
    case unsafePackageContent
    case operationInProgress(String)
    case operationFailed(String)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPluginID:
            return "插件标识符格式无效。"
        case .packageNotFound(let id):
            return "未在远程插件仓库找到插件包：\(id)。"
        case .manifestMissingOrInvalid:
            return "插件包缺少有效的 manifest.json 描述文件。"
        case .incompatibleManifest(let detail):
            return "插件包与当前宿主版本或能力规范不兼容（\(detail)）。"
        case .signatureMismatch(let file):
            return "插件包完整性或密码学签名校验失败（\(file)）。"
        case .untrustedPublisher(let detail):
            return "插件包发布者签名不受信任（\(detail)）。"
        case .unsafePackageContent:
            return "插件包包含不安全路径、隐藏入口、超限文件或符号链接，已拒绝加载。"
        case .operationInProgress(let id):
            return "插件「\(id)」正在执行其他变更操作，请稍候。"
        case .operationFailed(let detail):
            return detail
        case .downloadFailed(let detail):
            return "插件从 GitHub 下载失败：\(detail)"
        }
    }
}

enum SystemPluginPackageFactory {
    static let maxPackageFileCount = 128
    static let maxTotalPackageBytes: Int64 = 64 * 1024 * 1024

    @discardableResult
    static func createDeveloperTemplateDirectory(
        at destinationURL: URL,
        pluginID: String = "dev.custom.sample-capability",
        name: String = "自定义系统扩展插件",
        overwriteExisting: Bool = false,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard SystemPluginManifest.isValidPluginIdentifier(pluginID),
              !pluginID.hasPrefix("builtin.") else {
            throw SystemPluginPackageError.invalidPluginID
        }
        let finalURL: URL
        if fileManager.fileExists(atPath: destinationURL.path) {
            if overwriteExisting {
                try fileManager.removeItem(at: destinationURL)
                finalURL = destinationURL
            } else {
                let parent = destinationURL.deletingLastPathComponent()
                let baseName = destinationURL.lastPathComponent
                var index = 2
                var candidate = parent.appendingPathComponent("\(baseName)-\(index)", isDirectory: true)
                while fileManager.fileExists(atPath: candidate.path) {
                    index += 1
                    candidate = parent.appendingPathComponent("\(baseName)-\(index)", isDirectory: true)
                }
                finalURL = candidate
            }
        } else {
            finalURL = destinationURL
        }

        let hooksURL = finalURL.appendingPathComponent("hooks", isDirectory: true)
        try fileManager.createDirectory(at: hooksURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])

        let manifest = SystemPluginManifest(
            schemaVersion: SystemPluginManifest.supportedSchemaVersion,
            id: pluginID,
            name: name,
            subtitle: "开发者自研热插拔系统级插件示例 · 支持生命周期与定时硬件/系统钩子",
            version: "0.1.0",
            author: "开发者自研",
            category: "开发者扩展",
            iconSymbol: "puzzlepiece.extension.fill",
            accentHex: 0x10B981,
            minHostVersion: "0.1.0",
            capabilities: ["guest.shell", "lifecycle.hooks"],
            driverType: "external_script",
            entrypoints: SystemPluginEntrypoints(
                onEnable: "hooks/on-enable.sh",
                onDisable: "hooks/on-disable.sh",
                onRuntimeReady: "hooks/on-runtime-ready.sh",
                onAppLaunch: "hooks/on-app-launch.sh"
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: finalURL.appendingPathComponent("manifest.json"), options: .atomic)

        let onEnable = """
        #!/system/bin/sh
        # 当用户在管理台打开插件开关时立即热执行（无需重启容器）
        setprop debug.androiduse.custom_plugin 1 >/dev/null 2>&1 || true
        echo "AU_PLUGIN_HOOK_OK"
        """
        let onDisable = """
        #!/system/bin/sh
        # 停用或删除前停止插件功能；停用不得删除用户数据
        setprop debug.androiduse.custom_plugin 0 >/dev/null 2>&1 || true
        echo "AU_PLUGIN_HOOK_OK"
        """
        let onReady = """
        #!/system/bin/sh
        # 当 Android 容器启动就绪时自动挂载
        setprop debug.androiduse.custom_plugin 1 >/dev/null 2>&1 || true
        echo "AU_PLUGIN_HOOK_OK"
        """
        let onAppLaunch = """
        #!/system/bin/sh
        # 当任意应用打开时触发，$ANDROID_USE_ACTIVE_PACKAGE 为当前应用包名
        echo "Launching $ANDROID_USE_ACTIVE_PACKAGE" >/dev/null
        echo "AU_PLUGIN_HOOK_OK"
        """
        let readme = """
        # Android Use 系统级热插拔插件开发指南

        1. 编辑 `manifest.json` 定义插件 `id`、`name`、`version`、`capabilities` 与 `entrypoints`。
        2. 在 `hooks/` 目录下编写系统级脚本（支持在启用、关闭、容器就绪、应用启动及周期 Tick 时执行）。
        3. 修改文件后重新生成 `signature.json`（或使用 Ed25519 私钥签名发布到项目 GitHub 仓库）。
        4. 在 Android Use 管理台 → 「插件」页面点击「导入本地插件…」选择本目录（或打包后的 `.zip` / `.auplugin`），导入后点击启用即可使用；停用保留数据，删除清理插件文件和设置。
        """

        try Data(onEnable.utf8).write(to: hooksURL.appendingPathComponent("on-enable.sh"), options: .atomic)
        try Data(onDisable.utf8).write(to: hooksURL.appendingPathComponent("on-disable.sh"), options: .atomic)
        try Data(onReady.utf8).write(to: hooksURL.appendingPathComponent("on-runtime-ready.sh"), options: .atomic)
        try Data(onAppLaunch.utf8).write(to: hooksURL.appendingPathComponent("on-app-launch.sh"), options: .atomic)
        try Data(readme.utf8).write(to: finalURL.appendingPathComponent("README.md"), options: .atomic)

        try writeSignature(
            forPluginDirectory: finalURL,
            pluginID: pluginID,
            version: manifest.version,
            privateKey: nil,
            fileManager: fileManager
        )
        return finalURL
    }

    static func writeSignature(
        forPluginDirectory directoryURL: URL,
        pluginID: String,
        version: String,
        privateKey: Curve25519.Signing.PrivateKey? = nil,
        keyID: String = SystemPluginTrustConfig.officialKeyID,
        publisher: String = "developer-local",
        fileManager: FileManager = .default
    ) throws {
        let root = directoryURL.standardizedFileURL
        var files: [String: String] = [:]
        if let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) {
            for case let fileURL as URL in enumerator {
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    throw SystemPluginPackageError.unsafePackageContent
                }
                guard values.isRegularFile == true else { continue }
                let rel = String(fileURL.standardizedFileURL.path.dropFirst(root.path.count + 1))
                if rel == "signature.json" || rel == ".DS_Store" || rel.hasSuffix("/.DS_Store") {
                    continue
                }
                if rel.hasPrefix(".") || rel.contains("/.") {
                    throw SystemPluginPackageError.unsafePackageContent
                }
                let data = try Data(contentsOf: fileURL)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                files[rel] = digest
            }
        }
        guard let manifestSHA = files["manifest.json"] else {
            throw SystemPluginPackageError.manifestMissingOrInvalid
        }

        let algorithm: String
        let effectiveKeyID: String
        let effectivePublisher: String
        let sigString: String

        if let privateKey {
            algorithm = "ed25519-sha256"
            effectiveKeyID = keyID
            effectivePublisher = publisher
            let payload = SystemPluginTrustConfig.canonicalSigningPayload(
                algorithm: algorithm,
                keyID: effectiveKeyID,
                pluginID: pluginID,
                version: version,
                manifestSHA256: manifestSHA,
                files: files
            )
            let rawSig = try privateKey.signature(for: payload)
            sigString = rawSig.base64EncodedString()
        } else {
            guard !pluginID.hasPrefix("builtin.") else {
                throw SystemPluginPackageError.untrustedPublisher("官方 builtin.* 命名空间必须使用官方 Ed25519 私钥签名")
            }
            algorithm = "developer-local-sha256"
            effectiveKeyID = "developer-local"
            effectivePublisher = publisher
            let payload = SystemPluginTrustConfig.canonicalSigningPayload(
                algorithm: algorithm,
                keyID: effectiveKeyID,
                pluginID: pluginID,
                version: version,
                manifestSHA256: manifestSHA,
                files: files
            )
            sigString = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        }

        let signature = SystemPluginPackageSignature(
            pluginID: pluginID,
            version: version,
            algorithm: algorithm,
            keyID: effectiveKeyID,
            publisher: effectivePublisher,
            manifestSHA256: manifestSHA,
            files: files,
            signature: sigString
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(signature).write(to: root.appendingPathComponent("signature.json"), options: .atomic)
    }

    static func verifyPluginDirectory(
        _ directoryURL: URL,
        trustPolicy: SystemPluginTrustPolicy = .officialRepository,
        additionalTrustedPublicKeys: [String: String] = [:],
        hostVersion: String = SystemPluginManifest.currentHostVersion,
        fileManager: FileManager = .default
    ) throws -> SystemPluginManifest {
        if (try? directoryURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw SystemPluginPackageError.unsafePackageContent
        }
        let root = directoryURL.standardizedFileURL
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw SystemPluginPackageError.manifestMissingOrInvalid
        }
        if (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw SystemPluginPackageError.unsafePackageContent
        }
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard fileManager.isReadableFile(atPath: manifestURL.path),
              let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(SystemPluginManifest.self, from: manifestData),
              SystemPluginManifest.isValidPluginIdentifier(manifest.id) else {
            throw SystemPluginPackageError.manifestMissingOrInvalid
        }

        // 1. Validate schemaVersion, minHostVersion, driverType, and capabilities allowlist
        guard manifest.schemaVersion == SystemPluginManifest.supportedSchemaVersion else {
            throw SystemPluginPackageError.incompatibleManifest("schemaVersion=\(manifest.schemaVersion)")
        }
        guard SystemPluginManifest.parseSemanticVersion(manifest.version) != nil else {
            throw SystemPluginPackageError.incompatibleManifest("version=\(manifest.version)")
        }
        guard SystemPluginManifest.isHostVersionCompatible(minHostVersion: manifest.minHostVersion, hostVersion: hostVersion) else {
            throw SystemPluginPackageError.incompatibleManifest("minHostVersion=\(manifest.minHostVersion)")
        }
        guard SystemPluginManifest.supportedDriverTypes.contains(manifest.driverType) else {
            throw SystemPluginPackageError.incompatibleManifest("driverType=\(manifest.driverType)")
        }
        guard Set(manifest.capabilities).isSubset(of: SystemPluginManifest.supportedCapabilities) else {
            throw SystemPluginPackageError.incompatibleManifest("capabilities")
        }
        if manifest.driverType == "external_script" && manifest.entrypoints.hasGuestShellHooks {
            guard manifest.capabilities.contains("guest.shell") || manifest.capabilities.contains("lifecycle.hooks") else {
                throw SystemPluginPackageError.incompatibleManifest("missing guest.shell capability for hook scripts")
            }
        }

        // 2. Enumerate ALL files (including hidden files) and enforce file count / size / symlink safety
        var actualRelativeFiles = Set<String>()
        var totalBytes: Int64 = 0
        if let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) {
            for case let itemURL as URL in enumerator {
                let values = try? itemURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                if values?.isSymbolicLink == true {
                    throw SystemPluginPackageError.unsafePackageContent
                }
                if values?.isRegularFile == true {
                    let rel = String(itemURL.standardizedFileURL.path.dropFirst(root.path.count + 1))
                    if rel == "signature.json" || rel == ".DS_Store" || rel.hasSuffix("/.DS_Store") {
                        continue
                    }
                    if rel.hasPrefix(".") || rel.contains("/.") || rel.contains("..") {
                        throw SystemPluginPackageError.unsafePackageContent
                    }
                    actualRelativeFiles.insert(rel)
                    totalBytes += Int64(values?.fileSize ?? 0)
                    if actualRelativeFiles.count > maxPackageFileCount || totalBytes > maxTotalPackageBytes {
                        throw SystemPluginPackageError.unsafePackageContent
                    }
                }
            }
        }

        // 3. Validate signature.json structure and all entrypoints
        let signatureURL = root.appendingPathComponent("signature.json")
        guard fileManager.isReadableFile(atPath: signatureURL.path),
              let sigData = try? Data(contentsOf: signatureURL),
              let sig = try? JSONDecoder().decode(SystemPluginPackageSignature.self, from: sigData) else {
            throw SystemPluginPackageError.signatureMismatch("signature.json")
        }
        guard sig.pluginID == manifest.id else {
            throw SystemPluginPackageError.signatureMismatch("manifest.id")
        }
        guard sig.version == manifest.version else {
            throw SystemPluginPackageError.signatureMismatch("manifest.version")
        }
        guard let expectedManifestHash = sig.files["manifest.json"],
              sig.manifestSHA256 == expectedManifestHash else {
            throw SystemPluginPackageError.signatureMismatch("manifest.json")
        }
        for ep in manifest.entrypoints.allRelativePaths {
            guard !ep.contains(".."), !ep.hasPrefix("."), !ep.contains("/.") else {
                throw SystemPluginPackageError.unsafePackageContent
            }
            guard sig.files[ep] != nil else {
                throw SystemPluginPackageError.signatureMismatch(ep)
            }
        }

        let signedKeys = Set(sig.files.keys)
        if let missingOrExtra = actualRelativeFiles.symmetricDifference(signedKeys).sorted().first {
            throw SystemPluginPackageError.signatureMismatch(missingOrExtra)
        }
        for (relPath, expectedHash) in sig.files {
            guard !relPath.contains(".."), !relPath.hasPrefix("."), !relPath.contains("/.") else {
                throw SystemPluginPackageError.unsafePackageContent
            }
            let target = root.appendingPathComponent(relPath).standardizedFileURL
            guard target.path.hasPrefix(root.path + "/"),
                  let data = try? Data(contentsOf: target) else {
                throw SystemPluginPackageError.signatureMismatch(relPath)
            }
            let actualHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actualHash == expectedHash else {
                throw SystemPluginPackageError.signatureMismatch(relPath)
            }
        }

        // 4. Verify publisher cryptographic signature
        let requiresOfficialEd25519 = (trustPolicy == .officialRepository) || manifest.id.hasPrefix("builtin.")
        var trustedKeys = SystemPluginTrustConfig.trustedPublicKeys
        for (k, v) in additionalTrustedPublicKeys {
            trustedKeys[k] = v
        }

        if requiresOfficialEd25519 || sig.algorithm == "ed25519-sha256" {
            guard sig.algorithm == "ed25519-sha256" else {
                throw SystemPluginPackageError.untrustedPublisher("必须使用 ed25519-sha256 官方签名")
            }
            guard let pubKeyB64 = trustedKeys[sig.keyID],
                  let pubKeyData = Data(base64Encoded: pubKeyB64),
                  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubKeyData),
                  let rawSignature = Data(base64Encoded: sig.signature) else {
                throw SystemPluginPackageError.untrustedPublisher(sig.keyID)
            }
            let payload = SystemPluginTrustConfig.canonicalSigningPayload(
                algorithm: sig.algorithm,
                keyID: sig.keyID,
                pluginID: sig.pluginID,
                version: sig.version,
                manifestSHA256: sig.manifestSHA256,
                files: sig.files
            )
            guard publicKey.isValidSignature(rawSignature, for: payload) else {
                throw SystemPluginPackageError.signatureMismatch("ed25519.signature")
            }
        } else {
            guard trustPolicy == .developerLocalImport,
                  sig.algorithm == "developer-local-sha256" else {
                throw SystemPluginPackageError.untrustedPublisher(sig.algorithm)
            }
            let payload = SystemPluginTrustConfig.canonicalSigningPayload(
                algorithm: sig.algorithm,
                keyID: sig.keyID,
                pluginID: sig.pluginID,
                version: sig.version,
                manifestSHA256: sig.manifestSHA256,
                files: sig.files
            )
            let expectedDigest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            guard sig.signature == expectedDigest else {
                throw SystemPluginPackageError.signatureMismatch("developer-local.signature")
            }
        }

        return manifest
    }
}

// MARK: - Real GitHub Remote Plugin Package Fetcher (HTTPS + Ed25519 Verification)

protocol SystemPluginHTTPTransporting: Sendable {
    func fetchData(from url: URL, onProgress: (@Sendable (Double) -> Void)?) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionPluginHTTPTransport: SystemPluginHTTPTransporting {
    private let timeoutSeconds: TimeInterval

    init(timeoutSeconds: TimeInterval = 25) {
        self.timeoutSeconds = timeoutSeconds
    }

    func fetchData(from url: URL, onProgress: (@Sendable (Double) -> Void)?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeoutSeconds
        request.setValue("AndroidUse-PluginClient/1.0", forHTTPHeaderField: "User-Agent")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SystemPluginPackageError.downloadFailed("无效的 HTTP 响应")
        }
        guard (200...299).contains(http.statusCode) else {
            throw SystemPluginPackageError.downloadFailed("HTTP \(http.statusCode) (\(url.host ?? url.absoluteString))")
        }

        let expectedLength = http.expectedContentLength
        let maxBytes = 32 * 1024 * 1024
        if expectedLength > Int64(maxBytes) {
            throw SystemPluginPackageError.unsafePackageContent
        }

        var buffer = Data()
        if expectedLength > 0 {
            buffer.reserveCapacity(Int(min(expectedLength, 4 * 1024 * 1024)))
        }
        var lastReported: Double = 0.0
        onProgress?(0.05)

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count > maxBytes {
                throw SystemPluginPackageError.unsafePackageContent
            }
            if expectedLength > 0 {
                let ratio = min(0.90, max(0.05, Double(buffer.count) / Double(expectedLength) * 0.90))
                if ratio - lastReported >= 0.05 {
                    lastReported = ratio
                    onProgress?(ratio)
                }
            }
        }
        onProgress?(0.92)
        return (buffer, http)
    }
}

protocol SystemPluginPackageFetching: Sendable {
    func fetchRemoteRegistry() async throws -> SystemPluginRemoteRegistry
    func fetchPluginPackage(
        pluginID: String,
        stagingDirectoryURL: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL
}

extension SystemPluginPackageFetching {
    func fetchRemoteRegistry() async throws -> SystemPluginRemoteRegistry {
        throw SystemPluginPackageError.downloadFailed("当前下载器未配置远程插件清单源")
    }
}

struct DefaultSystemPluginPackageFetcher: SystemPluginPackageFetching {
    let registryURL: URL
    let fallbackRegistryURL: URL?
    let httpTransport: any SystemPluginHTTPTransporting
    let trustedPublicKeys: [String: String]

    init(
        registryURL: URL = SystemPluginTrustConfig.officialRegistryURL,
        fallbackRegistryURL: URL? = SystemPluginTrustConfig.fallbackRegistryURL,
        httpTransport: any SystemPluginHTTPTransporting = URLSessionPluginHTTPTransport(),
        trustedPublicKeys: [String: String] = SystemPluginTrustConfig.trustedPublicKeys
    ) {
        self.registryURL = registryURL
        self.fallbackRegistryURL = fallbackRegistryURL
        self.httpTransport = httpTransport
        self.trustedPublicKeys = trustedPublicKeys
    }

    func fetchRemoteRegistry() async throws -> SystemPluginRemoteRegistry {
        let registryData: Data
        do {
            let (data, _) = try await httpTransport.fetchData(from: registryURL, onProgress: nil)
            registryData = data
        } catch {
            if let fallbackRegistryURL {
                let (data, _) = try await httpTransport.fetchData(from: fallbackRegistryURL, onProgress: nil)
                registryData = data
            } else {
                throw error
            }
        }
        guard let registry = try? JSONDecoder().decode(SystemPluginRemoteRegistry.self, from: registryData),
              registry.schemaVersion == 1 else {
            throw SystemPluginPackageError.downloadFailed("远程 registry.json 格式无效")
        }
        if let expectedPub = trustedPublicKeys[registry.publicKeyID],
           expectedPub != registry.publicKeyEd25519 {
            throw SystemPluginPackageError.untrustedPublisher(registry.publicKeyID)
        }
        return registry
    }

    func fetchPluginPackage(
        pluginID: String,
        stagingDirectoryURL: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard SystemPluginManifest.isValidPluginIdentifier(pluginID) else {
            throw SystemPluginPackageError.invalidPluginID
        }
        onProgress(0.05)

        let registry = try await fetchRemoteRegistry()
        guard let entry = registry.plugins.first(where: { $0.id == pluginID }) else {
            throw SystemPluginPackageError.packageNotFound(pluginID)
        }
        guard let primaryURL = URL(string: entry.downloadURL),
              primaryURL.scheme?.lowercased() == "https" else {
            throw SystemPluginPackageError.downloadFailed("插件下载地址无效")
        }

        onProgress(0.15)
        let archiveData: Data
        do {
            let (data, _) = try await httpTransport.fetchData(from: primaryURL) { fraction in
                onProgress(0.15 + fraction * 0.70)
            }
            archiveData = data
        } catch {
            if let fallbackStr = entry.fallbackDownloadURL,
               let fallbackURL = URL(string: fallbackStr),
               fallbackURL.scheme?.lowercased() == "https" {
                let (data, _) = try await httpTransport.fetchData(from: fallbackURL) { fraction in
                    onProgress(0.15 + fraction * 0.70)
                }
                archiveData = data
            } else {
                throw error
            }
        }

        let actualArchiveSHA = SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
        guard actualArchiveSHA == entry.archiveSHA256 else {
            throw SystemPluginPackageError.signatureMismatch("archive.sha256")
        }

        let fm = FileManager.default
        let archiveFileURL = stagingDirectoryURL.appendingPathComponent("\(pluginID).auplugin.zip")
        let unpackRoot = stagingDirectoryURL.appendingPathComponent("unpacked-\(pluginID)", isDirectory: true)
        if fm.fileExists(atPath: unpackRoot.path) {
            try fm.removeItem(at: unpackRoot)
        }
        try fm.createDirectory(at: unpackRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try archiveData.write(to: archiveFileURL, options: .atomic)

        let candidateDir = try await Self.extractAndLocatePluginBundle(
            archiveURL: archiveFileURL,
            unpackRoot: unpackRoot,
            fileManager: fm
        )
        let manifest = try SystemPluginPackageFactory.verifyPluginDirectory(
            candidateDir,
            trustPolicy: .officialRepository,
            additionalTrustedPublicKeys: trustedPublicKeys,
            fileManager: fm
        )
        guard manifest.id == pluginID,
              manifest.version == entry.version else {
            throw SystemPluginPackageError.signatureMismatch("manifest.id/version")
        }
        onProgress(1.0)
        return candidateDir
    }

    static func extractAndLocatePluginBundle(
        archiveURL: URL,
        unpackRoot: URL,
        fileManager: FileManager = .default
    ) async throws -> URL {
        let srcPath = archiveURL.path
        let dstPath = unpackRoot.path
        let extractStatus: Int32 = try await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            proc.arguments = ["-x", "-k", srcPath, dstPath]
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        }.value
        guard extractStatus == 0 else {
            throw SystemPluginPackageError.downloadFailed("无法解压插件归档包")
        }
        if fileManager.fileExists(atPath: unpackRoot.appendingPathComponent("manifest.json").path) {
            return unpackRoot
        }
        let children = (try? fileManager.contentsOfDirectory(
            at: unpackRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        if let matched = children.first(where: {
            fileManager.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)
        }) {
            return matched
        }
        throw SystemPluginPackageError.manifestMissingOrInvalid
    }
}

// MARK: - Hot-Pluggable System Plugin Manager

@MainActor
final class SystemPluginManager {
    private static let enabledPluginsDefaultsKey = "AndroidUse.SystemPluginManager.enabledPluginIDs"

    let pluginsRootURL: URL

    weak var hostBridge: SystemPluginHostBridge? {
        didSet {
            for plugin in installedPlugins.values {
                if let loc = plugin as? DeveloperLocationPlugin {
                    loc.hostBridge = hostBridge
                }
            }
        }
    }

    var onCatalogChanged: (([SystemPluginCatalogItem]) -> Void)?
    var onLocationTelemetryChanged: ((String, DeveloperLocationTelemetry) -> Void)?

    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let packageFetcher: any SystemPluginPackageFetching
    private let additionalTrustedPublicKeys: [String: String]
    private let locationConsoleTransport: (any LocationConsoleTransport)?
    private var installedPlugins: [String: any HotPluggableSystemPlugin] = [:]
    private var downloadStates: [String: SystemPluginInstallState] = [:]
    private var lastOperationErrors: [String: String] = [:]
    private var remoteCatalogEntries: [String: SystemPluginRemoteCatalogEntry] = [:]
    private var activeOperationIDs: Set<String> = []
    private var runtimeCapabilityReservations: [String: Set<String>] = [:]
    private var runtimeOperationWaiters: [CheckedContinuation<Void, Never>] = []
    private var pluginGenerations: [String: UInt64] = [:]

    init(
        rootURL: URL,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        packageFetcher: any SystemPluginPackageFetching = DefaultSystemPluginPackageFetcher(),
        additionalTrustedPublicKeys: [String: String] = [:],
        locationConsoleTransport: (any LocationConsoleTransport)? = nil
    ) {
        self.pluginsRootURL = rootURL.resolvingSymlinksInPath().appendingPathComponent("plugins", isDirectory: true)
        self.fileManager = fileManager
        self.defaults = defaults
        self.packageFetcher = packageFetcher
        self.additionalTrustedPublicKeys = additionalTrustedPublicKeys
        self.locationConsoleTransport = locationConsoleTransport
        reloadInstalledPluginsFromDisk()
    }

    // MARK: - Generic Plugin Accessors & Health Queries

    var installedCount: Int {
        installedPlugins.count
    }

    var enabledCount: Int {
        installedPlugins.values.filter(\.isEnabled).count
    }

    var installedCatalogItems: [SystemPluginCatalogItem] {
        catalogItems().filter(\.state.isInstalled)
    }

    func plugin(for id: String) -> (any HotPluggableSystemPlugin)? {
        installedPlugins[id]
    }

    func locationPlugin(for id: String = SystemPluginCatalogItem.developerLocationID) -> DeveloperLocationPlugin? {
        installedPlugins[id] as? DeveloperLocationPlugin
    }

    func externalScriptPlugin(for id: String) -> ExternalDeveloperSystemPlugin? {
        installedPlugins[id] as? ExternalDeveloperSystemPlugin
    }

    func pluginHealthStatus(for id: String) -> SystemPluginHealthState {
        installedPlugins[id]?.healthState ?? .inactive
    }

    func pluginStatusText(for id: String) -> String {
        lastOperationErrors[id] ?? installedPlugins[id]?.runtimeStatusSummary ?? "未下载"
    }

    func lastError(for id: String) -> String? {
        lastOperationErrors[id]
    }

    func availableUpdateVersion(for id: String) -> String? {
        guard let installed = installedPlugins[id],
              let remote = remoteCatalogEntries[id],
              let cmp = SystemPluginManifest.compareSemanticVersion(installed.manifest.version, remote.version),
              cmp < 0 else {
            return nil
        }
        return remote.version
    }

    // MARK: - Catalog & Remote Version Discovery

    @discardableResult
    func refreshRemoteCatalog() async -> [SystemPluginCatalogItem] {
        if let registry = try? await packageFetcher.fetchRemoteRegistry() {
            var map: [String: SystemPluginRemoteCatalogEntry] = [:]
            for item in registry.plugins {
                map[item.id] = item
            }
            remoteCatalogEntries = map
            notifyChanged()
        }
        return catalogItems()
    }

    func catalogItems() -> [SystemPluginCatalogItem] {
        var items: [SystemPluginCatalogItem] = []
        var seen = Set<String>()

        var basePresets = SystemPluginCatalogItem.defaultPresetCatalog
        for idx in basePresets.indices {
            let id = basePresets[idx].id
            if let remote = remoteCatalogEntries[id] {
                basePresets[idx].name = remote.name
                basePresets[idx].subtitle = remote.subtitle
                basePresets[idx].version = remote.version
                basePresets[idx].author = remote.author
                basePresets[idx].category = remote.category
                basePresets[idx].iconSymbol = remote.iconSymbol
                basePresets[idx].accentHex = remote.accentHex
                basePresets[idx].capabilities = remote.capabilities
                basePresets[idx].driverType = remote.driverType
            }
        }

        for remote in remoteCatalogEntries.values where !basePresets.contains(where: { $0.id == remote.id }) {
            basePresets.append(
                SystemPluginCatalogItem(
                    id: remote.id,
                    name: remote.name,
                    subtitle: remote.subtitle,
                    version: remote.version,
                    availableUpdateVersion: nil,
                    author: remote.author,
                    category: remote.category,
                    iconSymbol: remote.iconSymbol,
                    accentHex: remote.accentHex,
                    isOfficialPreset: true,
                    packageSizeLabel: "远程组件包",
                    capabilities: remote.capabilities,
                    driverType: remote.driverType,
                    state: .notInstalled,
                    healthState: .inactive,
                    statusDetail: "未下载 · 点击从 GitHub 独立插件仓库获取",
                    lastErrorDetail: nil,
                    downloadSourceDescription: "github.com/samwang0041-star/macdora"
                )
            )
        }

        for var preset in basePresets {
            seen.insert(preset.id)
            preset.lastErrorDetail = lastOperationErrors[preset.id]
            preset.availableUpdateVersion = availableUpdateVersion(for: preset.id)

            if let activeDownload = downloadStates[preset.id], activeDownload.isDownloading {
                preset.state = activeDownload
                if case .downloading(let progress) = activeDownload {
                    preset.statusDetail = String(format: "正在从 GitHub 下载组件包… %.0f%%", progress * 100.0)
                }
            } else if let installed = installedPlugins[preset.id] {
                preset.version = installed.manifest.version
                preset.state = .installed(isEnabled: installed.isEnabled)
                preset.healthState = installed.healthState
                preset.statusDetail = pluginStatusText(for: preset.id)
            } else if let activeDownload = downloadStates[preset.id], case .failed(let reason) = activeDownload {
                preset.state = .failed(reason)
                preset.healthState = .degraded(reason)
                preset.statusDetail = reason
            } else {
                preset.state = .notInstalled
                preset.healthState = .inactive
                preset.statusDetail = "未下载"
            }
            items.append(preset)
        }

        for id in installedPlugins.keys.sorted() where !seen.contains(id) {
            guard let plugin = installedPlugins[id] else { continue }
            let m = plugin.manifest
            let err = lastOperationErrors[id]
            let detail = pluginStatusText(for: id)
            items.append(
                SystemPluginCatalogItem(
                    id: m.id,
                    name: m.name,
                    subtitle: m.subtitle,
                    version: m.version,
                    availableUpdateVersion: availableUpdateVersion(for: m.id),
                    author: m.author,
                    category: m.category,
                    iconSymbol: m.iconSymbol,
                    accentHex: m.accentHex,
                    isOfficialPreset: false,
                    packageSizeLabel: "外部热插拔包",
                    capabilities: m.capabilities,
                    driverType: m.driverType,
                    state: .installed(isEnabled: plugin.isEnabled),
                    healthState: plugin.healthState,
                    statusDetail: detail,
                    lastErrorDetail: err,
                    downloadSourceDescription: "本地 / 开发者插件目录"
                )
            )
        }
        return items
    }

    func isPluginInstalled(_ id: String) -> Bool {
        installedPlugins[id] != nil
    }

    func isPluginEnabled(_ id: String) -> Bool {
        installedPlugins[id]?.isEnabled == true
    }

    func isPluginBusy(_ id: String) -> Bool {
        activeOperationIDs.contains(id)
    }

    // MARK: - On-Demand Download & Atomic Hot-Plug Installation

    @discardableResult
    func downloadAndInstallPlugin(id: String, autoEnable: Bool = false) async throws -> SystemPluginCatalogItem {
        try validatePluginStorage(id: id)
        guard !activeOperationIDs.contains(id) else {
            throw SystemPluginPackageError.operationInProgress(id)
        }
        activeOperationIDs.insert(id)
        defer { finishOperation(id: id) }

        let opGen = bumpGeneration(for: id)
        lastOperationErrors.removeValue(forKey: id)
        downloadStates[id] = .downloading(0.05)
        notifyChanged()

        let stagingRoot = pluginsRootURL.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        do {
            try ensureDirectory(pluginsRootURL)
            try ensureDirectory(stagingRoot)
            defer { try? fileManager.removeItem(at: stagingRoot) }

            let unpackedStagingURL = try await packageFetcher.fetchPluginPackage(
                pluginID: id,
                stagingDirectoryURL: stagingRoot
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.pluginGenerations[id] == opGen,
                          case .downloading(let previous) = self.downloadStates[id] else { return }
                    self.downloadStates[id] = .downloading(max(previous, min(0.98, max(0.05, progress))))
                    self.notifyChanged()
                }
            }

            try Task.checkCancellation()
            guard pluginGenerations[id] == opGen else {
                throw CancellationError()
            }

            let manifest = try SystemPluginPackageFactory.verifyPluginDirectory(
                unpackedStagingURL,
                trustPolicy: .officialRepository,
                additionalTrustedPublicKeys: additionalTrustedPublicKeys,
                fileManager: fileManager
            )
            guard manifest.id == id else {
                throw SystemPluginPackageError.signatureMismatch("manifest.id")
            }

            downloadStates.removeValue(forKey: id)
            lastOperationErrors.removeValue(forKey: id)
            let item = try await commitValidatedPluginDirectory(
                stagedDirectoryURL: unpackedStagingURL,
                manifest: manifest,
                autoEnable: autoEnable,
                expectedGeneration: opGen
            )
            notifyChanged()
            hostBridge?.notifyPluginBanner(item.state.isEnabled ? "「\(manifest.name)」已更新。" : "「\(manifest.name)」已下载，启用后即可使用。")
            return item
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastOperationErrors[id] = msg
            if installedPlugins[id] != nil {
                downloadStates.removeValue(forKey: id)
            } else {
                downloadStates[id] = .failed(msg)
            }
            notifyChanged()
            throw error
        }
    }

    // MARK: - Import External Developer Plugin (Directory or .zip / .auplugin)

    @discardableResult
    func importDeveloperPlugin(from sourceURL: URL, autoEnable: Bool = false) async throws -> SystemPluginCatalogItem {
        try ensureDirectory(pluginsRootURL)
        let stagingRoot = pluginsRootURL.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try ensureDirectory(stagingRoot)
        defer { try? fileManager.removeItem(at: stagingRoot) }

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDir) else {
            throw SystemPluginPackageError.packageNotFound(sourceURL.lastPathComponent)
        }

        let candidateDir: URL
        if isDir.boolValue {
            candidateDir = stagingRoot.appendingPathComponent("bundle", isDirectory: true)
            try fileManager.copyItem(at: sourceURL, to: candidateDir)
        } else if ["zip", "auplugin"].contains(sourceURL.pathExtension.lowercased()) {
            let unpackDir = stagingRoot.appendingPathComponent("unpacked", isDirectory: true)
            try ensureDirectory(unpackDir)
            candidateDir = try await DefaultSystemPluginPackageFetcher.extractAndLocatePluginBundle(
                archiveURL: sourceURL,
                unpackRoot: unpackDir,
                fileManager: fileManager
            )
        } else {
            throw SystemPluginPackageError.manifestMissingOrInvalid
        }

        let manifest = try SystemPluginPackageFactory.verifyPluginDirectory(
            candidateDir,
            trustPolicy: .developerLocalImport,
            additionalTrustedPublicKeys: additionalTrustedPublicKeys,
            fileManager: fileManager
        )
        let id = manifest.id
        try validatePluginStorage(id: id)
        guard !activeOperationIDs.contains(id) else {
            throw SystemPluginPackageError.operationInProgress(id)
        }
        activeOperationIDs.insert(id)
        defer { finishOperation(id: id) }

        let opGen = bumpGeneration(for: id)
        lastOperationErrors.removeValue(forKey: id)
        let item = try await commitValidatedPluginDirectory(
            stagedDirectoryURL: candidateDir,
            manifest: manifest,
            autoEnable: autoEnable,
            expectedGeneration: opGen
        )
        downloadStates.removeValue(forKey: id)
        notifyChanged()
        hostBridge?.notifyPluginBanner(item.state.isEnabled ? "「\(manifest.name)」已更新。" : "「\(manifest.name)」已导入，启用后即可使用。")
        return item
    }

    // MARK: - Atomic Commit with Backup & Rollback

    private func commitValidatedPluginDirectory(
        stagedDirectoryURL: URL,
        manifest: SystemPluginManifest,
        autoEnable: Bool,
        expectedGeneration: UInt64
    ) async throws -> SystemPluginCatalogItem {
        let id = manifest.id
        let destinationURL = pluginsRootURL.appendingPathComponent(id, isDirectory: true)
        let backupURL = pluginsRootURL.appendingPathComponent(".backup-\(id)-\(UUID().uuidString)", isDirectory: true)
        let previousPlugin = installedPlugins[id]
        let wasPreviouslyEnabled = previousPlugin != nil
            && (previousPlugin?.isEnabled == true || persistedEnabledPluginIDs().contains(id))
        let shouldEnable = autoEnable || wasPreviouslyEnabled

        try validatePluginStorage(id: id)
        if shouldEnable {
            let capabilities = Set(manifest.capabilities + (previousPlugin?.manifest.capabilities ?? []))
                .intersection(SystemPluginManifest.exclusiveCapabilities)
            if let conflictingID = busyRuntimeConflict(id: id, capabilities: capabilities) {
                throw SystemPluginPackageError.operationInProgress(conflictingID)
            }
            runtimeCapabilityReservations[id] = capabilities
        }
        notifyChanged()
        if let existing = previousPlugin, existing.isEnabled {
            if let bridge = hostBridge {
                guard await existing.deactivate(bridge: bridge) else {
                    throw SystemPluginPackageError.operationFailed("未能停用插件，请重试后再更新。")
                }
            } else {
                await existing.setEnabledWithoutBridge(false)
            }
        }

        guard pluginGenerations[id] == expectedGeneration else {
            throw CancellationError()
        }
        try validatePluginStorage(id: id)

        var movedOldToBackup = false
        var movedNewIntoPlace = false
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.moveItem(at: destinationURL, to: backupURL)
                movedOldToBackup = true
            }
            try fileManager.moveItem(at: stagedDirectoryURL, to: destinationURL)
            movedNewIntoPlace = true
            let newPlugin = createPluginInstance(manifest: manifest, bundleURL: destinationURL)
            installedPlugins[id] = newPlugin
            if shouldEnable {
                guard await setPluginEnabledInternal(
                    id: id, enabled: true, generation: expectedGeneration, waitForRuntime: true
                ) else {
                    throw SystemPluginPackageError.operationFailed(lastOperationErrors[id] ?? "更新后未能恢复启用，已保留原设置。")
                }
            } else {
                persistEnabled(id: id, enabled: false)
            }
            // Keep the old instance and package recoverable until activation commits.
            previousPlugin?.retire()
            if movedOldToBackup { try? fileManager.removeItem(at: backupURL) }
        } catch {
            if let provisional = installedPlugins[id], provisional !== previousPlugin {
                if provisional.isEnabled {
                    if let bridge = hostBridge {
                        guard await provisional.deactivate(bridge: bridge) else {
                            throw SystemPluginPackageError.operationFailed("更新未完成，插件暂时无法停用，设置已保留，请重试。")
                        }
                    } else {
                        await provisional.setEnabledWithoutBridge(false)
                    }
                }
                provisional.retire()
            }
            if movedNewIntoPlace { try? fileManager.removeItem(at: destinationURL) }
            if movedOldToBackup { try? fileManager.moveItem(at: backupURL, to: destinationURL) }
            if let prev = previousPlugin {
                let policy: SystemPluginTrustPolicy = id.hasPrefix("builtin.") ? .officialRepository : .developerLocalImport
                let restored = try? SystemPluginPackageFactory.verifyPluginDirectory(
                    destinationURL, trustPolicy: policy,
                    additionalTrustedPublicKeys: additionalTrustedPublicKeys, fileManager: fileManager
                )
                guard restored == prev.manifest else {
                    prev.retire()
                    installedPlugins.removeValue(forKey: id)
                    persistEnabled(id: id, enabled: false)
                    throw SystemPluginPackageError.operationFailed("更新未完成，设置已保留，请重新下载插件。")
                }
                installedPlugins[id] = prev
                if wasPreviouslyEnabled {
                    if let bridge = hostBridge {
                        await prev.activate(bridge: bridge)
                    } else {
                        await prev.setEnabledWithoutBridge(true)
                    }
                }
            } else {
                installedPlugins.removeValue(forKey: id)
                persistEnabled(id: id, enabled: false)
            }
            throw error
        }

        if let item = catalogItems().first(where: { $0.id == id }) {
            return item
        }
        return SystemPluginCatalogItem(
            id: manifest.id,
            name: manifest.name,
            subtitle: manifest.subtitle,
            version: manifest.version,
            availableUpdateVersion: nil,
            author: manifest.author,
            category: manifest.category,
            iconSymbol: manifest.iconSymbol,
            accentHex: manifest.accentHex,
            isOfficialPreset: manifest.id.hasPrefix("builtin."),
            packageSizeLabel: "已下载",
            capabilities: manifest.capabilities,
            driverType: manifest.driverType,
            state: .installed(isEnabled: installedPlugins[id]?.isEnabled ?? false),
            healthState: installedPlugins[id]?.healthState ?? .inactive,
            statusDetail: installedPlugins[id]?.runtimeStatusSummary ?? "未启用",
            lastErrorDetail: nil,
            downloadSourceDescription: "本地插件目录"
        )
    }

    // MARK: - Enable / Disable / Delete / Hot-Reload

    func setPluginEnabled(id: String, enabled: Bool) async {
        guard !activeOperationIDs.contains(id), let plugin = installedPlugins[id], plugin.isEnabled != enabled else { return }
        activeOperationIDs.insert(id)
        runtimeCapabilityReservations[id] = Set(plugin.manifest.capabilities).intersection(SystemPluginManifest.exclusiveCapabilities)
        defer { finishOperation(id: id) }
        lastOperationErrors.removeValue(forKey: id)
        notifyChanged()
        let gen = bumpGeneration(for: id)
        await setPluginEnabledInternal(id: id, enabled: enabled, generation: gen)
    }

    @discardableResult
    private func setPluginEnabledInternal(
        id: String, enabled: Bool, generation: UInt64, waitForRuntime: Bool = false
    ) async -> Bool {
        guard let plugin = installedPlugins[id] else { return false }
        let requestedExclusive = Set(plugin.manifest.capabilities).intersection(SystemPluginManifest.exclusiveCapabilities)
        if enabled && !requestedExclusive.isEmpty {
            while true {
                guard pluginGenerations[id] == generation, !Task.isCancelled else { return false }
                if busyRuntimeConflict(id: id, capabilities: requestedExclusive) != nil {
                    guard waitForRuntime else {
                        lastOperationErrors[id] = "相关插件正在处理中，请稍后再启用。"
                        return false
                    }
                    notifyChanged()
                    await withCheckedContinuation { runtimeOperationWaiters.append($0) }
                    continue
                }
                guard let (otherID, otherPlugin) = installedPlugins.first(where: {
                    $0.key != id && $0.value.isEnabled
                        && !Set($0.value.manifest.capabilities).intersection(requestedExclusive).isEmpty
                }) else { break }
                let ownsOperation = activeOperationIDs.insert(otherID).inserted
                let previousReservation = runtimeCapabilityReservations[otherID]
                runtimeCapabilityReservations[otherID] = Set(otherPlugin.manifest.capabilities).intersection(SystemPluginManifest.exclusiveCapabilities)
                notifyChanged()
                let stopped: Bool
                if let bridge = hostBridge {
                    stopped = await otherPlugin.deactivate(bridge: bridge)
                } else {
                    await otherPlugin.setEnabledWithoutBridge(false)
                    stopped = true
                }
                if stopped {
                    persistEnabled(id: otherID, enabled: false)
                    lastOperationErrors.removeValue(forKey: otherID)
                }
                if ownsOperation {
                    finishOperation(id: otherID)
                } else {
                    runtimeCapabilityReservations[otherID] = previousReservation
                    resumeRuntimeWaiters()
                    notifyChanged()
                }
                guard stopped else {
                    lastOperationErrors[id] = "请先停用「\(otherPlugin.manifest.name)」后重试。"
                    return false
                }
            }
        }

        if let bridge = hostBridge {
            if enabled {
                await plugin.activate(bridge: bridge)
            } else {
                guard await plugin.deactivate(bridge: bridge) else {
                    lastOperationErrors[id] = "停用失败，数据已保留，请重试。"
                    return false
                }
            }
        } else {
            await plugin.setEnabledWithoutBridge(enabled)
        }
        guard pluginGenerations[id] == generation else { return false }
        persistEnabled(id: id, enabled: plugin.isEnabled)
        notifyChanged()
        return plugin.isEnabled == enabled
    }

    func deletePlugin(id: String) async throws {
        try validatePluginStorage(id: id)
        guard !activeOperationIDs.contains(id) else {
            throw SystemPluginPackageError.operationInProgress(id)
        }
        activeOperationIDs.insert(id)
        defer { finishOperation(id: id) }
        let deletionGen = bumpGeneration(for: id)
        lastOperationErrors.removeValue(forKey: id)
        notifyChanged()

        let existingPlugin = installedPlugins[id]
        let wasEnabled = existingPlugin != nil
            && (existingPlugin?.isEnabled == true || persistedEnabledPluginIDs().contains(id))
        if wasEnabled, let existingPlugin {
            runtimeCapabilityReservations[id] = Set(existingPlugin.manifest.capabilities).intersection(SystemPluginManifest.exclusiveCapabilities)
        }

        if let plugin = existingPlugin {
            if plugin.isEnabled, let bridge = hostBridge {
                guard await plugin.deactivate(bridge: bridge) else {
                    let message = "未能停用插件，尚未删除，请重试。"
                    lastOperationErrors[id] = message
                    throw SystemPluginPackageError.operationFailed(message)
                }
            } else {
                await plugin.setEnabledWithoutBridge(false)
            }
        }

        guard pluginGenerations[id] == deletionGen else {
            throw CancellationError()
        }
        try validatePluginStorage(id: id)

        let dir = pluginsRootURL.appendingPathComponent(id, isDirectory: true)
        let trashStagingURL = pluginsRootURL.appendingPathComponent(".delete-\(id)-\(UUID().uuidString)", isDirectory: true)
        if fileManager.fileExists(atPath: dir.path) {
            do {
                try removePluginResiduals(id: id)
                try fileManager.moveItem(at: dir, to: trashStagingURL)
                try fileManager.removeItem(at: trashStagingURL)
            } catch {
                if fileManager.fileExists(atPath: trashStagingURL.path),
                   !fileManager.fileExists(atPath: dir.path) {
                    try? fileManager.moveItem(at: trashStagingURL, to: dir)
                }
                if let plugin = existingPlugin, wasEnabled {
                    let policy: SystemPluginTrustPolicy = id.hasPrefix("builtin.") ? .officialRepository : .developerLocalImport
                    let restored = try? SystemPluginPackageFactory.verifyPluginDirectory(
                        dir, trustPolicy: policy, additionalTrustedPublicKeys: additionalTrustedPublicKeys, fileManager: fileManager
                    )
                    if restored == plugin.manifest {
                        if let bridge = hostBridge {
                            await plugin.activate(bridge: bridge)
                        } else {
                            await plugin.setEnabledWithoutBridge(true)
                        }
                    } else {
                        await plugin.setEnabledWithoutBridge(false)
                        persistEnabled(id: id, enabled: false)
                    }
                }
                let msg = "删除失败，请重试：\(error.localizedDescription)"
                lastOperationErrors[id] = msg
                notifyChanged()
                throw SystemPluginPackageError.operationFailed(msg)
            }
        } else {
            try removePluginResiduals(id: id)
        }

        existingPlugin?.deletePersistentData()
        // The ID can have used another driver in an earlier package version.
        DeveloperLocationPlugin.deleteStoredConfiguration(id: id, defaults: defaults)
        installedPlugins.removeValue(forKey: id)
        var enabledSet = persistedEnabledPluginIDs()
        enabledSet.remove(id)
        savePersistedEnabledPluginIDs(enabledSet)
        downloadStates.removeValue(forKey: id)
        lastOperationErrors.removeValue(forKey: id)
        notifyChanged()
        hostBridge?.notifyPluginBanner("插件及其设置已删除。")
    }

    func reloadInstalledPluginsFromDisk() {
        guard activeOperationIDs.isEmpty,
              pluginsRootURL.resolvingSymlinksInPath().path == pluginsRootURL.path else { return }
        let previousPlugins = installedPlugins
        var discovered: [String: any HotPluggableSystemPlugin] = [:]
        let enabledSet = persistedEnabledPluginIDs()

        if let entries = try? fileManager.contentsOfDirectory(
            at: pluginsRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let trustPolicy: SystemPluginTrustPolicy = url.lastPathComponent.hasPrefix("builtin.")
                    ? .officialRepository
                    : .developerLocalImport
                guard let manifest = try? SystemPluginPackageFactory.verifyPluginDirectory(
                    url,
                    trustPolicy: trustPolicy,
                    additionalTrustedPublicKeys: additionalTrustedPublicKeys,
                    fileManager: fileManager
                ), manifest.id == url.lastPathComponent else {
                    continue
                }
                if let existing = previousPlugins[manifest.id],
                   existing.manifest == manifest,
                   existing.bundleDirectoryURL.standardizedFileURL == url.standardizedFileURL {
                    discovered[manifest.id] = existing
                } else {
                    discovered[manifest.id] = createPluginInstance(manifest: manifest, bundleURL: url)
                }
            }
        }

        installedPlugins = discovered

        for (oldID, oldPlugin) in previousPlugins {
            let stillSameInstance = discovered[oldID] === oldPlugin
            let shouldStayEnabled = stillSameInstance && enabledSet.contains(oldID)
            if !shouldStayEnabled && oldPlugin.isEnabled {
                _ = bumpGeneration(for: oldID)
                let bridge = hostBridge
                Task { @MainActor in
                    if let bridge {
                        await oldPlugin.deactivate(bridge: bridge)
                    } else {
                        await oldPlugin.setEnabledWithoutBridge(false)
                    }
                }
            }
        }

        for (id, plugin) in installedPlugins where enabledSet.contains(id) && !plugin.isEnabled {
            let capturedGen = bumpGeneration(for: id)
            Task { @MainActor [weak self] in
                guard let self,
                      self.pluginGenerations[id] == capturedGen,
                      self.installedPlugins[id] === plugin,
                      self.persistedEnabledPluginIDs().contains(id) else {
                    return
                }
                await self.setPluginEnabled(id: id, enabled: true)
            }
        }
        notifyChanged()
    }

    // MARK: - Runtime Lifecycle Notifications

    func handleRuntimeBecameReady() async {
        guard let bridge = hostBridge else { return }
        for plugin in installedPlugins.values where plugin.isEnabled {
            await plugin.onRuntimeBecameReady(bridge: bridge)
        }
        notifyChanged()
    }

    func handleAppLaunching(package: String) async {
        guard let bridge = hostBridge else { return }
        for plugin in installedPlugins.values where plugin.isEnabled {
            await plugin.onAppLaunching(package: package, bridge: bridge)
        }
    }

    func handleRuntimeStopping() async {
        guard let bridge = hostBridge else { return }
        for plugin in installedPlugins.values where plugin.isEnabled {
            await plugin.onRuntimeStopping(bridge: bridge)
        }
        notifyChanged()
    }

    // MARK: - Helpers

    private func createPluginInstance(manifest: SystemPluginManifest, bundleURL: URL) -> any HotPluggableSystemPlugin {
        if manifest.driverType == "hardware_gnss_location" {
            let loc = DeveloperLocationPlugin(
                manifest: manifest,
                bundleDirectoryURL: bundleURL,
                defaults: defaults,
                consoleTransport: locationConsoleTransport
            )
            loc.hostBridge = hostBridge
            var lastReportedEnabled = loc.isEnabled
            var lastReportedHealth = loc.healthState
            loc.onTelemetryChanged = { [weak self, weak loc] telemetry in
                guard let self, let loc, self.installedPlugins[manifest.id] === loc else { return }
                self.onLocationTelemetryChanged?(manifest.id, telemetry)
                if telemetry.isPluginEnabled != lastReportedEnabled || telemetry.healthState != lastReportedHealth {
                    lastReportedEnabled = telemetry.isPluginEnabled
                    lastReportedHealth = telemetry.healthState
                    self.notifyChanged()
                }
            }
            return loc
        } else {
            return ExternalDeveloperSystemPlugin(manifest: manifest, bundleDirectoryURL: bundleURL)
        }
    }

    @discardableResult
    private func bumpGeneration(for id: String) -> UInt64 {
        let next = (pluginGenerations[id] ?? 0) &+ 1
        pluginGenerations[id] = next
        return next
    }

    private func persistedEnabledPluginIDs() -> Set<String> {
        let list = defaults.stringArray(forKey: Self.enabledPluginsDefaultsKey) ?? []
        return Set(list)
    }

    private func savePersistedEnabledPluginIDs(_ ids: Set<String>) {
        defaults.set(Array(ids).sorted(), forKey: Self.enabledPluginsDefaultsKey)
    }

    private func persistEnabled(id: String, enabled: Bool) {
        var ids = persistedEnabledPluginIDs()
        if enabled {
            if let plugin = installedPlugins[id] {
                let capabilities = Set(plugin.manifest.capabilities).intersection(SystemPluginManifest.exclusiveCapabilities)
                for otherID in Array(ids) where otherID != id {
                    if let other = installedPlugins[otherID], !Set(other.manifest.capabilities).intersection(capabilities).isEmpty {
                        ids.remove(otherID)
                    }
                }
            }
            ids.insert(id)
        } else {
            ids.remove(id)
        }
        savePersistedEnabledPluginIDs(ids)
    }

    private func finishOperation(id: String) {
        activeOperationIDs.remove(id)
        runtimeCapabilityReservations.removeValue(forKey: id)
        resumeRuntimeWaiters()
        notifyChanged()
    }

    private func resumeRuntimeWaiters() {
        let pending = runtimeOperationWaiters
        runtimeOperationWaiters.removeAll()
        pending.forEach { $0.resume() }
    }

    private func busyRuntimeConflict(id: String, capabilities: Set<String>) -> String? {
        guard !capabilities.isEmpty else { return nil }
        return activeOperationIDs.first { otherID in
            guard otherID != id else { return false }
            if let reserved = runtimeCapabilityReservations[otherID] {
                return !reserved.intersection(capabilities).isEmpty
            }
            guard let other = installedPlugins[otherID], other.isEnabled else { return false }
            return !Set(other.manifest.capabilities).intersection(capabilities).isEmpty
        }
    }

    private func validatePluginStorage(id: String) throws {
        guard SystemPluginManifest.isValidPluginIdentifier(id) else {
            throw SystemPluginPackageError.invalidPluginID
        }
        let directory = pluginsRootURL.appendingPathComponent(id, isDirectory: true)
        guard pluginsRootURL.resolvingSymlinksInPath().path == pluginsRootURL.path,
              directory.resolvingSymlinksInPath().path == directory.path else {
            throw SystemPluginPackageError.unsafePackageContent
        }
    }

    private func removePluginResiduals(id: String) throws {
        guard fileManager.fileExists(atPath: pluginsRootURL.path) else { return }
        let prefixes = [".backup-\(id)-", ".delete-\(id)-", ".uninstall-\(id)-"]
        let entries = try fileManager.contentsOfDirectory(at: pluginsRootURL, includingPropertiesForKeys: nil)
        for entry in entries {
            let name = entry.lastPathComponent
            let owned = prefixes.contains { prefix in
                name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
            }
            guard owned else { continue }
            guard try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw SystemPluginPackageError.unsafePackageContent
            }
            try fileManager.removeItem(at: entry)
        }
    }

    private func ensureDirectory(_ url: URL) throws {
        guard url.resolvingSymlinksInPath().path == url.path else {
            throw SystemPluginPackageError.unsafePackageContent
        }
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDir) {
            guard isDir.boolValue else { throw SystemPluginPackageError.unsafePackageContent }
            return
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func notifyChanged() {
        let snapshot = catalogItems()
        onCatalogChanged?(snapshot)
        hostBridge?.notifyPluginStateDidChange()
    }
}
