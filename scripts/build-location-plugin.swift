import CryptoKit
import Darwin
import Foundation

struct PackageSignature: Codable {
    let pluginID: String
    let version: String
    let algorithm: String
    let keyID: String
    let publisher: String
    let manifestSHA256: String
    let files: [String: String]
    let signature: String
}

enum SigningError: Error {
    case invalid(String)
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// Matches SystemPluginTrustConfig.canonicalSigningPayload exactly: no final newline.
func canonicalSigningPayload(_ signature: PackageSignature) -> Data {
    var lines = [signature.algorithm, signature.keyID, signature.pluginID,
                 signature.version, signature.manifestSHA256]
    for path in signature.files.keys.sorted() {
        lines.append("\(path):\(signature.files[path]!)")
    }
    return Data(lines.joined(separator: "\n").utf8)
}

func fileHashes(_ root: URL) throws -> [String: String] {
    let manager = FileManager.default
    guard (try root.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
          let enumerator = manager.enumerator(at: root,
              includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
        throw SigningError.invalid("Cannot enumerate the plugin directory.")
    }
    var files: [String: String] = [:]
    for case let file as URL in enumerator {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw SigningError.invalid("Symlinks are not permitted.") }
        guard values.isRegularFile == true else { continue }
        let relative = String(file.path.dropFirst(root.path.count + 1))
        if relative == "signature.json" || relative == ".DS_Store" || relative.hasSuffix("/.DS_Store") { continue }
        guard !relative.hasPrefix("."), !relative.contains("/."), !relative.contains("..") else {
            throw SigningError.invalid("Hidden or traversing paths are not permitted.")
        }
        files[relative] = sha256(try Data(contentsOf: file))
    }
    guard files["manifest.json"] != nil else { throw SigningError.invalid("Manifest is missing.") }
    return files
}

func option(_ name: String, _ arguments: [String]) throws -> String {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        throw SigningError.invalid("Missing \(name).")
    }
    return arguments[index + 1]
}

func loadKey(_ path: String, create: Bool) throws -> Curve25519.Signing.PrivateKey {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    if create && !FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SigningError.invalid("Cannot create the selected key file.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: Curve25519.Signing.PrivateKey().rawRepresentation)
        try handle.close()
    }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    guard values.isRegularFile == true, values.isSymbolicLink != true,
          let mode = attrs[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0,
          let owner = attrs[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid() else {
        throw SigningError.invalid("The selected key must be an owner-only regular file (0600).")
    }
    return try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: url))
}

func deterministicSignature(_ payload: Data, key: Curve25519.Signing.PrivateKey) throws -> Data {
    let manager = FileManager.default
    let scratch = manager.temporaryDirectory.appendingPathComponent("macdora-plugin-sign-\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: scratch, withIntermediateDirectories: false,
                                attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: scratch) }
    let payloadURL = scratch.appendingPathComponent("payload.bin")
    try payload.write(to: payloadURL)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    let executable = ProcessInfo.processInfo.environment["MACDORA_OPENSSL"] ?? "openssl"
    process.arguments = [executable, "pkeyutl", "-sign", "-rawin", "-keyform", "DER",
                         "-inkey", "/dev/stdin", "-in", payloadURL.path]
    let input = Pipe(), output = Pipe(), errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    // RFC 8410 PKCS#8 prefix followed by the raw seed; key bytes only enter a pipe.
    let prefix: [UInt8] = [0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06,
                          0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20]
    try input.fileHandleForWriting.write(contentsOf: Data(prefix) + key.rawRepresentation)
    try input.fileHandleForWriting.close()
    let signature = output.fileHandleForReading.readDataToEndOfFile()
    _ = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, signature.count == 64 else {
        throw SigningError.invalid("Deterministic Ed25519 signing requires OpenSSL with Ed25519 support (OpenSSL 3). Set MACDORA_OPENSSL if needed.")
    }
    return signature
}

func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let operation = arguments.first, arguments.count >= 2 else {
        throw SigningError.invalid("Expected sign/verify and a plugin directory.")
    }
    let root = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
    let files = try fileHashes(root)
    let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as? [String: Any]
    guard let id = manifest?["id"] as? String, let version = manifest?["version"] as? String else {
        throw SigningError.invalid("Manifest identity is missing.")
    }
    let signatureURL = root.appendingPathComponent("signature.json")
    let publicKey: Curve25519.Signing.PublicKey
    if operation == "sign" {
        let key = try loadKey(option("--private-key", arguments), create: arguments.contains("--generate-key"))
        let keyID = try option("--key-id", arguments)
        let publisher = try option("--publisher", arguments)
        guard [keyID, publisher, id, version].allSatisfy({ !$0.contains("\n") && !$0.contains("\r") }) else {
            throw SigningError.invalid("Signing identity contains a line break.")
        }
        let unsigned = PackageSignature(pluginID: id, version: version, algorithm: "ed25519-sha256",
            keyID: keyID, publisher: publisher, manifestSHA256: files["manifest.json"]!, files: files, signature: "")
        let signed = PackageSignature(pluginID: id, version: version, algorithm: unsigned.algorithm,
            keyID: keyID, publisher: publisher, manifestSHA256: unsigned.manifestSHA256, files: files,
            signature: try deterministicSignature(canonicalSigningPayload(unsigned), key: key).base64EncodedString())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(signed).write(to: signatureURL, options: .atomic)
        publicKey = key.publicKey
    } else if operation == "verify" {
        guard let data = Data(base64Encoded: try option("--public-key", arguments)) else {
            throw SigningError.invalid("Invalid public key encoding.")
        }
        publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: data)
    } else {
        throw SigningError.invalid("Unknown operation.")
    }
    let signature = try JSONDecoder().decode(PackageSignature.self, from: Data(contentsOf: signatureURL))
    guard signature.pluginID == id, signature.version == version,
          signature.algorithm == "ed25519-sha256", signature.files == files,
          signature.manifestSHA256 == files["manifest.json"],
          let bytes = Data(base64Encoded: signature.signature),
          publicKey.isValidSignature(bytes, for: canonicalSigningPayload(signature)) else {
        throw SigningError.invalid("Ed25519 signature or signed file hashes do not match.")
    }
    let result = ["publicKeyBase64": publicKey.rawRepresentation.base64EncodedString(),
                  "keyID": signature.keyID, "manifestSHA256": signature.manifestSHA256,
                  "pluginID": id, "version": version]
    let output = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
    print(String(decoding: output, as: UTF8.self))
}

do {
    try run()
} catch {
    // Errors identify the failed operation, never key bytes.
    FileHandle.standardError.write(Data("Plugin signing failed: \(error)\n".utf8))
    exit(1)
}
