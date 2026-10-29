import CryptoKit
import Foundation

/// A local capability copied only by an explicit user action. Never log the value.
struct HostServiceAgentCopyToken {
    let value: String

    var digest: String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func generate() -> Self {
        let key = SymmetricKey(size: .bits256)
        let value = key.withUnsafeBytes { bytes in
            bytes.map { String(format: "%02x", $0) }.joined()
        }
        return Self(value: value)
    }
}

struct HostServiceAgentCopyAuthorization: Codable, Equatable, Sendable {
    var mode: String = "copyToken"
    var instanceId: UUID
    var scope: String = "readOnly"
    var tokenSHA256: String

    enum CodingKeys: String, CodingKey {
        case mode, instanceId, scope, tokenSHA256
    }

    init(instanceId: UUID, tokenSHA256: String) {
        self.instanceId = instanceId
        self.tokenSHA256 = tokenSHA256
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(String.self, forKey: .mode)
        let instance = try container.decode(String.self, forKey: .instanceId)
        guard let decoded = UUID(uuidString: instance) else {
            throw HostServiceAgentControlStoreError.invalidRecord
        }
        instanceId = decoded
        scope = try container.decode(String.self, forKey: .scope)
        tokenSHA256 = try container.decode(String.self, forKey: .tokenSHA256)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(instanceId.uuidString.lowercased(), forKey: .instanceId)
        try container.encode(scope, forKey: .scope)
        try container.encode(tokenSHA256, forKey: .tokenSHA256)
    }

    var isValid: Bool {
        mode == "copyToken" && scope == "readOnly"
            && tokenSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }
}
