import Darwin
import Foundation

// MARK: - Persistent user-controlled Agent handoff

struct HostServiceAgentControlRecord: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var pluginId: String
    var generation: UUID
    var manual: Bool
    var authorization: HostServiceAgentCopyAuthorization? = nil

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case pluginId
        case generation
        case manual
        case authorization
    }

    init(
        schemaVersion: Int,
        pluginId: String,
        generation: UUID,
        manual: Bool,
        authorization: HostServiceAgentCopyAuthorization? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.pluginId = pluginId
        self.generation = generation
        self.manual = manual
        self.authorization = authorization
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        pluginId = try container.decode(String.self, forKey: .pluginId)
        let generationValue = try container.decode(String.self, forKey: .generation)
        guard let decodedGeneration = UUID(uuidString: generationValue) else {
            throw DecodingError.dataCorruptedError(
                forKey: .generation,
                in: container,
                debugDescription: "generation must be a UUID"
            )
        }
        generation = decodedGeneration
        manual = try container.decode(Bool.self, forKey: .manual)
        authorization = try container.decodeIfPresent(HostServiceAgentCopyAuthorization.self, forKey: .authorization)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(pluginId, forKey: .pluginId)
        try container.encode(generation.uuidString.lowercased(), forKey: .generation)
        try container.encode(manual, forKey: .manual)
        try container.encodeIfPresent(authorization, forKey: .authorization)
    }
}

enum HostServiceAgentControlStoreError: Error, Equatable, Sendable {
    case unsafePath
    case invalidRecord
}

struct HostServiceAgentControlStore: Sendable {
    static let maximumFileBytes = 16 * 1024

    let rootURL: URL
    let pluginID: String

    init(rootURL: URL, pluginID: String) {
        self.rootURL = rootURL.resolvingSymlinksInPath().standardizedFileURL
        self.pluginID = pluginID
    }

    var directoryURL: URL {
        rootURL
            .appendingPathComponent("private", isDirectory: true)
            .appendingPathComponent("agent-control", isDirectory: true)
    }

    var fileURL: URL {
        directoryURL.appendingPathComponent("\(pluginID).json", isDirectory: false)
    }

    private var lockURL: URL {
        directoryURL.appendingPathComponent(".control.lock", isDirectory: false)
    }

    func loadOrCreate() throws -> HostServiceAgentControlRecord {
        try withControlLock {
            try ensureDirectory()
            do {
                if let existing = try loadIfPresent() {
                    return existing
                }
            } catch HostServiceAgentControlStoreError.invalidRecord {
                return try writeNewManualState(true)
            }
            return try writeNewManualState(true)
        }
    }

    func reload() throws -> HostServiceAgentControlRecord {
        try withControlLock {
            try ensureDirectory()
            guard let record = try loadIfPresent() else {
                throw HostServiceAgentControlStoreError.invalidRecord
            }
            return record
        }
    }

    func setManual(_ manual: Bool) throws -> HostServiceAgentControlRecord {
        try withControlLock {
            try ensureDirectory()
            do {
                let existing = try loadIfPresent()
                if !manual, existing == nil {
                    throw HostServiceAgentControlStoreError.invalidRecord
                }
            } catch HostServiceAgentControlStoreError.invalidRecord {
                guard manual else {
                    throw HostServiceAgentControlStoreError.invalidRecord
                }
                try validateExistingFileForReplacement()
            }
            return try writeNewManualState(manual)
        }
    }

    func grant(ifUnchanged expected: HostServiceAgentControlRecord) throws -> HostServiceAgentControlRecord? {
        try withControlLock {
            try ensureDirectory()
            guard expected.manual, try loadIfPresent() == expected else { return nil }
            return try writeNewManualState(false)
        }
    }

    func authorizeCopy(
        ifUnchanged expected: HostServiceAgentControlRecord,
        instanceID: UUID,
        tokenDigest: String
    ) throws -> HostServiceAgentControlRecord? {
        let authorization = HostServiceAgentCopyAuthorization(
            instanceId: instanceID, tokenSHA256: tokenDigest
        )
        guard authorization.isValid else {
            throw HostServiceAgentControlStoreError.invalidRecord
        }
        return try withControlLock {
            try ensureDirectory()
            guard try loadIfPresent() == expected else { return nil }
            let record = HostServiceAgentControlRecord(
                schemaVersion: 2, pluginId: pluginID, generation: UUID(), manual: false,
                authorization: authorization
            )
            try write(record)
            return record
        }
    }

