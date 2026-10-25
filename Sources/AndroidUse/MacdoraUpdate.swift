import AppKit
import CryptoKit
import Foundation
import Security

// MARK: - Macdora Version System (0.01 Baseline)

/// Represents a Macdora release version in the `0.01` -> `0.02` -> `0.10` -> `1.00`
/// numbering scheme (also compatible with 3-part SemVer tags such as `0.1.0` or `v1.2.3`).
struct MacdoraVersion: Equatable, Comparable, Hashable, Sendable, Codable, CustomStringConvertible {
    static let initialRelease = MacdoraVersion(
        raw: MacdoraBrand.initialVersionString,
        major: 0,
        minorHundredths: 1,
        patch: 0,
        build: 1,
        isPrerelease: false
    )

    let raw: String
    let major: Int
    /// Normalized hundredths value for the minor component:
    /// - `"0.01"` -> `1`
    /// - `"0.02"` -> `2`
    /// - `"0.09"` -> `9`
    /// - `"0.10"` or `"0.1"` -> `10`
    /// - `"0.25"` -> `25`
    let minorHundredths: Int
    let patch: Int
    let build: Int
    let isPrerelease: Bool

    init(
        raw: String,
        major: Int,
        minorHundredths: Int,
        patch: Int = 0,
        build: Int = 1,
        isPrerelease: Bool = false
    ) {
        self.raw = raw
        self.major = major
        self.minorHundredths = minorHundredths
        self.patch = patch
        self.build = max(1, build)
        self.isPrerelease = isPrerelease
    }

    /// Parses two-decimal Macdora versions (`"0.01"`, `"v0.01"`, `"0.02"`, `"0.10"`, `"1.00"`)
    /// and three-segment SemVer tags (`"0.1.0"`, `"0.2.0"`, `"0.10.0"`, `"1.0.0"`).
    init?(_ rawInput: String, build: Int = 1) {
        var text = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.first == "v" || text.first == "V" {
            text.removeFirst()
        }
        let isPrerelease = text.contains("-")
        if let cutoff = text.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            text = String(text[..<cutoff])
        }
        guard !text.isEmpty else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 && parts.count <= 3 else { return nil }
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        guard let major = Int(parts[0]), major >= 0 else { return nil }

        let secondRaw = parts[1]
        if parts.count == 2 && secondRaw.count != 2 {
            // Two-segment versions must use explicit two-digit hundredths (e.g. "0.01", "0.10").
            return nil
        }
        guard let minorHundredths = Int(secondRaw), (0..<100).contains(minorHundredths) else {
            return nil
        }

        let patch: Int
        if parts.count == 3 {
            guard let p = Int(parts[2]), p >= 0 else { return nil }
            patch = p
        } else {
            patch = 0
        }

        self.raw = text
        self.major = major
        self.minorHundredths = minorHundredths
        self.patch = patch
        self.build = max(1, build)
        self.isPrerelease = isPrerelease
    }

    var displayString: String { raw }
    var tagName: String { "v\(raw)" }
    var fullDisplayString: String { "v\(raw) (Build \(build))" }
    var description: String { raw }

    static var current: MacdoraVersion {
        let env = ProcessInfo.processInfo.environment
        if let override = env["MACDORA_VERSION_OVERRIDE"],
           let parsed = MacdoraVersion(override) {
            return parsed
        }
        let isMacdoraBundle = (Bundle.main.bundleIdentifier == MacdoraUpdateService.expectedBundleIdentifier)
        let bundleBuild = isMacdoraBundle
            ? ((Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init) ?? 1)
            : 1
        if isMacdoraBundle,
           let bundleShort = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           bundleShort != "0.1.0",
           let parsed = MacdoraVersion(bundleShort, build: bundleBuild) {
            return parsed
        }
        return MacdoraVersion(
            raw: MacdoraBrand.initialVersionString,
            major: 0,
            minorHundredths: 1,
            patch: 0,
            build: bundleBuild,
            isPrerelease: false
        )
    }

    static func < (lhs: MacdoraVersion, rhs: MacdoraVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minorHundredths != rhs.minorHundredths { return lhs.minorHundredths < rhs.minorHundredths }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.isPrerelease != rhs.isPrerelease {
            return lhs.isPrerelease && !rhs.isPrerelease
        }
        return false
    }

    static func == (lhs: MacdoraVersion, rhs: MacdoraVersion) -> Bool {
        lhs.major == rhs.major
            && lhs.minorHundredths == rhs.minorHundredths
            && lhs.patch == rhs.patch
            && lhs.isPrerelease == rhs.isPrerelease
    }
}

// MARK: - GitHub Release Models & Feed Parser

