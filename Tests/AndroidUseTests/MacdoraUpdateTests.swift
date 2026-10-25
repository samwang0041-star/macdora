import AppKit
import CryptoKit
import XCTest
@testable import AndroidUse

final class MacdoraUpdateTests: XCTestCase {
    func testInstallationRechecksStagedSignatureAndKeepsExistingAppOnTampering() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacdoraInstallCheck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Macdora.app")
        let incoming = root.appendingPathComponent("Downloaded.app")
        try Self.createMockAppBundle(at: target, version: "0.01", build: "1")
        try Self.createMockAppBundle(at: incoming, version: "0.03", build: "3")
        let executable = incoming.appendingPathComponent("Contents/MacOS/AndroidUse")
        try "#!/bin/sh\necho modified-after-download\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        XCTAssertThrowsError(try MacdoraUpdateService.replaceAppBundle(at: target, with: incoming)) {
            guard case .replaceFailed(let intact, _) = $0 as? MacdoraUpdateError else {
                return XCTFail("Expected a failed install with the existing app preserved.")
            }
            XCTAssertTrue(intact)
        }
        try MacdoraUpdateService.verifyStagedAppBundle(at: target, expectedVersion: .initialRelease)
        let info = try XCTUnwrap(NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist")))
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, "0.01")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.contains(".incoming-") })
    }

    func testUpdateRejectsUnsignedTamperedAndDifferentSigningTeamBundles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacdoraSigningTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let version = try XCTUnwrap(MacdoraVersion("0.03"))
        let unsigned = root.appendingPathComponent("Unsigned.app")
        try Self.createMockAppBundle(at: unsigned, version: "0.03", build: "3", signBundle: false)
        XCTAssertThrowsError(try MacdoraUpdateService.verifyStagedAppBundle(at: unsigned, expectedVersion: version)) {
            XCTAssertEqual($0 as? MacdoraUpdateError, .signatureInvalid)
        }
        let signed = root.appendingPathComponent("Signed.app")
        try Self.createMockAppBundle(at: signed, version: "0.03", build: "3")
        XCTAssertNoThrow(try MacdoraUpdateService.verifyStagedAppBundle(at: signed, expectedVersion: version))
        XCTAssertThrowsError(try MacdoraUpdateService.verifyStagedAppBundle(at: signed, expectedVersion: version, expectedTeamIdentifier: "UNTRUSTEDTEAM")) {
            XCTAssertEqual($0 as? MacdoraUpdateError, .signatureInvalid)
        }
        try "#!/bin/sh\necho changed\n".write(to: signed.appendingPathComponent("Contents/MacOS/AndroidUse"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: signed.appendingPathComponent("Contents/MacOS/AndroidUse").path)
        XCTAssertThrowsError(try MacdoraUpdateService.verifyStagedAppBundle(at: signed, expectedVersion: version)) {
            XCTAssertEqual($0 as? MacdoraUpdateError, .signatureInvalid)
        }
    }

    func testInitialVersionIsZeroPointZeroOneAndVersionOrderingIsConsistent() throws {
        let v001 = try XCTUnwrap(MacdoraVersion("0.01"))
        XCTAssertEqual(v001.displayString, "0.01")
        XCTAssertEqual(v001.tagName, "v0.01")
        XCTAssertEqual(v001, MacdoraVersion.initialRelease)
        XCTAssertEqual(MacdoraVersion.current.displayString, "0.01")

        let v001Tag = try XCTUnwrap(MacdoraVersion("v0.01"))
        XCTAssertEqual(v001, v001Tag)

        let orderedStrings = ["0.01", "0.02", "0.03", "0.09", "0.10", "0.11", "0.20", "0.99", "1.00"]
        let versions = try orderedStrings.map { try XCTUnwrap(MacdoraVersion($0)) }
        for i in 0..<(versions.count - 1) {
            XCTAssertLessThan(
                versions[i],
                versions[i + 1],
                "Expected \(versions[i].displayString) < \(versions[i + 1].displayString)"
            )
        }

        let beta = try XCTUnwrap(MacdoraVersion("v0.02-beta.1"))
        let stable = try XCTUnwrap(MacdoraVersion("v0.02"))
        XCTAssertLessThan(beta, stable)

        // Ambiguous single-digit two-segment version is rejected; three-segment SemVer is monotonic
        XCTAssertNil(MacdoraVersion("0.1"))
        let semver010 = try XCTUnwrap(MacdoraVersion("0.1.0"))
        let semver020 = try XCTUnwrap(MacdoraVersion("0.2.0"))
        let semver0100 = try XCTUnwrap(MacdoraVersion("0.10.0"))
        XCTAssertLessThan(semver010, semver020)
        XCTAssertLessThan(semver020, semver0100)
    }

    @MainActor
    func testFullGitHubUpdateFlowFromCheckToProgressDownloadAndRestartInstall() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("MacdoraUpdateTest-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        // 1. Create an existing installed v0.01 Macdora.app target bundle
        let targetAppURL = tempRoot.appendingPathComponent("Installed/Macdora.app", isDirectory: true)
        try Self.createMockAppBundle(at: targetAppURL, version: "0.01", build: "1")

        // 2. Build a v0.02 release Macdora.app, zip it, and generate its .sha256 manifest
        let releaseBuildDir = tempRoot.appendingPathComponent("ReleaseBuild", isDirectory: true)
        let incomingAppURL = releaseBuildDir.appendingPathComponent("Macdora.app", isDirectory: true)
        try Self.createMockAppBundle(at: incomingAppURL, version: "0.02", build: "2")

        let zipURL = tempRoot.appendingPathComponent("Macdora-0.02-macOS-arm64.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", incomingAppURL.path, zipURL.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)

        let zipData = try Data(contentsOf: zipURL)
        let zipSHA256 = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
        let shaURL = tempRoot.appendingPathComponent("Macdora-0.02-macOS-arm64.zip.sha256")
        try "\(zipSHA256)  Macdora-0.02-macOS-arm64.zip\n".write(to: shaURL, atomically: true, encoding: .utf8)

        // 3. Create GitHub Releases JSON feed containing v0.01 and v0.02
        let feedURL = tempRoot.appendingPathComponent("releases.json")
        let feedJSON = """
        [
          {
            "tag_name": "v0.02",
            "name": "Macdora 0.02",
            "draft": false,
            "prerelease": false,
            "html_url": "https://github.com/samwang0041-star/macdora/releases/tag/v0.02",
            "published_at": "2026-10-26T08:00:00Z",
            "body": "新增性能优化与体验升级",
            "assets": [
              {
                "id": 101,
                "name": "Macdora-0.02-macOS-arm64.zip",
                "browser_download_url": "\(zipURL.absoluteString)",
                "size": \(zipData.count),
                "state": "uploaded"
              },
              {
                "id": 102,
                "name": "Macdora-0.02-macOS-arm64.zip.sha256",
                "browser_download_url": "\(shaURL.absoluteString)",
                "size": 96,
                "state": "uploaded"
              }
            ]
          },
          {
            "tag_name": "v0.01",
            "name": "Macdora 0.01",
            "draft": false,
            "prerelease": false,
            "html_url": "https://github.com/samwang0041-star/macdora/releases/tag/v0.01",
            "body": "首个正式版本",
            "assets": []
          }
        ]
        """
        try feedJSON.write(to: feedURL, atomically: true, encoding: .utf8)

        let service = MacdoraUpdateService(
            transport: URLSessionMacdoraUpdateTransport(),
            currentVersion: .initialRelease,
            repository: "samwang0041-star/macdora",
            feedURLOverride: feedURL
        )
        let controller = MacdoraUpdateController(service: service)
        var observedStates: [MacdoraUpdateState] = []
        controller.onStateChange = { state in
            observedStates.append(state)
        }

        // Step A: Startup check detects v0.02 > v0.01
        await controller.checkForUpdates(manual: false)
        guard case .available(let offer) = controller.state else {
            return XCTFail("Expected .available state, got \(controller.state)")
        }
        XCTAssertEqual(offer.version.displayString, "0.02")
        XCTAssertEqual(offer.tagName, "v0.02")

        // Step B: Click update -> download reports progressive percentages (0% .. 100%) and stages bundle
        await controller.performDownload(for: offer)
        guard case .readyToInstall(let staged) = controller.state else {
            return XCTFail("Expected .readyToInstall state, got \(controller.state)")
        }
        XCTAssertEqual(staged.archiveSHA256, zipSHA256)

        let recordedPercents: [Int] = observedStates.compactMap { state in
            if case .downloading(_, let progress) = state {
                return progress.percent
            }
            return nil
        }
        XCTAssertFalse(recordedPercents.isEmpty, "Should emit downloading progress updates")
        XCTAssertEqual(recordedPercents.first, 0)
        XCTAssertEqual(recordedPercents.last, 100)
        for i in 0..<(recordedPercents.count - 1) {
            XCTAssertLessThanOrEqual(recordedPercents[i], recordedPercents[i + 1], "Progress percentage must be monotonic")
        }

        // Step C: Click restart to auto-install -> prepares runtime, replaces bundle on disk, and relaunches
        var didPrepareForRestart = false
        var relaunchedURL: URL?
        controller.prepareForRestart = {
            didPrepareForRestart = true
        }
        controller.targetAppURLProvider = { targetAppURL }
        controller.relaunchHandler = { url in
            relaunchedURL = url
        }

        await controller.performRestartAndInstall(staged: staged)
        XCTAssertTrue(didPrepareForRestart)
        XCTAssertEqual(relaunchedURL?.standardizedFileURL, targetAppURL.standardizedFileURL)

        let updatedPlist = try XCTUnwrap(
            NSDictionary(contentsOf: targetAppURL.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        )
        XCTAssertEqual(updatedPlist["CFBundleShortVersionString"] as? String, "0.02")
        XCTAssertEqual(updatedPlist["CFBundleVersion"] as? String, "2")

        // Step D: Fail-closed SHA-256 verification rejects missingchecksum or tampered manifest
        let unverifiedOffer = MacdoraUpdateOffer(
            version: offer.version,
            tagName: offer.tagName,
            title: offer.title,
            notes: offer.notes,
            publishedAt: offer.publishedAt,
            htmlURL: offer.htmlURL,
            asset: offer.asset,
            checksumAsset: nil
        )
        await controller.performDownload(for: unverifiedOffer)
        if case .failed(let msg, _) = controller.state {
            XCTAssertEqual(msg, MacdoraUpdateError.checksumMismatch.userMessage)
        } else {
            XCTFail("Expected .failed when checksumAsset is nil, got \(controller.state)")
        }

        // Step E: Manifest filename mismatch is rejected fail-closed
        let wrongFileManifest = Data("\(zipSHA256)  other-file.zip\n".utf8)
        XCTAssertNil(
            MacdoraGitHubFeed.parseSHA256Manifest(
                wrongFileManifest,
                expectedAssetName: "Macdora-0.02-macOS-arm64.zip"
            )
        )

        // Step F: Replacement failure keeps existing bundle intact and reports honest message
        let missingStagedURL = tempRoot.appendingPathComponent("NonExistent/Macdora.app")
        XCTAssertThrowsError(try MacdoraUpdateService.replaceAppBundle(at: targetAppURL, with: missingStagedURL)) { err in
            guard case MacdoraUpdateError.replaceFailed(let intact, _) = err else {
                return XCTFail("Expected replaceFailed, got \(err)")
            }
            XCTAssertTrue(intact, "Existing bundle should remain intact when staging fails")
        }
    }

    @MainActor
    func testAboutMacdoraPageAndUpdateProgressBarRenderCorrectly() throws {
        _ = NSApplication.shared
        let manager = ManagementWindow()
        let window = try XCTUnwrap(manager.window)
        defer { window.close() }

        manager.selectSection(.about)
        manager.updateAppUpdateState(
            .upToDate(
                checkedAt: Date(),
                detail: "已是最新版本"
            )
        )
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        let snapDir = ProcessInfo.processInfo.environment["MACDORA_UPDATE_SNAPSHOT_DIR"]
        if let snapDir {
            Self.saveWindowSnapshot(window, to: URL(fileURLWithPath: snapDir).appendingPathComponent("macdora-about-v0.01.png"))
        }

        XCTAssertNotNil(findView(withIdentifier: "macdora-about-hero-card", in: root))
        XCTAssertNotNil(findView(withIdentifier: "macdora-about-version-pill", in: root))
        XCTAssertNotNil(findView(withIdentifier: "macdora-check-update-button", in: root))

        let offer = MacdoraUpdateOffer(
            version: try XCTUnwrap(MacdoraVersion("0.02")),
            tagName: "v0.02",
            title: "Macdora v0.02",
            notes: "支持 GitHub 自动更新与进度条下载",
            publishedAt: "2026-10-26",
            htmlURL: URL(string: "https://github.com/samwang0041-star/macdora/releases/tag/v0.02")!,
            asset: MacdoraReleaseAsset(
                id: 1,
                name: "Macdora-0.02-macOS-arm64.zip",
                browserDownloadURL: URL(string: "https://github.com/samwang0041-star/macdora/releases/download/v0.02/Macdora-0.02-macOS-arm64.zip")!,
                size: 20 * 1024 * 1024,
                state: "uploaded"
            ),
            checksumAsset: nil
        )

        // 1. Available state shows "点击更新" button
        manager.updateAppUpdateState(.available(offer))
        root.layoutSubtreeIfNeeded()
        if let snapDir {
            Self.saveWindowSnapshot(window, to: URL(fileURLWithPath: snapDir).appendingPathComponent("macdora-update-available.png"))
        }
        XCTAssertNotNil(findView(withIdentifier: "macdora-start-update-button", in: root))

        // 2. Downloading state shows progress bar + percentage label (68%)
        let progress = MacdoraDownloadProgress(receivedBytes: Int64(13.6 * 1024 * 1024), totalBytes: 20 * 1024 * 1024)
        manager.updateAppUpdateState(.downloading(offer: offer, progress: progress))
        root.layoutSubtreeIfNeeded()
        if let snapDir {
            Self.saveWindowSnapshot(window, to: URL(fileURLWithPath: snapDir).appendingPathComponent("macdora-update-downloading-68pct.png"))
        }
        let bar = try XCTUnwrap(findView(withIdentifier: "macdora-update-progress-bar", in: root) as? TFProgressBarView)
        XCTAssertEqual(bar.percent, 68)
        let pctLabel = try XCTUnwrap(findView(withIdentifier: "macdora-update-percent-label", in: root) as? NSTextField)
        XCTAssertEqual(pctLabel.stringValue, "68%")

        // 3. ReadyToInstall state shows 100% progress bar + "点击重启自动安装" button
        let staged = MacdoraStagedUpdate(
            offer: offer,
            stagingDirectory: URL(fileURLWithPath: "/tmp/macdora-stage"),
            stagedAppURL: URL(fileURLWithPath: "/tmp/macdora-stage/Macdora.app"),
            archiveSHA256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        manager.updateAppUpdateState(.readyToInstall(staged))
        root.layoutSubtreeIfNeeded()
        if let snapDir {
            Self.saveWindowSnapshot(window, to: URL(fileURLWithPath: snapDir).appendingPathComponent("macdora-update-ready-restart.png"))
        }
        let completedBar = try XCTUnwrap(findView(withIdentifier: "macdora-update-progress-bar", in: root) as? TFProgressBarView)
        XCTAssertEqual(completedBar.percent, 100)
        XCTAssertTrue(completedBar.isCompleted)
        XCTAssertNotNil(findView(withIdentifier: "macdora-restart-install-button", in: root))
    }

    @MainActor
    private static func saveWindowSnapshot(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext {
            let dots: [(CGFloat, UInt32, UInt32)] = [
                (13, 0xFF5F57, 0xE0443E),
                (33, 0xFEBC2E, 0xD89E24),
                (53, 0x28C840, 0x1AAB29)
            ]
            for (x, fillHex, strokeHex) in dots {
                let rect = CGRect(x: x, y: bounds.height - 22, width: 12, height: 12)
                ctx.setFillColor(MacdoraBrand.rgba(fillHex))
                ctx.fillEllipse(in: rect)
                ctx.setStrokeColor(MacdoraBrand.rgba(strokeHex, 0.55))
                ctx.setLineWidth(0.5)
                ctx.strokeEllipse(in: rect)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url, options: .atomic)
        }
    }

    private static func createMockAppBundle(at appURL: URL, version: String, build: String, signBundle: Bool = true) throws {
        let fm = FileManager.default
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macosURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try fm.createDirectory(at: macosURL, withIntermediateDirectories: true)

        let execURL = macosURL.appendingPathComponent("AndroidUse")
        try "#!/bin/sh\nexit 0\n".write(to: execURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: execURL.path)

        let info: [String: Any] = [
            "CFBundleIdentifier": "local.androiduse.app",
            "CFBundleName": "Macdora",
            "CFBundleDisplayName": "Macdora",
            "CFBundleExecutable": "AndroidUse",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"), options: .atomic)
        guard signBundle else { return }
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", appURL.path]
        sign.standardOutput = Pipe()
        sign.standardError = Pipe()
        try sign.run()
        sign.waitUntilExit()
        guard sign.terminationStatus == 0 else { throw MacdoraUpdateError.signatureInvalid }
    }

    @MainActor
    private func findView(withIdentifier id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        for sub in view.subviews {
            if let match = findView(withIdentifier: id, in: sub) {
                return match
            }
        }
        return nil
    }
}