    /// Rebind an existing local copy grant without creating a new credential.
    /// A newer copy or manual withdrawal always wins the compare-and-set.
    func rebindCopyAuthorization(
        ifUnchanged expected: HostServiceAgentControlRecord,
        toInstance instanceID: UUID
    ) throws -> HostServiceAgentControlRecord? {
        try withControlLock {
            try ensureDirectory()
            guard try loadIfPresent() == expected,
                  expected.schemaVersion == 2, !expected.manual,
                  var authorization = expected.authorization, authorization.isValid else {
                return nil
            }
            if authorization.instanceId == instanceID { return expected }
            authorization.instanceId = instanceID
            let rebound = HostServiceAgentControlRecord(
                schemaVersion: 2, pluginId: pluginID, generation: UUID(), manual: false,
                authorization: authorization
            )
            try write(rebound)
            return rebound
        }
    }

    /// Rolls a pending action back only when its exact generation is still current.
    /// The generation is intentionally preserved so a later explicit action remains
    /// distinguishable from this internal compensation.
    func compareAndSetManual(
        expectedGeneration: UUID,
        manual: Bool
    ) throws -> HostServiceAgentControlRecord? {
        try withControlLock {
            try ensureDirectory()
            guard let existing = try loadIfPresent(),
                  existing.generation == expectedGeneration else {
                return nil
            }
            if existing.manual == manual {
                return existing
            }
            let record = HostServiceAgentControlRecord(
                schemaVersion: HostServiceAgentControlRecord.schemaVersion,
                pluginId: pluginID,
                generation: existing.generation,
                manual: manual
            )
            try write(record)
            return record
        }
    }

    func ensureDefaultFile() throws -> HostServiceAgentControlRecord {
        try loadOrCreate()
    }

    private func writeNewManualState(
        _ manual: Bool
    ) throws -> HostServiceAgentControlRecord {
        let record = HostServiceAgentControlRecord(
            schemaVersion: HostServiceAgentControlRecord.schemaVersion,
            pluginId: pluginID,
            generation: UUID(),
            manual: manual
        )
        try write(record)
        return record
    }

