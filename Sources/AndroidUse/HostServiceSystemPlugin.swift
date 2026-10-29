import CryptoKit
import Darwin
import Foundation
import Security

struct HostServiceEndpointRecord: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var pluginId: String
    var instanceId: String
    var pid: Int32
    var socketPath: String
    var `protocol`: String
}

struct HostServicePingResult: Decodable, Equatable, Sendable {
    var pluginId: String
    var instanceId: String
    var ready: Bool
}

enum HostServiceHealthError: Error, Equatable, Sendable {
    case notRunning
    case endpointUnavailable
    case endpointMismatch
    case socketUnsafe
    case codeSignatureInvalid
    case packageChanged
    case protocolFailure
    case stopFailed
}

typealias HostServiceHealthProbe = @Sendable (
    URL,
    String,
    UUID
) async -> Result<Void, HostServiceHealthError>

struct HostServiceRuntimeConfiguration: Equatable, Sendable {
    static let socketPathLimit = 104
    static let endpointSchemaVersion = 1
    static let protocolName = "json-rpc-2.0"

    let stateDirectoryURL: URL
    let endpointURL: URL
    let socketURL: URL
    let instanceID: UUID
    let hostPID: Int32
    let pluginID: String

    static func make(
        rootURL: URL,
        pluginID: String,
        instanceID: UUID = UUID(),
        hostPID: Int32 = getpid(),
        temporaryRootURL: URL = URL(fileURLWithPath: "/tmp", isDirectory: true)
    ) -> HostServiceRuntimeConfiguration {
        let canonicalRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let stateDirectoryURL = canonicalRoot
            .appendingPathComponent("private/plugin-state", isDirectory: true)
            .appendingPathComponent(pluginID, isDirectory: true)
        let digest = shortStableDigest(canonicalRoot.path + "\u{0}" + pluginID)
        let primarySocketURL = canonicalRoot
            .appendingPathComponent("private/run", isDirectory: true)
            .appendingPathComponent("macdora-\(digest).sock")
        let socketURL: URL
        if primarySocketURL.path.utf8.count < socketPathLimit {
            socketURL = primarySocketURL
        } else {
            socketURL = fallbackSocketURL(
                temporaryRootURL: temporaryRootURL,
                digest: digest
            )
        }
        return HostServiceRuntimeConfiguration(
            stateDirectoryURL: stateDirectoryURL,
            endpointURL: stateDirectoryURL.appendingPathComponent("endpoint.json"),
            socketURL: socketURL,
            instanceID: instanceID,
            hostPID: hostPID,
            pluginID: pluginID
        )
    }

    var endpoint: HostServiceEndpointRecord {
        HostServiceEndpointRecord(
            schemaVersion: Self.endpointSchemaVersion,
            pluginId: pluginID,
            instanceId: instanceID.uuidString,
            pid: hostPID,
            socketPath: socketURL.path,
            protocol: Self.protocolName
        )
    }

    private static func shortStableDigest(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    static func canonicalExistingPath(_ url: URL) -> URL {
        let fallback = url.resolvingSymlinksInPath().standardizedFileURL
        let resolved = url.withUnsafeFileSystemRepresentation { path -> URL? in
            guard let path, let canonical = Darwin.realpath(path, nil) else {
                return nil
            }
            defer { free(canonical) }
            return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        }
        return resolved ?? fallback
    }

    private static func fallbackSocketURL(
        temporaryRootURL: URL,
        digest: String
    ) -> URL {
        let parent = relativeFallbackParent(temporaryRootURL: temporaryRootURL)
            .appendingPathComponent("macdora-\(getuid())", isDirectory: true)
        return parent.appendingPathComponent("macdora-\(digest).sock")
    }

    private static func relativeFallbackParent(temporaryRootURL: URL) -> URL {
        let canonical = canonicalExistingPath(temporaryRootURL)
        let resolvedTemporary = temporaryRootURL.resolvingSymlinksInPath()
            .standardizedFileURL
        if canonical.path == "/private/tmp" || resolvedTemporary.path == "/tmp" {
            return URL(
                fileURLWithPath: "/tmp",
                isDirectory: true,
                relativeTo: nil
            )
        }
        return canonical
    }
}

struct HostServiceFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let mode: mode_t
    let owner: uid_t
}

struct HostServiceServiceFileSnapshot: Equatable, Sendable {
    let identity: HostServiceFileIdentity
    let digest: String
}

struct HostServiceStartupTiming: Sendable {
    let now: @Sendable () -> Duration
    let sleep: @Sendable (Duration) async throws -> Void

    static func live() -> HostServiceStartupTiming {
        let clock = ContinuousClock()
        let startedAt = clock.now
        return HostServiceStartupTiming(
            now: {
                startedAt.duration(to: clock.now)
            },
            sleep: { duration in
                try await clock.sleep(for: duration)
            }
        )
    }
}

struct HostServiceFilesystemInspector: Sendable {
    func inspect(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw HostServiceHealthError.endpointUnavailable
        }
        return info
    }

    func isCurrentUser(_ info: stat) -> Bool {
        info.st_uid == getuid()
    }

    func isSymbolicLink(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFLNK
    }

    func isDirectory(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFDIR
    }

    func isRegularFile(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG
    }

    func isSocket(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFSOCK
    }
}

struct HostServicePackageSnapshotter: Sendable {
    func snapshot(serviceURL: URL) throws -> HostServiceServiceFileSnapshot {
        let fd = Darwin.open(serviceURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw HostServiceHealthError.codeSignatureInvalid }
        defer { Darwin.close(fd) }

        var signedInfo = stat()
        guard fstat(fd, &signedInfo) == 0,
              (signedInfo.st_mode & S_IFMT) == S_IFREG,
              signedInfo.st_uid == getuid(),
              (signedInfo.st_mode & 0o022) == 0,
              (signedInfo.st_mode & S_IXUSR) != 0 else {
            throw HostServiceHealthError.codeSignatureInvalid
        }
        let code = try staticCode(for: serviceURL)
        guard SecStaticCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        ) == errSecSuccess else {
            throw HostServiceHealthError.codeSignatureInvalid
        }

        var afterValidationInfo = stat()
        guard fstat(fd, &afterValidationInfo) == 0,
              sameStatContent(signedInfo, afterValidationInfo) else {
            throw HostServiceHealthError.packageChanged
        }

        var hasher = SHA256()
        while true {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw HostServiceHealthError.codeSignatureInvalid }
            hasher.update(data: Data(buffer.prefix(Int(count))))
        }
        var afterHashInfo = stat()
        guard fstat(fd, &afterHashInfo) == 0,
              sameStatContent(signedInfo, afterHashInfo) else {
            throw HostServiceHealthError.packageChanged
        }
        let identity = HostServiceFileIdentity(
            device: UInt64(signedInfo.st_dev),
            inode: UInt64(signedInfo.st_ino),
            size: Int64(signedInfo.st_size),
            modifiedSeconds: Int64(signedInfo.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(signedInfo.st_mtimespec.tv_nsec),
            mode: signedInfo.st_mode,
            owner: signedInfo.st_uid
        )
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return HostServiceServiceFileSnapshot(identity: identity, digest: digest)
    }

    private func sameStatContent(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_mode == rhs.st_mode
            && lhs.st_uid == rhs.st_uid
    }

    private func staticCode(for url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code else {
            throw HostServiceHealthError.codeSignatureInvalid
        }
        return code
    }
}

enum HostServiceEndpointReader {
    static let maximumEndpointBytes = 16 * 1024

