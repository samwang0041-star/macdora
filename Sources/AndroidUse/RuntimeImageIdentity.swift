import Foundation

/// SDK image identity and the incremental version used by the emulator's QCOW cache.
struct RuntimeImageIdentity: Equatable, Sendable {
    let api: String
    let revision: Int
    let incremental: String
    let abi: String
    let tag: String

    static func read(from image: URL) throws -> RuntimeImageIdentity {
        func property(_ key: String, in filename: String) throws -> String {
            let text = try String(contentsOf: image.appendingPathComponent(filename), encoding: .utf8)
            let values = text.components(separatedBy: .newlines).compactMap { line -> String? in
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespaces) == key else { return nil }
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
            guard values.count == 1, let value = values.first, !value.isEmpty else {
                throw RuntimeError.invalidSeed("Android 镜像版本信息")
            }
            return value
        }
        let api = try property("AndroidVersion.ApiLevel", in: "source.properties")
        let pieces = api.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIWholeNumber) }),
              pieces.allSatisfy({ Int($0) != nil }),
              let major = pieces.first.flatMap({ Int($0) }), major > 0,
              let revision = Int(try property("Pkg.Revision", in: "source.properties")), revision > 0 else {
            throw RuntimeError.invalidSeed("Android 镜像版本信息")
        }
        let incremental = try property("ro.build.version.incremental", in: "build.prop")
        guard incremental.allSatisfy(\.isASCIIWholeNumber), Int64(incremental) != nil else {
            throw RuntimeError.invalidSeed("Android 镜像构建版本")
        }
        let abi = try property("SystemImage.Abi", in: "source.properties")
        let tag = try property("SystemImage.TagId", in: "source.properties")
        guard abi == "arm64-v8a", tag == "default" else {
            throw RuntimeError.invalidSeed("不支持的 Android 镜像类型")
        }
        return RuntimeImageIdentity(api: api, revision: revision, incremental: incremental, abi: abi, tag: tag)
    }

    func permitsUpgrade(to next: RuntimeImageIdentity) -> Bool {
        guard abi == next.abi, tag == next.tag else { return false }
        let current = api.split(separator: ".").compactMap { Int($0) }
        let desired = next.api.split(separator: ".").compactMap { Int($0) }
        for index in 0..<max(current.count, desired.count) {
            let left = index < current.count ? current[index] : 0
            let right = index < desired.count ? desired[index] : 0
            if left != right { return right > left }
        }
        return next.revision >= revision
    }
}

private extension Character {
    var isASCIIWholeNumber: Bool { self >= "0" && self <= "9" }
}