struct MacdoraReleaseAsset: Equatable, Sendable, Codable {
    let id: Int
    let name: String
    let browserDownloadURL: URL
    let size: Int64
    let state: String
}

struct MacdoraGitHubRelease: Equatable, Sendable {
    let tagName: String
    let name: String
    let draft: Bool
    let prerelease: Bool
    let htmlURL: URL
    let publishedAt: String?
    let body: String
    let assets: [MacdoraReleaseAsset]
}

struct MacdoraUpdateOffer: Equatable, Sendable, Codable {
    let version: MacdoraVersion
    let tagName: String
    let title: String
    let notes: String
    let publishedAt: String?
    let htmlURL: URL
    let asset: MacdoraReleaseAsset
    let checksumAsset: MacdoraReleaseAsset?
}

struct MacdoraDownloadProgress: Equatable, Sendable {
    let receivedBytes: Int64
    let totalBytes: Int64
    let percent: Int
    let fractionCompleted: Double

    init(receivedBytes: Int64, totalBytes: Int64) {
        let safeReceived = max(0, receivedBytes)
        let safeTotal = max(0, totalBytes)
        self.receivedBytes = safeReceived
        self.totalBytes = safeTotal
        if safeTotal > 0 {
            let rawFraction = min(1.0, max(0.0, Double(safeReceived) / Double(safeTotal)))
            self.fractionCompleted = rawFraction
            self.percent = min(100, max(0, Int((rawFraction * 100.0).rounded())))
        } else {
            self.fractionCompleted = 0.0
            self.percent = 0
        }
    }

    var formattedBytesText: String {
        let recvMB = Double(receivedBytes) / (1024.0 * 1024.0)
        if totalBytes > 0 {
            let totalMB = Double(totalBytes) / (1024.0 * 1024.0)
            if totalMB >= 1.0 {
                return String(format: "%.1f MB / %.1f MB", recvMB, totalMB)
            } else {
                let recvKB = Double(receivedBytes) / 1024.0
                let totalKB = Double(totalBytes) / 1024.0
                return String(format: "%.0f KB / %.0f KB", recvKB, totalKB)
            }
        }
        return String(format: "%.1f MB", recvMB)
    }
}

struct MacdoraStagedUpdate: Equatable, Sendable {
    let offer: MacdoraUpdateOffer
    let stagingDirectory: URL
    let stagedAppURL: URL
    let archiveSHA256: String
}

enum MacdoraUpdateState: Equatable, Sendable {
    case idle(lastCheckedAt: Date?)
    case checking
    case upToDate(checkedAt: Date, detail: String)
    case available(MacdoraUpdateOffer)
    case downloading(offer: MacdoraUpdateOffer, progress: MacdoraDownloadProgress)
    case readyToInstall(MacdoraStagedUpdate)
    case installing(MacdoraUpdateOffer)
    case failed(message: String, retryOffer: MacdoraUpdateOffer?)

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .installing:
            return true
        default:
            return false
        }
    }
}

enum MacdoraUpdateError: Error, Equatable, LocalizedError {
    case invalidRepository
    case rateLimited
    case unauthorized
    case httpStatus(Int)
    case invalidDownloadURL
    case invalidArchive
    case checksumMismatch
    case bundleIdentityMismatch
    case signatureInvalid
    case replaceFailed(intact: Bool, detail: String)
    case restartFailed(String)

    var errorDescription: String? { userMessage }

    var userMessage: String {
        switch self {
        case .invalidRepository:
            return "更新地址无效"
        case .rateLimited:
            return "请求过于频繁，请稍后再试"
        case .unauthorized:
            return "暂时无法检查更新"
        case .httpStatus:
            return "暂时无法连接更新服务"
        case .invalidDownloadURL:
            return "安装包地址无效"
        case .invalidArchive:
            return "安装包损坏，请重新下载"
        case .checksumMismatch:
            return "安装包校验未通过，请重新下载"
        case .bundleIdentityMismatch:
            return "安装包版本不匹配"
        case .signatureInvalid:
            return "安装包签名校验未通过"
        case .replaceFailed(let intact, _):
            return intact ? "更新未完成，请重试" : "更新未完成，请重新安装应用"
        case .restartFailed:
            return "更新已安装，请手动重新打开"
        }
    }
}

enum MacdoraGitHubFeed {
    static func normalizedRepository(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let owner = String(parts[0])
        let repo = String(parts[1])
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        guard !owner.isEmpty, !repo.isEmpty,
              owner.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              repo.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return "\(owner)/\(repo)"
    }

    static func parseReleases(_ data: Data) throws -> [MacdoraGitHubRelease] {
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([ReleaseDTO].self, from: data) {
            return list.map { $0.model() }
        }
        let single = try decoder.decode(ReleaseDTO.self, from: data)
        return [single.model()]
    }