    static func read(
        at url: URL,
        expected: HostServiceEndpointRecord,
        inspector: HostServiceFilesystemInspector = HostServiceFilesystemInspector()
    ) throws -> HostServiceEndpointRecord {
        try validateDirectory(
            url.deletingLastPathComponent(),
            exactMode: 0o700,
            inspector: inspector,
            requireCanonical: false
        )
        try validateDirectory(
            url.deletingLastPathComponent().deletingLastPathComponent(),
            exactMode: 0o700,
            inspector: inspector,
            requireCanonical: false
        )
        try validateDirectory(
            url.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent(),
            exactMode: 0o700,
            inspector: inspector,
            requireCanonical: false
        )

        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw HostServiceHealthError.endpointUnavailable }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              (info.st_mode & 0o777) == 0o600,
              info.st_size > 0,
              info.st_size <= Int64(maximumEndpointBytes) else {
            throw HostServiceHealthError.endpointMismatch
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0, data.count + count <= maximumEndpointBytes else {
                throw HostServiceHealthError.endpointMismatch
            }
            data.append(contentsOf: buffer.prefix(Int(count)))
        }
        guard let decoded = try? JSONDecoder().decode(HostServiceEndpointRecord.self, from: data),
              decoded == expected else {
            throw HostServiceHealthError.endpointMismatch
        }
        return decoded
    }

    static func readUnvalidated(at url: URL) -> HostServiceEndpointRecord? {
        guard let data = try? Data(contentsOf: url),
              data.count <= maximumEndpointBytes else {
            return nil
        }
        return try? JSONDecoder().decode(HostServiceEndpointRecord.self, from: data)
    }

    private static func validateDirectory(
        _ url: URL,
        exactMode: mode_t,
        inspector: HostServiceFilesystemInspector,
        requireCanonical: Bool
    ) throws {
        let info = try inspector.inspect(url)
        let canonical = !requireCanonical
            || url.resolvingSymlinksInPath().standardizedFileURL.path
                == url.standardizedFileURL.path
        guard inspector.isDirectory(info),
              !inspector.isSymbolicLink(info),
              info.st_uid == getuid(),
              (info.st_mode & 0o777) == exactMode,
              canonical else {
            throw HostServiceHealthError.socketUnsafe
        }
    }
}

enum HostServiceSocketPathPolicy {
    static var fallbackRootURL: URL {
        URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("macdora-\(getuid())", isDirectory: true)
    }

    static func prepareParent(
        for socketURL: URL,
        rootURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard socketURL.path.utf8.count
            < HostServiceRuntimeConfiguration.socketPathLimit else {
            throw HostServiceHealthError.socketUnsafe
        }
        let canonicalRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let runRoot = canonicalRoot.appendingPathComponent("private/run", isDirectory: true)
        let parent = socketURL.deletingLastPathComponent().standardizedFileURL
        if parent.path == runRoot.path {
            try ensureSafeDirectory(runRoot, exactMode: 0o700, fileManager: fileManager)
            return
        }
        guard parent.path == fallbackRootURL.path else {
            throw HostServiceHealthError.socketUnsafe
        }
        try ensureSafeDirectory(fallbackRootURL, exactMode: 0o700, fileManager: fileManager)
    }

    static func validateSocketParent(
        for socketURL: URL,
        rootURL: URL
    ) throws {
        let canonicalRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let runRoot = canonicalRoot.appendingPathComponent("private/run", isDirectory: true)
        let parent = socketURL.deletingLastPathComponent().standardizedFileURL
        if parent.path == runRoot.path {
            try ensureSafeDirectory(runRoot, exactMode: 0o700)
            return
        }
        guard parent.path == fallbackRootURL.path else {
            throw HostServiceHealthError.socketUnsafe
        }
        try ensureSafeDirectory(fallbackRootURL, exactMode: 0o700)
    }

    static func ensureSafeDirectory(
        _ url: URL,
        exactMode: mode_t,
        fileManager: FileManager = .default
    ) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: Int(exactMode))]
            )
        }
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(),
              (info.st_mode & 0o777) == exactMode else {
            throw HostServiceHealthError.socketUnsafe
        }
    }

}

struct HostServicePingResponse: Decodable, Sendable {
    var jsonrpc: String?
    var id: Int?
    var result: HostServicePingResult?
    var error: JSONValue?
}

enum JSONValue: Decodable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }
}

enum HostServiceHealthClient {
    static let responseLimit = 4 * 1024

    #if DEBUG
    static func connectForTesting(socketURL: URL, deadline: DispatchTime) -> Int32? {
        connect(socketURL: socketURL, deadline: deadline)
    }
    #endif

    static func isValidPingResponse(
        _ data: Data,
        requestID: Int,
        expectedPluginID: String,
        expectedInstanceID: UUID
    ) -> Bool {
        guard data.count <= responseLimit,
              let response = try? JSONDecoder().decode(HostServicePingResponse.self, from: data),
              response.jsonrpc == "2.0",
              response.id == requestID,
              response.error == nil,
              let result = response.result,
              result.ready,
              result.pluginId == expectedPluginID,
              result.instanceId == expectedInstanceID.uuidString else {
            return false
        }
        return true
    }

    static func performPing(
        socketURL: URL,
        pluginID: String,
        instanceID: UUID,
        timeout: TimeInterval = 5
    ) async -> Result<Void, HostServiceHealthError> {
        let probe = Task.detached(priority: .utility) {
            pingBlocking(
                socketURL: socketURL,
                pluginID: pluginID,
                instanceID: instanceID,
                timeout: timeout
            )
        }
        return await withTaskCancellationHandler {
            await probe.value
        } onCancel: {
            probe.cancel()
        }
    }

    private static func pingBlocking(
        socketURL: URL,
        pluginID: String,
        instanceID: UUID,
        timeout: TimeInterval
    ) -> Result<Void, HostServiceHealthError> {
        let parentInfo = try? HostServiceFilesystemInspector().inspect(
            socketURL.deletingLastPathComponent()
        )
        guard let parentInfo,
              (parentInfo.st_mode & S_IFMT) == S_IFDIR,
              parentInfo.st_uid == getuid(),
              (parentInfo.st_mode & 0o777) == 0o700 else {
            return .failure(.socketUnsafe)
        }
        let socketInfo = try? HostServiceFilesystemInspector().inspect(socketURL)
        guard let socketInfo,
              (socketInfo.st_mode & S_IFMT) == S_IFSOCK,
              socketInfo.st_uid == getuid(),
              (socketInfo.st_mode & 0o777) == 0o600 else {
            return .failure(.socketUnsafe)
        }

        let deadline = DispatchTime.now() + max(0.1, timeout)
        guard let fd = connect(socketURL: socketURL, deadline: deadline) else {
            return .failure(.protocolFailure)
        }
        defer { Darwin.close(fd) }

        let requestID = Int.random(in: 1...Int(Int32.max))
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": "macdora.ping",
            "params": ["instanceId": instanceID.uuidString]
        ]
        guard let requestData = try? JSONSerialization.data(withJSONObject: request),
              sendAll(fd: fd, data: requestData + Data([0x0A]), deadline: deadline) else {
            return .failure(.protocolFailure)
        }

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            guard waitForEvent(fd: fd, events: Int16(POLLIN), deadline: deadline),
                  let count = readChunk(fd: fd, buffer: &buffer),
                  count > 0 else {
                return .failure(.protocolFailure)
            }
            let chunk = Data(buffer.prefix(count))
            if let newline = chunk.firstIndex(of: 0x0A) {
                received.append(chunk[..<newline])
                guard isValidPingResponse(
                    received,
                    requestID: requestID,
                    expectedPluginID: pluginID,
                    expectedInstanceID: instanceID
                ) else {
                    return .failure(.protocolFailure)
                }
                return .success(())
            }
            guard received.count + chunk.count <= responseLimit else {
                return .failure(.protocolFailure)
            }
            received.append(chunk)
        }
    }

    private static func connect(socketURL: URL, deadline: DispatchTime) -> Int32? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            Darwin.close(fd)
            return nil
        }
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            Darwin.close(fd)
            return nil
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8)
        guard pathBytes.count < HostServiceRuntimeConfiguration.socketPathLimit,
              pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            raw.copyBytes(from: pathBytes)
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS,
                  waitForEvent(fd: fd, events: Int16(POLLOUT), deadline: deadline) else {
                Darwin.close(fd)
                return nil
            }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
                  socketError == 0 else {
                Darwin.close(fd)
                return nil
            }
        }
        return fd
    }

    private static func sendAll(fd: Int32, data: Data, deadline: DispatchTime) -> Bool {
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return data.isEmpty }
            var remaining = raw.count
            while remaining > 0 {
                guard waitForEvent(fd: fd, events: Int16(POLLOUT), deadline: deadline) else {
                    return false
                }
                let written = Darwin.write(fd, pointer, remaining)
                if written < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                    continue
                }
                guard written > 0 else { return false }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
            return true
        }
    }

    private static func readChunk(fd: Int32, buffer: inout [UInt8]) -> Int? {
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count >= 0 { return count }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return nil }
            return nil
        }
    }

    private static func waitForEvent(
        fd: Int32,
        events: Int16,
        deadline: DispatchTime
    ) -> Bool {
        while true {
            let remaining = deadline.uptimeNanoseconds > DispatchTime.now().uptimeNanoseconds
                ? deadline.uptimeNanoseconds - DispatchTime.now().uptimeNanoseconds
                : 0
            guard remaining > 0 else { return false }
            let milliseconds = min(
                UInt64(Int32.max),
                max(1, remaining / 1_000_000)
            )
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&descriptor, 1, Int32(milliseconds))
            if result > 0 {
                return (descriptor.revents & events) != 0
            }
            if result == 0 { return false }
            if errno != EINTR { return false }
        }
    }
}