    private func withControlLock<T>(
        _ body: () throws -> T
    ) throws -> T {
        try ensureDirectory()
        let fd = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard fd >= 0 else {
            throw HostServiceAgentControlStoreError.unsafePath
        }
        defer { Darwin.close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              (info.st_mode & 0o777) == 0o600,
              info.st_nlink == 1 else {
            throw HostServiceAgentControlStoreError.unsafePath
        }
        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw HostServiceAgentControlStoreError.unsafePath
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    private func ensureDirectory() throws {
        guard SystemPluginManifest.isValidPluginIdentifier(pluginID) else {
            throw HostServiceAgentControlStoreError.unsafePath
        }
        let fileManager = FileManager.default
        var rootInfo = stat()
        guard lstat(rootURL.path, &rootInfo) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR,
              rootInfo.st_uid == getuid() else {
            throw HostServiceAgentControlStoreError.unsafePath
        }

        let privateURL = rootURL.appendingPathComponent("private", isDirectory: true)
        try ensureOwnerOnlyDirectory(privateURL, fileManager: fileManager)
        try ensureOwnerOnlyDirectory(directoryURL, fileManager: fileManager)
    }

    private func ensureOwnerOnlyDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            do {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: NSNumber(value: Int(0o700))]
                )
            } catch {
                guard lstat(url.path, &info) == 0 else {
                    throw HostServiceAgentControlStoreError.unsafePath
                }
            }
        }
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(),
              (info.st_mode & 0o777) == 0o700 else {
            throw HostServiceAgentControlStoreError.unsafePath
        }
    }

    private func loadIfPresent() throws -> HostServiceAgentControlRecord? {
        var info = stat()
        if lstat(fileURL.path, &info) != 0 {
            guard errno == ENOENT else {
                throw HostServiceAgentControlStoreError.unsafePath
            }
            return nil
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              (info.st_mode & 0o777) == 0o600,
              info.st_nlink == 1 else {
            throw HostServiceAgentControlStoreError.unsafePath
        }

        let fd = Darwin.open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            throw HostServiceAgentControlStoreError.unsafePath
        }
        defer { Darwin.close(fd) }

        var opened = stat()
        guard fstat(fd, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_uid == getuid(),
              (opened.st_mode & 0o777) == 0o600,
              opened.st_nlink == 1 else {
            throw HostServiceAgentControlStoreError.unsafePath
        }
        guard opened.st_size > 0,
              opened.st_size <= HostServiceAgentControlStore.maximumFileBytes else {
            throw HostServiceAgentControlStoreError.invalidRecord
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0,
                  data.count + count <= HostServiceAgentControlStore.maximumFileBytes else {
                throw HostServiceAgentControlStoreError.invalidRecord
            }
            data.append(contentsOf: buffer.prefix(Int(count)))
        }
        guard let record = try? JSONDecoder().decode(
            HostServiceAgentControlRecord.self,
            from: data
        ),
        record.pluginId == pluginID,
        (record.schemaVersion == 1 && record.authorization == nil
            || record.schemaVersion == 2 && !record.manual && record.authorization?.isValid == true) else {
            throw HostServiceAgentControlStoreError.invalidRecord
        }
        return record
    }

    private func validateExistingFileForReplacement() throws {
        var info = stat()
        if lstat(fileURL.path, &info) != 0 {
            guard errno == ENOENT else {
                throw HostServiceAgentControlStoreError.unsafePath
            }
            return
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              (info.st_mode & 0o777) == 0o600,
              info.st_nlink == 1 else {
            throw HostServiceAgentControlStoreError.unsafePath
        }

        let fd = Darwin.open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            throw HostServiceAgentControlStoreError.unsafePath
        }
        defer { Darwin.close(fd) }

        var opened = stat()
        guard fstat(fd, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_uid == getuid(),
              (opened.st_mode & 0o777) == 0o600,
              opened.st_nlink == 1 else {
            throw HostServiceAgentControlStoreError.unsafePath
        }
    }

    private func write(_ record: HostServiceAgentControlRecord) throws {
        guard record.pluginId == pluginID,
              (record.schemaVersion == 1 && record.authorization == nil
                || record.schemaVersion == 2 && !record.manual && record.authorization?.isValid == true) else {
            throw HostServiceAgentControlStoreError.invalidRecord
        }
        // Existing unsafe paths are rejected, while a safe malformed file may be
        // atomically replaced by an explicit manual withdrawal or default reset.
        try validateExistingFileForReplacement()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(record)
        data.append(0x0A)

        let temporaryURL = directoryURL.appendingPathComponent(
            ".control-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let fd = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard fd >= 0 else {
            throw HostServiceAgentControlStoreError.unsafePath
        }

        var shouldRemoveTemporary = true
        defer {
            Darwin.close(fd)
            if shouldRemoveTemporary {
                unlink(temporaryURL.path)
            }
        }

        let wrote = data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return data.isEmpty }
            var remaining = raw.count
            while remaining > 0 {
                let count = Darwin.write(fd, pointer, remaining)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
            return true
        }
        guard wrote,
              fchmod(fd, 0o600) == 0,
              fsync(fd) == 0,
              Darwin.rename(temporaryURL.path, fileURL.path) == 0 else {
            throw HostServiceAgentControlStoreError.unsafePath
        }
        shouldRemoveTemporary = false

        let directoryFD = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        if directoryFD >= 0 {
            _ = fsync(directoryFD)
            Darwin.close(directoryFD)
        }

        var finalInfo = stat()
        guard lstat(fileURL.path, &finalInfo) == 0,
              (finalInfo.st_mode & S_IFMT) == S_IFREG,
              finalInfo.st_uid == getuid(),
              (finalInfo.st_mode & 0o777) == 0o600,
              finalInfo.st_nlink == 1 else {
            throw HostServiceAgentControlStoreError.unsafePath
        }
    }
}

// MARK: - Read-only Agent protocol

enum HostServiceAgentState: String, Codable, CaseIterable, Sendable {
    case waitingForAgent
    case waitingForApproval
    case waitingForLogin
    case ready
    case running
    case recovering
    case needsAttention
    case manual
}

enum HostServiceAgentErrorCode: String, Codable, CaseIterable, Sendable {
    case agentNotConnected
    case consumerUnavailable
    case businessNotReady
    case approvalRequired
    case loginRequired
    case recoveryRequired
    case manualMode
    case invalidRequest
    case permissionDenied
    case internalFailure
}

