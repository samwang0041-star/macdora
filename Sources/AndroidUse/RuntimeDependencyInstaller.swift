import CryptoKit
import Foundation

struct RuntimeEnvironmentDownloadProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case downloading, verifying, preparing }
    let receivedBytes: Int64
    let totalBytes: Int64
    let phase: Phase

    var fraction: Double { totalBytes > 0 ? min(1, max(0, Double(receivedBytes) / Double(totalBytes))) : 0 }
    var percent: Int { min(100, Int(fraction * 100)) }
    var statusText: String {
        switch phase {
        case .downloading: return "下载环境 \(percent)%"
        case .verifying: return "正在校验环境"
        case .preparing: return "正在安装环境"
        }
    }
}

struct RuntimeDependencyArchive: Sendable {
    let url: URL
    let size: Int64
    let sha256: String
    let directory: String
    let destination: String

    // Fixed official artifacts; provenance is recorded in evidence/research/*-downloads.json.
    static let pinned: [Self] = [
        Self(url: URL(string: "https://dl.google.com/android/repository/emulator-darwin_aarch64-16428233.zip")!,
             size: 416_112_708, sha256: "f4c4a142bda54fcec064bdb32b51f19e25bae0a45ad019197ef968bf7a48979b",
             directory: "emulator", destination: "emulator"),
        Self(url: URL(string: "https://dl.google.com/android/repository/platform-tools_r37.0.1-darwin.zip")!,
             size: 16_110_554, sha256: "ee39ad5967e95c2a07f04dbcbde96b1a0c916ba376096db5d2f498b7727a5d1d",
             directory: "platform-tools", destination: "platform-tools"),
        Self(url: URL(string: "https://dl.google.com/android/repository/sys-img/android/arm64-v8a-37.0_r06.zip")!,
             size: 865_756_849, sha256: "ffccd67f6e26b1f4911854ba4e8510b2990ab6c71af33f71864d38bf5d80c57e",
             directory: "arm64-v8a", destination: "image")
    ]

    static var totalDownloadSize: Int64 { pinned.reduce(0) { $0 + $1.size } }
}

enum RuntimeDependencyError: LocalizedError, Equatable {
    case downloadFailed
    case checksumMismatch
    case unsafeArchive
    case extractionFailed
    case invalidEnvironment

    var errorDescription: String? {
        switch self {
        case .downloadFailed: return "环境下载失败，请检查网络后重试。"
        case .checksumMismatch: return "环境下载校验失败，请重新下载。"
        case .unsafeArchive: return "环境安装包无效，未修改已有环境。"
        case .extractionFailed: return "环境解压失败，请检查可用空间后重试。"
        case .invalidEnvironment: return "下载的环境不完整，未修改已有环境。"
        }
    }
}

protocol RuntimeArchiveDownloading: Sendable {
    func download(_ archive: RuntimeDependencyArchive, to destination: URL,
                  onProgress: @escaping @Sendable (Int64) -> Void) async throws
}

struct URLSessionRuntimeArchiveDownloader: RuntimeArchiveDownloading {
    func download(_ archive: RuntimeDependencyArchive, to destination: URL,
                  onProgress: @escaping @Sendable (Int64) -> Void) async throws {
        let download = RuntimeArchiveDownload(archive: archive, destination: destination, progress: onProgress)
        try await download.run()
    }
}

// URLSession writes to disk directly; a multi-gigabyte environment is never buffered in memory.
private final class RuntimeArchiveDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let archive: RuntimeDependencyArchive
    private let destination: URL
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var cancelled = false

    init(archive: RuntimeDependencyArchive, destination: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.archive = archive
        self.destination = destination
        self.progress = progress
    }

    func run() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
                lock.lock()
                guard !cancelled else { lock.unlock(); reply.resume(throwing: CancellationError()); return }
                continuation = reply
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 3_600
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                var request = URLRequest(url: archive.url)
                request.setValue("Macdora", forHTTPHeaderField: "User-Agent")
                let task = session.downloadTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let reply = continuation
        continuation = nil
        let session = session
        self.session = nil
        task = nil
        lock.unlock()
        session?.invalidateAndCancel()
        reply?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= archive.size else {
            finish(.failure(RuntimeDependencyError.checksumMismatch)); return
        }
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  response.statusCode == 200, response.url?.scheme == "https" else {
                throw RuntimeDependencyError.downloadFailed
            }
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard size.map(Int64.init) == archive.size else { throw RuntimeDependencyError.checksumMismatch }
            try FileManager.default.moveItem(at: location, to: destination)
            progress(archive.size)
            finish(.success(()))
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}

struct RuntimeDependencyResolution: Sendable {
    let seed: RuntimeSeed
    let temporaryDirectory: URL?

    func cleanup() {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }
}

struct RuntimeDependencyInstaller: Sendable {
    let archives: [RuntimeDependencyArchive]
    let downloader: any RuntimeArchiveDownloading
    let runner: any ProcessExecuting

    init(archives: [RuntimeDependencyArchive] = RuntimeDependencyArchive.pinned,
         downloader: any RuntimeArchiveDownloading = URLSessionRuntimeArchiveDownloader(),
         runner: any ProcessExecuting = ProcessRunner()) {
        self.archives = archives
        self.downloader = downloader
        self.runner = runner
    }

