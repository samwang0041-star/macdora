import CryptoKit
import Darwin
import Foundation
import Testing
@testable import AndroidUse

@MainActor
final class HostServiceTestBridge: SystemPluginHostBridge {
    var currentRuntimeState: RuntimeState = .ready
    var currentActivePackage: String? = "should.not.be.used"
    var emulatorConsolePort: UInt16 = 5584
    var emulatorAuthTokenURLs: [URL] = []
    var hostServiceEnvironment: [String: String] = [
        "MACDORA_ADB_PATH": "/test/adb",
        "MACDORA_ADB_SERIAL": "emulator-5584",
        "ANDROID_ADB_SERVER_PORT": "5043",
        "ADB_SERVER_SOCKET": "tcp:127.0.0.1:5043",
        "UNRELATED_SECRET": "not-copied"
    ]

    func executeGuestShell(_ script: String, operation: String, timeout: TimeInterval) async -> Bool {
        true
    }

    func sendEmulatorGeoFix(
        longitude: Double,
        latitude: Double,
        altitude: Double,
        satellites: Int,
        velocityKnots: Double
    ) async -> Bool {
        true
    }

    func notifyPluginBanner(_ message: String) {}
    func notifyPluginStateDidChange() {}
}

private enum HostServiceFixtureError: Error {
    case commandFailed(String)
}

private final class HostServiceFixtureBinaryCache: @unchecked Sendable {
    static let shared = HostServiceFixtureBinaryCache()
    private let lock = NSLock()
    private var binaries: [String: Data] = [:]

    func binary(source: Data, compile: () throws -> Data) throws -> Data {
        let key = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        lock.lock()
        defer { lock.unlock() }
        if let binary = binaries[key] { return binary }
        let binary = try compile()
        binaries[key] = binary
        return binary
    }
}

private struct HostServiceFixture {
    let rootURL: URL
    let bundleURL: URL
    let manifest: SystemPluginManifest
    let serviceURL: URL
    let serviceDigestBefore: String

    static func create(
        rootURL: URL,
        pluginID: String = "dev.host.service",
        capabilities: [String] = ["host.service"],
        markerName: String = "started-count",
        version: String = "1.0.0"
    ) throws -> HostServiceFixture {
        let fm = FileManager.default
        let bundleURL = rootURL.appendingPathComponent("plugins/\(pluginID)", isDirectory: true)
        let binURL = bundleURL.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: binURL, withIntermediateDirectories: true)
        let serviceURL = binURL.appendingPathComponent("service")
        let sourceURL = binURL.appendingPathComponent("service.c")
        let source = #"""
        #include <arpa/inet.h>
        #include <errno.h>
        #include <fcntl.h>
        #include <netinet/in.h>
        #include <signal.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <sys/socket.h>
        #include <sys/stat.h>
        #include <sys/un.h>
        #include <unistd.h>

        static void digest(const char *value, char *out) {
            unsigned long long hash = 1469598103934665603ULL;
            for (const unsigned char *p = (const unsigned char *)value; *p; ++p) {
                hash ^= *p;
                hash *= 1099511628211ULL;
            }
            snprintf(out, 17, "%016llx", hash);
        }