    static func selectOffer(
        from releases: [MacdoraGitHubRelease],
        currentVersion: MacdoraVersion,
        includePrerelease: Bool = false
    ) -> MacdoraUpdateOffer? {
        releases
            .filter { !$0.draft }
            .filter { includePrerelease || !$0.prerelease }
            .compactMap { release -> MacdoraUpdateOffer? in
                guard let version = MacdoraVersion(release.tagName) ?? MacdoraVersion(release.name),
                      version > currentVersion,
                      let asset = preferredAsset(in: release.assets),
                      let checksum = checksumAsset(for: asset, in: release.assets) else {
                    return nil
                }
                let title = release.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Macdora \(version.tagName)"
                    : release.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return MacdoraUpdateOffer(
                    version: version,
                    tagName: release.tagName,
                    title: title,
                    notes: release.body.trimmingCharacters(in: .whitespacesAndNewlines),
                    publishedAt: release.publishedAt,
                    htmlURL: release.htmlURL,
                    asset: asset,
                    checksumAsset: checksum
                )
            }
            .max { $0.version < $1.version }
    }

    static func preferredAsset(in assets: [MacdoraReleaseAsset]) -> MacdoraReleaseAsset? {
        let zips = assets.filter { asset in
            let lower = asset.name.lowercased()
            guard lower.hasSuffix(".zip") else { return false }
            if lower.contains("sha256") || lower.contains("source") { return false }
            return asset.state == "uploaded" || asset.state.isEmpty
        }
        return zips.max { assetScore($0.name) < assetScore($1.name) }
    }

    static func checksumAsset(for zip: MacdoraReleaseAsset, in assets: [MacdoraReleaseAsset]) -> MacdoraReleaseAsset? {
        let expected = zip.name.lowercased() + ".sha256"
        return assets.first {
            let lower = $0.name.lowercased()
            return lower == expected || lower == expected + ".txt"
        }
    }

    static func assetScore(_ name: String) -> Int {
        let lower = name.lowercased()
        var score = 0
        if lower.contains("macdora") { score += 10 }
        if lower.contains("macos") { score += 8 }
        if lower.contains("arm64") { score += 6 }
        return score
    }

    static func parseSHA256Manifest(_ data: Data, expectedAssetName: String? = nil) -> String? {
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        let firstLine = text.components(separatedBy: .newlines).first ?? text
        let parts = firstLine.split(whereSeparator: \.isWhitespace).map(String.init)
        let token = parts.first?.lowercased()
        guard let token, token.count == 64,
              token.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
            return nil
        }
        if let expectedAssetName {
            guard parts.count >= 2 else { return nil }
            let manifestFile = parts.last?.trimmingCharacters(in: CharacterSet(charactersIn: "*")) ?? ""
            guard !manifestFile.isEmpty,
                  manifestFile.lowercased() == expectedAssetName.lowercased() else {
                return nil
            }
        }
        return token
    }

    private struct ReleaseDTO: Decodable {
        let tagName: String
        let name: String?
        let draft: Bool?
        let prerelease: Bool?
        let htmlURL: URL
        let publishedAt: String?
        let body: String?
        let assets: [AssetDTO]?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case draft
            case prerelease
            case htmlURL = "html_url"
            case publishedAt = "published_at"
            case body
            case assets
        }

        func model() -> MacdoraGitHubRelease {
            MacdoraGitHubRelease(
                tagName: tagName,
                name: name ?? "",
                draft: draft ?? false,
                prerelease: prerelease ?? false,
                htmlURL: htmlURL,
                publishedAt: publishedAt,
                body: body ?? "",
                assets: (assets ?? []).map { $0.model() }
            )
        }
    }

    private struct AssetDTO: Decodable {
        let id: Int?
        let name: String
        let browserDownloadURL: URL
        let size: Int64?
        let state: String?

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case browserDownloadURL = "browser_download_url"
            case size
            case state
        }

        func model() -> MacdoraReleaseAsset {
            MacdoraReleaseAsset(
                id: id ?? 0,
                name: name,
                browserDownloadURL: browserDownloadURL,
                size: size ?? 0,
                state: state ?? "uploaded"
            )
        }
    }
}

// MARK: - Transport & Streaming Downloader

protocol MacdoraUpdateTransport: Sendable {
    func fetchData(for request: URLRequest) async throws -> (Data, URLResponse)
    func downloadFile(
        from url: URL,
        expectedSize: Int64,
        to destinationURL: URL,
        onProgress: @escaping @Sendable (MacdoraDownloadProgress) -> Void
    ) async throws
}