struct HostServiceAgentStatus: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var pluginId: String
    var instanceId: UUID
    var state: HostServiceAgentState
    var agentConnected: Bool
    var businessReady: Bool
    var taskRunning: Bool
    var manual: Bool
    var consumerId: UUID?
    var errorCode: HostServiceAgentErrorCode?
    var lastSuccessAt: Date?

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case pluginId
        case instanceId
        case state
        case agentConnected
        case businessReady
        case taskRunning
        case manual
        case consumerId
        case errorCode
        case lastSuccessAt
    }

    init(
        schemaVersion: Int = 1,
        pluginId: String,
        instanceId: UUID,
        state: HostServiceAgentState,
        agentConnected: Bool,
        businessReady: Bool,
        taskRunning: Bool,
        manual: Bool,
        consumerId: UUID? = nil,
        errorCode: HostServiceAgentErrorCode? = nil,
        lastSuccessAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.pluginId = pluginId
        self.instanceId = instanceId
        self.state = state
        self.agentConnected = agentConnected
        self.businessReady = businessReady
        self.taskRunning = taskRunning
        self.manual = manual
        self.consumerId = consumerId
        self.errorCode = errorCode
        self.lastSuccessAt = lastSuccessAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        pluginId = try container.decode(String.self, forKey: .pluginId)
        instanceId = try container.decode(UUID.self, forKey: .instanceId)
        state = try container.decode(HostServiceAgentState.self, forKey: .state)
        agentConnected = try container.decode(Bool.self, forKey: .agentConnected)
        businessReady = try container.decode(Bool.self, forKey: .businessReady)
        taskRunning = try container.decode(Bool.self, forKey: .taskRunning)
        manual = try container.decode(Bool.self, forKey: .manual)
        consumerId = try Self.decodeOptionalConsumerUUID(container, forKey: .consumerId)
        errorCode = try Self.decodeOptionalFixedCode(container, forKey: .errorCode)
        if let value = try Self.decodeOptionalString(container, forKey: .lastSuccessAt) {
            guard let date = HostServiceAgentPythonISO8601.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .lastSuccessAt,
                    in: container,
                    debugDescription: "lastSuccessAt must be ISO-8601"
                )
            }
            lastSuccessAt = date
        } else {
            lastSuccessAt = nil
        }
    }

    private static func decodeOptionalConsumerUUID(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> UUID? {
        guard container.contains(key) else {
            return nil
        }
        if try container.decodeNil(forKey: key) {
            return nil
        }
        let value = try container.decode(String.self, forKey: key)
        guard let identifier = UUID(uuidString: value),
              value == identifier.uuidString.lowercased() else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "consumerId must be a lowercase UUID"
            )
        }
        return identifier
    }

    private static func decodeOptionalFixedCode(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> HostServiceAgentErrorCode? {
        guard container.contains(key) else {
            return nil
        }
        if try container.decodeNil(forKey: key) {
            return nil
        }
        return try container.decode(HostServiceAgentErrorCode.self, forKey: key)
    }

    private static func decodeOptionalString(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> String? {
        guard container.contains(key) else {
            return nil
        }
        if try container.decodeNil(forKey: key) {
            return nil
        }
        let value = try container.decode(String.self, forKey: key)
        guard !value.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "ISO-8601 value is empty"
            )
        }
        return value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(pluginId, forKey: .pluginId)
        try container.encode(instanceId, forKey: .instanceId)
        try container.encode(state, forKey: .state)
        try container.encode(agentConnected, forKey: .agentConnected)
        try container.encode(businessReady, forKey: .businessReady)
        try container.encode(taskRunning, forKey: .taskRunning)
        try container.encode(manual, forKey: .manual)
        if let consumerId {
            try container.encode(
                HostServiceAgentWire.canonicalConsumerId(consumerId),
                forKey: .consumerId
            )
        }
        try container.encodeIfPresent(errorCode, forKey: .errorCode)
        if let lastSuccessAt {
            try container.encode(
                HostServiceAgentISO8601.format(lastSuccessAt),
                forKey: .lastSuccessAt
            )
        }
    }
}

enum HostServiceAgentWire {
    static let consumerIdKey = "consumerId"
    static let instanceIdKey = "instanceId"
    static let generationKey = "generation"
    static let methodKey = "method"
    static let paramsKey = "params"
    static let crossLanguageFixture = """
    {"id":17,"jsonrpc":"2.0","method":"macdora.agent.grant","params":{"consumerId":"0f5d5d2c-3f37-4c58-a4a2-d8dca58f5e2a","generation":"c1f58fda-222c-42a7-a354-ea6288dce9a1","instanceId":"19B4C6BE-2182-44EE-9D4C-B5A5E91F931D"}}
    """

    static func canonicalConsumerId(_ value: UUID) -> String {
        value.uuidString.lowercased()
    }

