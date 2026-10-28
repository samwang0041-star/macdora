import AppKit
import Metal
import QuartzCore
import Foundation
import XCTest
@testable import AndroidUse

final class RuntimeDependencyInstallerTests: XCTestCase {
    @MainActor
    func testFreshLightweightAppDownloadsAndPreparesAnIndependentEnvironment() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.remove() }
        let recorder = DownloadRecorder()
        let installer = RuntimeDependencyInstaller(archives: fixture.archives,
            downloader: FixtureArchiveDownloader(files: fixture.files, recorder: recorder))
        let controller = RuntimeController(rootURL: fixture.runtime, seed: fixture.thinSeed, dependencyInstaller: installer)
        try await controller.prepare()
        XCTAssertTrue(controller.isPrepared)
        XCTAssertFalse(controller.needsEnvironmentDownload)
        let count = await recorder.count
        XCTAssertEqual(count, 3)
        XCTAssertEqual(try Data(contentsOf: controller.paths.moltenVKDylibURL), Data("gpu".utf8))
        XCTAssertTrue(fixture.downloadStagingDirectories.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.bundle.appendingPathComponent("emulator").path))
    }

    @MainActor
    func testExistingEnvironmentDoesNotDownloadAgainAndKeepsGuestData() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.remove() }
        let recorder = DownloadRecorder()
        let installer = RuntimeDependencyInstaller(archives: fixture.archives,
            downloader: FixtureArchiveDownloader(files: fixture.files, recorder: recorder))
        let first = RuntimeController(rootURL: fixture.runtime, seed: fixture.thinSeed, dependencyInstaller: installer)
        try await first.prepare()
        let disk = first.paths.avdURL.appendingPathComponent("userdata-qemu.img")
        try Data("saved guest data".utf8).write(to: disk)
        let second = RuntimeController(rootURL: fixture.runtime, seed: fixture.thinSeed, dependencyInstaller: installer)
        try await second.prepare()
        let count = await recorder.count
        XCTAssertEqual(count, 3, "A software upgrade must reuse the installed environment.")
        XCTAssertTrue(second.isPrepared)
        XCTAssertEqual(try Data(contentsOf: disk), Data("saved guest data".utf8))
    }

    func testCorruptDownloadNeverPublishesAndRemovesItsStagingFiles() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.runtime, withIntermediateDirectories: true)
        let marker = fixture.runtime.appendingPathComponent("user-data")
        try Data("keep".utf8).write(to: marker)
        let installer = RuntimeDependencyInstaller(archives: fixture.archives,
            downloader: FixtureArchiveDownloader(files: fixture.files, corrupt: true))
        do {
            _ = try await installer.resolve(seed: fixture.thinSeed, paths: RuntimePaths(rootURL: fixture.runtime)) { _ in }
            XCTFail("Corrupt download must fail.")
        } catch { XCTAssertEqual(error as? RuntimeDependencyError, .checksumMismatch) }
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
        XCTAssertTrue(fixture.downloadStagingDirectories.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.runtime.appendingPathComponent("runtime").path))
    }

    func testCancelledDownloadCleansUpWithoutPreparingAnEnvironment() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.remove() }
        let installer = RuntimeDependencyInstaller(archives: fixture.archives,
            downloader: FixtureArchiveDownloader(files: fixture.files, cancelled: true))
        do {
            _ = try await installer.resolve(seed: fixture.thinSeed, paths: RuntimePaths(rootURL: fixture.runtime)) { _ in }
            XCTFail("Cancelled download must fail.")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(fixture.downloadStagingDirectories.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.runtime.path))
    }

    @MainActor
    func testPreparedOfficialRuntimeBootsAndStopsInIsolationWhenExplicitlyEnabled() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MACDORA_RUNTIME_BOOT_QA"] == "1", let bundlePath = env["MACDORA_QA_APP_BUNDLE"] else {
            throw XCTSkip("Booting an isolated real Android environment is an explicit release acceptance check.")
        }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory.appendingPathComponent("MacdoraBoot-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: workspace) }
        let resource = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/Resources")
        let seedDirectory = workspace.appendingPathComponent("seed")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        func clone(_ source: URL, _ destination: URL) throws {
            let copy = Process();copy.executableURL = URL(fileURLWithPath: "/bin/cp")
            copy.arguments = ["-cR", source.path, destination.path]
            try copy.run();copy.waitUntilExit()
            XCTAssertEqual(copy.terminationStatus, 0)
        }
        try clone(resource.appendingPathComponent("RuntimeSeed"), seedDirectory)
        try fm.removeItem(at: seedDirectory.appendingPathComponent("image"))
        try clone(repo.appendingPathComponent(".runtime/images/aosp-api37-r6/arm64-v8a"), seedDirectory.appendingPathComponent("image"))
        for name in ["emulator", "platform-tools"] {
            try clone(repo.appendingPathComponent(".cache/verified-runtime/" + name), seedDirectory.appendingPathComponent(name))
        }
        let defaultsName = "MacdoraBootQA." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let controller = RuntimeController(rootURL: workspace.appendingPathComponent("runtime"), defaults: defaults,
            connectionPorts: RuntimeConnectionPorts(adb: 5051, emulator: 5590),
            seed: RuntimeSeed(directoryURL: seedDirectory, scrcpyServerURL: resource.appendingPathComponent("scrcpy-server-v5.0.1")))
        controller.cameraEnabled = false
        do {
            try await controller.prepare()
            try await controller.start()
            XCTAssertEqual(controller.state, .ready)
            let endpoint = try await controller.openDisplay(package: DefaultApp.package)
            let stream = VideoStream()
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            let player = ApplicationWindow(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
            defer { stream.stop(); player.performExplicitClose() }
            let session = UUID()
            var presented = false
            var decoded = 0
            var streamError = "none"
            player.surface.beginSession(session)
            player.awaitFirstPresentation()
            player.surface.onFirstFrame = { player.ready(); presented = true }
            stream.decoder.onFrame = { frame in
                DispatchQueue.main.async { decoded += 1; player.surface.accept(frame, session: session) }
            }
            stream.onError = { error in DispatchQueue.main.async { streamError = error.localizedDescription } }
            stream.onSize = { width, height in
                DispatchQueue.main.async {
                    player.surface.pixelSize = CGSize(width: width, height: height)
                    player.syncToPixelSize(CGSize(width: width, height: height))
                }
            }
            player.presentWindow()
            stream.connect(port: endpoint.port, startApp: endpoint.package)
            let deadline = Date(timeIntervalSinceNow: 30)
            while !presented && Date() < deadline {
                while let event = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
                NSApp.updateWindows()
                CATransaction.flush()
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(presented, "System Settings must present through Metal. Decoded frames: \(decoded); stream error: \(streamError)")
            stream.stop()
            player.surface.onFirstFrame = nil
            await controller.closeDisplay()
            await controller.stop()
            XCTAssertEqual(controller.state, .stopped)
        } catch {
            await controller.stop()
            throw error
        }
    }

    @MainActor
    func testFirstUseGuideAndProgressUseTheExistingRuntimeControl() throws {
        let manager = ManagementWindow()
        defer { manager.window?.close() }
        manager.updateEnvironmentDownloadNeeded(true)
        manager.showWindow(nil)
        manager.window?.contentView?.layoutSubtreeIfNeeded()
        func controls(in view: NSView) -> [TFRuntimeControlButton] {
            (view as? TFRuntimeControlButton).map { [$0] } ?? view.subviews.flatMap { controls(in: $0) }
        }
        let button = try XCTUnwrap(manager.window?.contentView.flatMap { controls(in: $0).first })
        XCTAssertEqual(button.mode, .download)
        var requested = false
        manager.onStartRuntime = { requested = true }
        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertTrue(requested)
        try saveSnapshot(manager, name: "environment-download-guide")
        manager.update(.preparing("正在准备本地 Android 环境"))
        let progress = RuntimeEnvironmentDownloadProgress(receivedBytes: 47, totalBytes: 100, phase: .downloading)
        manager.updateEnvironmentDownloadProgress(progress)
        let downloading = try XCTUnwrap(manager.window?.contentView.flatMap { controls(in: $0).first })
        XCTAssertEqual(downloading.mode, .progress(fraction: 0.47, statusText: "下载环境 47%", isStopping: false))
        try saveSnapshot(manager, name: "environment-download-progress")
        manager.update(.failed("下载失败，请重试"))
        manager.update(.preparing("正在准备本地 Android 环境"))
        let retrying = try XCTUnwrap(manager.window?.contentView.flatMap { controls(in: $0).first })
        XCTAssertEqual(retrying.mode, .progress(fraction: 0, statusText: "正在准备环境", isStopping: false))
    }

    @MainActor
    func testOfficialRuntimeDownloadAndFreshPreparationWhenExplicitlyEnabled() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MACDORA_LIVE_RUNTIME_QA"] == "1", let bundlePath = env["MACDORA_QA_APP_BUNDLE"] else {
            throw XCTSkip("Live Google download is an explicit release acceptance check.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacdoraLiveRuntime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/Resources")
        let seed = RuntimeSeed(directoryURL: bundle.appendingPathComponent("RuntimeSeed"),
            scrcpyServerURL: bundle.appendingPathComponent("scrcpy-server-v5.0.1"), bundlesAndroidRuntime: false)
        let recorder = LiveProgressRecorder()
        let controller = RuntimeController(rootURL: root, seed: seed, dependencyInstaller: RuntimeDependencyInstaller())
        let manager = ManagementWindow()
        defer { manager.window?.close() }
        manager.updateEnvironmentDownloadNeeded(true)
        manager.update(.preparing("正在准备本地 Android 环境"))
        manager.showWindow(nil)
        var capturedLiveProgress = false
        controller.onEnvironmentDownloadProgress = { [weak self] progress in
            manager.updateEnvironmentDownloadProgress(progress)
            if let progress {
                recorder.record(progress)
                if progress.phase == .downloading, progress.percent >= 40, !capturedLiveProgress {
                    capturedLiveProgress = true
                    try? self?.saveSnapshot(manager, name: "environment-download-live")
                }
            }
        }
        try await controller.prepare()
        XCTAssertTrue(controller.isPrepared)
        XCTAssertFalse(controller.needsEnvironmentDownload)
        XCTAssertEqual(recorder.maximumDownloadedBytes, RuntimeDependencyArchive.totalDownloadSize)
        XCTAssertGreaterThan(recorder.percents.count, 10)
        if let report = env["MACDORA_RUNTIME_QA_REPORT"] {
            let object: [String: Any] = ["prepared": true, "downloadedBytes": recorder.maximumDownloadedBytes,
                "progressEvents": recorder.percents.count, "finalPercent": recorder.percents.last ?? 0,
                "source": "Google official pinned archives", "businessLoginTested": false]
            try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: report))
        }
    }

    @MainActor
    private func saveSnapshot(_ manager: ManagementWindow, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["MACDORA_RUNTIME_QA_SNAPSHOTS"],
              let view = manager.window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try data.write(to: url.appendingPathComponent(name + ".png"))
    }
}