struct URLSessionMacdoraUpdateTransport: MacdoraUpdateTransport {
    let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func fetchData(for request: URLRequest) async throws -> (Data, URLResponse) {
        if let url = request.url, url.isFileURL {
            let data = try Data(contentsOf: url)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (data, response)
        }
        return try await session.data(for: request)
    }

    func downloadFile(
        from url: URL,
        expectedSize: Int64,
        to destinationURL: URL,
        onProgress: @escaping @Sendable (MacdoraDownloadProgress) -> Void
    ) async throws {
        if url.isFileURL {
            let data = try Data(contentsOf: url)
            let total = max(Int64(data.count), expectedSize)
            let steps = 5
            let chunkSize = max(1, data.count / steps)
            FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destinationURL)
            defer { try? handle.close() }
            var offset = 0
            onProgress(MacdoraDownloadProgress(receivedBytes: 0, totalBytes: total))
            while offset < data.count {
                try Task.checkCancellation()
                let end = min(data.count, offset + chunkSize)
                try handle.write(contentsOf: data[offset..<end])
                offset = end
                onProgress(MacdoraDownloadProgress(receivedBytes: Int64(offset), totalBytes: total))
                try await Task.sleep(for: .milliseconds(25))
            }
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Macdora/\(MacdoraVersion.current.displayString) (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MacdoraUpdateError.httpStatus(http.statusCode)
        }

        let responseLength = response.expectedContentLength > 0 ? response.expectedContentLength : expectedSize
        let totalBytes = max(0, responseLength)
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destinationURL)
        defer { try? handle.close() }

        var received: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(65_536)
        var lastReportedPercent = -1

        onProgress(MacdoraDownloadProgress(receivedBytes: 0, totalBytes: totalBytes))

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 65_536 {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                let progress = MacdoraDownloadProgress(receivedBytes: received, totalBytes: max(totalBytes, received))
                if progress.percent != lastReportedPercent {
                    lastReportedPercent = progress.percent
                    onProgress(progress)
                }
            }
        }

        if !buffer.isEmpty {
            try Task.checkCancellation()
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: false)
        }

        let finalTotal = max(totalBytes, received)
        onProgress(MacdoraDownloadProgress(receivedBytes: finalTotal, totalBytes: max(1, finalTotal)))
    }
}

// MARK: - Update Service (Check, Download & Stage, Atomic Replace & Restart)

struct MacdoraUpdateService: Sendable {
    static let expectedBundleIdentifier = "local.androiduse.app"

    var transport: any MacdoraUpdateTransport
    var currentVersion: MacdoraVersion
    var repository: String
    var feedURLOverride: URL?

    init(
        transport: any MacdoraUpdateTransport = URLSessionMacdoraUpdateTransport(),
        currentVersion: MacdoraVersion = .current,
        repository: String = MacdoraUpdateService.resolvedRepository(),
        feedURLOverride: URL? = MacdoraUpdateService.resolvedFeedURLOverride()
    ) {
        self.transport = transport
        self.currentVersion = currentVersion
        self.repository = repository
        self.feedURLOverride = feedURLOverride
    }

    static func resolvedRepository() -> String {
        let env = ProcessInfo.processInfo.environment
        if let repo = env["MACDORA_GITHUB_REPOSITORY"],
           let normalized = MacdoraGitHubFeed.normalizedRepository(repo) {
            return normalized
        }
        if let plistRepo = Bundle.main.object(forInfoDictionaryKey: "MacdoraGitHubRepository") as? String,
           let normalized = MacdoraGitHubFeed.normalizedRepository(plistRepo) {
            return normalized
        }
        return MacdoraBrand.defaultGitHubRepository
    }

