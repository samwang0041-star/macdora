import AppKit
import QuartzCore
import XCTest
@testable import AndroidUse

final class DocumentationAssetsTests: XCTestCase {
    @MainActor
    func testExportReadmeScreenshotsWhenRequested() async throws {
        guard let directory = ProcessInfo.processInfo.environment["MACDORA_README_ASSETS"] else {
            throw XCTSkip("Set MACDORA_README_ASSETS to export native UI screenshots with demonstration data.")
        }
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.regular)
        let oldTheme = TFTheme.isDark
        TFTheme.isDark = false
        defer { TFTheme.isDark = oldTheme }
        let manager = ManagementWindow()
        let window = try XCTUnwrap(manager.window)
        defer { window.orderOut(nil) }
        window.setContentSize(NSSize(width: 1060, height: 700))
        window.appearance = NSAppearance(named: .aqua)
        let icons = FileManager.default.temporaryDirectory.appendingPathComponent("MacdoraReadmeIcons-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: icons) }
        func icon(_ name: String, symbol: String, color: NSColor) throws -> String {
            let image = NSImage(size: NSSize(width: 96, height: 96))
            image.lockFocus()
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 96, height: 96), xRadius: 22, yRadius: 22).fill()
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.white]))?
                .draw(in: NSRect(x: 21, y: 21, width: 54, height: 54))
            image.unlockFocus()
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let url = icons.appendingPathComponent(name + ".png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
            return url.path
        }
        let notes = try icon("notes", symbol: "note.text", color: .systemOrange)
        let browser = try icon("browser", symbol: "globe", color: .systemBlue)
        manager.update(.ready)
        let demonstrationApps = [
            ContainerApp(package: "local.macdora.notes", name: "便笺", subtitle: "记录生活中的小想法", version: "1.0", category: "办公", iconSymbol: "note.text", accentHex: 0xF5B82E, isSystem: false, isInstalled: true, iconPath: notes),
            ContainerApp(package: "local.macdora.browser", name: "浏览器", subtitle: "在熟悉的窗口里浏览", version: "1.0", category: "生活", iconSymbol: "globe", accentHex: 0x27A8F5, isSystem: false, isInstalled: true, iconPath: browser),
            ContainerApp.metadata(for: DefaultApp.package, isInstalled: true)
        ]
        manager.updateApps(demonstrationApps, activePackage: nil)
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        manager.showWindow(nil)
        func save(_ name: String, in captureWindow: NSWindow? = nil) async throws {
            let targetWindow = captureWindow ?? window
            targetWindow.contentView?.layoutSubtreeIfNeeded()
            targetWindow.displayIfNeeded()
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(150))
            let root = try XCTUnwrap(targetWindow.contentView)
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
        }
        try await save("workspace")
        manager.updateApps([], activePackage: nil)
        manager.updateEnvironmentDownloadNeeded(true)
        manager.update(.preparing("正在准备本地 Android 环境"))
        manager.updateEnvironmentDownloadProgress(.init(receivedBytes: 47, totalBytes: 100, phase: .downloading))
        try await save("environment")
        manager.update(.stopped)
        manager.selectSection(.plugins)
        try await save("plugins")

        // Use a fresh window per appearance: cacheDisplay can reuse stale image backing
        // stores after an appearance change and omit symbols from the exported bitmap.
        TFTheme.isDark = true
        let darkManager = ManagementWindow()
        let darkWindow = try XCTUnwrap(darkManager.window)
        defer { darkWindow.orderOut(nil) }
        darkWindow.setContentSize(try XCTUnwrap(window.contentView).bounds.size)
        darkManager.update(.ready)
        darkManager.updateApps(demonstrationApps, activePackage: nil)
        darkManager.showWindow(nil)
        try await save("workspace-dark", in: darkWindow)
        darkManager.selectSection(.plugins)
        try await save("plugins-dark", in: darkWindow)
    }
}