    static func canReuseEnvironment(seed: RuntimeSeed, paths: RuntimePaths) -> Bool {
        guard let directory = seed.directoryURL,
              let desired = try? RuntimeImageIdentity.read(from: directory.appendingPathComponent("image")),
              let installed = try? RuntimeImageIdentity.read(from: paths.imageURL), desired == installed else { return false }
        return ["emulator/emulator", "platform-tools/adb", "image/system.img", "image/vendor.img",
                "image/kernel-ranchu", "image/ramdisk.img", "image/NOTICE.txt"].allSatisfy {
            FileManager.default.fileExists(atPath: paths.runtimeURL.appendingPathComponent($0).path)
        }
    }

    func resolve(seed: RuntimeSeed, paths: RuntimePaths,
                 onProgress: @escaping @Sendable (RuntimeEnvironmentDownloadProgress) -> Void) async throws -> RuntimeDependencyResolution {
        if seed.bundlesAndroidRuntime || Self.canReuseEnvironment(seed: seed, paths: paths) {
            return RuntimeDependencyResolution(seed: seed, temporaryDirectory: nil)
        }
        try Task.checkCancellation()
        guard let bundledDirectory = seed.directoryURL else { throw RuntimeDependencyError.invalidEnvironment }
        let parent = paths.rootURL.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".\(paths.rootURL.lastPathComponent)-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        do {
            let staging = temporary.appendingPathComponent("seed", isDirectory: true)
            try FileManager.default.copyItem(at: bundledDirectory, to: staging)
            let total = archives.reduce(Int64(0)) { $0 + $1.size }
            var completed: Int64 = 0
            for archive in archives {
                try Task.checkCancellation()
                let downloadURL = temporary.appendingPathComponent(UUID().uuidString + ".zip")
                let prior = completed
                onProgress(.init(receivedBytes: completed, totalBytes: total, phase: .downloading))
                try await downloader.download(archive, to: downloadURL) { received in
                    onProgress(.init(receivedBytes: prior + min(archive.size, max(0, received)), totalBytes: total, phase: .downloading))
                }
                try Task.checkCancellation()
                onProgress(.init(receivedBytes: completed + archive.size, totalBytes: total, phase: .verifying))
                let digest = try await Task.detached(priority: .utility) {
                    try SHA256Digester().sha256(fileURL: downloadURL)
                }.value
                let size = try downloadURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard digest == archive.sha256, size.map(Int64.init) == archive.size else {
                    throw RuntimeDependencyError.checksumMismatch
                }
                try Task.checkCancellation()
                let unpacked = temporary.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: false)
                try await extract(archive, from: downloadURL, to: unpacked)
                let source = unpacked.appendingPathComponent(archive.directory, isDirectory: true)
                let destination = staging.appendingPathComponent(archive.destination, isDirectory: true)
                guard FileManager.default.fileExists(atPath: source.path) else { throw RuntimeDependencyError.invalidEnvironment }
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.moveItem(at: source, to: destination)
                try FileManager.default.removeItem(at: unpacked)
                try FileManager.default.removeItem(at: downloadURL)
                completed += archive.size
            }
            guard let expected = try? RuntimeImageIdentity.read(from: bundledDirectory.appendingPathComponent("image")),
                  try RuntimeImageIdentity.read(from: staging.appendingPathComponent("image")) == expected else {
                throw RuntimeDependencyError.invalidEnvironment
            }
            onProgress(.init(receivedBytes: total, totalBytes: total, phase: .preparing))
            return RuntimeDependencyResolution(seed: RuntimeSeed(directoryURL: staging, scrcpyServerURL: seed.scrcpyServerURL),
                                               temporaryDirectory: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func extract(_ archive: RuntimeDependencyArchive, from file: URL, to destination: URL) async throws {
        let listing = try await runner.run(ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-Z1", file.path],
            environment: [:], timeout: 30, captureOutput: true, outputLimit: 4 * 1024 * 1024))
        guard listing.exitCode == 0, !listing.timedOut,
              let names = String(data: listing.stdout, encoding: .utf8), !names.isEmpty else {
            throw RuntimeDependencyError.unsafeArchive
        }
        var seen = Set<String>()
        for line in names.split(separator: "\n") {
            let name = String(line)
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.first == Substring(archive.directory), !name.hasPrefix("/"), !name.contains("\\"),
                  !parts.contains(".."), !parts.contains("."), seen.insert(name.lowercased()).inserted else {
                throw RuntimeDependencyError.unsafeArchive
            }
        }
        let extracted = try await runner.run(ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", file.path, destination.path],
            environment: [:], timeout: 300, captureOutput: true))
        guard extracted.exitCode == 0, !extracted.timedOut else { throw RuntimeDependencyError.extractionFailed }
        try verifyExtractedFiles(at: destination)
    }

    private func verifyExtractedFiles(at destination: URL) throws {
        if let entries = FileManager.default.enumerator(at: destination, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let url as URL in entries {
                if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                    throw RuntimeDependencyError.unsafeArchive
                }
            }
        }
    }
}