@MainActor
private final class LiveProgressRecorder {
    var maximumDownloadedBytes: Int64 = 0
    var percents: [Int] = []
    func record(_ progress: RuntimeEnvironmentDownloadProgress) {
        maximumDownloadedBytes = max(maximumDownloadedBytes, progress.receivedBytes)
        if percents.last != progress.percent {
            percents.append(progress.percent)
            if progress.percent % 10 == 0 { print("LIVE_ENVIRONMENT_DOWNLOAD=\(progress.percent)%") }
        }
    }
}

private actor DownloadRecorder {
    var count = 0
    func record() { count += 1 }
}

private struct FixtureArchiveDownloader: RuntimeArchiveDownloading {
    let files: [URL: URL]
    var recorder: DownloadRecorder = DownloadRecorder()
    var corrupt = false
    var cancelled = false
    func download(_ archive: RuntimeDependencyArchive, to destination: URL,
                  onProgress: @escaping @Sendable (Int64) -> Void) async throws {
        await recorder.record()
        onProgress(archive.size / 2)
        if cancelled { throw CancellationError() }
        if corrupt { try Data("corrupted".utf8).write(to: destination) }
        else { try FileManager.default.copyItem(at: XCTUnwrap(files[archive.url]), to: destination) }
        onProgress(archive.size)
    }
}