    static func resolvedFeedURLOverride() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["MACDORA_UPDATE_FEED_URL"],
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw)
        }
        return URL(string: raw)
    }

    func checkForUpdates(includePrerelease: Bool = false) async throws -> MacdoraUpdateOffer? {
        let feedURL: URL
        if let feedURLOverride {
            feedURL = feedURLOverride
        } else {
            guard let normalized = MacdoraGitHubFeed.normalizedRepository(repository),
                  let url = URL(string: "https://api.github.com/repos/\(normalized)/releases?per_page=20") else {
                throw MacdoraUpdateError.invalidRepository
            }
            feedURL = url
        }

        var request = URLRequest(url: feedURL)
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Macdora/\(currentVersion.displayString) (macOS)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await transport.fetchData(for: request)
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200:
                break
            case 404:
                // When the repository has not yet published a release above 0.01,
                // treat 404 on /releases as "no newer version published yet".
                return nil
            case 403, 429:
                if let webOffer = try? await checkViaGitHubWeb(repository: repository) {
                    return webOffer
                }
                throw MacdoraUpdateError.rateLimited
            case 401:
                throw MacdoraUpdateError.unauthorized
            default:
                throw MacdoraUpdateError.httpStatus(http.statusCode)
            }
        }

        let releases = try MacdoraGitHubFeed.parseReleases(data)
        return MacdoraGitHubFeed.selectOffer(
            from: releases,
            currentVersion: currentVersion,
            includePrerelease: includePrerelease
        )
    }

    private func checkViaGitHubWeb(repository rawRepo: String) async throws -> MacdoraUpdateOffer? {
        guard let repo = MacdoraGitHubFeed.normalizedRepository(rawRepo),
              let latestURL = URL(string: "https://github.com/\(repo)/releases/latest") else {
            throw MacdoraUpdateError.invalidRepository
        }
        var req = URLRequest(url: latestURL)
        req.timeoutInterval = 12
        req.setValue("text/html", forHTTPHeaderField: "Accept")
        req.setValue("Macdora/\(currentVersion.displayString) (macOS)", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await transport.fetchData(for: req)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }
        guard let finalURL = http.url,
              let range = finalURL.path.range(of: "/releases/tag/", options: .backwards) else {
            return nil
        }
        let tag = String(finalURL.path[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let version = MacdoraVersion(tag), version > currentVersion else {
            return nil
        }
        let assetName = "Macdora-\(version.displayString)-macOS-arm64.zip"
        let checksumName = "\(assetName).sha256"
        guard let downloadURL = URL(string: "https://github.com/\(repo)/releases/download/\(tag)/\(assetName)"),
              let checksumURL = URL(string: "https://github.com/\(repo)/releases/download/\(tag)/\(checksumName)") else {
            return nil
        }
        return MacdoraUpdateOffer(
            version: version,
            tagName: tag,
            title: "Macdora \(version.tagName)",
            notes: "",
            publishedAt: nil,
            htmlURL: finalURL,
            asset: MacdoraReleaseAsset(
                id: 0,
                name: assetName,
                browserDownloadURL: downloadURL,
                size: 0,
                state: "uploaded"
            ),
            checksumAsset: MacdoraReleaseAsset(
                id: 0,
                name: checksumName,
                browserDownloadURL: checksumURL,
                size: 0,
                state: "uploaded"
            )
        )
    }

    static func validateAssetFileName(_ name: String) throws {
        guard !name.isEmpty,
              name == URL(fileURLWithPath: name).lastPathComponent,
              name != ".", name != "..",
              name.allSatisfy({ $0.isLetter || $0.isNumber || "._+- ".contains($0) }) else {
            throw MacdoraUpdateError.invalidArchive
        }
    }

    func downloadAndStage(
        offer: MacdoraUpdateOffer,
        onProgress: @escaping @Sendable (MacdoraDownloadProgress) -> Void
    ) async throws -> MacdoraStagedUpdate {
        guard offer.version > currentVersion else {
            throw MacdoraUpdateError.bundleIdentityMismatch
        }
        try Self.validateAssetFileName(offer.asset.name)
        guard let checksumAsset = offer.checksumAsset else {
            throw MacdoraUpdateError.checksumMismatch
        }
        try Self.validateAssetFileName(checksumAsset.name)

        let scheme = offer.asset.browserDownloadURL.scheme?.lowercased()
        let csScheme = checksumAsset.browserDownloadURL.scheme?.lowercased()
        guard (scheme == "https" || scheme == "http" || scheme == "file"),
              (csScheme == "https" || csScheme == "http" || csScheme == "file") else {
            throw MacdoraUpdateError.invalidDownloadURL
        }

        let fm = FileManager.default
        let stagingDir = fm.temporaryDirectory.appendingPathComponent("Macdora-Update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        do {
            let archiveURL = stagingDir.appendingPathComponent(offer.asset.name)
            try await transport.downloadFile(
                from: offer.asset.browserDownloadURL,
                expectedSize: offer.asset.size,
                to: archiveURL,
                onProgress: onProgress
            )
            try Task.checkCancellation()

            let actualSHA256 = try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let archiveData = try Data(contentsOf: archiveURL)
                try Task.checkCancellation()
                return SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
            }.value
            try Task.checkCancellation()

            var csReq = URLRequest(url: checksumAsset.browserDownloadURL)
            csReq.setValue("Macdora/\(currentVersion.displayString) (macOS)", forHTTPHeaderField: "User-Agent")
            let (csData, csResponse) = try await transport.fetchData(for: csReq)
            if let http = csResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw MacdoraUpdateError.checksumMismatch
            }
            guard let expectedSHA256 = MacdoraGitHubFeed.parseSHA256Manifest(
                csData,
                expectedAssetName: offer.asset.name
            ), expectedSHA256 == actualSHA256 else {
                throw MacdoraUpdateError.checksumMismatch
            }
            try Task.checkCancellation()

            let extractDir = stagingDir.appendingPathComponent("extracted", isDirectory: true)
            try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
            try await Self.extractZip(at: archiveURL, to: extractDir)
            try Task.checkCancellation()

            let appURL = try Self.findAppBundle(in: extractDir)
            try Self.verifyStagedAppBundle(at: appURL, expectedVersion: offer.version)
            try Task.checkCancellation()

            return MacdoraStagedUpdate(
                offer: offer,
                stagingDirectory: stagingDir,
                stagedAppURL: appURL,
                archiveSHA256: actualSHA256
            )
        } catch {
            try? fm.removeItem(at: stagingDir)
            throw error
        }
    }

    static func extractZip(at archiveURL: URL, to destinationURL: URL) async throws {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, destinationURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in
                    continuation.resume()
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            throw MacdoraUpdateError.invalidArchive
        }
    }

    static func findAppBundle(in rootURL: URL) throws -> URL {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw MacdoraUpdateError.invalidArchive
        }
        var candidates: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "app" else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            enumerator.skipDescendants()
            candidates.append(url)
        }
        if let macdora = candidates.first(where: { $0.lastPathComponent.lowercased() == "macdora.app" }) {
            return macdora
        }
        if candidates.count == 1, let only = candidates.first {
            return only
        }
        throw MacdoraUpdateError.invalidArchive
    }

    static func verifyStagedAppBundle(at appURL: URL, expectedVersion: MacdoraVersion, expectedTeamIdentifier: String? = nil) throws {
        let fm = FileManager.default
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOf: plistURL) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String,
              bundleID == expectedBundleIdentifier else {
            throw MacdoraUpdateError.bundleIdentityMismatch
        }
        let shortVersion = (plist["CFBundleShortVersionString"] as? String) ?? ""
        guard let bundleVersion = MacdoraVersion(shortVersion),
              bundleVersion >= expectedVersion else {
            throw MacdoraUpdateError.bundleIdentityMismatch
        }
        let execName = (plist["CFBundleExecutable"] as? String) ?? "AndroidUse"
        let execURL = appURL.appendingPathComponent("Contents/MacOS/\(execName)")
        guard fm.isExecutableFile(atPath: execURL.path) else {
            throw MacdoraUpdateError.invalidArchive
        }
        let stagedTeam = try validatedSigningTeam(at: appURL)
        let currentTeam: String?
        if let expectedTeamIdentifier {
            currentTeam = expectedTeamIdentifier
        } else if Bundle.main.bundleIdentifier == expectedBundleIdentifier {
            currentTeam = try validatedSigningTeam(at: Bundle.main.bundleURL)
        } else {
            currentTeam = nil
        }
        if let currentTeam {
            guard stagedTeam == currentTeam else { throw MacdoraUpdateError.signatureInvalid }
            _ = try validatedSigningTeam(at: appURL, requiredTeam: currentTeam)
        }
    }

    private static func validatedSigningTeam(at appURL: URL, requiredTeam: String? = nil) throws -> String? {
        var requirement: SecRequirement?
        if let requiredTeam {
            guard requiredTeam.range(of: "^[A-Z0-9]+$", options: .regularExpression) != nil else {
                throw MacdoraUpdateError.signatureInvalid
            }
            let expression = "anchor apple generic and identifier \"\(expectedBundleIdentifier)\" and certificate leaf[subject.OU] = \"\(requiredTeam)\""
            guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess else {
                throw MacdoraUpdateError.signatureInvalid
            }
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), requirement) == errSecSuccess else {
            throw MacdoraUpdateError.signatureInvalid
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess else {
            throw MacdoraUpdateError.signatureInvalid
        }
        let values = information as? [String: Any]
        let flags = (values?[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let certificates = values?[kSecCodeInfoCertificates as String] as? [Any] ?? []
        guard flags & 0x00000002 == 0, !certificates.isEmpty else { return nil }
        return values?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static func defaultTargetAppURL() -> URL {
        if let envTarget = ProcessInfo.processInfo.environment["MACDORA_UPDATE_TARGET_APP"],
           !envTarget.isEmpty {
            return URL(fileURLWithPath: envTarget).standardizedFileURL
        }
        let mainURL = Bundle.main.bundleURL.standardizedFileURL
        if mainURL.pathExtension.lowercased() == "app" {
            return mainURL
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return cwd.appendingPathComponent("artifacts/Macdora.app").standardizedFileURL
    }

    static func replaceAppBundle(at targetAppURL: URL, with stagedAppURL: URL) throws {
        let fm = FileManager.default
        let dest = targetAppURL.standardizedFileURL
        let parent = dest.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let sameVolumeStage = parent.appendingPathComponent(".\(dest.lastPathComponent).incoming-\(UUID().uuidString)")
        let backupName = ".\(dest.lastPathComponent).update-backup"
        let backupURL = parent.appendingPathComponent(backupName)
        let hadOriginal = fm.fileExists(atPath: dest.path)
        let originalShortVersion = (NSDictionary(contentsOf: dest.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleShortVersionString"] as? String

        if fm.fileExists(atPath: sameVolumeStage.path) {
            try? fm.removeItem(at: sameVolumeStage)
        }
        if fm.fileExists(atPath: backupURL.path) {
            try? fm.removeItem(at: backupURL)
        }

        do {
            try fm.copyItem(at: stagedAppURL, to: sameVolumeStage)
            let targetTeam = hadOriginal ? try validatedSigningTeam(at: dest) : nil
            try verifyStagedAppBundle(at: sameVolumeStage,
                                      expectedVersion: MacdoraVersion(originalShortVersion ?? "") ?? .initialRelease,
                                      expectedTeamIdentifier: targetTeam)
            if hadOriginal {
                _ = try fm.replaceItemAt(
                    dest,
                    withItemAt: sameVolumeStage,
                    backupItemName: backupName,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fm.moveItem(at: sameVolumeStage, to: dest)
            }
            if fm.fileExists(atPath: backupURL.path) {
                try? fm.removeItem(at: backupURL)
            }
        } catch {
            if fm.fileExists(atPath: sameVolumeStage.path) {
                try? fm.removeItem(at: sameVolumeStage)
            }
            var rollbackRestored = true
            if !fm.fileExists(atPath: dest.path), fm.fileExists(atPath: backupURL.path) {
                do {
                    try fm.moveItem(at: backupURL, to: dest)
                } catch {
                    rollbackRestored = false
                }
            }
            let intact: Bool
            if hadOriginal {
                let currentPlist = NSDictionary(contentsOf: dest.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
                let currentVer = currentPlist?["CFBundleShortVersionString"] as? String
                let execName = (currentPlist?["CFBundleExecutable"] as? String) ?? "AndroidUse"
                let hasExec = fm.isExecutableFile(atPath: dest.appendingPathComponent("Contents/MacOS/\(execName)").path)
                intact = rollbackRestored && hasExec && (currentVer == originalShortVersion)
            } else {
                intact = false
            }
            throw MacdoraUpdateError.replaceFailed(intact: intact, detail: error.localizedDescription)
        }
    }

    static func spawnDetachedRelaunch(for appURL: URL, waitingForPID pid: Int32) throws {
        let script = relaunchShellScript(waitingForPID: pid)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script, "macdora-relaunch", appURL.path]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
    }

    static func relaunchShellScript(waitingForPID pid: Int32) -> String {
        let script = [
            "PID=\(pid)",
            "APP_PATH=\"$1\"",
            "i=0",
            "while kill -0 \"$PID\" 2>/dev/null && [ $i -lt 30 ]; do",
            "  sleep 0.1",
            "  i=$((i + 1))",
            "done",
            "if kill -0 \"$PID\" 2>/dev/null; then",
            "  kill -TERM \"$PID\" 2>/dev/null || true",
            "  sleep 0.2",
            "  kill -KILL \"$PID\" 2>/dev/null || true",
            "  sleep 0.1",
            "fi",
            "/usr/bin/open \"$APP_PATH\""
        ].joined(separator: "\n")
        return script
    }
}

// MARK: - MainActor Update Controller

@MainActor
final class MacdoraUpdateController {
    static let shared = MacdoraUpdateController()

    private(set) var state: MacdoraUpdateState = .idle(lastCheckedAt: nil) {
        didSet {
            onStateChange?(state)
        }
    }

    var service: MacdoraUpdateService
    var onStateChange: ((MacdoraUpdateState) -> Void)?
    var prepareForRestart: (() async -> Void)?
    var targetAppURLProvider: () -> URL = { MacdoraUpdateService.defaultTargetAppURL() }
    var relaunchHandler: ((URL) throws -> Void)?

    private var activeTask: Task<Void, Never>?
    private var activeOperationID = UUID()
    private(set) var lastCheckedAt: Date?
    private(set) var stagedUpdate: MacdoraStagedUpdate?

    init(service: MacdoraUpdateService = MacdoraUpdateService()) {
        self.service = service
    }

    var currentVersion: MacdoraVersion {
        service.currentVersion
    }

    var repository: String {
        service.repository
    }

    /// Called automatically every time Macdora launches.
    func checkOnLaunch() {
        activeTask?.cancel()
        activeOperationID = UUID()
        activeTask = Task { @MainActor [weak self] in
            await self?.checkForUpdates(manual: false)
        }
    }

    func checkForUpdates(manual: Bool = true) async {
        guard !state.isBusy else { return }
        if let stagedUpdate {
            try? FileManager.default.removeItem(at: stagedUpdate.stagingDirectory)
            self.stagedUpdate = nil
        }
        state = .checking
        do {
            let offer = try await service.checkForUpdates()
            let now = Date()
            lastCheckedAt = now
            if let offer {
                state = .available(offer)
            } else {
                state = .upToDate(checkedAt: now, detail: "已是最新版本")
            }
        } catch is CancellationError {
            state = .idle(lastCheckedAt: lastCheckedAt)
        } catch let error as MacdoraUpdateError {
            state = .failed(message: error.userMessage, retryOffer: nil)
        } catch {
            state = .failed(message: "暂时无法检查更新", retryOffer: nil)
        }
    }

    func startDownload() {
        let targetOffer: MacdoraUpdateOffer?
        switch state {
        case .available(let offer):
            targetOffer = offer
        case .failed(_, let retryOffer):
            targetOffer = retryOffer
        default:
            targetOffer = nil
        }
        guard let offer = targetOffer else { return }

        activeTask?.cancel()
        let opID = UUID()
        activeOperationID = opID
        activeTask = Task { @MainActor [weak self] in
            await self?.performDownload(for: offer, operationID: opID)
        }
    }

    func performDownload(for offer: MacdoraUpdateOffer, operationID: UUID? = nil) async {
        let opID = operationID ?? {
            let id = UUID()
            activeOperationID = id
            return id
        }()
        state = .downloading(
            offer: offer,
            progress: MacdoraDownloadProgress(receivedBytes: 0, totalBytes: offer.asset.size)
        )
        let currentService = service
        do {
            let staged = try await currentService.downloadAndStage(offer: offer) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.activeOperationID == opID, !Task.isCancelled else { return }
                    if case .downloading(let activeOffer, _) = self.state, activeOffer == offer {
                        self.state = .downloading(offer: offer, progress: progress)
                    }
                }
            }
            guard self.activeOperationID == opID, !Task.isCancelled else {
                try? FileManager.default.removeItem(at: staged.stagingDirectory)
                return
            }
            self.stagedUpdate = staged
            self.state = .readyToInstall(staged)
        } catch is CancellationError {
            if self.activeOperationID == opID {
                self.state = .available(offer)
            }
        } catch let error as MacdoraUpdateError {
            if self.activeOperationID == opID {
                self.state = .failed(message: error.userMessage, retryOffer: offer)
            }
        } catch {
            if self.activeOperationID == opID {
                self.state = .failed(message: "下载更新包失败，请点击重试。", retryOffer: offer)
            }
        }
    }

    func cancelDownload() {
        if case .downloading(let offer, _) = state {
            activeOperationID = UUID()
            activeTask?.cancel()
            activeTask = nil
            state = .available(offer)
        }
    }

    func restartAndInstall() {
        guard case .readyToInstall(let staged) = state else { return }
        activeTask?.cancel()
        activeOperationID = UUID()
        activeTask = Task { @MainActor [weak self] in
            await self?.performRestartAndInstall(staged: staged)
        }
    }

    func performRestartAndInstall(staged: MacdoraStagedUpdate) async {
        state = .installing(staged.offer)
        let targetAppURL = targetAppURLProvider()
        do {
            if let prepareForRestart {
                await prepareForRestart()
            }
            try MacdoraUpdateService.replaceAppBundle(at: targetAppURL, with: staged.stagedAppURL)
            try? FileManager.default.removeItem(at: staged.stagingDirectory)
            self.stagedUpdate = nil

            if let relaunchHandler {
                try relaunchHandler(targetAppURL)
            } else {
                let pid = ProcessInfo.processInfo.processIdentifier
                try MacdoraUpdateService.spawnDetachedRelaunch(for: targetAppURL, waitingForPID: pid)
                DispatchQueue.main.async {
                    NSApplication.shared.terminate(nil)
                }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.2) {
                    Darwin.exit(0)
                }
            }
        } catch let error as MacdoraUpdateError {
            state = .failed(message: error.userMessage, retryOffer: staged.offer)
        } catch {
            state = .failed(
                message: MacdoraUpdateError.restartFailed(error.localizedDescription).userMessage,
                retryOffer: staged.offer
            )
        }
    }
}
