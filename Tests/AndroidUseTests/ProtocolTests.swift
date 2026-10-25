import XCTest
import AppKit
import Metal
@testable import AndroidUse

final class ProtocolTests: XCTestCase {
    func testTouchCoordinatesKeepRetinaPointsSeparateFromGuestPixels() {
        let geometry = SurfaceGeometry(bounds: CGRect(x: 0, y: 0, width: 800, height: 800), pixels: CGSize(width: 1080, height: 1920))
        XCTAssertEqual(geometry.contentRect.width, 450)
        XCTAssertNil(geometry.guestPoint(CGPoint(x: 10, y: 200)))
        XCTAssertEqual(geometry.guestPoint(CGPoint(x: 400, y: 400)), CGPoint(x: 540, y: 960))
        let clamped = geometry.guestPoint(CGPoint(x: 900, y: 900), clamp: true)
        XCTAssertEqual(clamped, CGPoint(x: 1079, y: 1919))
    }

    func testTouchMatchesPinnedServerWireLayout() {
        let bytes = Wire.touch(action: 0, x: 100, y: 200, width: 1080, height: 1920)
        XCTAssertEqual(bytes.count, 32)
        XCTAssertEqual(Array(bytes.prefix(2)), [2, 0])
        XCTAssertEqual(Wire.read(bytes, at: 10, as: UInt32.self), 100)
        XCTAssertEqual(Wire.read(bytes, at: 14, as: UInt32.self), 200)
        XCTAssertEqual(Wire.read(bytes, at: 18, as: UInt16.self), 1080)
        XCTAssertEqual(Wire.read(bytes, at: 20, as: UInt16.self), 1920)
        XCTAssertEqual(Wire.read(bytes, at: 22, as: UInt16.self), 65535)
        let up = Wire.touch(action: 1, x: 100, y: 200, width: 1080, height: 1920)
        XCTAssertEqual(Wire.read(up, at: 22, as: UInt16.self), 0)
    }

    func testChineseClipboardPayloadUsesUTF8ByteLength() {
        let bytes = Wire.paste("中文", sequence: 42)
        XCTAssertEqual(Wire.read(bytes, at: 1, as: UInt64.self), 42)
        XCTAssertEqual(bytes[9], 1)
        XCTAssertEqual(Wire.read(bytes, at: 10, as: UInt32.self), 6)
        XCTAssertEqual(String(data: bytes.dropFirst(14), encoding: .utf8), "中文")
    }

    func testAnnexBHandlesMixedStartCodesWithoutEmptyNALs() {
        let packet = Data([0, 0, 0, 1, 0x67, 10, 0, 0, 1, 0x68, 11, 0, 0, 0, 1])
        XCTAssertEqual(AnnexB.units(packet), [Data([0x67, 10]), Data([0x68, 11])])
    }

    func testTabletModeCommandLineAndPreferences() throws {
        var prefs = ContainerPreferences.default
        XCTAssertFalse(prefs.tabletMode)
        XCTAssertEqual(prefs.preferredPixelSize, CGSize(width: 1080, height: 1920))
        let phoneCmd = RuntimePorts.commandLine(scid: 0x12345678, resolutionPreset: "1080p", targetFPS: 60, tabletMode: false)
        XCTAssertTrue(phoneCmd.contains("new_display=1080x1920/420"))

        prefs.tabletMode = true
        XCTAssertEqual(prefs.preferredPixelSize, CGSize(width: 1920, height: 1200))
        let tabletCmd = RuntimePorts.commandLine(scid: 0x12345678, resolutionPreset: "1080p", targetFPS: 60, tabletMode: true)
        XCTAssertTrue(tabletCmd.contains("new_display=1920x1200/240"))
    }

    @MainActor
    func testApplicationWindowCloseMiniaturizesUnlessExplicit() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let appWin = ApplicationWindow(device: device)
        let nsWin = try XCTUnwrap(appWin.window)
        XCTAssertFalse(appWin.windowShouldClose(nsWin))

        var didExplicitClose = false
        appWin.onClose = { didExplicitClose = true }
        appWin.performExplicitClose()
        XCTAssertTrue(didExplicitClose)
    }

    @MainActor
    func testApplicationWindowZoomPreservesPhoneAndTabletAspectRatio() throws {
        _ = NSApplication.shared
        let appWin = ApplicationWindow(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let nsWin = try XCTUnwrap(appWin.window)
        defer { appWin.performExplicitClose() }

        for pixels in [CGSize(width: 1080, height: 1920), CGSize(width: 1920, height: 1200)] {
            appWin.applyDisplayMode(tabletMode: pixels.width > pixels.height, preferredPixelSize: pixels)
            nsWin.zoom(nil)
            nsWin.contentView?.layoutSubtreeIfNeeded()
            let surface = appWin.surface.bounds.size
            XCTAssertEqual(surface.width / surface.height, pixels.width / pixels.height, accuracy: 0.002)
            let screen = try XCTUnwrap((nsWin.screen ?? NSScreen.main)?.visibleFrame)
            XCTAssertLessThanOrEqual(nsWin.frame.width, screen.width + 1)
            XCTAssertLessThanOrEqual(nsWin.frame.height, screen.height + 1)
        }
    }
}