    static func canonicalGeneration(_ value: UUID) -> String {
        value.uuidString.lowercased()
    }

    static func canonicalInstanceId(_ value: UUID) -> String {
        value.uuidString
    }

    static func request(
        method: HostServiceAgentControlMethod,
        requestID: Int,
        instanceID: UUID,
        generation: UUID? = nil,
        consumerId: UUID? = nil,
        authorization: HostServiceAgentCopyAuthorization? = nil
    ) -> [String: Any] {
        var params: [String: Any] = [
            instanceIdKey: canonicalInstanceId(instanceID)
        ]
        switch method {
        case .status, .prepare:
            break
        case .grant:
            if let generation {
                params[generationKey] = canonicalGeneration(generation)
            }
            if let consumerId {
                params[consumerIdKey] = canonicalConsumerId(consumerId)
            }
        case .revoke:
            if let generation {
                params[generationKey] = canonicalGeneration(generation)
            }
        case .authorize:
            if let generation { params[generationKey] = canonicalGeneration(generation) }
            if let authorization {
                params["tokenSHA256"] = authorization.tokenSHA256
                params["scope"] = authorization.scope
            }
        }
        return [
            "jsonrpc": "2.0",
            "id": requestID,
            methodKey: method.rawValue,
            paramsKey: params
        ]
    }

    static func encodedRequest(
        _ method: HostServiceAgentControlMethod,
        requestID: Int,
        instanceID: UUID,
        generation: UUID? = nil,
        consumerId: UUID? = nil
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: request(
                method: method,
                requestID: requestID,
                instanceID: instanceID,
                generation: generation,
                consumerId: consumerId
            ),
            options: [.sortedKeys]
        )
    }
}

enum HostServiceAgentISO8601 {
    static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: value)
    }

    static func format(_ date: Date) -> String {
        HostServiceAgentPythonISO8601.string(from: date)
    }
}

enum HostServiceAgentPythonISO8601 {
    static func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'+00:00'"
        return formatter.string(from: date)
    }

    static func date(from value: String) -> Date? {
        guard value.hasSuffix("+00:00") else { return nil }
        return HostServiceAgentISO8601.parse(value)
    }
}

struct HostServiceAgentRuntimeContext: Sendable {
    let pluginID: String
    let instanceID: UUID
    let rootURL: URL
    let configuration: HostServiceRuntimeConfiguration
    let serviceURL: URL
    let agentURL: URL
    let securityStateCheck: HostServiceAgentSecurityCheck

    init(
        pluginID: String,
        instanceID: UUID,
        rootURL: URL,
        configuration: HostServiceRuntimeConfiguration,
        serviceURL: URL,
        agentURL: URL,
        securityStateCheck: HostServiceAgentSecurityCheck
    ) {
        self.pluginID = pluginID
        self.instanceID = instanceID
        self.rootURL = rootURL
        self.configuration = configuration
        self.serviceURL = serviceURL
        self.agentURL = agentURL
        self.securityStateCheck = securityStateCheck
    }
}

enum HostServiceAgentSecurityCheck: Sendable {
    case process(
        handle: any OwnedProcessHandle,
        serviceURL: URL,
        agentURL: URL,
        serviceSnapshot: HostServiceServiceFileSnapshot,
        agentSnapshot: HostServiceServiceFileSnapshot
    )

    func isCurrent() -> Bool {
        autoreleasepool {
            isCurrentUnchecked()
        }
    }

    func validate() async -> Bool {
        let check = self
        return await Task.detached(priority: .utility) {
            check.isCurrent()
        }.value
    }

    #if DEBUG
    func validateForTesting() -> Bool {
        isCurrentUnchecked()
    }
    #endif

    private func isCurrentUnchecked() -> Bool {
        switch self {
        case .process(let handle, let serviceURL, let agentURL, let serviceSnapshot, let agentSnapshot):
            guard handle.isRunning else { return false }
            let snapshotter = HostServicePackageSnapshotter()
            guard let service = try? snapshotter.snapshot(serviceURL: serviceURL),
                  service == serviceSnapshot,
                  let agent = try? snapshotter.snapshot(serviceURL: agentURL),
                  agent == agentSnapshot else {
                return false
            }
            return true
        }
    }
}

enum HostServiceAgentFailure: Error, Equatable, Sendable {
    case unavailable
    case invalidResponse
    case stale
    case busy
    case server(HostServiceAgentErrorCode)