private final class HostServiceProbeRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<Void, HostServiceHealthError>, Never>?
    private var pendingResult: Result<Void, HostServiceHealthError>?
    private var resolved = false

    func wait() async -> Result<Void, HostServiceHealthError> {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let pendingResult {
                self.pendingResult = nil
                resolved = true
                lock.unlock()
                continuation.resume(returning: pendingResult)
            } else if resolved {
                lock.unlock()
                continuation.resume(returning: .failure(.protocolFailure))
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func resolve(_ result: Result<Void, HostServiceHealthError>) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        if let continuation {
            self.continuation = nil
            resolved = true
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            pendingResult = result
            lock.unlock()
        }
    }

    func cancel() {
        resolve(.failure(.protocolFailure))
    }
}

struct HostServiceOwnedProcess: @unchecked Sendable {
    let rootURL: URL
    let pluginID: String
    let configuration: HostServiceRuntimeConfiguration
    let handle: any OwnedProcessHandle
    let serviceSnapshot: HostServiceServiceFileSnapshot
    let agentSnapshot: HostServiceServiceFileSnapshot?
    let environment: [String: String]
    let onExit: @Sendable (ProcessExit) -> Void
}

enum HostServiceOwnerDisposition: Equatable, Sendable {
    case active
    case retiring
}

@MainActor
final class HostServiceSupervisorRegistry: @unchecked Sendable {
    static let shared = HostServiceSupervisorRegistry()

    private struct Key: Hashable {
        let rootPath: String
        let pluginID: String
    }

    private var owners: [Key: HostServiceOwnedProcess] = [:]
    private var startClaims: [Key: UUID] = [:]
    private var retiring: [Key: any OwnedProcessHandle] = [:]

    func owner(rootURL: URL, pluginID: String) -> HostServiceOwnedProcess? {
        owners[key(rootURL: rootURL, pluginID: pluginID)]
    }

    func claimStart(rootURL: URL, pluginID: String) -> UUID? {
        let key = key(rootURL: rootURL, pluginID: pluginID)
        if let owner = owners[key], !owner.handle.isRunning {
            owners.removeValue(forKey: key)
        }
        if let retiringHandle = retiring[key], !retiringHandle.isRunning {
            retiring.removeValue(forKey: key)
        }
        guard owners[key] == nil,
              startClaims[key] == nil,
              retiring[key] == nil else {
            return nil
        }
        let token = UUID()
        startClaims[key] = token
        return token
    }

    func adoptOwner(
        rootURL: URL,
        pluginID: String
    ) -> HostServiceOwnedProcess? {
        let key = key(rootURL: rootURL, pluginID: pluginID)
        guard startClaims[key] == nil,
              retiring[key] == nil,
              let owner = owners[key],
              owner.handle.isRunning else {
            return nil
        }
        return owner
    }

    func releaseStart(rootURL: URL, pluginID: String, token: UUID) {
        let key = key(rootURL: rootURL, pluginID: pluginID)
        if startClaims[key] == token {
            startClaims.removeValue(forKey: key)
        }
    }

    func install(
        _ owned: HostServiceOwnedProcess,
        claimToken: UUID
    ) -> Bool {
        let key = key(rootURL: owned.rootURL, pluginID: owned.pluginID)
        guard startClaims[key] == claimToken,
              owners[key] == nil,
              retiring[key] == nil else {
            return false
        }
        owners[key] = owned
        return true
    }

    func removeIfOwned(
        rootURL: URL,
        pluginID: String,
        by handle: any OwnedProcessHandle
    ) -> HostServiceOwnedProcess? {
        let key = key(rootURL: rootURL, pluginID: pluginID)
        if retiring[key] === handle {
            retiring.removeValue(forKey: key)
        }
        guard let owner = owners[key], owner.handle === handle else {
            return nil
        }
        owners.removeValue(forKey: key)
        return owner
    }

    func hasStartClaim(rootURL: URL, pluginID: String) -> Bool {
        startClaims[key(rootURL: rootURL, pluginID: pluginID)] != nil
    }

    func disposition(
        rootURL: URL,
        pluginID: String
    ) -> HostServiceOwnerDisposition {
        let key = key(rootURL: rootURL, pluginID: pluginID)
        guard let handle = retiring[key] else { return .active }
        if !handle.isRunning {
            retiring.removeValue(forKey: key)
            return .active
        }
        return .retiring
    }

    func markRetiring(
        rootURL: URL,
        pluginID: String,
        by handle: any OwnedProcessHandle
    ) {
        let key = key(rootURL: rootURL, pluginID: pluginID)
        if let owner = owners[key], owner.handle === handle {
            retiring[key] = handle
        }
    }

    func clearOwner(
        rootURL: URL,
        pluginID: String,
        by handle: any OwnedProcessHandle
    ) -> HostServiceOwnedProcess? {
        let key = key(rootURL: rootURL, pluginID: pluginID)
        if retiring[key] === handle {
            retiring.removeValue(forKey: key)
        }
        guard let owner = owners[key], owner.handle === handle else {
            return nil
        }
        owners.removeValue(forKey: key)
        return owner
    }

    private func key(rootURL: URL, pluginID: String) -> Key {
        Key(
            rootPath: rootURL.resolvingSymlinksInPath().standardizedFileURL.path,
            pluginID: pluginID
        )
    }
}

enum HostServicePrivateStateStore {
    enum CleanupOutcome: Equatable {
        case removed
        case absent
        case retained
    }

    static func stateDirectory(rootURL: URL, pluginID: String) -> URL {
        rootURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .appendingPathComponent("private/plugin-state", isDirectory: true)
            .appendingPathComponent(pluginID, isDirectory: true)
    }

    static func preflightRemoval(rootURL: URL, pluginID: String) throws {
        let stateURL = stateDirectory(rootURL: rootURL, pluginID: pluginID)
        let pluginStateRoot = stateURL.deletingLastPathComponent()
        let privateRoot = pluginStateRoot.deletingLastPathComponent()
        try validateOptionalDirectory(
            privateRoot,
            exactMode: 0o700,
            requireCanonical: false
        )
        try validateOptionalDirectory(
            pluginStateRoot,
            exactMode: 0o700,
            requireCanonical: false
        )
        try validateOptionalDirectory(
            stateURL,
            exactMode: 0o700,
            requireCanonical: true
        )
    }