private struct DownloadFixture {
    let workspace: URL
    let runtime: URL
    let bundle: URL
    let thinSeed: RuntimeSeed
    let archives: [RuntimeDependencyArchive]
    let files: [URL: URL]
    var downloadStagingDirectories: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: workspace.path)) ?? [])
            .filter { $0.hasPrefix(".runtime-download-") }
    }

    init() throws {
        let fm = FileManager.default
        workspace = fm.temporaryDirectory.appendingPathComponent("MacdoraDownload-\(UUID().uuidString)")
        runtime = workspace.appendingPathComponent("runtime")
        bundle = workspace.appendingPathComponent("bundle")
        try fm.createDirectory(at: bundle.appendingPathComponent("image"), withIntermediateDirectories: true)
        let properties = "AndroidVersion.ApiLevel=37.0\nPkg.Revision=6\nSystemImage.Abi=arm64-v8a\nSystemImage.TagId=default\n"
        let build = "ro.build.version.incremental=16571990\n"
        try Data(properties.utf8).write(to: bundle.appendingPathComponent("image/source.properties"))
        try Data(build.utf8).write(to: bundle.appendingPathComponent("image/build.prop"))
        for (name, contents) in [("android-use-ime.apk", "ime"), ("libmaccamera_frame_sync.dylib", "camera"),
                                 ("libMacdoraMoltenVK.dylib", "gpu"), ("scrcpy-server-v5.0.1", "server")] {
            try Data(contents.utf8).write(to: bundle.appendingPathComponent(name))
        }
        thinSeed = RuntimeSeed(directoryURL: bundle, scrcpyServerURL: bundle.appendingPathComponent("scrcpy-server-v5.0.1"),
                               bundlesAndroidRuntime: false)
        var specs: [RuntimeDependencyArchive] = []
        var archiveFiles: [URL: URL] = [:]
        for name in ["emulator", "platform-tools", "image"] {
            let directory = workspace.appendingPathComponent("source-" + name).appendingPathComponent(name)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let entries: [String: String]
            if name == "image" {
                entries = ["system.img": "system", "vendor.img": "vendor", "kernel-ranchu": "kernel", "ramdisk.img": "ramdisk",
                           "source.properties": properties, "build.prop": build, "NOTICE.txt": "notice"]
            } else { entries = [name == "emulator" ? "emulator" : "adb": "#!/bin/sh\nexit 0\n"] }
            for (file, contents) in entries {
                let path = directory.appendingPathComponent(file)
                try Data(contents.utf8).write(to: path)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
            }
            let archive = workspace.appendingPathComponent(name + ".zip")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--keepParent", directory.path, archive.path]
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw RuntimeDependencyError.extractionFailed }
            let url = URL(string: "https://example.invalid/\(name).zip")!
            let size = Int64(try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize!)
            specs.append(.init(url: url, size: size, sha256: try SHA256Digester().sha256(fileURL: archive), directory: name, destination: name))
            archiveFiles[url] = archive
        }
        archives = specs
        files = archiveFiles
    }

    func remove() { try? FileManager.default.removeItem(at: workspace) }
}
