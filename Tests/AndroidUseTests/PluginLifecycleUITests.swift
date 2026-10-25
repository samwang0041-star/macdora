import AppKit
import Foundation
import Testing
@testable import AndroidUse

private actor PluginUIDownloadCheckpoint {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private struct PluginUIFetcher: SystemPluginPackageFetching {
    let wrapped: DefaultSystemPluginPackageFetcher
    let checkpoint: PluginUIDownloadCheckpoint

    func fetchRemoteRegistry() async throws -> SystemPluginRemoteRegistry {
        try await wrapped.fetchRemoteRegistry()
    }

    func fetchPluginPackage(
        pluginID: String,
        stagingDirectoryURL: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        onProgress(0.42)
        await checkpoint.wait()
        return try await wrapped.fetchPluginPackage(
            pluginID: pluginID,
            stagingDirectoryURL: stagingDirectoryURL,
            onProgress: onProgress
        )
    }
}

@Suite(.serialized)
@MainActor
struct PluginLifecycleUITests {
    @Test("Native plugin controls preserve settings on disable and confirm deletion before resetting data")
    func nativePluginLifecycle() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("macdora-plugin-ui-\(UUID().uuidString)")
        let suite = "Macdora.PluginLifecycleUI.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let (_, harness) = try SignedArchiveTestHarness.buildSignedLocationPackage(in: root)
        let checkpoint = PluginUIDownloadCheckpoint()
        defer { Task { await checkpoint.release() } }
        let fetcher = PluginUIFetcher(
            wrapped: DefaultSystemPluginPackageFetcher(
                httpTransport: MockGitHubHTTPTransport(registryData: harness.registryData, archiveData: harness.archiveData),
                trustedPublicKeys: [harness.keyID: harness.publicKeyBase64]
            ),
            checkpoint: checkpoint
        )
        let bridge = MockPluginHostBridge()
        let manager = SystemPluginManager(
            rootURL: root,
            defaults: defaults,
            packageFetcher: fetcher,
            additionalTrustedPublicKeys: [harness.keyID: harness.publicKeyBase64],
            locationConsoleTransport: MockLocationConsoleTransport()
        )
        manager.hostBridge = bridge
        let controller = ManagementWindow()
        let window = try #require(controller.window)
        defer { withExtendedLifetime(controller) { window.close() } }
        window.title = "Macdora - Plugin QA"
        controller.bindPluginManager(manager)
        controller.selectSection(.plugins)
        window.setContentSize(window.contentMinSize)
        window.makeKeyAndOrderFront(nil)
        let content = try #require(window.contentView)
        let id = SystemPluginCatalogItem.developerLocationID
        let refreshCatalog = manager.onCatalogChanged
        var progressSamples: [Double] = []
        manager.onCatalogChanged = { items in
            if case .downloading(let progress) = items.first(where: { $0.id == id })?.state {
                progressSamples.append(progress)
            }
            refreshCatalog?(items)
        }

        let download = try #require(button("plugin-download-\(id)", in: content))
        #expect(download.title == "下载")
        try snapshot(window, "01-not-downloaded.png")
        #expect(download.accessibilityPerformPress())
        let progressVisible = await eventually {
            (view("plugin-download-progress-\(id)", in: content) as? TFProgressBarView)?.percent == 42
        }
        try #require(progressVisible, "Download state: \(String(describing: manager.catalogItems().first?.state)); error: \(manager.lastError(for: id) ?? "none")")
        #expect(manager.isPluginBusy(id))
        #expect(button("plugin-delete-\(id)", in: content) == nil)
        try snapshot(window, "02-downloading.png")
        await checkpoint.release()
        try #require(await eventually { manager.isPluginInstalled(id) && !manager.isPluginBusy(id) })
        #expect(progressSamples.count >= 2)
        #expect(progressSamples == progressSamples.sorted())

        #expect(!manager.isPluginEnabled(id))
        #expect(button("plugin-toggle-\(id)", in: content)?.title == "启用")
        try snapshot(window, "03-downloaded-disabled.png")
        let plugin = try #require(manager.locationPlugin(for: id))
        let selected = GeoCoordinate(latitude: 31.236305, longitude: 121.501540, name: "验收保留选点", subtitle: "隔离数据")
        plugin.selectLocation(selected)

        let enable = try #require(button("plugin-toggle-\(id)", in: content))
        #expect(window.makeFirstResponder(enable))
        let space = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: false, keyCode: 49
        ))
        enable.keyDown(with: space)
        try #require(await eventually { manager.isPluginEnabled(id) && !manager.isPluginBusy(id) })
        #expect(button("plugin-toggle-\(id)", in: content)?.title == "停用")
        try snapshot(window, "04-enabled.png")

        controller.openPluginDetailPage(id: id)
        let workspace = try #require(descendants(in: content).first { $0 is DeveloperLocationWorkspaceView })
        let stopCheckpoint = PluginUIDownloadCheckpoint()
        defer { Task { await stopCheckpoint.release() } }
        var stopStarted = false
        bridge.guestScriptHookFilter = { script in
            guard script.contains("AU_LOCATION_ON_DISABLE") else { return true }
            stopStarted = true
            await stopCheckpoint.wait()
            return false
        }
        let failedStop = try #require(descendants(in: content).compactMap { $0 as? TFButton }.first { $0.title == "停用" })
        #expect(failedStop.accessibilityPerformPress())
        try #require(await eventually { manager.isPluginBusy(id) && stopStarted })
        #expect(!failedStop.isEnabled)
        #expect(!failedStop.accessibilityPerformPress())
        #expect(failedStop.title == "处理中…")
        #expect(descendants(in: content).contains { $0 === workspace })
        try snapshot(window, "04a-detail-stopping.png")
        await stopCheckpoint.release()
        try #require(await eventually { !manager.isPluginBusy(id) && manager.lastError(for: id) != nil })
        #expect(manager.isPluginEnabled(id))
        let stopError = try #require(manager.lastError(for: id))
        _ = await plugin.injectSingleTick()
        #expect(labels(in: content).contains(stopError))
        #expect(failedStop.isEnabled)
        #expect(failedStop.title == "停用")
        let errorLabel = try #require(descendants(in: content).compactMap { $0 as? NSTextField }.first { $0.stringValue == stopError })
        #expect(errorLabel.textColor == TFTheme.danger)
        try snapshot(window, "04c-detail-stop-failed.png")
        controller.closePluginDetailPage()
        try snapshot(window, "04b-stop-failed-data-retained.png")
        bridge.guestScriptHookFilter = nil

        let disable = try #require(button("plugin-toggle-\(id)", in: content))
        #expect(disable.accessibilityPerformPress())
        try #require(await eventually { !manager.isPluginEnabled(id) && !manager.isPluginBusy(id) })
        #expect(plugin.configuration.selectedCoordinate.name == selected.name)
        #expect(manager.isPluginInstalled(id))
        try snapshot(window, "05-disabled-data-retained.png")

        let delete = try #require(button("plugin-delete-\(id)", in: content))
        #expect(delete.title == "删除")
        #expect(delete.accessibilityPerformPress())
        let sheet = try #require(window.attachedSheet)
        let sheetContent = try #require(sheet.contentView)
        #expect(labels(in: sheetContent).contains { $0.contains("将删除插件及其数据") })
        sheet.orderFront(nil)
        try #require(await eventually { sheet.isVisible })
        let cancel = try #require(nativeButton("取消", in: sheetContent))
        cancel.performClick(nil)
        try #require(await eventually { window.attachedSheet == nil })
        #expect(manager.isPluginInstalled(id))
        #expect(plugin.configuration.selectedCoordinate.name == selected.name)

        #expect(delete.accessibilityPerformPress())
        let confirmedSheet = try #require(window.attachedSheet?.contentView)
        let confirm = try #require(nativeButton("删除", in: confirmedSheet))
        confirm.performClick(nil)
        try #require(await eventually { !manager.isPluginInstalled(id) && !manager.isPluginBusy(id) })
        #expect(button("plugin-toggle-\(id)", in: content) == nil)
        try snapshot(window, "07-deleted.png")

        let redownload = try #require(button("plugin-download-\(id)", in: content))
        #expect(redownload.accessibilityPerformPress())
        try #require(await eventually { manager.isPluginInstalled(id) && !manager.isPluginBusy(id) })
        #expect(!manager.isPluginEnabled(id))
        #expect(manager.locationPlugin(for: id)?.configuration.selectedCoordinate.name != selected.name)
        try snapshot(window, "08-redownloaded-defaults.png")
        #expect(!labels(in: content).contains("卸载"))
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func view(_ identifier: String, in root: NSView) -> NSView? {
        if root.identifier?.rawValue == identifier { return root }
        for child in root.subviews {
            if let found = view(identifier, in: child) { return found }
        }
        return nil
    }

    private func button(_ identifier: String, in root: NSView) -> TFButton? {
        view(identifier, in: root) as? TFButton
    }

    private func nativeButton(_ title: String, in root: NSView) -> NSButton? {
        if let button = root as? NSButton, button.title == title { return button }
        return root.subviews.compactMap { nativeButton(title, in: $0) }.first
    }

    private func labels(in root: NSView) -> [String] {
        (root as? NSTextField).map { [$0.stringValue] } ?? root.subviews.flatMap { labels(in: $0) }
    }

    private func snapshot(_ window: NSWindow, _ filename: String) throws {
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let controls = descendants(in: content).compactMap { $0 as? TFButton }.filter { $0.identifier?.rawValue.hasPrefix("plugin-") == true }
        for control in controls {
            let rect = control.convert(control.bounds, to: content)
            #expect(rect.width > 20 && rect.height > 20)
            #expect(content.bounds.contains(rect))
        }
        guard let output = ProcessInfo.processInfo.environment["MACDORA_PLUGIN_QA_DIR"] else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rep = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(filename), options: .atomic)
    }

    private func descendants(in root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { descendants(in: $0) }
    }
}
