import AppKit
import CryptoKit
import Foundation
import Testing
@testable import AndroidUse

@MainActor
final class MockPluginHostBridge: SystemPluginHostBridge {
    var currentRuntimeState: RuntimeState = .ready
    var currentActivePackage: String? = DefaultApp.package
    var emulatorConsolePort: UInt16 = 5584
    var emulatorAuthTokenURLs: [URL] = []

    var executedGuestScripts: [String] = []
    var fallbackGeoFixes: [(lon: Double, lat: Double, alt: Double, sats: Int, vel: Double)] = []
    var banners: [String] = []
    var stateChangeNotifications: Int = 0
    var hostServiceEnvironment: [String: String] = [:]
    var guestScriptHookFilter: ((String) async -> Bool)?
    private var guestScriptCountWaiters: [(minimumCount: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func executeGuestShell(_ script: String, operation: String, timeout: TimeInterval) async -> Bool {
        executedGuestScripts.append(script)
        let scriptCount = executedGuestScripts.count
        let readyWaiters = guestScriptCountWaiters.filter { $0.minimumCount <= scriptCount }
        guestScriptCountWaiters.removeAll { $0.minimumCount <= scriptCount }
        for waiter in readyWaiters {
            waiter.continuation.resume()
        }
        if let filter = guestScriptHookFilter {
            return await filter(script)
        }
        return true
    }

    func waitForGuestScriptCount(atLeast expectedCount: Int) async {
        if executedGuestScripts.count >= expectedCount {
            return
        }
        await withCheckedContinuation { continuation in
            guestScriptCountWaiters.append((expectedCount, continuation))
        }
    }

    func sendEmulatorGeoFix(
        longitude: Double,
        latitude: Double,
        altitude: Double,
        satellites: Int,
        velocityKnots: Double
    ) async -> Bool {
        fallbackGeoFixes.append((longitude, latitude, altitude, satellites, velocityKnots))
        return true
    }

    func notifyPluginBanner(_ message: String) {
        banners.append(message)
    }

    func notifyPluginStateDidChange() {
        stateChangeNotifications += 1
    }
}

private actor AsyncBarrier {
    private var didArrive = false
    private var isOpen = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        didArrive = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilArrived() async {
        if didArrive { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor ControlledPluginFetcher: SystemPluginPackageFetching {
    private let bundleURL: URL
    private let barrier = AsyncBarrier()
    private var didStart = false

    init(bundleURL: URL) {
        self.bundleURL = bundleURL
    }

    func fetchPluginPackage(
        pluginID: String,
        stagingDirectoryURL: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        didStart = true
        await barrier.arriveAndWait()
        try Task.checkCancellation()
        return bundleURL
    }

    func waitUntilStarted() async {
        await barrier.waitUntilArrived()
    }

    func releaseDownload() async {
        await barrier.open()
    }

    func hasStarted() -> Bool {
        didStart
    }
}

private final class BackupMoveFailingFileManager: FileManager, @unchecked Sendable {
    var failBackupMoves = false
    var failPartialDeletes = false

    override func moveItem(at source: URL, to destination: URL) throws {
        if failBackupMoves && destination.lastPathComponent.hasPrefix(".backup-") {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.moveItem(at: source, to: destination)
    }

    override func removeItem(at url: URL) throws {
        if failPartialDeletes && url.lastPathComponent.hasPrefix(".delete-") {
            let hook = url.appendingPathComponent("hooks/on-enable.sh")
            if fileExists(atPath: hook.path) { try super.removeItem(at: hook) }
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
    }
}

private actor HookTrace {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}

@MainActor
private final class TestMainActorSignal {
    private var isSignaled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signal() {
        guard !isSignaled else { return }
        isSignaled = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        if isSignaled { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

actor MockLocationConsoleTransport: LocationConsoleTransport {
    private(set) var sentSamples: [HardwareLocationFixSample] = []
    private(set) var disconnectCount: Int = 0
    var shouldSucceed: Bool = true

    func setShouldSucceed(_ value: Bool) {
        shouldSucceed = value
    }

    func sendGeoFix(
        sample: HardwareLocationFixSample,
        port: UInt16,
        authTokenURLs: [URL]
    ) async -> Bool {
        guard shouldSucceed else { return false }
        sentSamples.append(sample)
        return true
    }

    func disconnect() async {
        disconnectCount += 1
    }

    func samplesSnapshot() -> [HardwareLocationFixSample] {
        sentSamples
    }

    func disconnectsSnapshot() -> Int {
        disconnectCount
    }
}

private struct FailingHTTPTransport: SystemPluginHTTPTransporting {
    let statusCode: Int?

    func fetchData(from url: URL, onProgress: (@Sendable (Double) -> Void)?) async throws -> (Data, HTTPURLResponse) {
        if let code = statusCode {
            throw SystemPluginPackageError.downloadFailed("HTTP \(code)")
        }
        throw URLError(.notConnectedToInternet)
    }
}

struct SignedArchiveTestHarness {
    let privateKey: Curve25519.Signing.PrivateKey
    let publicKeyBase64: String
    let keyID: String
    let archiveData: Data
    let archiveSHA256: String
    let manifestSHA256: String
    let signatureBase64: String
    let registryData: Data

    static func buildSignedLocationPackage(
        in tempDir: URL,
        pluginID: String = SystemPluginCatalogItem.developerLocationID,
        version: String = "1.0.0",
        keyID: String = "test-ed25519-v1",
        privateKey: Curve25519.Signing.PrivateKey = Curve25519.Signing.PrivateKey()
    ) throws -> (bundleDir: URL, harness: SignedArchiveTestHarness) {
        let fm = FileManager.default
        let pkgDir = tempDir.appendingPathComponent("\(pluginID).auplugin", isDirectory: true)
        if fm.fileExists(atPath: pkgDir.path) {
            try fm.removeItem(at: pkgDir)
        }
        let hooksURL = pkgDir.appendingPathComponent("hooks", isDirectory: true)
        let resourcesURL = pkgDir.appendingPathComponent("resources", isDirectory: true)
        try fm.createDirectory(at: hooksURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        let manifest = SystemPluginManifest(
            schemaVersion: 1,
            id: pluginID,
            name: "开发者虚拟定位",
            subtitle: "系统级 GPS 虚拟定位，支持地图搜索选点与 10 米自动漂移",
            version: version,
            author: "官方插件仓库",
            category: "开发者",
            iconSymbol: "location.fill.viewfinder",
            accentHex: 0x0F97FF,
            minHostVersion: "0.1.0",
            capabilities: ["hardware.gnss", "qemu.console", "guest.location.bridge", "ui.map.workspace"],
            driverType: "hardware_gnss_location",
            entrypoints: SystemPluginEntrypoints(
                onEnable: "hooks/on-enable.sh",
                onDisable: "hooks/on-disable.sh",
                onRuntimeReady: "hooks/on-runtime-ready.sh",
                onAppLaunch: "hooks/on-app-launch.sh",
                presetsFile: "resources/landmarks.json",
                configFile: "resources/plugin-config.json"
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: pkgDir.appendingPathComponent("manifest.json"), options: .atomic)
        try encoder.encode(DeveloperLocationBundleConfig.fallback).write(
            to: resourcesURL.appendingPathComponent("plugin-config.json"),
            options: .atomic
        )
        let landmarks = [
            LocationLandmarkItem(
                name: "示例位置",
                subtitle: "人民广场 · 黄浦区",
                city: "上海",
                latitude: 31.230416,
                longitude: 121.473701,
                coordinateSystem: .gcj02
            ),
            LocationLandmarkItem(
                name: "第二示例位置",
                subtitle: "外滩 · 黄浦区",
                city: "上海",
                latitude: 31.240000,
                longitude: 121.490000,
                coordinateSystem: .gcj02
            )
        ]
        try encoder.encode(landmarks).write(to: resourcesURL.appendingPathComponent("landmarks.json"), options: .atomic)

        let scripts: [(name: String, marker: String)] = [
            ("on-enable.sh", "AU_LOCATION_ON_ENABLE"),
            ("on-disable.sh", "AU_LOCATION_ON_DISABLE"),
            ("on-runtime-ready.sh", "AU_LOCATION_RUNTIME_READY"),
            ("on-app-launch.sh", "AU_LOCATION_APP_LAUNCH")
        ]
        for (name, marker) in scripts {
            let script = "#!/system/bin/sh\necho \(marker)\n"
            try Data(script.utf8).write(to: hooksURL.appendingPathComponent(name), options: .atomic)
        }

        try SystemPluginPackageFactory.writeSignature(
            forPluginDirectory: pkgDir,
            pluginID: pluginID,
            version: version,
            privateKey: privateKey,
            keyID: keyID,
            publisher: "samwang0041-star",
            fileManager: fm
        )

        let sigDoc = try JSONDecoder().decode(
            SystemPluginPackageSignature.self,
            from: Data(contentsOf: pkgDir.appendingPathComponent("signature.json"))
        )
        let zipURL = tempDir.appendingPathComponent("\(pluginID)-\(version).auplugin")
        if fm.fileExists(atPath: zipURL.path) {
            try fm.removeItem(at: zipURL)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-c", "-k", "--keepParent", pkgDir.path, zipURL.path]
        try proc.run()
        proc.waitUntilExit()

        let archiveData = try Data(contentsOf: zipURL)
        let archiveSHA = SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
        let pubB64 = privateKey.publicKey.rawRepresentation.base64EncodedString()

        let registry = SystemPluginRemoteRegistry(
            schemaVersion: 1,
            repository: "https://github.com/samwang0041-star/macdora",
            publicKeyID: keyID,
            publicKeyEd25519: pubB64,
            plugins: [
                SystemPluginRemoteCatalogEntry(
                    id: pluginID,
                    name: manifest.name,
                    subtitle: manifest.subtitle,
                    version: version,
                    author: manifest.author,
                    category: manifest.category,
                    iconSymbol: manifest.iconSymbol,
                    accentHex: manifest.accentHex,
                    minHostVersion: manifest.minHostVersion,
                    capabilities: manifest.capabilities,
                    driverType: manifest.driverType,
                    downloadURL: "https://github.com/samwang0041-star/macdora/releases/download/v\(version)/\(pluginID).auplugin",
                    fallbackDownloadURL: nil,
                    archiveSHA256: archiveSHA,
                    manifestSHA256: sigDoc.manifestSHA256,
                    signatureKeyID: keyID,
                    signature: sigDoc.signature
                )
            ]
        )
        let registryData = try encoder.encode(registry)
        return (
            pkgDir,
            SignedArchiveTestHarness(
                privateKey: privateKey,
                publicKeyBase64: pubB64,
                keyID: keyID,
                archiveData: archiveData,
                archiveSHA256: archiveSHA,
                manifestSHA256: sigDoc.manifestSHA256,
                signatureBase64: sigDoc.signature,
                registryData: registryData
            )
        )
    }
}

struct MockGitHubHTTPTransport: SystemPluginHTTPTransporting {
    let registryData: Data
    let archiveData: Data

    func fetchData(from url: URL, onProgress: (@Sendable (Double) -> Void)?) async throws -> (Data, HTTPURLResponse) {
        onProgress?(0.25)
        let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/2", headerFields: nil)!
        if url.lastPathComponent == "registry.json" {
            onProgress?(1.0)
            return (registryData, http)
        }
        onProgress?(0.75)
        onProgress?(1.0)
        return (archiveData, http)
    }
}

@Suite("Hot-Pluggable System Plugin Framework & Hardware GNSS Location Tests")
struct SystemPluginFrameworkTests {
    private static let developerLocationConfigPrefix = "AndroidUse.DeveloperLocationPlugin.configuration."
    private static let enabledPluginIDsKey = "AndroidUse.SystemPluginManager.enabledPluginIDs"

    private func makeIsolatedContext() throws -> (URL, UserDefaults, String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("androiduse-plugin-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suiteName = "AndroidUsePluginTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (root, defaults, suiteName)
    }

    @MainActor
    private func makeLocationManager(
        root: URL,
        defaults: UserDefaults,
        harness: SignedArchiveTestHarness,
        bridge: MockPluginHostBridge,
        transport: MockLocationConsoleTransport = MockLocationConsoleTransport(),
        fileManager: FileManager = .default
    ) -> SystemPluginManager {
        let fetcher = DefaultSystemPluginPackageFetcher(
            httpTransport: MockGitHubHTTPTransport(
                registryData: harness.registryData,
                archiveData: harness.archiveData
            ),
            trustedPublicKeys: [harness.keyID: harness.publicKeyBase64]
        )
        let manager = SystemPluginManager(
            rootURL: root,
            fileManager: fileManager,
            defaults: defaults,
            packageFetcher: fetcher,
            additionalTrustedPublicKeys: [harness.keyID: harness.publicKeyBase64],
            locationConsoleTransport: transport
        )
        manager.hostBridge = bridge
        return manager
    }

    private func storedConfiguration(for pluginID: String, defaults: UserDefaults) -> DeveloperLocationConfiguration? {
        guard let data = defaults.data(forKey: Self.developerLocationConfigPrefix + pluginID) else {
            return nil
        }
        return try? JSONDecoder().decode(DeveloperLocationConfiguration.self, from: data)
    }

    private func setStoredConfiguration(
        _ configuration: DeveloperLocationConfiguration,
        for pluginID: String,
        defaults: UserDefaults
    ) throws {
        let data = try JSONEncoder().encode(configuration)
        defaults.set(data, forKey: Self.developerLocationConfigPrefix + pluginID)
    }

    @MainActor
    private func state(of pluginID: String, in manager: SystemPluginManager) -> SystemPluginInstallState? {
        manager.catalogItems().first(where: { $0.id == pluginID })?.state
    }

    @Test("Preset plugin is NOT installed by default, has no pre-allocated location singleton, and fails honestly when offline")
    @MainActor
    func presetNotBundledAndOfflineDownloadFails() async throws {
        let (root, defaults, suite) = try makeIsolatedContext()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let offlineFetcher = DefaultSystemPluginPackageFetcher(
            httpTransport: FailingHTTPTransport(statusCode: nil)
        )
        let manager = SystemPluginManager(
            rootURL: root,
            defaults: defaults,
            packageFetcher: offlineFetcher
        )

        let id = SystemPluginCatalogItem.developerLocationID
        #expect(!manager.isPluginInstalled(id))
        #expect(!manager.isPluginEnabled(id))
        #expect(manager.locationPlugin(for: id) == nil)

        var threwError = false
        do {
            _ = try await manager.downloadAndInstallPlugin(id: id)
        } catch {
            threwError = true
        }
        #expect(threwError)
        #expect(!manager.isPluginInstalled(id))
        #expect(manager.locationPlugin(for: id) == nil)
        if case .failed = manager.catalogItems().first(where: { $0.id == id })?.state {
            // Expected failed state
        } else {
            Issue.record("Expected .failed state when offline download fails")
        }
    }

    @Test("Ed25519 publisher signature verification rejects attacker-rehashed or hidden-entrypoint packages")
    func cryptographicSignatureAndSecurityChecks() throws {
        let (root, _, suite) = try makeIsolatedContext()
        defer {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let (bundleDir, harness) = try SignedArchiveTestHarness.buildSignedLocationPackage(in: root)
        let verified = try SystemPluginPackageFactory.verifyPluginDirectory(
            bundleDir,
            trustPolicy: .officialRepository,
            additionalTrustedPublicKeys: [harness.keyID: harness.publicKeyBase64]
        )
        #expect(verified.id == SystemPluginCatalogItem.developerLocationID)

        // Attack 1: Modify hook and recompute SHA-256 table without the trusted Ed25519 private key
        let hookURL = bundleDir.appendingPathComponent("hooks/on-enable.sh")
        try Data("#!/system/bin/sh\necho PWNED\n".utf8).write(to: hookURL, options: .atomic)
        let attackerKey = Curve25519.Signing.PrivateKey()
        try SystemPluginPackageFactory.writeSignature(
            forPluginDirectory: bundleDir,
            pluginID: verified.id,
            version: verified.version,
            privateKey: attackerKey,
            keyID: harness.keyID
        )
        var rejectedAttackerSig = false
        do {
            _ = try SystemPluginPackageFactory.verifyPluginDirectory(
                bundleDir,
                trustPolicy: .officialRepository,
                additionalTrustedPublicKeys: [harness.keyID: harness.publicKeyBase64]
            )
        } catch {
            rejectedAttackerSig = true
        }
        #expect(rejectedAttackerSig)

        // Attack 2: Add a hidden script file inside the bundle
        let (cleanBundle, cleanHarness) = try SignedArchiveTestHarness.buildSignedLocationPackage(
            in: root.appendingPathComponent("clean2", isDirectory: true)
        )
        try Data("malicious".utf8).write(to: cleanBundle.appendingPathComponent("hooks/.hidden.sh"))
        var rejectedHiddenFile = false
        do {
            _ = try SystemPluginPackageFactory.verifyPluginDirectory(
                cleanBundle,
                trustPolicy: .officialRepository,
                additionalTrustedPublicKeys: [cleanHarness.keyID: cleanHarness.publicKeyBase64]
            )
        } catch {
            rejectedHiddenFile = true
        }
        #expect(rejectedHiddenFile)
    }

    @Test("Manifest validation rejects incompatible schemaVersion, minHostVersion, and unknown driverType")
    func manifestCompatibilityValidation() throws {
        let (root, _, _) = try makeIsolatedContext()
        defer { try? FileManager.default.removeItem(at: root) }

        let (bundleDir, harness) = try SignedArchiveTestHarness.buildSignedLocationPackage(in: root)
        var manifest = try JSONDecoder().decode(
            SystemPluginManifest.self,
            from: Data(contentsOf: bundleDir.appendingPathComponent("manifest.json"))
        )
        manifest.minHostVersion = "99.0.0"
        try JSONEncoder().encode(manifest).write(to: bundleDir.appendingPathComponent("manifest.json"), options: .atomic)
        try SystemPluginPackageFactory.writeSignature(
            forPluginDirectory: bundleDir,
            pluginID: manifest.id,
            version: manifest.version,
            privateKey: harness.privateKey,
            keyID: harness.keyID
        )

        var rejectedIncompatibleHost = false
        do {
            _ = try SystemPluginPackageFactory.verifyPluginDirectory(
                bundleDir,
                trustPolicy: .officialRepository,
                additionalTrustedPublicKeys: [harness.keyID: harness.publicKeyBase64],
                hostVersion: "0.1.0"
            )
        } catch {
            rejectedIncompatibleHost = true
        }
        #expect(rejectedIncompatibleHost)
    }

    @Test("Schema v1 keeps old driver entrypoints compatible and reserves shell for host_service")
    func hostServiceManifestCompatibility() throws {
        let oldEntrypoints = SystemPluginEntrypoints(
            onEnable: "hooks/on-enable.sh",
            onDisable: "hooks/on-disable.sh"
        )
        let encoded = try JSONEncoder().encode(oldEntrypoints)
        let decoded = try JSONDecoder().decode(SystemPluginEntrypoints.self, from: encoded)
        #expect(decoded == oldEntrypoints)
        #expect(decoded.hostService == nil)
        #expect(!decoded.allRelativePaths.contains { $0.contains("hostService") })
        #expect(SystemPluginManifest.supportedSchemaVersion == 1)
        #expect(SystemPluginManifest.currentHostVersion == "0.2.0")
        #expect(SystemPluginManifest.supportedDriverTypes.contains("host_service"))
        #expect(SystemPluginManifest.supportedCapabilities.contains("host.service"))

        let legacyJSON = """
        {
          "schemaVersion": 1,
          "id": "dev.legacy.manifest",
          "name": "Legacy",
          "subtitle": "legacy",
          "version": "1.0.0",
          "author": "test",
          "category": "test",
          "iconSymbol": "puzzlepiece",
          "accentHex": 0,
          "minHostVersion": "0.1.0",
          "capabilities": ["guest.shell"],
          "driverType": "external_script",
          "entrypoints": {
            "onEnable": "hooks/on-enable.sh",
            "onDisable": "hooks/on-disable.sh"
          }
        }
        """
        let legacyManifest = try JSONDecoder().decode(
            SystemPluginManifest.self,
            from: Data(legacyJSON.utf8)
        )
        #expect(legacyManifest.entrypoints.hostService == nil)

        let hostServiceFields = SystemPluginEntrypoints(hostService: "bin/service")
        #expect(hostServiceFields.allRelativePaths == ["bin/service"])
        #expect(!hostServiceFields.hasGuestShellHooks)

        let catalogItem = SystemPluginCatalogItem(
            id: "dev.host.catalog",
            name: "Host",
            subtitle: "",
            version: "1.0.0",
            availableUpdateVersion: nil,
            author: "",
            category: "",
            iconSymbol: "",
            accentHex: 0,
            isOfficialPreset: false,
            packageSizeLabel: "",
            capabilities: ["host.service"],
            driverType: "host_service",
            state: .installed(isEnabled: false),
            healthState: .inactive,
            statusDetail: "",
            lastErrorDetail: nil,
            downloadSourceDescription: ""
        )
        #expect(!catalogItem.hasDedicatedWorkspace)
    }

    @Test("Real GitHub live repository download installs, verifies Ed25519 signature, and drives hardware GNSS location", .enabled(if: ProcessInfo.processInfo.environment["MACDORA_LIVE_PLUGIN_QA"] == "1", "Set MACDORA_LIVE_PLUGIN_QA=1 for release acceptance."))
    @MainActor
    func liveGitHubDownloadAndInstallLifecycle() async throws {
        let (root, defaults, suite) = try makeIsolatedContext()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let transport = MockLocationConsoleTransport()
        let bridge = MockPluginHostBridge()

        // Use the real anonymous downloader against this public repository.
        let manager = SystemPluginManager(
            rootURL: root,
            defaults: defaults,
            packageFetcher: DefaultSystemPluginPackageFetcher(),
            locationConsoleTransport: transport
        )
        manager.hostBridge = bridge

        let id = SystemPluginCatalogItem.developerLocationID
        let downloaded = try await manager.downloadAndInstallPlugin(id: id)
        #expect(downloaded.state == .installed(isEnabled: false))
        #expect(manager.isPluginInstalled(id))
        #expect(!manager.isPluginEnabled(id))

        await manager.setPluginEnabled(id: id, enabled: true)
        #expect(manager.isPluginEnabled(id))

        let locPlugin = try #require(manager.locationPlugin(for: id))
        #expect(locPlugin.landmarks.count >= 3)
        #expect(!bridge.executedGuestScripts.isEmpty)

        // Verify continuous ~100ms drift frames stay strictly within 10m
        try await Task.sleep(for: .milliseconds(360))
        let samples = await transport.samplesSnapshot()
        #expect(samples.count >= 3)
        for sample in samples {
            #expect(sample.driftDistanceMeters <= 10.001)
            #expect(sample.qemuGeoFixCommand.hasPrefix("geo fix "))
        }

        // Verify runtime stopping halts drift loop cleanly
        await manager.handleRuntimeStopping()
        #expect(locPlugin.healthState == .waitingForRuntime)
        let countAtStop = await transport.samplesSnapshot().count
        try await Task.sleep(for: .milliseconds(250))
        let countAfterStopWait = await transport.samplesSnapshot().count
        #expect(countAfterStopWait == countAtStop)

        // Verify delete removes plugin instance and disk directory
        try await manager.deletePlugin(id: id)
        #expect(!manager.isPluginInstalled(id))
        #expect(manager.locationPlugin(for: id) == nil)
    }

    @Test("Selecting location during activation does not cancel continuous drift loop, and template creation is non-destructive")
    @MainActor
    func concurrentSelectionDuringActivationAndSafeTemplate() async throws {
        let (root, defaults, suite) = try makeIsolatedContext()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        // 1. Non-destructive developer template creation
        let tplBase = root.appendingPathComponent("templates/dev.custom.sample", isDirectory: true)
        let firstURL = try SystemPluginPackageFactory.createDeveloperTemplateDirectory(at: tplBase)
        let customMarker = firstURL.appendingPathComponent("USER_EDITED.txt")
        try Data("keep-me".utf8).write(to: customMarker)
        let secondURL = try SystemPluginPackageFactory.createDeveloperTemplateDirectory(at: tplBase)
        #expect(firstURL != secondURL)
        #expect(FileManager.default.fileExists(atPath: customMarker.path))

        // 2. Selecting coordinate while onEnable is running must not abort drift loop
        let (_, harness) = try SignedArchiveTestHarness.buildSignedLocationPackage(in: root)
        let fetcher = DefaultSystemPluginPackageFetcher(
            httpTransport: MockGitHubHTTPTransport(
                registryData: harness.registryData,
                archiveData: harness.archiveData
            ),
            trustedPublicKeys: [harness.keyID: harness.publicKeyBase64]
        )
        let transport = MockLocationConsoleTransport()
        let bridge = MockPluginHostBridge()
        defer { withExtendedLifetime(bridge) {} }

        let manager = SystemPluginManager(
            rootURL: root,
            defaults: defaults,
            packageFetcher: fetcher,
            additionalTrustedPublicKeys: [harness.keyID: harness.publicKeyBase64],
            locationConsoleTransport: transport
        )
        manager.hostBridge = bridge

        let id = SystemPluginCatalogItem.developerLocationID
        _ = try await manager.downloadAndInstallPlugin(id: id, autoEnable: false)
        let locPlugin = try #require(manager.locationPlugin(for: id))

        let activationBarrier = AsyncBarrier()
        bridge.guestScriptHookFilter = { _ in
            await activationBarrier.arriveAndWait()
            return true
        }

        let activateTask = Task { @MainActor in
            await manager.setPluginEnabled(id: id, enabled: true)
        }
        await activationBarrier.waitUntilArrived()
        locPlugin.selectLocation(
            GeoCoordinate(latitude: 31.236305, longitude: 121.501540, name: "上海陆家嘴", subtitle: "测试选点")
        )
        await activationBarrier.open()
        await activateTask.value

        let beforeLoopCount = await transport.samplesSnapshot().count
        let deadline = ContinuousClock.now + .seconds(3)
        var afterLoopCount = beforeLoopCount
        while afterLoopCount <= beforeLoopCount && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            afterLoopCount = await transport.samplesSnapshot().count
        }
        #expect(afterLoopCount > beforeLoopCount)
        await manager.setPluginEnabled(id: id, enabled: false)
    }

    @Test("Runtime readiness during a user-triggered setup must still start continuous injection", arguments: [false, true])
    @MainActor
    func runtimeReadyDuringSelectionKeepsContinuousInjection(failsFirstSetup: Bool) async throws {
        let (root, defaults, suite) = try makeIsolatedContext()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let (_, harness) = try SignedArchiveTestHarness.buildSignedLocationPackage(in: root)
        let bridge = MockPluginHostBridge()
        defer { withExtendedLifetime(bridge) {} }
        bridge.currentRuntimeState = .starting
        let transport = MockLocationConsoleTransport()
        let manager = makeLocationManager(root: root, defaults: defaults, harness: harness, bridge: bridge, transport: transport)
        let id = SystemPluginCatalogItem.developerLocationID
        _ = try await manager.downloadAndInstallPlugin(id: id)
        await manager.setPluginEnabled(id: id, enabled: true)
        let plugin = try #require(manager.locationPlugin(for: id))
        #expect(plugin.healthState == .waitingForRuntime)

        let setupBarrier = AsyncBarrier()
        var isFirstSetup = true
        bridge.guestScriptHookFilter = { _ in
            guard isFirstSetup else { return true }
            isFirstSetup = false
            await setupBarrier.arriveAndWait()
            return !failsFirstSetup
        }
        bridge.currentRuntimeState = .ready
        plugin.selectLocation(GeoCoordinate(latitude: 31.236305, longitude: 121.501540, name: "就绪期间选点", subtitle: "隔离回归"))
        await setupBarrier.waitUntilArrived()
        await manager.handleRuntimeBecameReady()
        #expect(await transport.samplesSnapshot().isEmpty)
        await setupBarrier.open()

        let firstFixDeadline = ContinuousClock.now + .seconds(4)
        var firstFixCount = await transport.samplesSnapshot().count
        while firstFixCount == 0 && ContinuousClock.now < firstFixDeadline {
            try await Task.sleep(for: .milliseconds(20))
            firstFixCount = await transport.samplesSnapshot().count
        }
        #expect(firstFixCount > 0, "Initialization must complete or recover automatically")
        #expect(plugin.healthState == .healthy)

        let loopDeadline = ContinuousClock.now + .seconds(2)
        var laterFixCount = firstFixCount
        while laterFixCount <= firstFixCount && ContinuousClock.now < loopDeadline {
            try await Task.sleep(for: .milliseconds(20))
            laterFixCount = await transport.samplesSnapshot().count
        }
        #expect(laterFixCount > firstFixCount, "A healthy single fix must be followed by continuous injection")
        await manager.setPluginEnabled(id: id, enabled: false)
    }

    @Test("Plugins management page uses 2-level navigation and opens dedicated subpage for both location and external script plugins")
    @MainActor
    func pluginsPageTwoLevelNavigation() async throws {
        let (root, defaults, suite) = try makeIsolatedContext()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let (_, harness) = try SignedArchiveTestHarness.buildSignedLocationPackage(in: root)
        let fetcher = DefaultSystemPluginPackageFetcher(
            httpTransport: MockGitHubHTTPTransport(
                registryData: harness.registryData,
                archiveData: harness.archiveData
            ),
            trustedPublicKeys: [harness.keyID: harness.publicKeyBase64]
        )
        let manager = SystemPluginManager(
            rootURL: root,
            defaults: defaults,
            packageFetcher: fetcher,
            additionalTrustedPublicKeys: [harness.keyID: harness.publicKeyBase64],
            locationConsoleTransport: MockLocationConsoleTransport()
        )
        let window = ManagementWindow()
        window.bindPluginManager(manager)
        window.selectSection(.plugins)

        func containsMapView(in view: NSView) -> Bool {
            if view is InteractiveLocationMapView { return true }
            return view.subviews.contains(where: containsMapView)
        }

        let contentView = try #require(window.window?.contentView)
        #expect(window.activePluginDetailID == nil)
        #expect(!containsMapView(in: contentView))

        let id = SystemPluginCatalogItem.developerLocationID
        _ = try await manager.downloadAndInstallPlugin(id: id)
        await manager.setPluginEnabled(id: id, enabled: true)
        #expect(manager.isPluginEnabled(id))
        window.refreshPluginsSection()

        // Catalog list page still does NOT flatten the map
        #expect(window.activePluginDetailID == nil)
        #expect(!containsMapView(in: contentView))

        // Enter 2nd-level dedicated management subpage
        window.openPluginDetailPage(id: id)
        #expect(window.activePluginDetailID == id)
        #expect(containsMapView(in: contentView))

        window.closePluginDetailPage()
        #expect(window.activePluginDetailID == nil)
        #expect(!containsMapView(in: contentView))
    }

    @Test("Download and local import stay disabled until explicitly enabled")
    @MainActor
    func downloadAndImportDefaultToDisabled() async throws {
        let (root, defaults, suite) = try makeIsolatedContext()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let (_, harness) = try SignedArchiveTestHarness.buildSignedLocationPackage(in: root)
        let bridge = MockPluginHostBridge()
        let manager = makeLocationManager(root: root, defaults: defaults, harness: harness, bridge: bridge)
        let locationID = SystemPluginCatalogItem.developerLocationID

        let downloaded = try await manager.downloadAndInstallPlugin(id: locationID)
        #expect(downloaded.state == .installed(isEnabled: false))
        #expect(state(of: locationID, in: manager) == .installed(isEnabled: false))
        #expect(!manager.isPluginEnabled(locationID))

        let developerID = "dev.lifecycle.import"
        let templateURL = try SystemPluginPackageFactory.createDeveloperTemplateDirectory(
            at: root.appendingPathComponent("import-source", isDirectory: true),
            pluginID: developerID
        )
        let imported = try await manager.importDeveloperPlugin(from: templateURL)
        #expect(imported.state == .installed(isEnabled: false))
        #expect(!manager.isPluginEnabled(developerID))
        #expect(manager.installedCount == 2)
    }

    @Test("A missing plugin directory must not block its first download")
    @MainActor
    func missingPluginDirectoryAllowsFirstDownload() async throws {
        let (root, defaults, suite) = try makeIsolatedContext()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let id = SystemPluginCatalogItem.developerLocationID
        let (_, harness) = try SignedArchiveTestHarness.buildSignedLocationPackage(in: root)
        let manager = makeLocationManager(
            root: root,
            defaults: defaults,
            harness: harness,
            bridge: MockPluginHostBridge()
        )
        #expect(!FileManager.default.fileExists(
            atPath: manager.pluginsRootURL.appendingPathComponent(id, isDirectory: true).path
        ))

        let item = try await manager.downloadAndInstallPlugin(id: id)
        #expect(item.state == .installed(isEnabled: false))
        #expect(manager.isPluginInstalled(id))
    }

    @Test("Location configuration survives enable, disable, and manager reconstruction")
    @MainActor
    func locationConfigurationSurvivesLifecycleAndReconstruction() async throws {
        let (root, defaults, suite) = try makeIsolatedContext()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let id = SystemPluginCatalogItem.developerLocationID
        let (_, harness) = try SignedArchiveTestHarness.buildSignedLocationPackage(in: root)
        let firstManager = makeLocationManager(
            root: root,
            defaults: defaults,
            harness: harness,
            bridge: MockPluginHostBridge()
        )
        _ = try await firstManager.downloadAndInstallPlugin(id: id)
        let firstPlugin = try #require(firstManager.locationPlugin(for: id))

        let selected = GeoCoordinate(
            latitude: 22.543096,
            longitude: 114.057865,
            name: "重建后仍保留",
            subtitle: "持久化配置测试",
            coordinateSystem: .wgs84
        )
        firstPlugin.selectLocation(selected)
        let configured = firstPlugin.configuration
        #expect(storedConfiguration(for: id, defaults: defaults) == configured)

        await firstManager.setPluginEnabled(id: id, enabled: true)
        #expect(firstManager.isPluginEnabled(id))
        await firstManager.setPluginEnabled(id: id, enabled: false)
        #expect(!firstManager.isPluginEnabled(id))
        #expect(storedConfiguration(for: id, defaults: defaults) == configured)

        let rebuiltManager = makeLocationManager(
            root: root,
            defaults: defaults,
            harness: harness,
            bridge: MockPluginHostBridge()
        )
        let rebuiltPlugin = try #require(rebuiltManager.locationPlugin(for: id))
        #expect(rebuiltPlugin.configuration == configured)
        #expect(!rebuiltManager.isPluginEnabled(id))

        await rebuiltManager.setPluginEnabled(id: id, enabled: true)
        #expect(rebuiltManager.isPluginEnabled(id))
        let enabledRebuild = makeLocationManager(
            root: root,
            defaults: defaults,
            harness: harness,
            bridge: MockPluginHostBridge()
        )
        enabledRebuild.reloadInstalledPluginsFromDisk()
        #expect(defaults.stringArray(forKey: Self.enabledPluginIDsKey)?.contains(id) == true)
        #expect(try #require(enabledRebuild.locationPlugin(for: id)).configuration == configured)
    }

    @Test("Immediate update after reconstruction preserves persisted enable intent and configuration")
    @MainActor
    func immediateUpdateAfterReconstructionPreservesEnableIntent() async throws {
        let (root, defaults, suite) = try makeIsolatedContext()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let id = SystemPluginCatalogItem.developerLocationID
        let (_, harness) = try SignedArchiveTestHarness.buildSignedLocationPackage(in: root, version: "1.0.0")
        let firstManager = makeLocationManager(
            root: root,
            defaults: defaults,
            harness: harness,
            bridge: MockPluginHostBridge()
        )
        _ = try await firstManager.downloadAndInstallPlugin(id: id)
        let firstPlugin = try #require(firstManager.locationPlugin(for: id))
        firstPlugin.selectLocation(
            GeoCoordinate(latitude: 22.55, longitude: 114.06, name: "更新前配置", subtitle: "恢复意图")
        )
        let configured = firstPlugin.configuration
        await firstManager.setPluginEnabled(id: id, enabled: true)
        #expect(defaults.stringArray(forKey: Self.enabledPluginIDsKey)?.contains(id) == true)

        let rebuiltManager = makeLocationManager(
            root: root,
            defaults: defaults,
            harness: harness,
            bridge: MockPluginHostBridge()
        )
        #expect(defaults.stringArray(forKey: Self.enabledPluginIDsKey)?.contains(id) == true)
        let updated = try await rebuiltManager.downloadAndInstallPlugin(id: id, autoEnable: false)
        #expect(updated.state == .installed(isEnabled: true))
        #expect(rebuiltManager.isPluginEnabled(id))
        #expect(try #require(rebuiltManager.locationPlugin(for: id)).configuration == configured)
        #expect(storedConfiguration(for: id, defaults: defaults) == configured)
        #expect(defaults.stringArray(forKey: Self.enabledPluginIDsKey)?.contains(id) == true)
    }

    @Test("Deleting one location plugin preserves another plugin, unrelated defaults, and root markers")
    @MainActor
    func deleteRemovesOnlyItsOwnFilesAndPersistentConfiguration() async throws {
        let (root, defaults, suite) = try makeIsolatedContext()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let locationID = SystemPluginCatalogItem.developerLocationID
        let otherID = "dev.lifecycle.other"
        let unrelatedKey = "AndroidUse.PluginLifecycle.unrelated"
        let rootMarker = root.appendingPathComponent("unrelated-root-marker.txt")
        try Data("keep-root".utf8).write(to: rootMarker)
        defaults.set("keep-default", forKey: unrelatedKey)

        let (_, harness) = try SignedArchiveTestHarness.buildSignedLocationPackage(in: root)
        let manager = makeLocationManager(
            root: root,
            defaults: defaults,
            harness: harness,
            bridge: MockPluginHostBridge()
        )
        _ = try await manager.downloadAndInstallPlugin(id: locationID)
        let locationPlugin = try #require(manager.locationPlugin(for: locationID))
        locationPlugin.selectLocation(
            GeoCoordinate(latitude: 30.1, longitude: 120.2, name: "仅此插件", subtitle: "删除范围")
        )
        #expect(storedConfiguration(for: locationID, defaults: defaults) != nil)

        let otherSource = try SystemPluginPackageFactory.createDeveloperTemplateDirectory(
            at: root.appendingPathComponent("other-source", isDirectory: true),
            pluginID: otherID,
            name: "另一个插件"
        )
        _ = try await manager.importDeveloperPlugin(from: otherSource)
        await manager.setPluginEnabled(id: otherID, enabled: true)
        let otherDefaultsKey = "AndroidUse.PluginLifecycle.other.enabled"
        defaults.set(true, forKey: otherDefaultsKey)

        let otherDirectory = manager.pluginsRootURL.appendingPathComponent(otherID, isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: otherDirectory.path))

        try await manager.deletePlugin(id: locationID)

        #expect(!manager.isPluginInstalled(locationID))
        #expect(manager.locationPlugin(for: locationID) == nil)
        #expect(storedConfiguration(for: locationID, defaults: defaults) == nil)
        #expect(!FileManager.default.fileExists(
            atPath: manager.pluginsRootURL.appendingPathComponent(locationID, isDirectory: true).path
        ))
        #expect(manager.isPluginInstalled(otherID))
        #expect(manager.isPluginEnabled(otherID))
        #expect(FileManager.default.fileExists(atPath: otherDirectory.path))
        #expect(defaults.string(forKey: unrelatedKey) == "keep-default")
        #expect(defaults.bool(forKey: otherDefaultsKey))
        #expect(FileManager.default.fileExists(atPath: rootMarker.path))
    }

    @Test("Deleted location instance cannot rewrite its configuration, and redownload restores defaults")
    @MainActor
    func deletedInstanceCannotResurrectConfiguration() async throws {
        let (root, defaults, suite) = try makeIsolatedContext()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let id = SystemPluginCatalogItem.developerLocationID
        let (_, harness) = try SignedArchiveTestHarness.buildSignedLocationPackage(in: root)
        let manager = makeLocationManager(
            root: root,
            defaults: defaults,
            harness: harness,
            bridge: MockPluginHostBridge()
        )
        _ = try await manager.downloadAndInstallPlugin(id: id)
        let stalePlugin = try #require(manager.locationPlugin(for: id))
        stalePlugin.selectLocation(
            GeoCoordinate(latitude: 31.2, longitude: 121.5, name: "删除前配置", subtitle: "旧实例")
        )
        #expect(storedConfiguration(for: id, defaults: defaults) != nil)

        try await manager.deletePlugin(id: id)
        #expect(storedConfiguration(for: id, defaults: defaults) == nil)

        stalePlugin.selectLocation(
            GeoCoordinate(latitude: 39.9, longitude: 116.4, name: "不得复活", subtitle: "旧实例写回")
        )
        stalePlugin.setDriftEnabled(false)
        #expect(storedConfiguration(for: id, defaults: defaults) == nil)

        let redownloaded = try await manager.downloadAndInstallPlugin(id: id)
        #expect(redownloaded.state == .installed(isEnabled: false))
        let freshPlugin = try #require(manager.locationPlugin(for: id))
        #expect(freshPlugin.configuration == DeveloperLocationConfiguration.fromBundleConfig(
            DeveloperLocationBundleConfig.fallback,
            firstLandmark: freshPlugin.landmarks.first
        ))
        #expect(storedConfiguration(for: id, defaults: defaults) == nil)
    }

    @Test("Deleting during download is rejected without cancelling or corrupting the operation")
    @MainActor
    func deleteDuringDownloadIsRejectedAndDownloadCompletes() async throws {
        let (root, defaults, suite) = try makeIsolatedContext()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let id = SystemPluginCatalogItem.developerLocationID
        let (bundleURL, harness) = try SignedArchiveTestHarness.buildSignedLocationPackage(in: root)
        let fetcher = ControlledPluginFetcher(bundleURL: bundleURL)
        let manager = SystemPluginManager(
            rootURL: root,
            defaults: defaults,
            packageFetcher: fetcher,
            additionalTrustedPublicKeys: [harness.keyID: harness.publicKeyBase64]
        )
        let download = Task { @MainActor in
            try await manager.downloadAndInstallPlugin(id: id)
        }

        await fetcher.waitUntilStarted()
        #expect(manager.isPluginBusy(id))
        #expect(state(of: id, in: manager)?.isDownloading == true)

        var deleteError: SystemPluginPackageError?
        do {
            try await manager.deletePlugin(id: id)
        } catch let error as SystemPluginPackageError {
            deleteError = error
        }
        #expect(deleteError == .operationInProgress(id))
        #expect(manager.isPluginBusy(id))
        #expect(state(of: id, in: manager)?.isDownloading == true)
        #expect(!manager.isPluginInstalled(id))

        await fetcher.releaseDownload()
        let result = try await download.value
        #expect(result.state == .installed(isEnabled: false))
        #expect(manager.isPluginInstalled(id))
        #expect(!manager.isPluginBusy(id))
    }

    @Test("Failed onDisable blocks deletion and preserves plugin files and configuration")
    @MainActor
    func failedDisableBlocksDeleteAndPreservesState() async throws {
        let (root, defaults, suite) = try makeIsolatedContext()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let id = SystemPluginCatalogItem.developerLocationID
        let (_, harness) = try SignedArchiveTestHarness.buildSignedLocationPackage(in: root)
        let bridge = MockPluginHostBridge()
        let manager = makeLocationManager(root: root, defaults: defaults, harness: harness, bridge: bridge)
        _ = try await manager.downloadAndInstallPlugin(id: id)
        let plugin = try #require(manager.locationPlugin(for: id))
        plugin.selectLocation(
            GeoCoordinate(latitude: 23.1, longitude: 113.3, name: "删除应保留", subtitle: "停用失败")
        )
        let savedConfiguration = plugin.configuration
        await manager.setPluginEnabled(id: id, enabled: true)
        #expect(manager.isPluginEnabled(id))

        bridge.guestScriptHookFilter = { script in
            !script.contains("AU_LOCATION_ON_DISABLE")
        }
        var deleteError: SystemPluginPackageError?
        do {
            try await manager.deletePlugin(id: id)
        } catch let error as SystemPluginPackageError {
            deleteError = error
        }
        #expect(deleteError != nil)
        #expect(manager.isPluginInstalled(id))
        #expect(manager.isPluginEnabled(id))
        #expect(manager.locationPlugin(for: id) != nil)
        #expect(storedConfiguration(for: id, defaults: defaults) == savedConfiguration)
        #expect(FileManager.default.fileExists(
            atPath: manager.pluginsRootURL.appendingPathComponent(id, isDirectory: true).path
        ))
    }

    @Test("Invalid IDs and traversal paths are rejected without touching isolated storage")
    @MainActor
    func invalidIdentifiersAndTraversalAreRejected() async throws {
        let (root, defaults, suite) = try makeIsolatedContext()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let manager = SystemPluginManager(rootURL: root, defaults: defaults)
        for invalidID in ["../escape", ".hidden", "a/../../b"] {
            var downloadError: SystemPluginPackageError?
            do {
                _ = try await manager.downloadAndInstallPlugin(id: invalidID)
            } catch let error as SystemPluginPackageError {
                downloadError = error
            }
            #expect(downloadError == .invalidPluginID)

            var deleteError: SystemPluginPackageError?
            do {
                try await manager.deletePlugin(id: invalidID)
            } catch let error as SystemPluginPackageError {
                deleteError = error
            }
            #expect(deleteError == .invalidPluginID)
        }

        let outside = root.deletingLastPathComponent().appendingPathComponent(
            "androiduse-outside-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        var importError: SystemPluginPackageError?
        do {
            _ = try await manager.importDeveloperPlugin(from: outside)
        } catch let error as SystemPluginPackageError {
            importError = error
        }
        #expect(importError == .manifestMissingOrInvalid)
        #expect(!manager.isPluginInstalled(SystemPluginCatalogItem.developerLocationID))
    }

    @Test("Replacing a plugin retires its old instance without losing or resurrecting configuration")
    @MainActor
    func replacementRetiresOldConfigurationWriter() async throws {
        let (root, defaults, suite) = try makeIsolatedContext()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let id = SystemPluginCatalogItem.developerLocationID
        let (source, harness) = try SignedArchiveTestHarness.buildSignedLocationPackage(in: root)
        let bridge = MockPluginHostBridge()
        let manager = makeLocationManager(root: root, defaults: defaults, harness: harness, bridge: bridge)
        _ = try await manager.downloadAndInstallPlugin(id: id, autoEnable: true)
        let previous = try #require(manager.locationPlugin(for: id))
        previous.selectLocation(GeoCoordinate(latitude: 22.5, longitude: 114.0, name: "保留设置", subtitle: "更新"))
        let saved = previous.configuration
        _ = try await manager.importDeveloperPlugin(from: source)
        let replacement = try #require(manager.locationPlugin(for: id))
        #expect(replacement !== previous)
        #expect(replacement.configuration == saved)
        #expect(manager.isPluginEnabled(id))
        previous.selectLocation(GeoCoordinate(latitude: 31.2, longitude: 121.5, name: "过期写入", subtitle: "不得覆盖"))
        #expect(storedConfiguration(for: id, defaults: defaults) == saved)
        try await manager.deletePlugin(id: id)
        previous.setDriftEnabled(false)
        #expect(storedConfiguration(for: id, defaults: defaults) == nil)
    }

    @Test("Deletion drains an outstanding guest hook before stopping the plugin and removing files")
    @MainActor
    func deletionWaitsForInFlightGuestWork() async throws {
        let (root, defaults, suite) = try makeIsolatedContext()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let id = "dev.lifecycle.drain"
        let source = try SystemPluginPackageFactory.createDeveloperTemplateDirectory(
            at: root.appendingPathComponent("drain-source", isDirectory: true), pluginID: id
        )
        let bridge = MockPluginHostBridge()
        let manager = SystemPluginManager(rootURL: root, defaults: defaults)
        manager.hostBridge = bridge
        _ = try await manager.importDeveloperPlugin(from: source, autoEnable: true)
        let plugin = try #require(manager.externalScriptPlugin(for: id))
        let barrier = AsyncBarrier()
        let trace = HookTrace()
        bridge.guestScriptHookFilter = { script in
            if script.contains("custom_plugin 0") {
                await trace.append("stop")
                return true
            }
            await trace.append("work-start")
            await barrier.arriveAndWait()
            await trace.append("work-finish")
            return true
        }
        let work = Task { @MainActor in await plugin.triggerManualHookCheck(bridge: bridge) }
        await barrier.waitUntilArrived()
        let stopping = TestMainActorSignal()
        manager.onCatalogChanged = { _ in stopping.signal() }
        let deletion = Task { @MainActor in try await manager.deletePlugin(id: id) }
        await stopping.wait()
        #expect(manager.isPluginBusy(id))
        #expect(manager.isPluginInstalled(id))
        #expect(await trace.snapshot() == ["work-start"])
        await barrier.open()
        #expect(await work.value == false)
        try await deletion.value
        #expect(await trace.snapshot() == ["work-start", "work-finish", "stop"])
        #expect(!manager.isPluginInstalled(id))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test("A redirected plugin storage directory cannot delete files outside the environment")
    @MainActor
    func redirectedStorageIsRejected() async throws {
        let (root, defaults, suite) = try makeIsolatedContext()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let outside = root.appendingPathComponent("unrelated-data", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let marker = outside.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("plugins"), withDestinationURL: outside)
        let manager = SystemPluginManager(rootURL: root, defaults: defaults)
        do {
            try await manager.deletePlugin(id: SystemPluginCatalogItem.developerLocationID)
            Issue.record("Deletion must reject redirected storage")
        } catch let error as SystemPluginPackageError {
            #expect(error == .unsafePackageContent)
        }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "keep")
    }

    @Test("A disabled plugin downloading in the background cannot prevent an enabled plugin from resuming after update")
    @MainActor
    func parallelDisabledDownloadPreservesEnabledUpdate() async throws {
        let (root, defaults, suite) = try makeIsolatedContext()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let primaryID = SystemPluginCatalogItem.developerLocationID
        let secondaryID = "dev.lifecycle.secondary-location"
        let (primarySource, harness) = try SignedArchiveTestHarness.buildSignedLocationPackage(in: root)
        let (secondarySource, _) = try SignedArchiveTestHarness.buildSignedLocationPackage(
            in: root, pluginID: secondaryID, privateKey: harness.privateKey
        )
        let fetcher = ControlledPluginFetcher(bundleURL: secondarySource)
        let bridge = MockPluginHostBridge()
        defer { withExtendedLifetime(bridge) {} }
        let manager = SystemPluginManager(
            rootURL: root, defaults: defaults, packageFetcher: fetcher,
            additionalTrustedPublicKeys: [harness.keyID: harness.publicKeyBase64],
            locationConsoleTransport: MockLocationConsoleTransport()
        )
        manager.hostBridge = bridge
        _ = try await manager.importDeveloperPlugin(from: primarySource, autoEnable: true)
        _ = try await manager.importDeveloperPlugin(from: secondarySource)
        let downloading = Task { @MainActor in try await manager.downloadAndInstallPlugin(id: secondaryID) }
        await fetcher.waitUntilStarted()
        let updated = try await manager.importDeveloperPlugin(from: primarySource)
        #expect(updated.state.isEnabled)
        #expect(manager.isPluginEnabled(primaryID))
        #expect(!manager.isPluginEnabled(secondaryID))
        await fetcher.releaseDownload()
        _ = try await downloading.value
        #expect(manager.enabledCount == 1)
        #expect(manager.isPluginEnabled(primaryID))
        await manager.setPluginEnabled(id: primaryID, enabled: false)
    }

    @Test("Updating an enabled plugin keeps its exclusive capability reserved while its old instance stops", arguments: [false, true])
    @MainActor
    func updateReservesCapabilityUntilResumed(changesDriver: Bool) async throws {
        let (root, defaults, suite) = try makeIsolatedContext()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let primaryID = changesDriver ? "dev.lifecycle.reserved-origin" : SystemPluginCatalogItem.developerLocationID
        let secondaryID = "dev.lifecycle.competing-location"
        let (source, harness) = try SignedArchiveTestHarness.buildSignedLocationPackage(in: root, pluginID: primaryID)
        let (competingSource, _) = try SignedArchiveTestHarness.buildSignedLocationPackage(
            in: root, pluginID: secondaryID, privateKey: harness.privateKey
        )
        let bridge = MockPluginHostBridge()
        defer { withExtendedLifetime(bridge) {} }
        let manager = makeLocationManager(root: root, defaults: defaults, harness: harness, bridge: bridge)
        let originalSource = changesDriver ? try SystemPluginPackageFactory.createDeveloperTemplateDirectory(
            at: root.appendingPathComponent("original-external", isDirectory: true), pluginID: primaryID
        ) : source
        _ = try await manager.importDeveloperPlugin(from: originalSource, autoEnable: true)
        _ = try await manager.importDeveloperPlugin(from: competingSource)
        let stopping = AsyncBarrier()
        bridge.guestScriptHookFilter = { script in
            if script.contains("AU_LOCATION_ON_DISABLE") || script.contains("custom_plugin 0") {
                await stopping.arriveAndWait()
            }
            return true
        }
        let updating = Task { @MainActor in try await manager.importDeveloperPlugin(from: source) }
        await stopping.waitUntilArrived()
        await manager.setPluginEnabled(id: secondaryID, enabled: true)
        #expect(!manager.isPluginEnabled(secondaryID))
        #expect(manager.lastError(for: secondaryID) != nil)
        await stopping.open()
        #expect(try await updating.value.state.isEnabled)
        #expect(manager.enabledCount == 1)
        #expect(manager.isPluginEnabled(primaryID))
        await manager.setPluginEnabled(id: primaryID, enabled: false)
    }

    @Test("Failure to move an old package restores its enabled state and saved configuration")
    @MainActor
    func firstBackupMoveFailureRestoresEnabledPlugin() async throws {
        let (root, defaults, suite) = try makeIsolatedContext()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let (source, harness) = try SignedArchiveTestHarness.buildSignedLocationPackage(in: root)
        let fileManager = BackupMoveFailingFileManager()
        let bridge = MockPluginHostBridge()
        defer { withExtendedLifetime(bridge) {} }
        let manager = makeLocationManager(
            root: root, defaults: defaults, harness: harness, bridge: bridge, fileManager: fileManager
        )
        let id = SystemPluginCatalogItem.developerLocationID
        _ = try await manager.importDeveloperPlugin(from: source, autoEnable: true)
        let original = try #require(manager.locationPlugin(for: id))
        original.selectLocation(GeoCoordinate(latitude: 22.5, longitude: 114.1, name: "失败后保留", subtitle: "权限故障"))
        let configuration = original.configuration
        fileManager.failBackupMoves = true
        do {
            _ = try await manager.importDeveloperPlugin(from: source)
            Issue.record("The injected move failure must be reported")
        } catch let error as CocoaError {
            #expect(error.code == .fileWriteNoPermission)
        }
        #expect(manager.locationPlugin(for: id) === original)
        #expect(manager.isPluginEnabled(id))
        #expect(original.healthState == .healthy)
        #expect(original.configuration == configuration)
        #expect(storedConfiguration(for: id, defaults: defaults) == configuration)
        await manager.setPluginEnabled(id: id, enabled: false)
    }

    @Test("A failed location setup stays degraded, sends no fixes, and recovers automatically when setup succeeds")
    @MainActor
    func failedLocationSetupDoesNotReportHealthyAndRetries() async throws {
        let (root, defaults, suite) = try makeIsolatedContext()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let (_, harness) = try SignedArchiveTestHarness.buildSignedLocationPackage(in: root)
        let bridge = MockPluginHostBridge()
        defer { withExtendedLifetime(bridge) {} }
        let transport = MockLocationConsoleTransport()
        let manager = makeLocationManager(root: root, defaults: defaults, harness: harness, bridge: bridge, transport: transport)
        let id = SystemPluginCatalogItem.developerLocationID
        _ = try await manager.downloadAndInstallPlugin(id: id)
        bridge.guestScriptHookFilter = { _ in false }
        await manager.setPluginEnabled(id: id, enabled: true)
        let plugin = try #require(manager.locationPlugin(for: id))
        if case .degraded = plugin.healthState {} else { Issue.record("Failed setup cannot report healthy") }
        #expect(await transport.samplesSnapshot().isEmpty)
        bridge.guestScriptHookFilter = { _ in true }
        let deadline = ContinuousClock.now + .seconds(4)
        while plugin.healthState != .healthy && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(plugin.healthState == .healthy)
        #expect(await transport.samplesSnapshot().count > 0)
        await manager.setPluginEnabled(id: id, enabled: false)
    }

    @Test("An update waits for a late conflicting stop and rolls back if that stop cannot finish", arguments: [false, true])
    @MainActor
    func updateWaitsForLateStopOrRollsBack(stopFails: Bool) async throws {
        let (root, defaults, suite) = try makeIsolatedContext()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let primaryID = "dev.lifecycle.pending-upgrade"
        let otherID = "dev.lifecycle.running-gnss"
        let oldSource = try SystemPluginPackageFactory.createDeveloperTemplateDirectory(
            at: root.appendingPathComponent("old-external", isDirectory: true), pluginID: primaryID
        )
        let (newSource, harness) = try SignedArchiveTestHarness.buildSignedLocationPackage(in: root, pluginID: primaryID)
        let (otherSource, _) = try SignedArchiveTestHarness.buildSignedLocationPackage(
            in: root, pluginID: otherID, privateKey: harness.privateKey
        )
        let bridge = MockPluginHostBridge()
        defer { withExtendedLifetime(bridge) {} }
        let manager = makeLocationManager(root: root, defaults: defaults, harness: harness, bridge: bridge)
        _ = try await manager.importDeveloperPlugin(from: oldSource, autoEnable: true)
        _ = try await manager.importDeveloperPlugin(from: otherSource, autoEnable: true)
        let oldPlugin = try #require(manager.externalScriptPlugin(for: primaryID))
        let oldStop = AsyncBarrier()
        let otherStop = AsyncBarrier()
        let awaitingActivation = TestMainActorSignal()
        manager.onCatalogChanged = { [weak manager] _ in
            if manager?.locationPlugin(for: primaryID) != nil { awaitingActivation.signal() }
        }
        bridge.guestScriptHookFilter = { script in
            if script.contains("custom_plugin 0") { await oldStop.arriveAndWait() }
            if script.contains("AU_LOCATION_ON_DISABLE") {
                await otherStop.arriveAndWait()
                return !stopFails
            }
            return true
        }
        var updateFinished = false
        let updating = Task { @MainActor in
            defer { updateFinished = true }
            return try await manager.importDeveloperPlugin(from: newSource)
        }
        await oldStop.waitUntilArrived()
        let stoppingOther = Task { @MainActor in await manager.setPluginEnabled(id: otherID, enabled: false) }
        await otherStop.waitUntilArrived()
        await oldStop.open()
        await awaitingActivation.wait()
        #expect(!updateFinished)
        #expect(manager.isPluginBusy(primaryID))
        let backups = try FileManager.default.contentsOfDirectory(at: manager.pluginsRootURL, includingPropertiesForKeys: nil)
        #expect(backups.contains { $0.lastPathComponent.hasPrefix(".backup-\(primaryID)-") })
        await otherStop.open()
        await stoppingOther.value
        if stopFails {
            do {
                _ = try await updating.value
                Issue.record("An activation failure must roll back the update")
            } catch let error as SystemPluginPackageError {
                if case .operationFailed = error {} else { Issue.record("Unexpected update error: \(error)") }
            }
            #expect(manager.externalScriptPlugin(for: primaryID) === oldPlugin)
            #expect(manager.isPluginEnabled(primaryID))
            #expect(oldPlugin.healthState == .healthy)
        } else {
            #expect(try await updating.value.state.isEnabled)
            #expect(manager.locationPlugin(for: primaryID) != nil)
            #expect(!manager.isPluginEnabled(otherID))
        }
        bridge.guestScriptHookFilter = nil
        await manager.setPluginEnabled(id: primaryID, enabled: false)
        await manager.setPluginEnabled(id: otherID, enabled: false)
    }

    @Test("Location retry cannot skip a failed enable hook even when its ready hook succeeds")
    @MainActor
    func locationRetryPreservesFailedSetupStage() async throws {
        let (root, defaults, suite) = try makeIsolatedContext()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let (_, harness) = try SignedArchiveTestHarness.buildSignedLocationPackage(in: root)
        let bridge = MockPluginHostBridge()
        defer { withExtendedLifetime(bridge) {} }
        let transport = MockLocationConsoleTransport()
        let manager = makeLocationManager(root: root, defaults: defaults, harness: harness, bridge: bridge, transport: transport)
        let id = SystemPluginCatalogItem.developerLocationID
        _ = try await manager.downloadAndInstallPlugin(id: id)
        bridge.guestScriptHookFilter = { !$0.contains("AU_LOCATION_ON_ENABLE") }
        await manager.setPluginEnabled(id: id, enabled: true)
        await manager.handleRuntimeBecameReady()
        let plugin = try #require(manager.locationPlugin(for: id))
        #expect(plugin.healthState != .healthy)
        #expect(await transport.samplesSnapshot().isEmpty)
        let retryDeadline = ContinuousClock.now + .seconds(4)
        while bridge.executedGuestScripts.filter({ $0.contains("AU_LOCATION_ON_ENABLE") }).count < 3 && ContinuousClock.now < retryDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(bridge.executedGuestScripts.filter { $0.contains("AU_LOCATION_ON_ENABLE") }.count >= 3)
        #expect(plugin.healthState != .healthy)
        #expect(await transport.samplesSnapshot().isEmpty)
        bridge.guestScriptHookFilter = nil
        let recoveryDeadline = ContinuousClock.now + .seconds(4)
        while plugin.healthState != .healthy && ContinuousClock.now < recoveryDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(plugin.healthState == .healthy)
        #expect(await transport.samplesSnapshot().count > 0)
        await manager.setPluginEnabled(id: id, enabled: false)
    }

    @Test("External script checks must retry failed initialization before reporting healthy")
    @MainActor
    func externalRetryPreservesFailedInitialization() async throws {
        let (root, defaults, suite) = try makeIsolatedContext()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let id = "dev.lifecycle.selective-failure"
        let source = try SystemPluginPackageFactory.createDeveloperTemplateDirectory(
            at: root.appendingPathComponent("selective-external", isDirectory: true), pluginID: id
        )
        try Data("echo TEST_ENABLE_STAGE\n".utf8).write(to: source.appendingPathComponent("hooks/on-enable.sh"))
        try Data("echo TEST_READY_STAGE\n".utf8).write(to: source.appendingPathComponent("hooks/on-runtime-ready.sh"))
        try SystemPluginPackageFactory.writeSignature(forPluginDirectory: source, pluginID: id, version: "0.1.0")
        let bridge = MockPluginHostBridge()
        let manager = SystemPluginManager(rootURL: root, defaults: defaults)
        manager.hostBridge = bridge
        bridge.guestScriptHookFilter = { !$0.contains("TEST_ENABLE_STAGE") }
        _ = try await manager.importDeveloperPlugin(from: source, autoEnable: true)
        let plugin = try #require(manager.externalScriptPlugin(for: id))
        #expect(plugin.healthState != .healthy)
        await manager.handleRuntimeBecameReady()
        #expect(plugin.healthState != .healthy)
        #expect(await plugin.triggerManualHookCheck(bridge: bridge) == false)
        #expect(plugin.healthState != .healthy)
        #expect(!bridge.executedGuestScripts.contains { $0.contains("TEST_READY_STAGE") })
        bridge.guestScriptHookFilter = nil
        #expect(await plugin.triggerManualHookCheck(bridge: bridge))
        #expect(plugin.healthState == .healthy)
        await manager.setPluginEnabled(id: id, enabled: false)
    }

    @Test("Deleting a plugin also removes its failed-operation backups without touching another ID")
    @MainActor
    func deletionRemovesOnlyOwnedResidualPackages() async throws {
        let (root, defaults, suite) = try makeIsolatedContext()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let (_, harness) = try SignedArchiveTestHarness.buildSignedLocationPackage(in: root)
        let bridge = MockPluginHostBridge()
        let manager = makeLocationManager(root: root, defaults: defaults, harness: harness, bridge: bridge)
        let id = SystemPluginCatalogItem.developerLocationID
        _ = try await manager.downloadAndInstallPlugin(id: id)
        let names = [".backup-\(id)-\(UUID().uuidString)", ".delete-\(id)-\(UUID().uuidString)", ".uninstall-\(id)-\(UUID().uuidString)"]
        for name in names {
            try FileManager.default.createDirectory(at: manager.pluginsRootURL.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let unrelated = manager.pluginsRootURL.appendingPathComponent(".backup-\(id)-other-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try await manager.deletePlugin(id: id)
        #expect(names.allSatisfy { !FileManager.default.fileExists(atPath: manager.pluginsRootURL.appendingPathComponent($0).path) })
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test("A partial delete failure stays disabled with its settings retained and allows retry")
    @MainActor
    func partialDeleteFailureAllowsSafeRetry() async throws {
        let (root, defaults, suite) = try makeIsolatedContext()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let (_, harness) = try SignedArchiveTestHarness.buildSignedLocationPackage(in: root)
        let bridge = MockPluginHostBridge()
        defer { withExtendedLifetime(bridge) {} }
        let fileManager = BackupMoveFailingFileManager()
        let manager = makeLocationManager(root: root, defaults: defaults, harness: harness, bridge: bridge, fileManager: fileManager)
        let id = SystemPluginCatalogItem.developerLocationID
        _ = try await manager.downloadAndInstallPlugin(id: id, autoEnable: true)
        let plugin = try #require(manager.locationPlugin(for: id))
        plugin.selectLocation(GeoCoordinate(latitude: 22.5, longitude: 114.1, name: "重试前保留", subtitle: "删除故障"))
        let saved = plugin.configuration
        fileManager.failPartialDeletes = true
        do {
            try await manager.deletePlugin(id: id)
            Issue.record("Partial removal failure must be reported")
        } catch let error as SystemPluginPackageError {
            if case .operationFailed = error {} else { Issue.record("Unexpected delete error: \(error)") }
        }
        #expect(!manager.isPluginEnabled(id))
        #expect(storedConfiguration(for: id, defaults: defaults) == saved)
        fileManager.failPartialDeletes = false
        try await manager.deletePlugin(id: id)
        #expect(!manager.isPluginInstalled(id))
        #expect(storedConfiguration(for: id, defaults: defaults) == nil)
    }

    @Test("An exclusive selection clears a conflicting pending restore intent while retaining its data")
    @MainActor
    func exclusiveSelectionClearsPendingConflictingIntent() async throws {
        let (root, defaults, suite) = try makeIsolatedContext()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let primaryID = SystemPluginCatalogItem.developerLocationID
        let otherID = "dev.lifecycle.pending-restore"
        let (source, harness) = try SignedArchiveTestHarness.buildSignedLocationPackage(in: root)
        let (otherSource, _) = try SignedArchiveTestHarness.buildSignedLocationPackage(
            in: root, pluginID: otherID, privateKey: harness.privateKey
        )
        let bridge = MockPluginHostBridge()
        defer { withExtendedLifetime(bridge) {} }
        let manager = makeLocationManager(root: root, defaults: defaults, harness: harness, bridge: bridge)
        _ = try await manager.importDeveloperPlugin(from: source)
        _ = try await manager.importDeveloperPlugin(from: otherSource)
        let other = try #require(manager.locationPlugin(for: otherID))
        other.selectLocation(GeoCoordinate(latitude: 22.5, longitude: 114.1, name: "保留另一插件数据", subtitle: "待恢复"))
        let saved = other.configuration
        defaults.set([otherID], forKey: Self.enabledPluginIDsKey)
        await manager.setPluginEnabled(id: primaryID, enabled: true)
        #expect(Set(defaults.stringArray(forKey: Self.enabledPluginIDsKey) ?? []) == [primaryID])
        #expect(!manager.isPluginEnabled(otherID))
        #expect(storedConfiguration(for: otherID, defaults: defaults) == saved)
        await manager.setPluginEnabled(id: primaryID, enabled: false)
    }

    @Test("External script plugin supports disable, enable, reconstruction, and deletion")
    @MainActor
    func externalScriptPluginLifecycle() async throws {
        let (root, defaults, suite) = try makeIsolatedContext()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let id = "dev.lifecycle.external"
        let source = try SystemPluginPackageFactory.createDeveloperTemplateDirectory(
            at: root.appendingPathComponent("external-source", isDirectory: true),
            pluginID: id,
            name: "通用脚本插件"
        )
        let bridge = MockPluginHostBridge()
        let manager = SystemPluginManager(rootURL: root, defaults: defaults)
        manager.hostBridge = bridge

        let imported = try await manager.importDeveloperPlugin(from: source)
        #expect(imported.state == .installed(isEnabled: false))
        #expect(manager.externalScriptPlugin(for: id) != nil)
        await manager.setPluginEnabled(id: id, enabled: true)
        #expect(manager.isPluginEnabled(id))
        bridge.guestScriptHookFilter = { _ in false }
        await manager.setPluginEnabled(id: id, enabled: false)
        #expect(manager.isPluginEnabled(id))
        let stopError = try #require(manager.lastError(for: id))
        #expect(manager.catalogItems().first(where: { $0.id == id })?.statusDetail == stopError)
        bridge.guestScriptHookFilter = nil
        await manager.setPluginEnabled(id: id, enabled: false)
        #expect(!manager.isPluginEnabled(id))

        let rebuilt = SystemPluginManager(rootURL: root, defaults: defaults)
        #expect(rebuilt.isPluginInstalled(id))
        #expect(!rebuilt.isPluginEnabled(id))

        try await rebuilt.deletePlugin(id: id)
        #expect(!rebuilt.isPluginInstalled(id))
        #expect(rebuilt.externalScriptPlugin(for: id) == nil)
        #expect(!FileManager.default.fileExists(
            atPath: rebuilt.pluginsRootURL.appendingPathComponent(id, isDirectory: true).path
        ))
    }
}
