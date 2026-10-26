import AppKit
import XCTest
@testable import AndroidUse

final class AppDockPresentationTests: XCTestCase {
    func testLaunchOptionDefaultsToApplicationIconAndAllowsMacdoraIcon() {
        XCTAssertEqual(AppDockIconMode.parse(arguments: ["Macdora"]), .application)
        XCTAssertEqual(AppDockIconMode.parse(arguments: ["Macdora", "--dock-icon", "app"]), .application)
        XCTAssertEqual(AppDockIconMode.parse(arguments: ["Macdora", "--dock-icon", "macdora"]), .macdora)
        XCTAssertEqual(AppDockIconMode.parse(arguments: ["Macdora", "--dock-icon=macdora"]), .macdora)
        XCTAssertEqual(AppDockIconMode.parse(arguments: ["Macdora", "--dock-icon"]), .application)
        XCTAssertEqual(AppDockIconMode.parse(arguments: ["Macdora", "--dock-icon", "unknown"]), .application)
    }

    @MainActor
    func testDockEntryUsesAppIconAndRestoresBrandWhenSessionEnds() throws {
        _ = NSApplication.shared
        let previousIcon = NSApp.applicationIconImage
        let previousBadge = NSApp.dockTile.badgeLabel
        defer { NSApp.applicationIconImage = previousIcon; NSApp.dockTile.badgeLabel = previousBadge }
        let presentation = AppDockPresentation(mode: .application)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let iconURL = directory.appendingPathComponent("notes.png")
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 64).fill()
        image.unlockFocus()
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: iconURL)
        var app = ContainerApp.metadata(for: "org.example.notes")
        app.name = "Notes"
        app.iconPath = iconURL.path
        presentation.update(app: app)
        let appIcon = try XCTUnwrap(NSApp.applicationIconImage.tiffRepresentation)
        let dockRep = try XCTUnwrap(NSBitmapImageRep(data: appIcon))
        let center = try XCTUnwrap(dockRep.colorAt(x: dockRep.pixelsWide / 2, y: dockRep.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(center.redComponent, 0.9)
        XCTAssertGreaterThan(center.redComponent - center.blueComponent, 0.5)
        XCTAssertLessThan(try XCTUnwrap(dockRep.colorAt(x: 0, y: 0)).alphaComponent, 0.1)
        XCTAssertNil(NSApp.dockTile.badgeLabel, "Application identity must not look like an unread-message badge.")
        presentation.update(app: nil)
        XCTAssertNotEqual(NSApp.applicationIconImage.tiffRepresentation, appIcon)
        XCTAssertNil(NSApp.dockTile.badgeLabel)
    }

    @MainActor
    func testMacdoraIconOptionKeepsBrandWhenApplicationOpens() {
        _ = NSApplication.shared
        let previousIcon = NSApp.applicationIconImage
        let previousBadge = NSApp.dockTile.badgeLabel
        defer { NSApp.applicationIconImage = previousIcon; NSApp.dockTile.badgeLabel = previousBadge }
        NSApp.dockTile.badgeLabel = "Previous app"
        AppDockPresentation(mode: .macdora).update(app: ContainerApp.metadata(for: "org.example.notes"))
        XCTAssertNil(NSApp.dockTile.badgeLabel)
        XCTAssertNotNil(NSApp.applicationIconImage)
    }
}