    @MainActor
    static func remove(
        rootURL: URL,
        pluginID: String,
        configuration: HostServiceRuntimeConfiguration? = nil,
        supervisor: HostServiceSupervisorRegistry? = nil,
        fileManager: FileManager = .default
    ) throws -> CleanupOutcome {
        try preflightRemoval(rootURL: rootURL, pluginID: pluginID)
        let stateURL = stateDirectory(rootURL: rootURL, pluginID: pluginID)
        let endpointURL = stateURL.appendingPathComponent("endpoint.json")
        let endpoint = HostServiceEndpointReader.readUnvalidated(at: endpointURL)
        let runtimeConfiguration = configuration
            ?? HostServiceRuntimeConfiguration.make(
                rootURL: rootURL,
                pluginID: pluginID
            )
        let endpointMatches = endpoint == nil
            || (configuration != nil && endpoint == runtimeConfiguration.endpoint)
            || (endpoint?.pluginId == pluginID
                && endpoint?.socketPath == runtimeConfiguration.socketURL.path)
        guard endpointMatches else { return .retained }
        if let supervisor {
            guard supervisor.disposition(
                rootURL: rootURL,
                pluginID: pluginID
            ) != .retiring else {
                return .retained
            }
            if let owner = supervisor.owner(rootURL: rootURL, pluginID: pluginID) {
                if owner.handle.isRunning {
                    return .retained
                }
                _ = supervisor.removeIfOwned(
                    rootURL: rootURL,
                    pluginID: pluginID,
                    by: owner.handle
                )
            }
            if supervisor.hasStartClaim(rootURL: rootURL, pluginID: pluginID) {
                return .retained
            }
            guard !hasLiveSocket(runtimeConfiguration.socketURL) else {
                return .retained
            }
        } else {
            guard !hasLiveSocket(runtimeConfiguration.socketURL) else {
                return .retained
            }
        }
        removeSafeFile(endpointURL, exactMode: 0o600, fileManager: fileManager)
        removeSafeSocket(runtimeConfiguration.socketURL, fileManager: fileManager)
        if fileManager.fileExists(atPath: stateURL.path) {
            try fileManager.removeItem(at: stateURL)
            return .removed
        }
        return endpoint == nil ? .absent : .removed
    }

    @MainActor
    static func canStageForDriverSwitch(
        rootURL: URL,
        pluginID: String,
        supervisor: HostServiceSupervisorRegistry? = nil,
        fileManager: FileManager = .default
    ) -> Bool {
        let stateURL = stateDirectory(rootURL: rootURL, pluginID: pluginID)
        guard fileManager.fileExists(atPath: stateURL.path) else { return true }
        if let supervisor {
            guard supervisor.disposition(
                rootURL: rootURL,
                pluginID: pluginID
            ) != .retiring else {
                return false
            }
            if let owner = supervisor.owner(rootURL: rootURL, pluginID: pluginID),
               owner.handle.isRunning {
                return false
            }
            if supervisor.hasStartClaim(rootURL: rootURL, pluginID: pluginID) {
                return false
            }
        }
        let endpoint = HostServiceEndpointReader.readUnvalidated(
            at: stateURL.appendingPathComponent("endpoint.json")
        )
        let configuration = HostServiceRuntimeConfiguration.make(
            rootURL: rootURL,
            pluginID: pluginID
        )
        if let endpoint {
            guard endpoint.pluginId == pluginID,
                  endpoint.socketPath == configuration.socketURL.path else {
                return false
            }
        }
        return !hasLiveSocket(configuration.socketURL)
    }

    private static func hasLiveSocket(_ socketURL: URL) -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8)
        guard !pathBytes.isEmpty,
              pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            return true
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            raw.copyBytes(from: pathBytes)
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { Darwin.close(fd) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0 || (errno != ENOENT && errno != ECONNREFUSED)
    }

    @MainActor
    static func stageForDriverSwitch(
        rootURL: URL,
        pluginID: String,
        supervisor: HostServiceSupervisorRegistry? = nil,
        fileManager: FileManager = .default
    ) throws -> URL? {
        let stateURL = stateDirectory(rootURL: rootURL, pluginID: pluginID)
        guard fileManager.fileExists(atPath: stateURL.path) else { return nil }
        guard canStageForDriverSwitch(
            rootURL: rootURL,
            pluginID: pluginID,
            supervisor: supervisor,
            fileManager: fileManager
        ) else { return nil }
        try preflightRemoval(rootURL: rootURL, pluginID: pluginID)
        let backupURL = stateURL.deletingLastPathComponent()
            .appendingPathComponent(".driver-switch-\(pluginID)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.moveItem(at: stateURL, to: backupURL)
        return backupURL
    }

    static func restoreStaged(
        _ backupURL: URL?,
        rootURL: URL,
        pluginID: String,
        fileManager: FileManager = .default
    ) throws {
        guard let backupURL, fileManager.fileExists(atPath: backupURL.path) else { return }
        let stateURL = stateDirectory(rootURL: rootURL, pluginID: pluginID)
        if fileManager.fileExists(atPath: stateURL.path) {
            try preflightRemoval(rootURL: rootURL, pluginID: pluginID)
            try fileManager.removeItem(at: stateURL)
        }
        try fileManager.moveItem(at: backupURL, to: stateURL)
    }

    static func discardStaged(
        _ backupURL: URL?,
        fileManager: FileManager = .default
    ) throws {
        guard let backupURL, fileManager.fileExists(atPath: backupURL.path) else { return }
        let info = try inspect(backupURL)
        guard isSafeDirectory(info) else { throw HostServiceHealthError.socketUnsafe }
        try fileManager.removeItem(at: backupURL)
    }

    private static func validateOptionalDirectory(
        _ url: URL,
        exactMode: mode_t,
        requireCanonical: Bool
    ) throws {
        guard lstatPath(url.path) else { return }
        let info = try inspect(url)
        let canonical = !requireCanonical
            || url.resolvingSymlinksInPath().standardizedFileURL.path
                == url.standardizedFileURL.path
        guard isSafeDirectory(info),
              (info.st_mode & 0o777) == exactMode,
              canonical else {
            throw HostServiceHealthError.socketUnsafe
        }
    }

    private static func inspect(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw HostServiceHealthError.endpointUnavailable
        }
        return info
    }

    private static func isSafeDirectory(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid()
    }

    private static func lstatPath(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func removeSafeFile(
        _ url: URL,
        exactMode: mode_t,
        fileManager: FileManager
    ) {
        guard let info = try? inspect(url),
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              (info.st_mode & 0o777) == exactMode else {
            return
        }
        try? fileManager.removeItem(at: url)
    }

    private static func removeSafeSocket(
        _ url: URL,
        fileManager: FileManager
    ) {
        guard let info = try? inspect(url),
              (info.st_mode & S_IFMT) == S_IFSOCK,
              info.st_uid == getuid(),
              (info.st_mode & 0o777) == 0o600 else {
            return
        }
        try? fileManager.removeItem(at: url)
    }
}

@MainActor
final class HostServiceSystemPlugin: HotPluggableSystemPlugin, @unchecked Sendable {
    static let fixedHealthError = "宿主服务健康检查失败，请重试。"
    static let fixedStartError = "宿主服务启动失败，请重试。"
    static let standardStartupHealthBudget: TimeInterval = 5
    static let agentStartupHealthBudget: TimeInterval = 35

    let manifest: SystemPluginManifest
    let bundleDirectoryURL: URL
    let rootURL: URL

    private let fileManager: FileManager
    private let processExecuter: any ProcessExecuting
    private let processTerminator: any OwnedProcessTerminating
    private let supervisor: HostServiceSupervisorRegistry
    private let healthClient: HostServiceHealthProbe
    private let inspector = HostServiceFilesystemInspector()
    private let snapshotter = HostServicePackageSnapshotter()
    private var ownedProcess: HostServiceOwnedProcess?
    private var retiringOwnedProcess: HostServiceOwnedProcess?
    private var lastOwnedConfiguration: HostServiceRuntimeConfiguration?
    private var pendingTask: Task<Void, Never>?
    private var pendingTaskID: UUID?
    private var agentRestoreTask: Task<Void, Never>?
    private var lifecycleGeneration: UInt64 = 0
    private var isDeleted = false
    private weak var notificationBridge: SystemPluginHostBridge?
    let agentControlStore: HostServiceAgentControlStore
    let agentRPCClient: any HostServiceAgentRPCPerforming
    private let startupHealthBudgetOverride: TimeInterval?
    private let startupTiming: HostServiceStartupTiming
    private let agentRestoreRetryDelay: Duration