    var userMessage: String {
        switch self {
        case .unavailable:
            return "连接暂时不可用，请确认运行环境和插件已就绪。"
        case .invalidResponse:
            return "插件返回了无法确认的结果，请稍后重试。"
        case .stale:
            return ""
        case .busy:
            return "正在处理上一项请求，请稍候。"
        case .server(let code):
            switch code {
            case .loginRequired:
                return "需要先在 App 内登录。"
            case .recoveryRequired:
                return "App 正在恢复，请稍后再试。"
            case .businessNotReady:
                return "业务尚未就绪，请稍后再试。"
            case .approvalRequired:
                return "等待 App 内确认。"
            case .agentNotConnected, .consumerUnavailable:
                return "Agent 连接尚未就绪。"
            case .manualMode:
                return "当前为手动操作。"
            case .invalidRequest:
                return "请求未被插件接受。"
            case .permissionDenied:
                return "插件未获得所需权限。"
            case .internalFailure:
                return "插件暂时无法完成请求。"
            }
        }
    }
}

enum HostServiceAgentControlMethod: String, Sendable {
    case status = "macdora.agent.status"
    case prepare = "macdora.agent.prepare"
    case grant = "macdora.agent.grant"
    case revoke = "macdora.agent.revoke"
    case authorize = "macdora.agent.authorize"
}

struct HostServiceAgentWireFixture: Codable, Equatable, Sendable {
    let jsonrpc: String
    let id: Int
    let method: String
    let params: Params

    struct Params: Codable, Equatable, Sendable {
        let instanceId: String
        let generation: String?
        let consumerId: String?
    }
}

enum HostServiceAgentSocketTestSupport {
    static func connect(
        socketURL: URL,
        deadline: DispatchTime = .now() + 2
    ) -> Int32? {
        HostServiceAgentSocket.connect(socketURL: socketURL, deadline: deadline)
    }

    static func sendAll(
        fd: Int32,
        data: Data,
        deadline: DispatchTime = .now() + 2
    ) -> Bool {
        HostServiceAgentSocket.sendAll(fd: fd, data: data, deadline: deadline)
    }

    static func readChunk(
        fd: Int32,
        buffer: inout [UInt8],
        deadline: DispatchTime = .now() + 2
    ) -> Int? {
        HostServiceAgentSocket.readChunk(
            fd: fd,
            buffer: &buffer,
            deadline: deadline
        )
    }
}

protocol HostServiceAgentRPCPerforming: Sendable {
    func authorize(
        context: HostServiceAgentRuntimeContext,
        record: HostServiceAgentControlRecord
    ) async -> Result<HostServiceAgentStatus, HostServiceAgentFailure>
    func request(
        _ method: HostServiceAgentControlMethod,
        context: HostServiceAgentRuntimeContext,
        generation: UUID?,
        consumerId: UUID?
    ) async -> Result<HostServiceAgentStatus, HostServiceAgentFailure>
}

extension HostServiceAgentRPCPerforming {
    func authorize(
        context: HostServiceAgentRuntimeContext,
        record: HostServiceAgentControlRecord
    ) async -> Result<HostServiceAgentStatus, HostServiceAgentFailure> {
        await request(.authorize, context: context, generation: record.generation, consumerId: nil)
    }
}

struct HostServiceAgentRPCClient: HostServiceAgentRPCPerforming {
    static let responseLimit = 16 * 1024
    static let timeout: TimeInterval = 4