        int main(void) {
            signal(SIGPIPE, SIG_IGN);
            const char *state_dir = getenv("MACDORA_PLUGIN_STATE_DIR");
            const char *socket_path = getenv("MACDORA_PLUGIN_SOCKET_PATH");
            const char *plugin_id = getenv("MACDORA_PLUGIN_ID");
            const char *instance_id = getenv("MACDORA_PLUGIN_INSTANCE_ID");
            if (!state_dir || !socket_path || !plugin_id || !instance_id) return 2;
            char marker[4096];
            snprintf(marker, sizeof(marker), "%s/__MARKER_NAME__", state_dir);
            int marker_fd = open(marker, O_WRONLY | O_CREAT | O_APPEND, 0600);
            if (marker_fd >= 0) { write(marker_fd, "started\n", 8); close(marker_fd); }
            unlink(socket_path);
            int server = socket(AF_UNIX, SOCK_STREAM, 0);
            if (server < 0) return 3;
            struct sockaddr_un address;
            memset(&address, 0, sizeof(address));
            address.sun_family = AF_UNIX;
            if (strlen(socket_path) >= sizeof(address.sun_path)) return 4;
            strncpy(address.sun_path, socket_path, sizeof(address.sun_path) - 1);
            mode_t old_mask = umask(0177);
            int bound = bind(server, (struct sockaddr *)&address, sizeof(address));
            umask(old_mask);
            if (bound != 0) return 5;
            chmod(socket_path, 0600);
            listen(server, 8);
            char endpoint[4096], temporary[4096];
            snprintf(endpoint, sizeof(endpoint), "%s/endpoint.json", state_dir);
            snprintf(temporary, sizeof(temporary), "%s.tmp", endpoint);
            int endpoint_fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0600);
            if (endpoint_fd < 0) return 6;
            dprintf(endpoint_fd,
                "{\"schemaVersion\":1,\"pluginId\":\"%s\",\"instanceId\":\"%s\",\"pid\":%d,\"socketPath\":\"%s\",\"protocol\":\"json-rpc-2.0\"}",
                plugin_id, instance_id, getppid(), socket_path);
            fsync(endpoint_fd);
            close(endpoint_fd);
            chmod(temporary, 0600);
            if (rename(temporary, endpoint) != 0) return 7;
            for (;;) {
                int client = accept(server, NULL, NULL);
                if (client < 0) continue;
                char request[4096];
                ssize_t length = read(client, request, sizeof(request) - 1);
                if (length <= 0) { close(client); continue; }
                request[length] = 0;
                char *id_start = strstr(request, "\"id\":");
                long request_id = id_start ? strtol(id_start + 5, NULL, 10) : 0;
                char response[1024];
                int written = snprintf(response, sizeof(response),
                    "{\"jsonrpc\":\"2.0\",\"id\":%ld,\"result\":{\"pluginId\":\"%s\",\"instanceId\":\"%s\",\"ready\":true}}\n",
                    request_id, plugin_id, instance_id);
                write(client, response, (size_t)written);
                close(client);
            }
        }
        """#
        let compiledSource = source.replacingOccurrences(of: "__MARKER_NAME__", with: markerName)
        let sourceData = Data(compiledSource.utf8)
        try sourceData.write(to: sourceURL, options: .atomic)
        let binary = try HostServiceFixtureBinaryCache.shared.binary(source: sourceData) {
            try runCommand(
                executable: "/usr/bin/xcrun",
                arguments: ["clang", "-O0", sourceURL.path, "-o", serviceURL.path]
            )
            try runCommand(executable: "/usr/bin/codesign", arguments: ["--force", "--sign", "-", serviceURL.path])
            return try Data(contentsOf: serviceURL)
        }
        try binary.write(to: serviceURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: serviceURL.path)
        let manifest = SystemPluginManifest(
            schemaVersion: 1,
            id: pluginID,
            name: "Host Service",
            subtitle: "Fixture",
            version: version,
            author: "test",
            category: "test",
            iconSymbol: "server.rack",
            accentHex: 0,
            minHostVersion: "0.2.0",
            capabilities: capabilities,
            driverType: "host_service",
            entrypoints: SystemPluginEntrypoints(hostService: "bin/service")
        )
        try JSONEncoder().encode(manifest).write(
            to: bundleURL.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        try SystemPluginPackageFactory.writeSignature(
            forPluginDirectory: bundleURL,
            pluginID: manifest.id,
            version: manifest.version
        )
        let before = try digest(serviceURL)
        return HostServiceFixture(
            rootURL: rootURL,
            bundleURL: bundleURL,
            manifest: manifest,
            serviceURL: serviceURL,
            serviceDigestBefore: before
        )
    }

    func serviceDigestAfter() throws -> String {
        try Self.digest(serviceURL)
    }

    static func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    static func runCommand(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HostServiceFixtureError.commandFailed(
                "\(URL(fileURLWithPath: executable).lastPathComponent) failed"
            )
        }
    }
}

private func makeHostServiceEnvironmentProbe(bundleURL: URL) throws -> URL {
    let probeURL = bundleURL.appendingPathComponent("bin/environment-probe")
    let sourceURL = bundleURL.appendingPathComponent("bin/environment-probe.c")
    let source = #"""
    #include <fcntl.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <unistd.h>

    int main(void) {
        const char *state_dir = getenv("MACDORA_PLUGIN_STATE_DIR");
        if (!state_dir) return 2;
        char path[4096];
        snprintf(path, sizeof(path), "%s/environment.txt", state_dir);
        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (fd < 0) return 3;
        const char *names[] = {
            "MACDORA_PLUGIN_ID",
            "MACDORA_PLUGIN_BUNDLE_DIR",
            "MACDORA_PLUGIN_STATE_DIR",
            "MACDORA_PLUGIN_SOCKET_PATH",
            "MACDORA_PLUGIN_INSTANCE_ID",
            "MACDORA_HOST_PID",
            "MACDORA_ADB_PATH",
            "MACDORA_ADB_SERIAL",
            "ANDROID_ADB_SERVER_PORT",
            "ADB_SERVER_SOCKET",
            "UNRELATED_SECRET",
            "HOME",
            NULL
        };
        for (size_t i = 0; names[i]; ++i) {
            const char *value = getenv(names[i]);
            dprintf(fd, "%s=%s\n", names[i], value ? value : "<unset>");
        }
        fsync(fd);
        close(fd);
        return 0;
    }
    """#
    try Data(source.utf8).write(to: sourceURL, options: .atomic)
    try HostServiceFixture.runCommand(
        executable: "/usr/bin/xcrun",
        arguments: ["clang", "-O0", sourceURL.path, "-o", probeURL.path]
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int(0o700))],
        ofItemAtPath: probeURL.path
    )
    try HostServiceFixture.runCommand(
        executable: "/usr/bin/codesign",
        arguments: ["--force", "--sign", "-", probeURL.path]
    )
    return probeURL
}

private func hostServiceTestRoot() throws -> URL {
    let root = URL(
        fileURLWithPath: "/tmp/mds-\(UUID().uuidString.prefix(8).lowercased())",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func hostServicePackageDigest(_ bundleURL: URL) throws -> String {
    var hasher = SHA256()
    let files = try FileManager.default.subpathsOfDirectory(atPath: bundleURL.path).sorted()
    for relativePath in files {
        let fileURL = bundleURL.appendingPathComponent(relativePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: fileURL.path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue else {
            continue
        }
        hasher.update(data: Data(relativePath.utf8))
        hasher.update(data: try Data(contentsOf: fileURL))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func hostServiceStubManifest(
    capabilities: [String] = ["host.service"],
    hostService: String? = "bin/service"
) -> SystemPluginManifest {
    SystemPluginManifest(
        schemaVersion: 1,
        id: "dev.host.stub",
        name: "Host Stub",
        subtitle: "Stub",
        version: "1.0.0",
        author: "test",
        category: "test",
        iconSymbol: "server.rack",
        accentHex: 0,
        minHostVersion: "0.2.0",
        capabilities: capabilities,
        driverType: "host_service",
        entrypoints: SystemPluginEntrypoints(hostService: hostService)
    )
}

private final class HostServiceSyntheticProcessHandle: OwnedProcessHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var terminateStopsProcess = true
    private var terminationAttempts = 0
    let processIdentifier: Int32
    var exitHandler: (@Sendable () -> Void)?

    init(processIdentifier: Int32) {
        self.processIdentifier = processIdentifier
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    var terminationAttemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return terminationAttempts
    }

    func preventTermination() {
        lock.lock()
        terminateStopsProcess = false
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        terminationAttempts += 1
        let shouldStop = terminateStopsProcess
        lock.unlock()
        if shouldStop {
            finish()
        }
    }

    func kill() {
        finish()
    }

    func finish() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        running = false
        let handler = exitHandler
        lock.unlock()
        handler?()
    }
}

private actor HostServiceLaunchBarrier {
    private var hasLaunched = false
    private var launchWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func launchStarted() {
        hasLaunched = true
        let waiters = launchWaiters
        launchWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForLaunch() async {
        if hasLaunched { return }
        await withCheckedContinuation { launchWaiters.append($0) }
    }

    func waitUntilReleased() async {
        if isReleased { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private final class HostServiceSyntheticLauncher: ProcessExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var invocations: [ProcessInvocation] = []
    private var handles: [HostServiceSyntheticProcessHandle] = []
    private var exitCallbacks: [@Sendable (ProcessExit) -> Void] = []
    private var invocationWaiters: [UUID: (count: Int, continuation: CheckedContinuation<Void, Error>)] = [:]
    let barrier: HostServiceLaunchBarrier?

    init(barrier: HostServiceLaunchBarrier? = nil) {
        self.barrier = barrier
    }

    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: Data(), timedOut: false)
    }

    func launch(
        _ invocation: ProcessInvocation,
        operation: String,
        onExit: @escaping @Sendable (ProcessExit) -> Void
    ) async throws -> any OwnedProcessHandle {
        let handle = launchSynchronously(invocation, onExit: onExit)
        handle.exitHandler = { onExit(ProcessExit(status: 0)) }
        await barrier?.launchStarted()
        await barrier?.waitUntilReleased()
        return handle
    }

    private func launchSynchronously(
        _ invocation: ProcessInvocation,
        onExit: @escaping @Sendable (ProcessExit) -> Void
    ) -> HostServiceSyntheticProcessHandle {
        lock.lock()
        invocations.append(invocation)
        exitCallbacks.append(onExit)
        let handle = HostServiceSyntheticProcessHandle(processIdentifier: Int32(invocations.count))
        handles.append(handle)
        let ready = invocationWaiters.filter { $0.value.count <= invocations.count }
        for key in ready.keys { invocationWaiters.removeValue(forKey: key) }
        lock.unlock()
        ready.values.forEach { $0.continuation.resume() }
        return handle
    }

    func waitForInvocationCount(_ count: Int) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            lock.lock()
            if invocations.count >= count {
                lock.unlock()
                continuation.resume()
                return
            }
            invocationWaiters[id] = (count, continuation)
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [self] in
                lock.lock()
                let waiter = invocationWaiters.removeValue(forKey: id)
                lock.unlock()
                waiter?.continuation.resume(throwing: HostServiceFixtureError.commandFailed("launch event timed out"))
            }
        }
    }

    func invocationSnapshot() -> [ProcessInvocation] {
        lock.lock()
        defer { lock.unlock() }
        return invocations
    }

    func runningHandleCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return handles.filter(\.isRunning).count
    }

    func handle(at index: Int) -> HostServiceSyntheticProcessHandle? {
        lock.lock()
        defer { lock.unlock() }
        guard handles.indices.contains(index) else { return nil }
        return handles[index]
    }

    func emitExit(at index: Int) {
        lock.lock()
        guard exitCallbacks.indices.contains(index) else {
            lock.unlock()
            return
        }
        let callback = exitCallbacks[index]
        lock.unlock()
        callback(ProcessExit(status: 0))
    }

    func stopAll() {
        lock.lock()
        let snapshot = handles
        lock.unlock()
        snapshot.forEach { $0.finish() }
    }
}

private enum HostServiceSyntheticEndpoint {
    static func write(
        invocation: ProcessInvocation,
        fixture: HostServiceFixture,
        endpointPID: Int32 = getpid(),
        endpointPluginID: String? = nil,
        endpointInstanceID: String? = nil,
        endpointSocketPath: String? = nil
    ) throws {
        let stateDirectory = try requireEnvironment(
            "MACDORA_PLUGIN_STATE_DIR",
            in: invocation
        )
        let socketPath = try requireEnvironment(
            "MACDORA_PLUGIN_SOCKET_PATH",
            in: invocation
        )
        let instanceID = try requireEnvironment(
            "MACDORA_PLUGIN_INSTANCE_ID",
            in: invocation
        )
        let endpoint = HostServiceEndpointRecord(
            schemaVersion: 1,
            pluginId: endpointPluginID
                ?? invocation.environment["MACDORA_PLUGIN_ID"]
                ?? fixture.manifest.id,
            instanceId: endpointInstanceID ?? instanceID,
            pid: endpointPID,
            socketPath: endpointSocketPath ?? socketPath,
            protocol: "json-rpc-2.0"
        )
        let endpointURL = URL(fileURLWithPath: stateDirectory, isDirectory: true)
            .appendingPathComponent("endpoint.json")
        try JSONEncoder().encode(endpoint).write(to: endpointURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int(0o600))],
            ofItemAtPath: endpointURL.path
        )
        let socketURL = URL(fileURLWithPath: socketPath)
        if !FileManager.default.fileExists(atPath: socketURL.path) {
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw HostServiceFixtureError.commandFailed("socket") }
            defer { Darwin.close(fd) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(socketPath.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
                throw HostServiceFixtureError.commandFailed("socket path")
            }
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.initializeMemory(as: UInt8.self, repeating: 0)
                raw.copyBytes(from: bytes)
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw HostServiceFixtureError.commandFailed("bind") }
            #expect(Darwin.chmod(socketPath, 0o600) == 0)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int(0o600))],
                ofItemAtPath: socketURL.path
            )
        }
    }

    private static func requireEnvironment(
        _ name: String,
        in invocation: ProcessInvocation
    ) throws -> String {
        guard let value = invocation.environment[name], !value.isEmpty else {
            throw HostServiceFixtureError.commandFailed("missing \(name)")
        }
        return value
    }
}

private struct HostServiceSyntheticTerminator: OwnedProcessTerminating {
    let launcher: HostServiceSyntheticLauncher
    let fail: Bool
    let shouldFail: (@Sendable (any OwnedProcessHandle) -> Bool)?

    init(launcher: HostServiceSyntheticLauncher, fail: Bool = false) {
        self.launcher = launcher
        self.fail = fail
        self.shouldFail = nil
    }

    init(
        launcher: HostServiceSyntheticLauncher,
        shouldFail: @escaping @Sendable (any OwnedProcessHandle) -> Bool
    ) {
        self.launcher = launcher
        self.fail = false
        self.shouldFail = shouldFail
    }

    func terminateAndWait(
        _ handle: any OwnedProcessHandle,
        timeout: TimeInterval
    ) async -> Bool {
        if fail || shouldFail?(handle) == true { return false }
        handle.terminate()
        return !handle.isRunning
    }
}

private struct HostServiceSharedTerminator: OwnedProcessTerminating {
    let launcher: HostServiceSyntheticLauncher
    let fail: Bool
    let stopAllOnExit: Bool

    init(
        launcher: HostServiceSyntheticLauncher,
        fail: Bool = false,
        stopAllOnExit: Bool = true
    ) {
        self.launcher = launcher
        self.fail = fail
        self.stopAllOnExit = stopAllOnExit
    }

    func terminateAndWait(
        _ handle: any OwnedProcessHandle,
        timeout: TimeInterval
    ) async -> Bool {
        if fail { return false }
        if stopAllOnExit {
            launcher.stopAll()
        } else {
            handle.terminate()
        }
        return !handle.isRunning
    }
}

private actor HostServiceDelayedHealthGate {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var entered = false
    private var released = false

    func probe() async -> Result<Void, HostServiceHealthError> {
        entered = true
        let enteredWaiter = enteredContinuation
        enteredContinuation = nil
        enteredWaiter?.resume()
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
                return
            }
            releaseContinuation = continuation
        }
        return .failure(.protocolFailure)
    }

    func waitUntilEntered() async {
        if entered {
            return
        }
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func release() {
        released = true
        let continuation = releaseContinuation
        releaseContinuation = nil
        continuation?.resume()
    }
}

private final class HostServiceAtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private func bindForeignSocket(at socketURL: URL) throws {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw HostServiceFixtureError.commandFailed("socket") }
    defer { Darwin.close(fd) }
    let bytes = Array(socketURL.path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
        throw HostServiceFixtureError.commandFailed("socket path")
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.initializeMemory(as: UInt8.self, repeating: 0)
        raw.copyBytes(from: bytes)
    }
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else { throw HostServiceFixtureError.commandFailed("bind") }
}

@Suite("Host Service System Plugin")
struct HostServiceSystemPluginTests {
    @Test("Host service schema and signature rules retain legacy script packages")
    func schemaAndImportRules() throws {
        let root = try hostServiceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let missingCapability = SystemPluginManifest(
            schemaVersion: 1,
            id: "dev.host.no-capability",
            name: "No Capability",
            subtitle: "",
            version: "1.0.0",
            author: "test",
            category: "test",
            iconSymbol: "",
            accentHex: 0,
            minHostVersion: "0.2.0",
            capabilities: [],
            driverType: "host_service",
            entrypoints: SystemPluginEntrypoints(hostService: "bin/service")
        )
        let missingCapabilityURL = root.appendingPathComponent("missing-capability", isDirectory: true)
        try FileManager.default.createDirectory(at: missingCapabilityURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(missingCapability).write(
            to: missingCapabilityURL.appendingPathComponent("manifest.json")
        )
        #expect(throws: SystemPluginPackageError.self) {
            _ = try SystemPluginPackageFactory.verifyPluginDirectory(
                missingCapabilityURL,
                trustPolicy: .developerLocalImport
            )
        }

        let missingEntrypoint = SystemPluginManifest(
            schemaVersion: 1,
            id: "dev.host.no-entrypoint",
            name: "No Entrypoint",
            subtitle: "",
            version: "1.0.0",
            author: "test",
            category: "test",
            iconSymbol: "",
            accentHex: 0,
            minHostVersion: "0.2.0",
            capabilities: ["host.service"],
            driverType: "host_service",
            entrypoints: SystemPluginEntrypoints(hostService: nil)
        )
        let missingEntrypointURL = root.appendingPathComponent("missing-entrypoint", isDirectory: true)
        try FileManager.default.createDirectory(at: missingEntrypointURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(missingEntrypoint).write(
            to: missingEntrypointURL.appendingPathComponent("manifest.json")
        )
        #expect(throws: SystemPluginPackageError.self) {
            _ = try SystemPluginPackageFactory.verifyPluginDirectory(
                missingEntrypointURL,
                trustPolicy: .developerLocalImport
            )
        }

        let legacy = try SystemPluginPackageFactory.createDeveloperTemplateDirectory(
            at: root.appendingPathComponent("legacy-source"),
            pluginID: "dev.host.legacy"
        )
        let verifiedLegacy = try SystemPluginPackageFactory.verifyPluginDirectory(
            legacy,
            trustPolicy: .developerLocalImport
        )
        #expect(verifiedLegacy.driverType == "external_script")
        #expect(verifiedLegacy.entrypoints.hostService == nil)

        let defaultFixture = try HostServiceFixture.create(rootURL: root)
        let verifiedHost = try SystemPluginPackageFactory.verifyPluginDirectory(
            defaultFixture.bundleURL,
            trustPolicy: .developerLocalImport
        )
        #expect(verifiedHost.driverType == "host_service")
        #expect(verifiedHost.entrypoints.hostService == "bin/service")
    }

    @Test("Missing executable or unsigned entrypoint is refused before any process launch")
    @MainActor
    func rejectsUnsignedAndNonExecutableEntrypoints() async throws {
        let root = try hostServiceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("bin"),
            withIntermediateDirectories: true
        )
        let serviceURL = bundle.appendingPathComponent("bin/service")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: serviceURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: serviceURL.path)
        let plugin = HostServiceSystemPlugin(
            manifest: hostServiceStubManifest(),
            bundleDirectoryURL: bundle,
            rootURL: root
        )
        let bridge = HostServiceTestBridge()
        await plugin.activate(bridge: bridge)
        #expect(plugin.healthState != .healthy)
        #expect(!FileManager.default.fileExists(
            atPath: HostServiceRuntimeConfiguration.make(
                rootURL: root,
                pluginID: plugin.manifest.id
            ).endpointURL.path
        ))

        let executableButUnsigned = root.appendingPathComponent("unsigned", isDirectory: true)
        try FileManager.default.createDirectory(
            at: executableButUnsigned.appendingPathComponent("bin"),
            withIntermediateDirectories: true
        )
        let unsignedService = executableButUnsigned.appendingPathComponent("bin/service")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: unsignedService)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int(0o700))],
            ofItemAtPath: unsignedService.path
        )
        let unsignedPlugin = HostServiceSystemPlugin(
            manifest: hostServiceStubManifest(),
            bundleDirectoryURL: executableButUnsigned,
            rootURL: root
        )
        await unsignedPlugin.activate(bridge: bridge)
        #expect(unsignedPlugin.healthState != .healthy)
    }

    @Test("Long roots use the owner-verified temporary socket parent")
    func longSocketPathFallback() throws {
        let longRoot = URL(
            fileURLWithPath: "/" + String(repeating: "a", count: 110),
            isDirectory: true
        )
        let config = HostServiceRuntimeConfiguration.make(
            rootURL: longRoot,
            pluginID: "dev.host.service.long",
            instanceID: UUID(),
            hostPID: 42,
            temporaryRootURL: URL(fileURLWithPath: "/tmp")
        )
        #expect(config.socketURL.path.hasPrefix("/tmp/macdora-\(getuid())/"))
        #expect(config.socketURL.path.utf8.count <= HostServiceRuntimeConfiguration.socketPathLimit)
        #expect(config.endpoint.socketPath == config.socketURL.path)
        #expect(config.endpoint.protocol == "json-rpc-2.0")
    }

    @Test("The temporary socket parent is created through its canonical /private/tmp path")
    func temporarySocketParentUsesCanonicalPath() throws {
        let manager = FileManager.default
        let literalRoot = URL(
            fileURLWithPath: "/tmp/macdora-test-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        defer { try? manager.removeItem(at: literalRoot) }
        let canonicalRoot = HostServiceRuntimeConfiguration.canonicalExistingPath(literalRoot)
        let parentURL = canonicalRoot
        #expect(canonicalRoot.deletingLastPathComponent().path == "/tmp")
        #expect(canonicalRoot.path == literalRoot.path)

        try HostServiceSocketPathPolicy.ensureSafeDirectory(parentURL, exactMode: 0o700)
        var info = stat()
        #expect(lstat(parentURL.path, &info) == 0)
        #expect((info.st_mode & S_IFMT) == S_IFDIR)
        #expect(info.st_uid == getuid())
        #expect((info.st_mode & 0o777) == 0o700)
        #expect(parentURL.resolvingSymlinksInPath().standardizedFileURL.path == parentURL.path)
    }

    @Test("Socket safety rejects a non-owner-only parent even when the socket itself is secure")
    func socketHealthChecksParentOwnershipAndMode() throws {
        let root = try hostServiceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("private/run", isDirectory: true),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int(0o700))]
        )
        for path in ["private", "private/run"] {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int(0o700))],
                ofItemAtPath: root.appendingPathComponent(path).path
            )
        }
        let configuration = HostServiceRuntimeConfiguration.make(
            rootURL: root,
            pluginID: "dev.host.socket-policy"
        )
        let socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(socketFD >= 0)
        guard socketFD >= 0 else { return }
        defer { Darwin.close(socketFD) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(configuration.socketURL.path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            raw.copyBytes(from: pathBytes.prefix(raw.count))
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bound == 0)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int(0o600))],
            ofItemAtPath: configuration.socketURL.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int(0o755))],
            ofItemAtPath: configuration.socketURL.deletingLastPathComponent().path
        )
        #expect(throws: HostServiceHealthError.socketUnsafe) {
            try HostServiceSocketPathPolicy.validateSocketParent(
                for: configuration.socketURL,
                rootURL: root
            )
        }
    }

    @Test("Runtime ready launches exactly one owned process and stop preserves enable intent")
    @MainActor
    func runtimeLifecycleAndOwnedStop() async throws {
        let root = try hostServiceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try HostServiceFixture.create(rootURL: root)
        let plugin = HostServiceSystemPlugin(
            manifest: fixture.manifest,
            bundleDirectoryURL: fixture.bundleURL,
            rootURL: root
        )
        let bridge = HostServiceTestBridge()
        bridge.currentRuntimeState = .stopped
        await plugin.activate(bridge: bridge)
        #expect(plugin.isEnabled)
        #expect(plugin.healthState == .waitingForRuntime)
        #expect(!FileManager.default.fileExists(
            atPath: HostServiceRuntimeConfiguration.make(
                rootURL: root,
                pluginID: fixture.manifest.id
            ).endpointURL.path
        ))

        bridge.currentRuntimeState = .ready
        let readyTask = Task { @MainActor in
            await plugin.onRuntimeBecameReady(bridge: bridge)
        }
        let readinessDeadline = ContinuousClock.now + .seconds(3)
        let configuration = HostServiceRuntimeConfiguration.make(
            rootURL: root,
            pluginID: fixture.manifest.id
        )
        while !FileManager.default.fileExists(atPath: configuration.endpointURL.path),
              ContinuousClock.now < readinessDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        await readyTask.value
        #expect(plugin.healthState == .healthy)
        #expect(try fixture.serviceDigestAfter() == fixture.serviceDigestBefore)
        let rawEndpoint = try #require(
            HostServiceEndpointReader.readUnvalidated(at: configuration.endpointURL)
        )
        #expect(UUID(uuidString: rawEndpoint.instanceId) != nil)
        let endpoint = try HostServiceEndpointReader.read(
            at: configuration.endpointURL,
            expected: HostServiceEndpointRecord(
                schemaVersion: 1,
                pluginId: fixture.manifest.id,
                instanceId: rawEndpoint.instanceId,
                pid: getpid(),
                socketPath: configuration.socketURL.path,
                protocol: "json-rpc-2.0"
            )
        )
        #expect(endpoint.pluginId == fixture.manifest.id)

        await plugin.onRuntimeStopping(bridge: bridge)
        #expect(plugin.isEnabled)
        #expect(plugin.healthState == .waitingForRuntime)
        #expect(!FileManager.default.fileExists(atPath: configuration.endpointURL.path))
        #expect(!FileManager.default.fileExists(atPath: configuration.socketURL.path))
    }

    @Test("Runtime health checks reject a socket with an unsafe parent")
    @MainActor
    func healthRejectsUnsafeSocketParent() async throws {
        let root = try hostServiceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try HostServiceFixture.create(rootURL: root)
        let launcher = HostServiceSyntheticLauncher()
        let plugin = HostServiceSystemPlugin(
            manifest: fixture.manifest,
            bundleDirectoryURL: fixture.bundleURL,
            rootURL: root,
            processExecuter: launcher,
            processTerminator: HostServiceSyntheticTerminator(launcher: launcher),
            healthClient: { _, _, _ in .success(()) }
        )
        let bridge = HostServiceTestBridge()
        let activation = Task { @MainActor in await plugin.activate(bridge: bridge) }
        try await launcher.waitForInvocationCount(1)
        #expect(launcher.invocationSnapshot().count == 1)
        let invocation = try #require(launcher.invocationSnapshot().first)
        try HostServiceSyntheticEndpoint.write(invocation: invocation, fixture: fixture)
        await activation.value
        #expect(plugin.healthState == .healthy)
        let socketPath = try #require(invocation.environment["MACDORA_PLUGIN_SOCKET_PATH"])
        let parent = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        #expect(Darwin.chmod(parent.path, 0o755) == 0)
        #expect(await plugin.triggerHealthCheck(bridge: bridge) == false)
        #expect(plugin.healthState != .healthy)
        launcher.stopAll()
    }

    @Test("Enable and restart launch distinct instances with no inherited arguments")
    @MainActor
    func enableStartsOnceAndRestartUsesNewInstance() async throws {
        let root = try hostServiceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try HostServiceFixture.create(rootURL: root)
        let launcher = HostServiceSyntheticLauncher()
        let plugin = HostServiceSystemPlugin(
            manifest: fixture.manifest,
            bundleDirectoryURL: fixture.bundleURL,
            rootURL: root,
            processExecuter: launcher,
            processTerminator: HostServiceSyntheticTerminator(launcher: launcher),
            healthClient: { _, _, _ in .success(()) }
        )
        let bridge = HostServiceTestBridge()

        let firstActivation = Task { @MainActor in await plugin.activate(bridge: bridge) }
        try await launcher.waitForInvocationCount(1)
        let firstInvocation = try #require(launcher.invocationSnapshot().first)
        try HostServiceSyntheticEndpoint.write(invocation: firstInvocation, fixture: fixture)
        await firstActivation.value
        #expect(plugin.healthState == .healthy)
        #expect(firstInvocation.arguments.isEmpty)
        let firstInstance = UUID(
            uuidString: try #require(firstInvocation.environment["MACDORA_PLUGIN_INSTANCE_ID"])
        )

        await plugin.onRuntimeStopping(bridge: bridge)
        #expect(launcher.runningHandleCount() == 0)
        let secondActivation = Task { @MainActor in await plugin.onRuntimeBecameReady(bridge: bridge) }
        try await launcher.waitForInvocationCount(2)
        let secondInvocation = try #require(launcher.invocationSnapshot().dropFirst().first)
        try HostServiceSyntheticEndpoint.write(invocation: secondInvocation, fixture: fixture)
        await secondActivation.value
        #expect(plugin.healthState == .healthy)
        #expect(
            UUID(uuidString: try #require(secondInvocation.environment["MACDORA_PLUGIN_INSTANCE_ID"]))
                != firstInstance
        )
    }

    @Test("A shared owner that cannot be stopped blocks disable and keeps its reservation")
    @MainActor
    func sharedOwnerStopFailureBlocksDisableAndDelete() async throws {
        let root = try hostServiceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try HostServiceFixture.create(rootURL: root)
        let supervisor = HostServiceSupervisorRegistry()
        let launcher = HostServiceSyntheticLauncher()
        let terminator = HostServiceSharedTerminator(launcher: launcher, fail: true)
        let first = HostServiceSystemPlugin(
            manifest: fixture.manifest,
            bundleDirectoryURL: fixture.bundleURL,
            rootURL: root,
            processExecuter: launcher,
            processTerminator: terminator,
            supervisor: supervisor,
            healthClient: { _, _, _ in .success(()) }
        )
        let bridge = HostServiceTestBridge()
        let firstActivation = Task { @MainActor in await first.activate(bridge: bridge) }
        try await launcher.waitForInvocationCount(1)
        let invocation = try #require(launcher.invocationSnapshot().first)
        try HostServiceSyntheticEndpoint.write(invocation: invocation, fixture: fixture)
        await firstActivation.value
        #expect(first.healthState == .healthy)

        let rebuilt = HostServiceSystemPlugin(
            manifest: fixture.manifest,
            bundleDirectoryURL: fixture.bundleURL,
            rootURL: root,
            processExecuter: launcher,
            processTerminator: terminator,
            supervisor: supervisor,
            healthClient: { _, _, _ in .success(()) }
        )
        await rebuilt.activate(bridge: bridge)
        #expect(rebuilt.healthState == .healthy)
        await rebuilt.setEnabledWithoutBridge(false)
        #expect(rebuilt.isEnabled)
        #expect(supervisor.owner(rootURL: root, pluginID: fixture.manifest.id) != nil)
    }

    @Test("An unhealthy shared owner is stopped before a clean restart")
    @MainActor
    func unhealthySharedOwnerIsReplaced() async throws {
        let root = try hostServiceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try HostServiceFixture.create(rootURL: root)
        let supervisor = HostServiceSupervisorRegistry()
        let launcher = HostServiceSyntheticLauncher()
        let terminator = HostServiceSharedTerminator(launcher: launcher)
        let healthClient: HostServiceHealthProbe = { _, _, _ in .success(()) }
        let first = HostServiceSystemPlugin(
            manifest: fixture.manifest,
            bundleDirectoryURL: fixture.bundleURL,
            rootURL: root,
            processExecuter: launcher,
            processTerminator: terminator,
            supervisor: supervisor,
            healthClient: healthClient
        )
        let bridge = HostServiceTestBridge()
        let firstActivation = Task { @MainActor in await first.activate(bridge: bridge) }
        try await launcher.waitForInvocationCount(1)
        let firstInvocation = try #require(launcher.invocationSnapshot().first)
        try HostServiceSyntheticEndpoint.write(invocation: firstInvocation, fixture: fixture)
        await firstActivation.value
        #expect(first.healthState == .healthy)

        let rebuiltHealthCounter = HostServiceAtomicCounter()
        let rebuilt = HostServiceSystemPlugin(
            manifest: fixture.manifest,
            bundleDirectoryURL: fixture.bundleURL,
            rootURL: root,
            processExecuter: launcher,
            processTerminator: terminator,
            supervisor: supervisor,
            healthClient: { _, _, _ in
                if rebuiltHealthCounter.increment() == 1 {
                    return .failure(.protocolFailure)
                }
                return .success(())
            }
        )
        let secondActivation = Task { @MainActor in await rebuilt.activate(bridge: bridge) }
        try await launcher.waitForInvocationCount(2)
        let secondInvocation = try #require(launcher.invocationSnapshot().dropFirst().first)
        try HostServiceSyntheticEndpoint.write(invocation: secondInvocation, fixture: fixture)
        await secondActivation.value
        if launcher.invocationSnapshot().count == 2 {
            #expect(launcher.runningHandleCount() == 1)
            #expect(supervisor.owner(rootURL: root, pluginID: fixture.manifest.id) != nil)
            return
        }
        // The first shared health probe consumes the injected failure and the
        // retry loop correctly reuses that same still-running owner.
        #expect(rebuiltHealthCounter.increment() > 1)
        #expect(launcher.runningHandleCount() == 1)
        #expect(supervisor.owner(rootURL: root, pluginID: fixture.manifest.id) != nil)
    }

    @Test("Running the service does not change the signed package")
    @MainActor
    func signedPackageIsUnchangedAfterRun() async throws {
        let root = try hostServiceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try HostServiceFixture.create(rootURL: root)
        let packageBefore = try hostServicePackageDigest(fixture.bundleURL)
        let plugin = HostServiceSystemPlugin(
            manifest: fixture.manifest,
            bundleDirectoryURL: fixture.bundleURL,
            rootURL: root
        )
        let bridge = HostServiceTestBridge()
        await plugin.activate(bridge: bridge)
        #expect(plugin.healthState == .healthy)
        await plugin.onRuntimeStopping(bridge: bridge)
        #expect(try hostServicePackageDigest(fixture.bundleURL) == packageBefore)
    }

    @Test("Late launch after disable is stopped and cannot resurrect health")
    @MainActor
    func disableDuringLaunchStopsLateProcess() async throws {
        let root = try hostServiceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try HostServiceFixture.create(rootURL: root)
        let barrier = HostServiceLaunchBarrier()
        let launcher = HostServiceSyntheticLauncher(barrier: barrier)
        let terminator = HostServiceSyntheticTerminator(launcher: launcher)
        let plugin = HostServiceSystemPlugin(
            manifest: fixture.manifest,
            bundleDirectoryURL: fixture.bundleURL,
            rootURL: root,
            processExecuter: launcher,
            processTerminator: terminator,
            healthClient: { _, _, _ in .success(()) }
        )
        let bridge = HostServiceTestBridge()
        bridge.currentRuntimeState = .ready
        defer { bridge.currentRuntimeState = .stopped }
        let activation = Task { @MainActor in await plugin.activate(bridge: bridge) }
        await barrier.waitForLaunch()
        let invocation = try #require(launcher.invocationSnapshot().first)
        try HostServiceSyntheticEndpoint.write(invocation: invocation, fixture: fixture)
        let deactivation = Task { @MainActor in await plugin.deactivate(bridge: bridge) }
        await Task.yield()
        await barrier.release()
        await activation.value
        #expect(await deactivation.value)
        #expect(!plugin.isEnabled)
        #expect(launcher.runningHandleCount() == 0)
    }

    @Test("A failed owned stop blocks disable and preserves its state")
    @MainActor
    func stopFailureBlocksDisable() async throws {
        let root = try hostServiceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try HostServiceFixture.create(rootURL: root)
        let launcher = HostServiceSyntheticLauncher()
        let plugin = HostServiceSystemPlugin(
            manifest: fixture.manifest,
            bundleDirectoryURL: fixture.bundleURL,
            rootURL: root,
            processExecuter: launcher,
            processTerminator: HostServiceSyntheticTerminator(
                launcher: launcher,
                fail: true
            ),
            healthClient: { _, _, _ in .success(()) }
        )
        let bridge = HostServiceTestBridge()
        let activation = Task { @MainActor in await plugin.activate(bridge: bridge) }
        try await launcher.waitForInvocationCount(1)
        let invocation = try #require(launcher.invocationSnapshot().first)
        try HostServiceSyntheticEndpoint.write(invocation: invocation, fixture: fixture)
        await activation.value
        #expect(plugin.healthState == .healthy)
        #expect(await plugin.deactivate(bridge: bridge) == false)
        #expect(plugin.healthState != .healthy)
        #expect(launcher.runningHandleCount() == 1)
        let configuration = HostServiceRuntimeConfiguration.make(
            rootURL: root,
            pluginID: fixture.manifest.id
        )
        #expect(FileManager.default.fileExists(atPath: configuration.endpointURL.path))
    }

    @Test("Reconstructed manager adopts the shared owner without launching twice")
    @MainActor
    func reconstructionReusesSingleOwner() async throws {
        let root = try hostServiceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try HostServiceFixture.create(rootURL: root)
        let supervisor = HostServiceSupervisorRegistry()
        let defaults = UserDefaults(suiteName: "HostServiceTests.\(UUID().uuidString)")!
        let launcher = HostServiceSyntheticLauncher()
        let healthClient: HostServiceHealthProbe = { _, _, _ in .success(()) }
        let manager = SystemPluginManager(
            rootURL: root,
            defaults: defaults,
            hostServiceProcessExecuter: launcher,
            hostServiceProcessTerminator: HostServiceSyntheticTerminator(launcher: launcher),
            hostServiceSupervisor: supervisor,
            hostServiceHealthClient: healthClient
        )
        let bridge = HostServiceTestBridge()
        manager.hostBridge = bridge
        _ = try await manager.importDeveloperPlugin(from: fixture.bundleURL, autoEnable: false)
        let first = try #require(manager.hostServicePlugin(for: fixture.manifest.id))
        let enableTask = Task { @MainActor in
            await manager.setPluginEnabled(id: fixture.manifest.id, enabled: true)
        }
        try await launcher.waitForInvocationCount(1)
        let invocation = try #require(launcher.invocationSnapshot().first)
        try HostServiceSyntheticEndpoint.write(invocation: invocation, fixture: fixture)
        await enableTask.value
        #expect(first.healthState == .healthy)
        await first.activate(bridge: bridge)
        #expect(launcher.invocationSnapshot().count == 1)
        #expect(manager.isPluginEnabled(fixture.manifest.id))

        let rebuilt = SystemPluginManager(
            rootURL: root,
            defaults: defaults,
            hostServiceProcessExecuter: launcher,
            hostServiceProcessTerminator: HostServiceSyntheticTerminator(launcher: launcher),
            hostServiceSupervisor: supervisor,
            hostServiceHealthClient: healthClient
        )
        rebuilt.hostBridge = bridge
        let rebuiltPlugin = try #require(rebuilt.hostServicePlugin(for: fixture.manifest.id))
        await rebuiltPlugin.activate(bridge: bridge)
        #expect(launcher.invocationSnapshot().count == 1)
        launcher.stopAll()
    }

    @Test("Only controlled host-service environment values cross the process boundary")
    @MainActor
    func environmentWhitelist() async throws {
        let root = try hostServiceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try HostServiceFixture.create(rootURL: root)
        let launcher = HostServiceSyntheticLauncher()
        let plugin = HostServiceSystemPlugin(
            manifest: fixture.manifest,
            bundleDirectoryURL: fixture.bundleURL,
            rootURL: root,
            processExecuter: launcher,
            processTerminator: HostServiceSyntheticTerminator(launcher: launcher),
            healthClient: { _, _, _ in .success(()) }
        )
        let bridge = HostServiceTestBridge()

        let activation = Task { @MainActor in await plugin.activate(bridge: bridge) }
        try await launcher.waitForInvocationCount(1)
        let invocation = try #require(launcher.invocationSnapshot().first)
        try HostServiceSyntheticEndpoint.write(invocation: invocation, fixture: fixture)
        await activation.value

        let environment = invocation.environment
        #expect(environment["MACDORA_PLUGIN_ID"] == fixture.manifest.id)
        #expect(environment["MACDORA_PLUGIN_INSTANCE_ID"] != nil)
        #expect(environment["MACDORA_HOST_PID"] == String(getpid()))
        #expect(environment["UNRELATED_SECRET"] == nil)
        #expect(environment["HOME"] == nil)
        #expect(environment["MACDORA_ADB_PATH"] == nil)
        #expect(environment["ADB_SERVER_SOCKET"] == nil)
        #expect(plugin.healthState == .healthy)
    }

    @Test("Guest access variables are passed only when the service declares guest.shell")
    @MainActor
    func guestEnvironmentRequiresCapability() async throws {
        let root = try hostServiceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try HostServiceFixture.create(
            rootURL: root,
            capabilities: ["host.service", "guest.shell"],
            markerName: "guest-started-count"
        )
        let launcher = HostServiceSyntheticLauncher()
        let plugin = HostServiceSystemPlugin(
            manifest: fixture.manifest,
            bundleDirectoryURL: fixture.bundleURL,
            rootURL: root,
            processExecuter: launcher,
            processTerminator: HostServiceSyntheticTerminator(launcher: launcher),
            healthClient: { _, _, _ in .success(()) }
        )
        let bridge = HostServiceTestBridge()

        let activation = Task { @MainActor in await plugin.activate(bridge: bridge) }
        try await launcher.waitForInvocationCount(1)
        let invocation = try #require(launcher.invocationSnapshot().first)
        try HostServiceSyntheticEndpoint.write(invocation: invocation, fixture: fixture)
        await activation.value

        #expect(invocation.environment["MACDORA_ADB_PATH"] == "/test/adb")
        #expect(invocation.environment["MACDORA_ADB_SERIAL"] == "emulator-5584")
        #expect(invocation.environment["ANDROID_ADB_SERVER_PORT"] == "5043")
        #expect(
            invocation.environment["ADB_SERVER_SOCKET"]
                == "tcp:127.0.0.1:5043"
        )
        #expect(invocation.environment["UNRELATED_SECRET"] == nil)
        #expect(plugin.healthState == .healthy)
    }

    @Test("A failed process reports one fixed health error without process output")
    @MainActor
    func processFailureUsesFixedError() async throws {
        let root = try hostServiceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try HostServiceFixture.create(rootURL: root)
        let launcher = HostServiceSyntheticLauncher()
        let plugin = HostServiceSystemPlugin(
            manifest: fixture.manifest,
            bundleDirectoryURL: fixture.bundleURL,
            rootURL: root,
            processExecuter: launcher,
            processTerminator: HostServiceSyntheticTerminator(launcher: launcher),
            healthClient: { _, _, _ in .failure(.protocolFailure) }
        )
        let bridge = HostServiceTestBridge()

        let activation = Task { @MainActor in await plugin.activate(bridge: bridge) }
        try await launcher.waitForInvocationCount(1)
        let invocation = try #require(launcher.invocationSnapshot().first)
        try HostServiceSyntheticEndpoint.write(invocation: invocation, fixture: fixture)
        await activation.value

        #expect(plugin.healthState == .degraded(HostServiceSystemPlugin.fixedHealthError))
        #expect(plugin.runtimeStatusSummary == HostServiceSystemPlugin.fixedHealthError)
        #expect(!plugin.runtimeStatusSummary.contains("SECRET"))
        #expect(!plugin.runtimeStatusSummary.contains("stdout"))
        #expect(!plugin.runtimeStatusSummary.contains("stderr"))
        #expect(launcher.runningHandleCount() == 0)
    }

    @Test("Deletion only removes the private state owned by the deleted plugin")
    @MainActor
    func deletionOnlyClearsOwnedPrivateState() async throws {
        let root = try hostServiceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try HostServiceFixture.create(rootURL: root)
        let defaults = UserDefaults(suiteName: "HostServiceTests.\(UUID().uuidString)")!
        let manager = SystemPluginManager(rootURL: root, defaults: defaults)
        _ = try await manager.importDeveloperPlugin(from: fixture.bundleURL)

        let pluginStateRoot = root.appendingPathComponent(
            "private/plugin-state",
            isDirectory: true
        )
        let ownedState = pluginStateRoot.appendingPathComponent(
            fixture.manifest.id,
            isDirectory: true
        )
        let siblingState = pluginStateRoot.appendingPathComponent(
            "dev.host.sibling",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: ownedState,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int(0o700))]
        )
        try FileManager.default.createDirectory(
            at: siblingState,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int(0o700))]
        )
        let ownedMarker = ownedState.appendingPathComponent("owned.txt")
        let siblingMarker = siblingState.appendingPathComponent("keep.txt")
        try Data("owned".utf8).write(to: ownedMarker)
        try Data("keep".utf8).write(to: siblingMarker)

        try await manager.deletePlugin(id: fixture.manifest.id)
        #expect(!FileManager.default.fileExists(atPath: ownedState.path))
        #expect(FileManager.default.fileExists(atPath: siblingState.path))
        #expect(try String(contentsOf: siblingMarker, encoding: .utf8) == "keep")
    }

    @Test("Cleanup never deletes another plugin's socket named by a forged endpoint")
    @MainActor
    func cleanupNeverDeletesAnotherSocketFromEndpoint() async throws {
        let root = try hostServiceTestRoot()
        let forgedSocketParent = URL(
            fileURLWithPath: "/tmp/macdora-test-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: forgedSocketParent)
        }
        let pluginID = "dev.host.cleanup-owner"
        let pluginStateRoot = root.appendingPathComponent("private/plugin-state", isDirectory: true)
        let stateURL = pluginStateRoot.appendingPathComponent(pluginID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: stateURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int(0o700))]
        )
        try FileManager.default.createDirectory(
            at: forgedSocketParent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int(0o700))]
        )
        let foreignSocket = forgedSocketParent.appendingPathComponent("foreign.sock")
        try bindForeignSocket(at: foreignSocket)
        #expect(Darwin.chmod(foreignSocket.path, 0o600) == 0)

        let endpoint = HostServiceEndpointRecord(
            schemaVersion: 1,
            pluginId: pluginID,
            instanceId: UUID().uuidString,
            pid: getpid(),
            socketPath: foreignSocket.path,
            protocol: "json-rpc-2.0"
        )
        let endpointURL = stateURL.appendingPathComponent("endpoint.json")
        try JSONEncoder().encode(endpoint).write(to: endpointURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int(0o600))],
            ofItemAtPath: endpointURL.path
        )

        let supervisor = HostServiceSupervisorRegistry()
        let outcome = try HostServicePrivateStateStore.remove(
            rootURL: root,
            pluginID: pluginID,
            supervisor: supervisor
        )
        #expect(outcome == .retained)
        #expect(FileManager.default.fileExists(atPath: foreignSocket.path))
        #expect(FileManager.default.fileExists(atPath: endpointURL.path))
        #expect(FileManager.default.fileExists(atPath: stateURL.path))
    }

    @Test("A failed owned stop blocks deletion and preserves package and private state")
    @MainActor
    func failedStopBlocksDeletion() async throws {
        let root = try hostServiceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try HostServiceFixture.create(rootURL: root)
        let defaults = UserDefaults(suiteName: "HostServiceTests.\(UUID().uuidString)")!
        let launcher = HostServiceSyntheticLauncher()
        let manager = SystemPluginManager(
            rootURL: root,
            defaults: defaults,
            hostServiceProcessExecuter: launcher,
            hostServiceProcessTerminator: HostServiceSyntheticTerminator(
                launcher: launcher,
                fail: true
            ),
            hostServiceHealthClient: { _, _, _ in .success(()) }
        )
        let bridge = HostServiceTestBridge()
        manager.hostBridge = bridge
        _ = try await manager.importDeveloperPlugin(from: fixture.bundleURL)
        let enableTask = Task { @MainActor in
            await manager.setPluginEnabled(id: fixture.manifest.id, enabled: true)
        }
        try await launcher.waitForInvocationCount(1)
        let invocation = try #require(launcher.invocationSnapshot().first)
        try HostServiceSyntheticEndpoint.write(invocation: invocation, fixture: fixture)
        await enableTask.value

        var deletionError: SystemPluginPackageError?
        do {
            try await manager.deletePlugin(id: fixture.manifest.id)
        } catch let error as SystemPluginPackageError {
            deletionError = error
        }
        #expect(deletionError != nil)
        #expect(manager.isPluginInstalled(fixture.manifest.id))
        #expect(manager.isPluginEnabled(fixture.manifest.id))
        #expect(FileManager.default.fileExists(atPath: fixture.bundleURL.path))
        #expect(FileManager.default.fileExists(
            atPath: HostServiceRuntimeConfiguration.make(
                rootURL: root,
                pluginID: fixture.manifest.id
            ).endpointURL.path
        ))
    }

    @Test("A failed process becomes unhealthy without becoming a permanent orphan gate")
    @MainActor
    func failedProcessCanRestart() async throws {
        let root = try hostServiceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try HostServiceFixture.create(rootURL: root)
        let launcher = HostServiceSyntheticLauncher()
        let plugin = HostServiceSystemPlugin(
            manifest: fixture.manifest,
            bundleDirectoryURL: fixture.bundleURL,
            rootURL: root,
            processExecuter: launcher,
            processTerminator: HostServiceSyntheticTerminator(launcher: launcher),
            healthClient: { _, _, _ in .success(()) }
        )
        let bridge = HostServiceTestBridge()

        let firstActivation = Task { @MainActor in await plugin.activate(bridge: bridge) }
        try await launcher.waitForInvocationCount(1)
        await firstActivation.value
        _ = await plugin.deactivate(bridge: bridge)
        #expect(!plugin.isEnabled)
        launcher.stopAll()

        let secondActivation = Task { @MainActor in await plugin.activate(bridge: bridge) }
        try await launcher.waitForInvocationCount(2)
        let secondInvocation = try #require(launcher.invocationSnapshot().dropFirst().first)
        try HostServiceSyntheticEndpoint.write(
            invocation: secondInvocation,
            fixture: fixture
        )
        await secondActivation.value
        #expect(launcher.invocationSnapshot().count == 2)
    }

    @Test("A retiring owner is neither adopted nor duplicated until its stop is confirmed")
    @MainActor
    func retiringOwnerBlocksAdoptionUntilConfirmedStop() async throws {
        let root = try hostServiceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try HostServiceFixture.create(rootURL: root)
        let supervisor = HostServiceSupervisorRegistry()
        let launcher = HostServiceSyntheticLauncher()
        let firstDefaultsSuiteName = "HostServiceTests.\(UUID().uuidString)"
        let firstDefaults = UserDefaults(suiteName: firstDefaultsSuiteName)!
        defer { firstDefaults.removePersistentDomain(forName: firstDefaultsSuiteName) }
        let firstManager = SystemPluginManager(
            rootURL: root,
            defaults: firstDefaults,
            hostServiceProcessExecuter: launcher,
            hostServiceProcessTerminator: HostServiceSyntheticTerminator(
                launcher: launcher,
                fail: true
            ),
            hostServiceSupervisor: supervisor,
            hostServiceHealthClient: { _, _, _ in .success(()) }
        )
        let bridge = HostServiceTestBridge()
        firstManager.hostBridge = bridge
        _ = try await firstManager.importDeveloperPlugin(
            from: fixture.bundleURL,
            autoEnable: false
        )
        let firstPlugin = try #require(
            firstManager.hostServicePlugin(for: fixture.manifest.id)
        )
        let enabling = Task { @MainActor in
            await firstManager.setPluginEnabled(id: fixture.manifest.id, enabled: true)
        }
        try await launcher.waitForInvocationCount(1)
        let firstInvocation = try #require(launcher.invocationSnapshot().first)
        try HostServiceSyntheticEndpoint.write(invocation: firstInvocation, fixture: fixture)
        await enabling.value
        #expect(firstPlugin.healthState == .healthy)

        // The stop is deliberately unconfirmed. Retiring must retain the owner.
        #expect(await firstPlugin.deactivate(bridge: bridge) == false)
        #expect(firstPlugin.isEnabled)
        let firstHandle = try #require(launcher.handle(at: 0))
        firstHandle.preventTermination()
        firstPlugin.retire()
        #expect(firstHandle.terminationAttemptCount == 1)
        #expect(launcher.runningHandleCount() == 1)
        #expect(supervisor.owner(rootURL: root, pluginID: fixture.manifest.id) != nil)
        #expect(
            supervisor.disposition(rootURL: root, pluginID: fixture.manifest.id)
                == .retiring
        )

        let secondDefaultsSuiteName = "HostServiceTests.\(UUID().uuidString)"
        let secondDefaults = UserDefaults(suiteName: secondDefaultsSuiteName)!
        defer { secondDefaults.removePersistentDomain(forName: secondDefaultsSuiteName) }
        let rebuiltManager = SystemPluginManager(
            rootURL: root,
            defaults: secondDefaults,
            hostServiceProcessExecuter: launcher,
            hostServiceProcessTerminator: HostServiceSyntheticTerminator(launcher: launcher),
            hostServiceSupervisor: supervisor,
            hostServiceHealthClient: { _, _, _ in .success(()) }
        )
        let rebuilt = try #require(
            rebuiltManager.hostServicePlugin(for: fixture.manifest.id)
        )
        await rebuilt.activate(bridge: bridge)
        #expect(launcher.invocationSnapshot().count == 1)
        #expect(launcher.runningHandleCount() == 1)
        #expect(
            supervisor.disposition(rootURL: root, pluginID: fixture.manifest.id)
                == .retiring
        )
        #expect(rebuilt.healthState != .healthy)

        // Simulate the service confirming its own exit. Only then may the
        // rebuilt instance launch a replacement.
        firstHandle.finish()
        let stopDeadline = ContinuousClock.now + .seconds(2)
        while supervisor.owner(rootURL: root, pluginID: fixture.manifest.id) != nil,
              ContinuousClock.now < stopDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(supervisor.owner(rootURL: root, pluginID: fixture.manifest.id) == nil)

        let restarting = Task { @MainActor in
            await rebuilt.onRuntimeBecameReady(bridge: bridge)
        }
        try await launcher.waitForInvocationCount(2)
        let secondInvocation = try #require(
            launcher.invocationSnapshot().dropFirst().first
        )
        try HostServiceSyntheticEndpoint.write(
            invocation: secondInvocation,
            fixture: fixture
        )
        await restarting.value
        #expect(launcher.invocationSnapshot().count == 2)
        #expect(launcher.runningHandleCount() == 1)
        #expect(rebuilt.healthState == .healthy)
    }

    @Test("Updating retires only the previous instance's owner")
    @MainActor
    func updateRetiresOnlyPreviousInstanceOwner() async throws {
        let root = try hostServiceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pluginID = "dev.host.update-retire"
        let oldFixture = try HostServiceFixture.create(
            rootURL: root,
            pluginID: pluginID,
            version: "1.0.0"
        )
        let newFixture = try HostServiceFixture.create(
            rootURL: root.appendingPathComponent("update-source", isDirectory: true),
            pluginID: pluginID,
            version: "1.1.0"
        )
        let defaultsSuiteName = "HostServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let supervisor = HostServiceSupervisorRegistry()
        let launcher = HostServiceSyntheticLauncher()
        let manager = SystemPluginManager(
            rootURL: root,
            defaults: defaults,
            hostServiceProcessExecuter: launcher,
            hostServiceProcessTerminator: HostServiceSyntheticTerminator(launcher: launcher),
            hostServiceSupervisor: supervisor,
            hostServiceHealthClient: { _, _, _ in .success(()) }
        )
        let bridge = HostServiceTestBridge()
        manager.hostBridge = bridge
        _ = try await manager.importDeveloperPlugin(from: oldFixture.bundleURL, autoEnable: false)
        let previousPlugin = try #require(manager.hostServicePlugin(for: pluginID))
        let enabling = Task { @MainActor in
            await manager.setPluginEnabled(id: pluginID, enabled: true)
        }
        try await launcher.waitForInvocationCount(1)
        let firstInvocation = try #require(launcher.invocationSnapshot().first)
        try HostServiceSyntheticEndpoint.write(invocation: firstInvocation, fixture: oldFixture)
        await enabling.value
        #expect(previousPlugin.healthState == .healthy)

        let updating = Task { @MainActor in
            try await manager.importDeveloperPlugin(from: newFixture.bundleURL)
        }
        try await launcher.waitForInvocationCount(2)
        let secondInvocation = try #require(launcher.invocationSnapshot().dropFirst().first)
        try HostServiceSyntheticEndpoint.write(invocation: secondInvocation, fixture: newFixture)
        let updated = try await updating.value

        #expect(updated.version == "1.1.0")
        #expect(updated.state.isEnabled)
        #expect(manager.hostServicePlugin(for: pluginID) !== previousPlugin)
        let currentOwner = try #require(
            supervisor.owner(rootURL: root, pluginID: pluginID)
        )
        let newHandle = try #require(launcher.handle(at: 1))
        #expect(currentOwner.handle === newHandle)
        #expect(supervisor.disposition(rootURL: root, pluginID: pluginID) == .active)

        // The updated manager already retires the old instance. Repeating that
        // retirement must not reach the supervisor's new shared owner.
        previousPlugin.retire()
        #expect(supervisor.owner(rootURL: root, pluginID: pluginID)?.handle === newHandle)
        #expect(supervisor.disposition(rootURL: root, pluginID: pluginID) == .active)
        #expect(launcher.runningHandleCount() == 1)
    }

    @Test("A reconstructed disabled manager stops its shared owner before update")
    @MainActor
    func reconstructedDisabledManagerStopsOwnerBeforeUpdate() async throws {
        let root = try hostServiceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pluginID = "dev.host.rebuilt-update"
        let oldFixture = try HostServiceFixture.create(
            rootURL: root,
            pluginID: pluginID,
            version: "1.0.0"
        )
        let newFixture = try HostServiceFixture.create(
            rootURL: root.appendingPathComponent("update-source", isDirectory: true),
            pluginID: pluginID,
            version: "1.1.0"
        )
        let firstSuiteName = "HostServiceTests.\(UUID().uuidString)"
        let firstDefaults = UserDefaults(suiteName: firstSuiteName)!
        defer { firstDefaults.removePersistentDomain(forName: firstSuiteName) }
        let supervisor = HostServiceSupervisorRegistry()
        let launcher = HostServiceSyntheticLauncher()
        let firstManager = SystemPluginManager(
            rootURL: root,
            defaults: firstDefaults,
            hostServiceProcessExecuter: launcher,
            hostServiceProcessTerminator: HostServiceSyntheticTerminator(launcher: launcher),
            hostServiceSupervisor: supervisor,
            hostServiceHealthClient: { _, _, _ in .success(()) }
        )
        let bridge = HostServiceTestBridge()
        firstManager.hostBridge = bridge
        _ = try await firstManager.importDeveloperPlugin(from: oldFixture.bundleURL, autoEnable: false)
        let enabling = Task { @MainActor in
            await firstManager.setPluginEnabled(id: pluginID, enabled: true)
        }
        try await launcher.waitForInvocationCount(1)
        let firstInvocation = try #require(launcher.invocationSnapshot().first)
        try HostServiceSyntheticEndpoint.write(invocation: firstInvocation, fixture: oldFixture)
        await enabling.value
        #expect(launcher.runningHandleCount() == 1)

        let rebuiltSuiteName = "HostServiceTests.\(UUID().uuidString)"
        let rebuiltDefaults = UserDefaults(suiteName: rebuiltSuiteName)!
        defer { rebuiltDefaults.removePersistentDomain(forName: rebuiltSuiteName) }
        let rebuiltManager = SystemPluginManager(
            rootURL: root,
            defaults: rebuiltDefaults,
            hostServiceProcessExecuter: launcher,
            hostServiceProcessTerminator: HostServiceSyntheticTerminator(launcher: launcher),
            hostServiceSupervisor: supervisor,
            hostServiceHealthClient: { _, _, _ in .success(()) }
        )
        rebuiltManager.hostBridge = bridge
        #expect(!rebuiltManager.isPluginEnabled(pluginID))
        #expect(supervisor.owner(rootURL: root, pluginID: pluginID) != nil)

        let updated = try await rebuiltManager.importDeveloperPlugin(
            from: newFixture.bundleURL,
            autoEnable: false
        )
        #expect(updated.version == "1.1.0")
        #expect(!updated.state.isEnabled)
        #expect(launcher.invocationSnapshot().count == 1)
        #expect(launcher.runningHandleCount() == 0)
        #expect(supervisor.owner(rootURL: root, pluginID: pluginID) == nil)
        #expect(!FileManager.default.fileExists(atPath: firstInvocation.environment[
            "MACDORA_PLUGIN_STATE_DIR"
        ].map { URL(fileURLWithPath: $0).appendingPathComponent("endpoint.json").path } ?? ""))
    }

    @Test("A rebuilt manager cannot disable or delete a running retiring owner")
    @MainActor
    func rebuiltManagerCannotSkipRetiringOwnerStop() async throws {
        let root = try hostServiceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try HostServiceFixture.create(rootURL: root)
        let firstSuiteName = "HostServiceTests.\(UUID().uuidString)"
        let firstDefaults = UserDefaults(suiteName: firstSuiteName)!
        defer { firstDefaults.removePersistentDomain(forName: firstSuiteName) }
        let supervisor = HostServiceSupervisorRegistry()
        let launcher = HostServiceSyntheticLauncher()
        let firstManager = SystemPluginManager(
            rootURL: root,
            defaults: firstDefaults,
            hostServiceProcessExecuter: launcher,
            hostServiceProcessTerminator: HostServiceSyntheticTerminator(launcher: launcher),
            hostServiceSupervisor: supervisor,
            hostServiceHealthClient: { _, _, _ in .success(()) }
        )
        let bridge = HostServiceTestBridge()
        firstManager.hostBridge = bridge
        _ = try await firstManager.importDeveloperPlugin(from: fixture.bundleURL, autoEnable: false)
        let firstPlugin = try #require(
            firstManager.hostServicePlugin(for: fixture.manifest.id)
        )
        let enabling = Task { @MainActor in
            await firstManager.setPluginEnabled(id: fixture.manifest.id, enabled: true)
        }
        try await launcher.waitForInvocationCount(1)
        let invocation = try #require(launcher.invocationSnapshot().first)
        try HostServiceSyntheticEndpoint.write(invocation: invocation, fixture: fixture)
        await enabling.value
        let runningHandle = try #require(launcher.handle(at: 0))
        runningHandle.preventTermination()
        firstPlugin.retire()
        #expect(supervisor.disposition(
            rootURL: root,
            pluginID: fixture.manifest.id
        ) == .retiring)

        let rebuiltSuiteName = "HostServiceTests.\(UUID().uuidString)"
        let rebuiltDefaults = UserDefaults(suiteName: rebuiltSuiteName)!
        defer { rebuiltDefaults.removePersistentDomain(forName: rebuiltSuiteName) }
        let rebuiltManager = SystemPluginManager(
            rootURL: root,
            defaults: rebuiltDefaults,
            hostServiceProcessExecuter: launcher,
            hostServiceProcessTerminator: HostServiceSyntheticTerminator(
                launcher: launcher,
                fail: true
            ),
            hostServiceSupervisor: supervisor,
            hostServiceHealthClient: { _, _, _ in .success(()) }
        )
        rebuiltManager.hostBridge = bridge
        let rebuiltPlugin = try #require(
            rebuiltManager.hostServicePlugin(for: fixture.manifest.id)
        )
        #expect(!rebuiltPlugin.isEnabled)

        do {
            try await rebuiltManager.deletePlugin(id: fixture.manifest.id)
            Issue.record("A running retiring owner must block deletion")
        } catch let error as SystemPluginPackageError {
            if case .operationFailed = error {} else {
                Issue.record("Unexpected deletion error: \(error)")
            }
        }
        #expect(rebuiltManager.isPluginInstalled(fixture.manifest.id))
        #expect(rebuiltManager.isPluginEnabled(fixture.manifest.id))
        #expect(FileManager.default.fileExists(atPath: fixture.bundleURL.path))
        #expect(supervisor.owner(
            rootURL: root,
            pluginID: fixture.manifest.id
        )?.handle === runningHandle)
        #expect(supervisor.disposition(
            rootURL: root,
            pluginID: fixture.manifest.id
        ) == .retiring)
        #expect(runningHandle.isRunning)
        #expect(FileManager.default.fileExists(atPath: invocation.environment[
            "MACDORA_PLUGIN_STATE_DIR"
        ].map { URL(fileURLWithPath: $0).appendingPathComponent("endpoint.json").path } ?? ""))

        await rebuiltManager.setPluginEnabled(id: fixture.manifest.id, enabled: false)
        #expect(rebuiltPlugin.isEnabled)
        #expect(rebuiltManager.isPluginEnabled(fixture.manifest.id))
        #expect(supervisor.owner(
            rootURL: root,
            pluginID: fixture.manifest.id
        )?.handle === runningHandle)
        #expect(supervisor.disposition(
            rootURL: root,
            pluginID: fixture.manifest.id
        ) == .retiring)
        #expect(runningHandle.isRunning)

        runningHandle.finish()
    }
}