    private(set) var isEnabled = false
    private(set) var healthState: SystemPluginHealthState = .inactive
    private(set) var runtimeStatusSummary = "未启用"

    nonisolated static func serviceFileURL(
        in bundleDirectoryURL: URL,
        manifest: SystemPluginManifest
    ) -> URL? {
        guard let relativePath = manifest.entrypoints.hostService,
              !relativePath.isEmpty,
              !relativePath.contains(".."),
              !relativePath.hasPrefix("."),
              !relativePath.contains("/.") else {
            return nil
        }
        let root = bundleDirectoryURL.standardizedFileURL
        let target = root.appendingPathComponent(relativePath).standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else { return nil }
        return target
    }

    init(
        manifest: SystemPluginManifest,
        bundleDirectoryURL: URL,
        rootURL: URL,
        fileManager: FileManager = .default,
        processExecuter: any ProcessExecuting = ProcessRunner(),
        processTerminator: any OwnedProcessTerminating = ProcessRunner(),
        supervisor: HostServiceSupervisorRegistry? = nil,
        healthClient: HostServiceHealthProbe? = nil,
        startupHealthBudgetOverride: TimeInterval? = nil,
        startupTiming: HostServiceStartupTiming? = nil,
        agentRPCClient: (any HostServiceAgentRPCPerforming)? = nil,
        agentRestoreRetryDelay: Duration = .seconds(5)
    ) {
        self.manifest = manifest
        self.bundleDirectoryURL = bundleDirectoryURL.standardizedFileURL
        self.rootURL = rootURL.resolvingSymlinksInPath().standardizedFileURL
        self.agentControlStore = HostServiceAgentControlStore(
            rootURL: rootURL,
            pluginID: manifest.id
        )
        self.agentRPCClient = agentRPCClient ?? HostServiceAgentRPCClient()
        self.fileManager = fileManager
        self.processExecuter = processExecuter
        self.processTerminator = processTerminator
        self.supervisor = supervisor ?? .shared
        self.healthClient = healthClient ?? {
            await HostServiceHealthClient.performPing(
                socketURL: $0,
                pluginID: $1,
                instanceID: $2
            )
        }
        self.startupHealthBudgetOverride = startupHealthBudgetOverride
        self.startupTiming = startupTiming ?? .live()
        self.agentRestoreRetryDelay = agentRestoreRetryDelay
    }

    func setEnabledWithoutBridge(_ enabled: Bool) async {
        guard !isDeleted else { return }
        cancelAgentAuthorizationRestore()
        await waitForPendingTask()
        lifecycleGeneration &+= 1
        if enabled {
            isEnabled = true
            healthState = .waitingForRuntime
            runtimeStatusSummary = "已启用 · 等待安卓容器就绪"
            return
        }
        isEnabled = false
        let stopped = await stopOwnedProcess()
        isEnabled = !stopped
        healthState = stopped ? .inactive : .degraded(Self.fixedHealthError)
        runtimeStatusSummary = stopped ? "未启用" : "停用失败，请重试。"
    }

    func setNotificationBridge(_ bridge: SystemPluginHostBridge?) {
        notificationBridge = bridge
        ensureAgentControlDefaultIfNeeded()
    }

    func activate(bridge: SystemPluginHostBridge) async {
        guard !isDeleted else { return }
        cancelAgentAuthorizationRestore()
        await waitForPendingTask()
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        isEnabled = true
        guard bridge.currentRuntimeState == .ready || bridge.currentRuntimeState == .running else {
            healthState = .waitingForRuntime
            runtimeStatusSummary = "已启用 · 等待安卓容器就绪"
            return
        }
        guard await prepareSharedOwnerForUse(generation: generation) else {
            return
        }
        guard isCurrent(generation) else { return }
        healthState = .waitingForRuntime
        runtimeStatusSummary = "正在启动宿主服务"
        await runLaunchTask(bridge: bridge, generation: generation)
    }

    private func prepareSharedOwnerForUse(generation: UInt64) async -> Bool {
        guard isCurrent(generation) else { return false }
        if let shared = supervisor.owner(rootURL: rootURL, pluginID: manifest.id) {
            guard supervisor.disposition(
                rootURL: rootURL,
                pluginID: manifest.id
            ) != .retiring else {
                healthState = .degraded(Self.fixedHealthError)
                runtimeStatusSummary = "宿主服务正在退出，请稍后重试。"
                return false
            }
            ownedProcess = shared
            lastOwnedConfiguration = shared.configuration
            if shared.handle.isRunning, await validateHealth(shared) {
                guard isCurrent(generation) else { return false }
                healthState = .healthy
                runtimeStatusSummary = "已启用 · 宿主服务运行中"
                scheduleAgentAuthorizationRestore()
                return false
            }
            guard isCurrent(generation) else { return false }
            guard await stopOwnedProcess() else {
                isEnabled = true
                healthState = .degraded(Self.fixedHealthError)
                runtimeStatusSummary = "停用失败，请重试。"
                return false
            }
            return true
        }
        if let local = ownedProcess {
            if local.handle.isRunning, await validateHealth(local) {
                guard isCurrent(generation) else { return false }
                healthState = .healthy
                runtimeStatusSummary = "已启用 · 宿主服务运行中"
                scheduleAgentAuthorizationRestore()
                return false
            }
            guard isCurrent(generation) else { return false }
            guard await stopOwnedProcess() else {
                isEnabled = true
                healthState = .degraded(Self.fixedHealthError)
                runtimeStatusSummary = "停用失败，请重试。"
                return false
            }
        }
        cleanupStoppedOwnerIfPresent()
        return true
    }