    func authorize(
        context: HostServiceAgentRuntimeContext,
        record: HostServiceAgentControlRecord
    ) async -> Result<HostServiceAgentStatus, HostServiceAgentFailure> {
        let task = Task.detached(priority: .utility) {
            Self.requestBlocking(.authorize, context: context, generation: record.generation,
                consumerId: nil, authorization: record.authorization)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func request(
        _ method: HostServiceAgentControlMethod,
        context: HostServiceAgentRuntimeContext,
        generation: UUID?,
        consumerId: UUID?
    ) async -> Result<HostServiceAgentStatus, HostServiceAgentFailure> {
        let task = Task.detached(priority: .utility) {
            Self.requestBlocking(
                method,
                context: context,
                generation: generation,
                consumerId: consumerId
            )
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func requestBlocking(
        _ method: HostServiceAgentControlMethod,
        context: HostServiceAgentRuntimeContext,
        generation: UUID?,
        consumerId: UUID?,
        authorization: HostServiceAgentCopyAuthorization? = nil
    ) -> Result<HostServiceAgentStatus, HostServiceAgentFailure> {
        guard context.securityStateCheck.isCurrent() else {
            return .failure(.unavailable)
        }
        do {
            _ = try HostServiceEndpointReader.read(
                at: context.configuration.endpointURL,
                expected: context.configuration.endpoint
            )
            try HostServiceSocketPathPolicy.validateSocketParent(
                for: context.configuration.socketURL,
                rootURL: context.rootURL
            )
            let socketInfo = try HostServiceFilesystemInspector().inspect(
                context.configuration.socketURL
            )
            guard (socketInfo.st_mode & S_IFMT) == S_IFSOCK,
                  socketInfo.st_uid == getuid(),
                  (socketInfo.st_mode & 0o777) == 0o600 else {
                return .failure(.unavailable)
            }
        } catch {
            return .failure(.unavailable)
        }

        switch method {
        case .status, .prepare:
            break
        case .grant where generation == nil || consumerId == nil,
             .revoke where generation == nil,
             .authorize where generation == nil || authorization?.isValid != true
                || authorization?.instanceId != context.instanceID:
            return .failure(.invalidResponse)
        default:
            break
        }

        let requestID = Int.random(in: 1...Int(Int32.max))
        let request = HostServiceAgentWire.request(
            method: method,
            requestID: requestID,
            instanceID: context.instanceID,
            generation: generation,
            consumerId: consumerId,
            authorization: authorization
        )
        guard let requestData = try? JSONSerialization.data(withJSONObject: request) else {
            return .failure(.invalidResponse)
        }

        let deadline = DispatchTime.now() + (method == .authorize ? 35 : timeout)
        guard let fd = HostServiceAgentSocket.connect(
            socketURL: context.configuration.socketURL,
            deadline: deadline
        ) else {
            return .failure(.unavailable)
        }
        defer { Darwin.close(fd) }

        guard HostServiceAgentSocket.sendAll(
                fd: fd,
                data: requestData + Data([0x0A]),
                deadline: deadline
              ),
              context.securityStateCheck.isCurrent() else {
            return .failure(.unavailable)
        }

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            guard HostServiceAgentSocket.waitForEvent(
                fd: fd,
                events: Int16(POLLIN),
                deadline: deadline
            ),
            let count = HostServiceAgentSocket.readChunk(
                fd: fd,
                buffer: &buffer,
                deadline: deadline
            ),
            count > 0 else {
                return .failure(.unavailable)
            }
            let chunk = Data(buffer.prefix(count))
            if let newline = chunk.firstIndex(of: 0x0A) {
                received.append(chunk[..<newline])
                guard received.count <= responseLimit else {
                    return .failure(.invalidResponse)
                }
                guard context.securityStateCheck.isCurrent() else {
                    return .failure(.unavailable)
                }
                return decode(
                    received,
                    requestID: requestID,
                    expectedPluginID: context.pluginID,
                    expectedInstanceID: context.instanceID
                )
            }
            guard received.count + chunk.count <= responseLimit else {
                return .failure(.invalidResponse)
            }
            received.append(chunk)
        }
    }

    static func decode(
        _ data: Data,
        requestID: Int,
        expectedPluginID: String,
        expectedInstanceID: UUID
    ) -> Result<HostServiceAgentStatus, HostServiceAgentFailure> {
        guard data.count <= responseLimit,
              let envelope = try? JSONDecoder().decode(
                HostServiceAgentResponseEnvelope.self,
                from: data
              ),
              envelope.jsonrpc == "2.0",
              envelope.id == requestID,
              (envelope.error == nil) != (envelope.result == nil) else {
            return .failure(.invalidResponse)
        }
        if let error = envelope.error {
            guard error.code == -32000, let errorCode = error.data?.errorCode else {
                return .failure(.invalidResponse)
            }
            if errorCode == "busy" {
                return .failure(.busy)
            }
            guard let parsed = HostServiceAgentErrorCode(rawValue: errorCode) else {
                return .failure(.invalidResponse)
            }
            return .failure(.server(parsed))
        }
        guard let result = envelope.result,
              result.schemaVersion == 1,
              result.pluginId == expectedPluginID,
              result.instanceId == expectedInstanceID else {
            return .failure(.invalidResponse)
        }
        return .success(result)
    }

}

private struct HostServiceAgentResponseEnvelope: Decodable {
    var jsonrpc: String?
    var id: Int?
    var result: HostServiceAgentStatus?
    var error: HostServiceAgentRPCErrorEnvelope?

    enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case result
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
        id = try container.decode(Int.self, forKey: .id)
        if container.contains(.error), try !container.decodeNil(forKey: .error) {
            error = try container.decode(
                HostServiceAgentRPCErrorEnvelope.self,
                forKey: .error
            )
        } else {
            error = nil
        }
        result = try container.decodeIfPresent(HostServiceAgentStatus.self, forKey: .result)
    }
}

private struct HostServiceAgentRPCErrorEnvelope: Decodable {
    let code: Int
    let message: String?
    let data: HostServiceAgentRPCErrorData?

    enum CodingKeys: String, CodingKey {
        case code
        case message
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(Int.self, forKey: .code)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        data = try container.decodeIfPresent(HostServiceAgentRPCErrorData.self, forKey: .data)
    }
}

private struct HostServiceAgentRPCErrorData: Decodable {
    let errorCode: String?
}

private enum HostServiceAgentSocket {
    static func connect(socketURL: URL, deadline: DispatchTime) -> Int32? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var noSignal: Int32 = 1
        guard setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
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

    static func sendAll(fd: Int32, data: Data, deadline: DispatchTime) -> Bool {
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return data.isEmpty }
            var remaining = raw.count
            while remaining > 0 {
                guard waitForEvent(
                    fd: fd,
                    events: Int16(POLLOUT),
                    deadline: deadline
                ) else {
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

    static func readChunk(
        fd: Int32,
        buffer: inout [UInt8],
        deadline: DispatchTime
    ) -> Int? {
        while true {
            guard waitForEvent(
                fd: fd,
                events: Int16(POLLIN),
                deadline: deadline
            ) else {
                return nil
            }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count >= 0 { return count }
            if errno == EINTR { continue }
            return nil
        }
    }

    static func waitForEvent(
        fd: Int32,
        events: Int16,
        deadline: DispatchTime
    ) -> Bool {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard deadline.uptimeNanoseconds > now else { return false }
            let remaining = deadline.uptimeNanoseconds - now
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

// MARK: - Standard MCP stdio configuration

enum HostServiceAgentMCPConfiguration {
    static func handoff(instructions: String?, configuration: Data) throws -> String {
        if let instructions,
           !SystemPluginManifest.isValidAgentText(instructions, maximumBytes: 16_384) {
            throw HostServiceAgentFailure.invalidResponse
        }
        let guide = instructions ?? "通过 MCP 工具发现了解本插件的能力和使用顺序。"
        let document = try? JSONDecoder().decode(Document.self, from: configuration)
        let tokenIncluded = document?.mcpServers.values.contains { $0.env?["MACDORA_AGENT_TOKEN"] != nil } == true
        let authorizationGuide = tokenIncluded
            ? "本次复制已授权本机只读访问。使用配置携带的凭据接入，无需再次点击授权。保留用户随时接回控制的入口。"
            : "分别核实已配置、已连接、业务可用和已获授权。连接成功不代表用户已经授权。\n需要人工确认时说明具体动作；保留用户随时接回控制的入口。"
        return """
        请将以下已安装的本机插件接入当前 Agent。
        使用当前客户端支持的 MCP 配置方式合并下方 JSON，保留已有服务。请完成你能够执行的配置步骤。
        command 是完整的程序路径，args 是逐项参数；按结构化参数启动，不要拼接成 shell 脚本。
        如果当前客户端不支持本地 stdio MCP，请明确说明兼容限制，不要转发本机端点到网络。

        插件提供的接入与使用说明：
        \(guide)

        本机 MCP 配置：
        ```json
        \(String(decoding: configuration, as: UTF8.self))
        ```

        \(authorizationGuide)
        """
    }

    struct Server: Codable, Equatable, Sendable {
        var command: String
        var args: [String]
        var env: [String: String]? = nil
    }

    struct Document: Codable, Equatable, Sendable {
        var mcpServers: [String: Server]
    }

    static func document(
        pluginID: String,
        agentExecutableURL: URL,
        endpointURL: URL,
        token: String? = nil
    ) -> Document {
        Document(
            mcpServers: [
                pluginID: Server(
                    command: agentExecutableURL.path,
                    args: ["--endpoint", endpointURL.path],
                    env: token.map { ["MACDORA_AGENT_TOKEN": $0] }
                )
            ]
        )
    }

    static func data(
        pluginID: String,
        agentExecutableURL: URL,
        endpointURL: URL,
        token: String? = nil
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(
            document(
                pluginID: pluginID,
                agentExecutableURL: agentExecutableURL,
                endpointURL: endpointURL,
                token: token
            )
        )
    }
}