    private func runLaunchTask(bridge: SystemPluginHostBridge, generation: UInt64) async {
        let taskID = UUID()
        let task = launchTask(bridge: bridge, generation: generation)
        pendingTask = task
        pendingTaskID = taskID
        await task.value
        if pendingTaskID == taskID {
            pendingTask = nil
            pendingTaskID = nil
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        isEnabled && !isDeleted && lifecycleGeneration == generation && !Task.isCancelled
    }

    private func currentOwnedProcess() -> HostServiceOwnedProcess? {
        if let owned = ownedProcess {
            return owned
        }
        guard supervisor.disposition(rootURL: rootURL, pluginID: manifest.id) != .retiring else {
            return nil
        }
        return supervisor.owner(rootURL: rootURL, pluginID: manifest.id)
    }

    private func stoppableOwnedProcess() -> HostServiceOwnedProcess? {
        ownedProcess
            ?? retiringOwnedProcess
            ?? supervisor.owner(rootURL: rootURL, pluginID: manifest.id)
    }

    @discardableResult
    func deactivate(bridge: SystemPluginHostBridge) async -> Bool {
        guard !isDeleted else { return !isEnabled }
        cancelAgentAuthorizationRestore()
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        isEnabled = false
        await waitForPendingTask()
        guard !isDeleted,
              lifecycleGeneration == generation,
              !Task.isCancelled else {
            return false
        }
        let stopped = await stopOwnedProcess()
        guard !isDeleted,
              lifecycleGeneration == generation,
              !Task.isCancelled else {
            return false
        }
        if stopped {
            healthState = .inactive
            runtimeStatusSummary = "未启用"
            return true
        }
        isEnabled = true
        healthState = .degraded(Self.fixedHealthError)
        runtimeStatusSummary = "停用失败，请重试。"
        return false
    }

    func retire() {
        cancelAgentAuthorizationRestore()
        isDeleted = true
        isEnabled = false
        lifecycleGeneration &+= 1
        pendingTask?.cancel()
        pendingTask = nil
        pendingTaskID = nil
        let localOwned = ownedProcess ?? retiringOwnedProcess
        if let owned = localOwned {
            supervisor.markRetiring(
                rootURL: owned.rootURL,
                pluginID: owned.pluginID,
                by: owned.handle
            )
            if owned.handle.isRunning {
                retiringOwnedProcess = owned
                owned.handle.terminate()
            }
            if !owned.handle.isRunning {
                _ = supervisor.removeIfOwned(
                    rootURL: owned.rootURL,
                    pluginID: owned.pluginID,
                    by: owned.handle
                )
                removeEndpointAndSocket(for: owned)
                if retiringOwnedProcess?.handle === owned.handle {
                    retiringOwnedProcess = nil
                }
            }
            lastOwnedConfiguration = owned.configuration
            ownedProcess = nil
        }
        healthState = .inactive
        runtimeStatusSummary = "未启用"
    }

    func deletePersistentData() {
        retire()
        if let owner = supervisor.owner(rootURL: rootURL, pluginID: manifest.id),
           owner.handle.isRunning {
            ownedProcess = owner
            return
        }
        let configuration = ownedProcess?.configuration
            ?? supervisor.owner(rootURL: rootURL, pluginID: manifest.id)?.configuration
            ?? lastOwnedConfiguration
        if (try? HostServicePrivateStateStore.remove(
            rootURL: rootURL,
            pluginID: manifest.id,
            configuration: configuration,
            supervisor: supervisor,
            fileManager: fileManager
        )) == .retained {
            return
        }
        ownedProcess = nil
        lastOwnedConfiguration = nil
    }

    func onRuntimeBecameReady(bridge: SystemPluginHostBridge) async {
        guard isEnabled, !isDeleted else { return }
        cancelAgentAuthorizationRestore()
        await waitForPendingTask()
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        guard isCurrent(generation) else { return }
        guard await prepareSharedOwnerForUse(generation: generation) else { return }
        guard isCurrent(generation) else { return }
        healthState = .waitingForRuntime
        runtimeStatusSummary = "正在启动宿主服务"
        await runLaunchTask(bridge: bridge, generation: generation)
    }

    func onAppLaunching(package: String, bridge: SystemPluginHostBridge) async {
        // The private service owns business login and RPC behavior.
    }

    func onRuntimeStopping(bridge: SystemPluginHostBridge) async {
        guard !isDeleted else { return }
        cancelAgentAuthorizationRestore()
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        await waitForPendingTask()
        guard !isDeleted, lifecycleGeneration == generation else { return }
        let stopped = await stopOwnedProcess()
        guard !isDeleted, lifecycleGeneration == generation else { return }
        if isEnabled {
            healthState = stopped ? .waitingForRuntime : .degraded(Self.fixedHealthError)
            runtimeStatusSummary = stopped
                ? "已启用 · 等待安卓容器就绪"
                : Self.fixedHealthError
        }
    }

    func triggerHealthCheck(bridge: SystemPluginHostBridge) async -> Bool {
        guard isEnabled, !isDeleted,
              let owned = currentOwnedProcess(),
              owned.handle.isRunning else {
            return false
        }
        guard await validateHealth(owned) else {
            healthState = .degraded(Self.fixedHealthError)
            runtimeStatusSummary = Self.fixedHealthError
            return false
        }
        guard isEnabled, !isDeleted, currentOwnedProcess()?.handle === owned.handle else {
            return false
        }
        healthState = .healthy
        runtimeStatusSummary = "已启用 · 宿主服务运行中"
        return true
    }

    func confirmStoppedWithoutBridge() async -> Bool {
        await setEnabledWithoutBridge(false)
        return !isEnabled
    }

    private func launchTask(
        bridge: SystemPluginHostBridge,
        generation: UInt64
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLaunch(bridge: bridge, generation: generation)
        }
    }

    private func waitForPendingTask() async {
        let task = pendingTask
        task?.cancel()
        if let task {
            await task.value
        }
        pendingTask = nil
        pendingTaskID = nil
    }

    private func performLaunch(
        bridge: SystemPluginHostBridge,
        generation: UInt64
    ) async {
        guard let claimToken = await acquireStartClaim() else {
            guard isEnabled, lifecycleGeneration == generation, !Task.isCancelled else { return }
            healthState = .degraded(Self.fixedHealthError)
            runtimeStatusSummary = Self.fixedHealthError
            return
        }
        defer {
            supervisor.releaseStart(
                rootURL: rootURL,
                pluginID: manifest.id,
                token: claimToken
            )
        }

        let configuration = HostServiceRuntimeConfiguration.make(
            rootURL: rootURL,
            pluginID: manifest.id
        )
        do {
            try Task.checkCancellation()
            guard isCurrent(generation),
                  bridge.currentRuntimeState == .ready || bridge.currentRuntimeState == .running,
                  manifest.driverType == "host_service",
                  manifest.capabilities.contains("host.service"),
                  let serviceURL = Self.serviceFileURL(
                    in: bundleDirectoryURL,
                    manifest: manifest
                  ) else {
                throw HostServiceHealthError.notRunning
            }
            try preparePrivateDirectories(for: configuration)
            let agentURL = agentMCPExecutableURL
            let serviceSnapshot = try snapshotter.snapshot(serviceURL: serviceURL)
            let agentSnapshot = manifest.capabilities.contains("agent.readonly")
                ? try snapshotter.snapshot(serviceURL: agentURL)
                : nil
            if manifest.capabilities.contains("agent.readonly") {
                guard agentSnapshot != nil else {
                    throw HostServiceHealthError.notRunning
                }
                _ = try agentControlStore.loadOrCreate()
            }
            cleanupStoppedOwnerIfPresent()
            try removeStaleEndpointIfOwned(for: configuration)
            let environment = serviceEnvironment(bridge: bridge, configuration: configuration)

            let onExit: @Sendable (ProcessExit) -> Void = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleOwnedExit(instanceID: configuration.instanceID)
                }
            }
            let launched = try await launchDetached(
                ProcessInvocation(
                    executableURL: serviceURL,
                    arguments: [],
                    environment: environment,
                    workingDirectoryURL: configuration.stateDirectoryURL,
                    timeout: 90 * 60,
                    captureOutput: true,
                    outputLimit: 0
                ),
                onExit: onExit
            )
            let owned = HostServiceOwnedProcess(
                rootURL: rootURL,
                pluginID: manifest.id,
                configuration: configuration,
                handle: launched,
                serviceSnapshot: serviceSnapshot,
                agentSnapshot: agentSnapshot,
                environment: environment,
                onExit: onExit
            )
            guard isCurrent(generation) else {
                await terminateLaunchedHandleAfterCancellation(
                    owned,
                    claimToken: claimToken
                )
                throw CancellationError()
            }
            ownedProcess = owned
            lastOwnedConfiguration = configuration
            guard supervisor.install(owned, claimToken: claimToken) else {
                throw HostServiceHealthError.stopFailed
            }
            guard await validateRuntime(owned: owned, generation: generation) else {
                guard !isCurrent(generation) else {
                    throw HostServiceHealthError.protocolFailure
                }
                throw CancellationError()
            }
            guard isCurrent(generation) else {
                throw CancellationError()
            }
            guard ownedProcess?.handle === owned.handle else {
                throw HostServiceHealthError.protocolFailure
            }
            healthState = .healthy
            runtimeStatusSummary = "已启用 · 宿主服务运行中"
            scheduleAgentAuthorizationRestore()
        } catch is CancellationError {
            _ = await stopOwnedProcess()
        } catch {
            _ = await stopOwnedProcess()
            guard !isDeleted, lifecycleGeneration == generation, !Task.isCancelled else { return }
            healthState = .degraded(Self.fixedHealthError)
            runtimeStatusSummary = Self.fixedHealthError
        }
    }

    private func launchDetached(
        _ invocation: ProcessInvocation,
        onExit: @escaping @Sendable (ProcessExit) -> Void
    ) async throws -> any OwnedProcessHandle {
        let executer = processExecuter
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                do {
                    let handle = try await executer.launch(
                        invocation,
                        operation: "宿主服务",
                        onExit: onExit
                    )
                    continuation.resume(returning: handle)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func acquireStartClaim() async -> UUID? {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline, !Task.isCancelled {
            guard isEnabled, !isDeleted else { return nil }
            cleanupStoppedOwnerIfPresent()
            if let token = supervisor.claimStart(rootURL: rootURL, pluginID: manifest.id) {
                return token
            }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return nil
            }
        }
        return nil
    }

    private func cleanupStoppedOwnerIfPresent() {
        guard let owner = supervisor.owner(rootURL: rootURL, pluginID: manifest.id),
              !owner.handle.isRunning else {
            return
        }
        _ = supervisor.removeIfOwned(
            rootURL: owner.rootURL,
            pluginID: owner.pluginID,
            by: owner.handle
        )
        removeEndpointAndSocket(for: owner)
    }

    private func removeStaleEndpointIfOwned(
        for configuration: HostServiceRuntimeConfiguration
    ) throws {
        let endpointURL = configuration.endpointURL
        guard fileManager.fileExists(atPath: endpointURL.path) else { return }
        let endpoint = HostServiceEndpointReader.readUnvalidated(at: endpointURL)
        if endpoint == nil {
            removeSafeFile(endpointURL, exactMode: 0o600)
            return
        }
        guard endpoint?.pluginId == manifest.id,
              endpoint?.socketPath == configuration.socketURL.path else {
            throw HostServiceHealthError.stopFailed
        }
        removeSafeFile(endpointURL, exactMode: 0o600)
    }

    private func validateRuntime(
        owned: HostServiceOwnedProcess,
        generation: UInt64
    ) async -> Bool {
        let budget = startupHealthBudget
        let deadline = startupTiming.now() + .seconds(budget)
        while startupTiming.now() < deadline {
            guard isCurrent(generation), owned.handle.isRunning else { return false }
            if await validateHealth(owned) {
                return isCurrent(generation)
            }
            let remaining = max(
                .zero,
                deadline - startupTiming.now()
            )
            guard remaining > .zero,
                  await sleepAfterRuntimeCheck(upTo: remaining) else {
                return false
            }
        }
        return false
    }

    private var startupHealthBudget: TimeInterval {
        if let startupHealthBudgetOverride {
            return startupHealthBudgetOverride
        }
        return manifest.capabilities.contains("agent.readonly")
            && manifest.entrypoints.agentMCP != nil
            ? Self.agentStartupHealthBudget
            : Self.standardStartupHealthBudget
    }

    #if DEBUG
    func startupHealthBudgetForTesting() -> TimeInterval {
        startupHealthBudget
    }
    #endif

    private func sleepAfterRuntimeCheck(upTo remaining: Duration) async -> Bool {
        guard !Task.isCancelled else { return false }
        do {
            try await startupTiming.sleep(min(Duration.milliseconds(100), remaining))
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private func validateHealth(_ owned: HostServiceOwnedProcess) async -> Bool {
        guard owned.handle.isRunning,
              let serviceURL = currentServiceFileURL else {
            return false
        }
        do {
            _ = try HostServiceEndpointReader.read(
                at: owned.configuration.endpointURL,
                expected: owned.configuration.endpoint,
                inspector: inspector
            )
            guard try snapshotter.snapshot(serviceURL: serviceURL) == owned.serviceSnapshot else {
                return false
            }
            if manifest.capabilities.contains("agent.readonly") {
                guard let agentSnapshot = owned.agentSnapshot,
                      try snapshotter.snapshot(serviceURL: agentMCPExecutableURL)
                        == agentSnapshot else {
                    return false
                }
            }
        } catch {
            return false
        }
        do {
            try HostServiceSocketPathPolicy.validateSocketParent(
                for: owned.configuration.socketURL,
                rootURL: rootURL
            )
        } catch {
            return false
        }
        guard owned.handle.isRunning else { return false }
        if case .success = await probeHealth(owned) {
            return owned.handle.isRunning
        }
        return false
    }

    private func probeHealth(
        _ owned: HostServiceOwnedProcess
    ) async -> Result<Void, HostServiceHealthError> {
        let race = HostServiceProbeRace()
        let task = Task {
            race.resolve(await healthClient(
                owned.configuration.socketURL,
                owned.pluginID,
                owned.configuration.instanceID
            ))
        }
        return await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            race.cancel()
            task.cancel()
        }
    }

    private func serviceEnvironment(
        bridge: SystemPluginHostBridge,
        configuration: HostServiceRuntimeConfiguration
    ) -> [String: String] {
        var environment = [
            "MACDORA_PLUGIN_ID": manifest.id,
            "MACDORA_PLUGIN_BUNDLE_DIR": bundleDirectoryURL.path,
            "MACDORA_PLUGIN_STATE_DIR": configuration.stateDirectoryURL.path,
            "MACDORA_PLUGIN_SOCKET_PATH": configuration.socketURL.path,
            "MACDORA_PLUGIN_INSTANCE_ID": configuration.instanceID.uuidString,
            "MACDORA_HOST_PID": String(configuration.hostPID)
        ]
        if manifest.capabilities.contains("agent.readonly") {
            environment["MACDORA_AGENT_CONTROL_PATH"] = agentControlStore.fileURL.path
        }
        if manifest.usesCopyTokenAuthorization {
            environment["MACDORA_AGENT_AUTH_MODE"] = "token-v1"
        }
        if manifest.capabilities.contains("guest.shell") {
            for name in [
                "MACDORA_ADB_PATH",
                "MACDORA_ADB_SERIAL",
                "ANDROID_ADB_SERVER_PORT",
                "ADB_SERVER_SOCKET"
            ] {
                if let value = bridge.hostServiceEnvironment[name] {
                    environment[name] = value
                }
            }
        }
        return environment
    }

    var agentControlPath: URL? {
        manifest.capabilities.contains("agent.readonly") ? agentControlStore.fileURL : nil
    }

    #if DEBUG
    func agentServiceEnvironmentForTesting(
        bridge: SystemPluginHostBridge
    ) -> [String: String] {
        serviceEnvironment(
            bridge: bridge,
            configuration: HostServiceRuntimeConfiguration.make(
                rootURL: rootURL,
                pluginID: manifest.id
            )
        )
    }
    #endif

    @discardableResult
    func ensureAgentControlDefaultIfNeeded() -> HostServiceAgentControlRecord? {
        guard manifest.capabilities.contains("agent.readonly"),
              FileManager.default.fileExists(atPath: rootURL.path) else {
            return nil
        }
        return try? agentControlStore.loadOrCreate()
    }

    #if DEBUG
    func installAgentTestRuntime(handle: any OwnedProcessHandle) {
        let configuration = HostServiceRuntimeConfiguration.make(
            rootURL: rootURL,
            pluginID: manifest.id
        )
        try? preparePrivateDirectories(for: configuration)
        let serviceURL = currentServiceFileURL ?? agentMCPExecutableURL
        let snapshot = try? snapshotter.snapshot(serviceURL: serviceURL)
        guard let snapshot, currentServiceFileURL != nil else { return }
        let agentSnapshot = try? snapshotter.snapshot(serviceURL: agentMCPExecutableURL)
        guard let agentSnapshot else { return }
        isEnabled = true
        ownedProcess = HostServiceOwnedProcess(
            rootURL: rootURL,
            pluginID: manifest.id,
            configuration: configuration,
            handle: handle,
            serviceSnapshot: snapshot,
            agentSnapshot: agentSnapshot,
            environment: [:],
            onExit: { _ in }
        )
        healthState = .healthy
        runtimeStatusSummary = "已启用 · 宿主服务运行中"
    }
    #endif

    var agentMCPExecutableURL: URL {
        guard let relativePath = manifest.entrypoints.agentMCP,
              !relativePath.isEmpty,
              !relativePath.contains(".."),
              !relativePath.hasPrefix("."),
              !relativePath.contains("/.") else {
            return bundleDirectoryURL.appendingPathComponent("__unavailable-agent-entry__")
        }
        let root = bundleDirectoryURL.standardizedFileURL
        let target = root.appendingPathComponent(relativePath).standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else {
            return bundleDirectoryURL.appendingPathComponent("__unavailable-agent-entry__")
        }
        return target
    }

    var currentAgentStatusEndpointURL: URL {
        currentAgentRuntimeConfiguration?.endpointURL
            ?? lastOwnedConfiguration?.endpointURL
            ?? HostServiceRuntimeConfiguration.make(
                rootURL: rootURL,
                pluginID: manifest.id
            ).endpointURL
    }

    private func cancelAgentAuthorizationRestore() {
        agentRestoreTask?.cancel()
        agentRestoreTask = nil
    }

    /// A copy grant belongs to the local user, not to one host-service process.
    /// Restore it only through the same host-only authorization RPC as a copy.
    func scheduleAgentAuthorizationRestore() {
        cancelAgentAuthorizationRestore()
        guard manifest.usesCopyTokenAuthorization,
              let context = agentRuntimeContext() else { return }
        let generation = lifecycleGeneration
        agentRestoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.restoreAgentAuthorization(context: context, generation: generation)
        }
    }

    private func restoreAgentAuthorization(
        context: HostServiceAgentRuntimeContext,
        generation: UInt64
    ) async {
        func isCurrentContext() -> Bool {
            isCurrent(generation)
                && currentOwnedProcess()?.configuration.instanceID == context.instanceID
                && context.securityStateCheck.isCurrent()
        }
        guard isCurrentContext(),
              let previous = try? agentControlStore.reload(),
              let record = try? agentControlStore.rebindCopyAuthorization(
                ifUnchanged: previous, toInstance: context.instanceID
              ) else { return }

        while isCurrentContext() {
            guard let current = try? agentControlStore.reload(), current == record else { return }
            let response = await agentRPCClient.authorize(context: context, record: record)
            guard isCurrentContext(), let current = try? agentControlStore.reload(),
                  current == record else { return }
            switch response {
            case .success(let status):
                guard status.pluginId == context.pluginID, status.instanceId == context.instanceID,
                      !status.manual else { return }
                notificationBridge?.notifyPluginStateDidChange()
                return
            case .failure(let error):
                switch error {
                case .unavailable, .busy, .server(.loginRequired),
                     .server(.businessNotReady), .server(.recoveryRequired):
                    break
                default:
                    return
                }
            }
            do {
                try await Task.sleep(for: agentRestoreRetryDelay)
            } catch {
                return
            }
        }
    }

    func agentRuntimeContext() -> HostServiceAgentRuntimeContext? {
        guard let owned = currentOwnedProcess(),
              owned.handle.isRunning,
              manifest.driverType == "host_service",
              manifest.capabilities.contains("host.service"),
              manifest.capabilities.contains("agent.readonly"),
              isEnabled,
              !isDeleted,
              let configuration = currentAgentRuntimeConfiguration,
              let agentSnapshot = owned.agentSnapshot else {
            return nil
        }
        let serviceSnapshot = owned.serviceSnapshot
        let serviceURL = currentServiceFileURL ?? owned.configuration.endpointURL
        return HostServiceAgentRuntimeContext(
            pluginID: manifest.id,
            instanceID: configuration.instanceID,
            rootURL: rootURL,
            configuration: configuration,
            serviceURL: serviceURL,
            agentURL: agentMCPExecutableURL,
            securityStateCheck: .process(
                handle: owned.handle,
                serviceURL: serviceURL,
                agentURL: agentMCPExecutableURL,
                serviceSnapshot: serviceSnapshot,
                agentSnapshot: agentSnapshot
            )
        )
    }

    private var currentAgentRuntimeConfiguration: HostServiceRuntimeConfiguration? {
        currentOwnedProcess()?.configuration
    }

    private func preparePrivateDirectories(
        for configuration: HostServiceRuntimeConfiguration
    ) throws {
        let privateRoot = rootURL.appendingPathComponent("private", isDirectory: true)
        try HostServiceSocketPathPolicy.ensureSafeDirectory(
            privateRoot,
            exactMode: 0o700,
            fileManager: fileManager
        )
        let pluginStateRoot = privateRoot.appendingPathComponent("plugin-state", isDirectory: true)
        try HostServiceSocketPathPolicy.ensureSafeDirectory(
            pluginStateRoot,
            exactMode: 0o700,
            fileManager: fileManager
        )
        try HostServiceSocketPathPolicy.ensureSafeDirectory(
            configuration.stateDirectoryURL,
            exactMode: 0o700,
            fileManager: fileManager
        )
        try HostServiceSocketPathPolicy.prepareParent(
            for: configuration.socketURL,
            rootURL: rootURL,
            fileManager: fileManager
        )
    }

    private func stopOwnedProcess() async -> Bool {
        guard let owned = stoppableOwnedProcess() else {
            return true
        }
        ownedProcess = owned
        lastOwnedConfiguration = owned.configuration
        if owned.handle.isRunning {
            let exited = await processTerminator.terminateAndWait(owned.handle, timeout: 3)
            guard exited, !owned.handle.isRunning else {
                healthState = .degraded(Self.fixedHealthError)
                runtimeStatusSummary = "停用失败，请重试。"
                return false
            }
        }
        _ = supervisor.removeIfOwned(
            rootURL: owned.rootURL,
            pluginID: owned.pluginID,
            by: owned.handle
        )
        removeEndpointAndSocket(for: owned)
        ownedProcess = nil
        if retiringOwnedProcess?.handle === owned.handle {
            retiringOwnedProcess = nil
        }
        lastOwnedConfiguration = owned.configuration
        return true
    }

    private func terminateLaunchedHandleAfterCancellation(
        _ owned: HostServiceOwnedProcess,
        claimToken: UUID
    ) async {
        if owned.handle.isRunning {
            _ = await processTerminator.terminateAndWait(owned.handle, timeout: 3)
        }
        if owned.handle.isRunning {
            ownedProcess = owned
            lastOwnedConfiguration = owned.configuration
            guard supervisor.install(owned, claimToken: claimToken) else {
                return
            }
            supervisor.releaseStart(
                rootURL: rootURL,
                pluginID: manifest.id,
                token: claimToken
            )
        } else {
            removeEndpointAndSocket(for: owned)
            if ownedProcess?.handle === owned.handle {
                ownedProcess = nil
            }
        }
    }

    private func handleOwnedExit(instanceID: UUID) {
        guard let owned = stoppableOwnedProcess(),
              owned.configuration.instanceID == instanceID,
              !owned.handle.isRunning else {
            return
        }
        cancelAgentAuthorizationRestore()
        _ = supervisor.removeIfOwned(
            rootURL: owned.rootURL,
            pluginID: owned.pluginID,
            by: owned.handle
        )
        removeEndpointAndSocket(for: owned)
        if ownedProcess?.handle === owned.handle {
            ownedProcess = nil
        }
        if retiringOwnedProcess?.handle === owned.handle {
            retiringOwnedProcess = nil
        }
        lastOwnedConfiguration = owned.configuration
        notificationBridge?.notifyPluginStateDidChange()
        guard isEnabled, !isDeleted else { return }
        healthState = .degraded(Self.fixedHealthError)
        runtimeStatusSummary = Self.fixedHealthError
    }

    private func removeEndpointAndSocket(for owned: HostServiceOwnedProcess) {
        let endpointURL = owned.configuration.endpointURL
        let endpoint = HostServiceEndpointReader.readUnvalidated(at: endpointURL)
        if endpoint == nil || endpoint == owned.configuration.endpoint {
            removeSafeFile(endpointURL, exactMode: 0o600)
            removeSafeSocket(owned.configuration.socketURL)
        }
    }

    private func removeSafeFile(_ url: URL, exactMode: mode_t) {
        guard let info = try? inspector.inspect(url),
              inspector.isRegularFile(info),
              !inspector.isSymbolicLink(info),
              info.st_uid == getuid(),
              (info.st_mode & 0o777) == exactMode else {
            return
        }
        try? fileManager.removeItem(at: url)
    }

    private func removeSafeSocket(_ url: URL) {
        guard let info = try? inspector.inspect(url),
              inspector.isSocket(info),
              !inspector.isSymbolicLink(info),
              info.st_uid == getuid(),
              (info.st_mode & 0o777) == 0o600 else {
            return
        }
        try? fileManager.removeItem(at: url)
    }

    private var currentServiceFileURL: URL? {
        Self.serviceFileURL(in: bundleDirectoryURL, manifest: manifest)
    }
}
