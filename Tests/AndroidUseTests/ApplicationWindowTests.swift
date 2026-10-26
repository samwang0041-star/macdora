import AppKit
import Metal
import QuartzCore
import CoreVideo
import XCTest
@testable import AndroidUse

final class ApplicationWindowTests: XCTestCase {
    @MainActor
    func testApplicationActivationRedrawsStaticCachedFrameWithoutNewDecode() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let controller = ApplicationWindow(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        defer { controller.surface.onRenderPath = nil; controller.performExplicitClose() }
        controller.presentWindow()
        let session = UUID()
        controller.surface.beginSession(session)
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer), kCVReturnSuccess)
        let image = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(image, [])
        memset(CVPixelBufferGetBaseAddress(image), 255, CVPixelBufferGetBytesPerRow(image) * 64)
        CVPixelBufferUnlockBaseAddress(image, [])
        var rendered = false
        controller.surface.onRenderPath = { _ in rendered = true }
        controller.surface.accept(DecodedFrame(buffer: image, pts: 0, marker: nil), session: session)
        let initialDeadline = Date(timeIntervalSinceNow: 3)
        while !rendered && Date() < initialDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(rendered)
        try await Task.sleep(for: .milliseconds(100))
        var redraws = 0
        controller.surface.onRenderPath = { _ in redraws += 1 }
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        let redrawDeadline = Date(timeIntervalSinceNow: 0.5)
        while redraws == 0 && Date() < redrawDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(redraws, 0, "Activation must refresh a static frame without waiting for decoder output.")
    }

    @MainActor
    func testStartupMinimizeRestorePresentsCachedFrameBeforeEnablingInput() async throws {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let controller = ApplicationWindow(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let window = try XCTUnwrap(controller.window)
        defer { controller.surface.onFirstFrame = nil; controller.performExplicitClose() }
        controller.loading("Waiting for frame")
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        window.miniaturize(nil)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(window.isMiniaturized)
        let session = UUID()
        controller.surface.beginSession(session)
        var firstPresentations = 0
        var renderPaths: [String] = []
        var rejected: [Double] = []
        controller.surface.onRenderPath = { renderPaths.append($0) }
        controller.surface.onInvalidPresentation = { rejected.append($0) }
        controller.surface.onFirstFrame = {
            firstPresentations += 1
            controller.ready()
        }
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer), kCVReturnSuccess)
        let image = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(image, [])
        memset(CVPixelBufferGetBaseAddress(image), 255, CVPixelBufferGetBytesPerRow(image) * 64)
        CVPixelBufferUnlockBaseAddress(image, [])
        controller.awaitFirstPresentation()
        controller.surface.accept(DecodedFrame(buffer: image, pts: 0, marker: nil), session: session)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(firstPresentations, 0)
        XCTAssertFalse(controller.surface.inputEnabled)
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        let deadline = Date(timeIntervalSinceNow: 3)
        while firstPresentations == 0 && Date() < deadline {
            while let event = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            NSApp.updateWindows()
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(renderPaths.contains("metal-bgra"))
        XCTAssertTrue(rejected.isEmpty)
        XCTAssertEqual(firstPresentations, 1, "Restoring the window must present its cached frame without a new decoder output.")
        XCTAssertTrue(controller.surface.inputEnabled)
        controller.failure("Stream ended")
        XCTAssertFalse(controller.surface.videoVisible)
        XCTAssertFalse(controller.surface.inputEnabled)
    }

    @MainActor
    func testPhoneResizeUsesNativeAspectConstraintOnVideoOnlyContent() throws {
        _ = NSApplication.shared
        let controller = ApplicationWindow(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let window = try XCTUnwrap(controller.window)
        defer { controller.performExplicitClose() }

        controller.applyDisplayMode(tabletMode: false, preferredPixelSize: CGSize(width: 1080, height: 1920))
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(window.contentAspectRatio.width / window.contentAspectRatio.height, 9.0 / 16.0, accuracy: 0.0001)
        XCTAssertEqual(controller.surface.bounds.size, window.contentView?.bounds.size)
        XCTAssertFalse(window.titlebarAccessoryViewControllers.isEmpty)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(window.titlebarAccessoryViewControllers.first).view.bounds.height, 28)
        // A resize delegate is insufficient: AppKit can constrain a single axis
        // before/after it runs. The native aspect constraint must own this path.
        XCTAssertFalse(controller.responds(to: #selector(NSWindowDelegate.windowWillResize(_:to:))))
    }

    @MainActor
    func testTabletRotationUpdatesNativeRatioAndMatchingSizeLimits() throws {
        _ = NSApplication.shared
        let controller = ApplicationWindow(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let window = try XCTUnwrap(controller.window)
        defer { controller.performExplicitClose() }

        for pixels in [CGSize(width: 1920, height: 1200), CGSize(width: 1200, height: 1920), CGSize(width: 1080, height: 1920)] {
            controller.applyDisplayMode(tabletMode: pixels.width != 1080, preferredPixelSize: pixels)
            window.contentView?.layoutSubtreeIfNeeded()
            let aspect = pixels.width / pixels.height
            XCTAssertEqual(window.contentAspectRatio.width / window.contentAspectRatio.height, aspect, accuracy: 0.0001)
            XCTAssertEqual(window.contentMinSize.width / window.contentMinSize.height, aspect, accuracy: 0.002)
            XCTAssertEqual(window.contentMaxSize.width / window.contentMaxSize.height, aspect, accuracy: 0.002)
            XCTAssertEqual(controller.surface.bounds.width / controller.surface.bounds.height, aspect, accuracy: 0.002)
        }
    }

    @MainActor
    func testSmallestVisibleWindowKeepsVideoFlushWithEveryEdge() throws {
        _ = NSApplication.shared
        let controller = ApplicationWindow(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let window = try XCTUnwrap(controller.window)
        defer { controller.performExplicitClose() }
        controller.configureForApp(ContainerApp.metadata(for: DemoApp.package))
        controller.updateFPSBadge(60)
        window.orderFront(nil)

        for pixels in [CGSize(width: 1080, height: 1920), CGSize(width: 1920, height: 1200)] {
            controller.applyDisplayMode(tabletMode: pixels.width > pixels.height, preferredPixelSize: pixels)
            window.setContentSize(window.contentMinSize)
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            window.contentView?.layoutSubtreeIfNeeded()
            let metal = try XCTUnwrap(controller.surface.layer?.sublayers?.compactMap { $0 as? CAMetalLayer }.first)
            XCTAssertEqual(controller.surface.bounds.width / controller.surface.bounds.height, pixels.width / pixels.height, accuracy: 0.002)
            XCTAssertEqual(metal.frame.width, controller.surface.bounds.width, accuracy: 1)
            XCTAssertEqual(metal.frame.height, controller.surface.bounds.height, accuracy: 1)
        }
    }

    @MainActor
    func testRuntimeOperationCloseDoesNotApplyUserClosePolicy() throws {
        _ = NSApplication.shared
        let controller = ApplicationWindow(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var closeCallbacks = 0
        controller.onClose = { closeCallbacks += 1 }

        controller.performRuntimeOperationClose()
        XCTAssertEqual(closeCallbacks, 0)

        controller.showWindow(nil)
        controller.performExplicitClose()
        XCTAssertEqual(closeCallbacks, 1)
    }

    @MainActor
    func testVideoViewportNeverStretchesAndKeepsSourceResolutionWhileResizing() throws {
        let surface = AndroidSurfaceView(frame: NSRect(x: 0, y: 0, width: 413, height: 734), device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        surface.pixelSize = CGSize(width: 1080, height: 1920)

        for size in [CGSize(width: 413, height: 530), CGSize(width: 300, height: 533), CGSize(width: 750, height: 420)] {
            surface.setFrameSize(size)
            surface.needsLayout = true
            surface.layoutSubtreeIfNeeded()
            let metal = try XCTUnwrap(surface.layer?.sublayers?.compactMap { $0 as? CAMetalLayer }.first)
            XCTAssertEqual(metal.frame.width / metal.frame.height, 9.0 / 16.0, accuracy: 0.0001)
            XCTAssertEqual(metal.drawableSize, surface.pixelSize)
            XCTAssertLessThanOrEqual(metal.frame.width, size.width + 0.001)
            XCTAssertLessThanOrEqual(metal.frame.height, size.height + 0.001)
        }
    }

    @MainActor
    func testManagementWindowUsesRealAppIconsAndExposesUninstallForInstalledUserApps() throws {
        _ = NSApplication.shared
        let iconDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macdora-icon-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: iconDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: iconDirectory) }
        let fixtureIconURL = iconDirectory.appendingPathComponent("fixture.png")
        let fixtureImage = NSImage(size: NSSize(width: 8, height: 8))
        fixtureImage.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        fixtureImage.unlockFocus()
        let rep = try XCTUnwrap(fixtureImage.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: fixtureIconURL)

        let manager = ManagementWindow()
        let window = try XCTUnwrap(manager.window)
        defer { window.close() }

        let fixtureApp = ContainerApp.metadata(
            for: "com.example.fixture",
            isInstalled: true,
            iconPath: fixtureIconURL.path
        )
        let fallbackApp = ContainerApp.metadata(
            for: "com.example.fallback",
            isInstalled: true,
            includeBundledResources: false
        )
        let fixtureView = TFAppIconView(app: fixtureApp, size: 18)
        let fallbackView = TFAppIconView(app: fallbackApp, size: 18)
        XCTAssertTrue(fixtureView.hasOwnAppIcon, "Expected temporary image fixture to be used.")
        XCTAssertNotNil(fixtureView.imageView.image)
        XCTAssertFalse(fallbackView.hasOwnAppIcon, "Missing images must use the system fallback.")
        XCTAssertNotNil(fallbackView.imageView.image)

        let apps = [
            ContainerApp.metadata(
                for: "com.sankuai.meituan.takeoutnew",
                isInstalled: true,
                iconPath: fixtureIconURL.path
            ),
            ContainerApp.metadata(
                for: DemoApp.package,
                isInstalled: true,
                iconPath: fixtureIconURL.path
            )
        ]
        manager.update(.ready)
        manager.updateApps(apps, activePackage: nil)
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()

        for pkg in ["com.sankuai.meituan.takeoutnew", DemoApp.package] {
            let row = try XCTUnwrap(findView(withIdentifier: "app-row-\(pkg)", in: root))
            let iconView = try XCTUnwrap(findFirstSubview(ofType: TFAppIconView.self, in: row))
            XCTAssertTrue(iconView.hasOwnAppIcon, "Expected temporary image fixture for \(pkg)")
            XCTAssertNotNil(iconView.imageView.image)
        }
        XCTAssertNotNil(findView(withIdentifier: "uninstall-com.sankuai.meituan.takeoutnew", in: root))
        XCTAssertNotNil(findView(withIdentifier: "uninstall-\(DemoApp.package)", in: root))

        if let snapPath = ProcessInfo.processInfo.environment["ANDROID_USE_TEST_SNAPSHOT"],
           let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: snapPath), options: .atomic)
            }
        }

        let appsAfterUninstall = [
            ContainerApp.metadata(
                for: DemoApp.package,
                isInstalled: true,
                iconPath: fixtureIconURL.path
            )
        ]
        manager.updateApps(appsAfterUninstall, activePackage: nil)
        root.layoutSubtreeIfNeeded()
        XCTAssertNil(findView(withIdentifier: "uninstall-com.sankuai.meituan.takeoutnew", in: root), "Uninstalled app should not show uninstall")
    }

    @MainActor
    private func findView(withIdentifier id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        for subview in view.subviews {
            if let match = findView(withIdentifier: id, in: subview) {
                return match
            }
        }
        return nil
    }

    @MainActor
    private func findFirstSubview<T: NSView>(ofType type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = findFirstSubview(ofType: type, in: subview) {
                return match
            }
        }
        return nil
    }

    @MainActor
    func testMacdoraBrandingAndTopLeftLogoLayout() throws {
        _ = NSApplication.shared
        XCTAssertEqual(MacdoraBrand.appName, "Macdora")
        let icon = MacdoraBrand.appIconImage(size: 512)
        XCTAssertGreaterThanOrEqual(icon.size.width, 512)

        let manager = ManagementWindow()
        let window = try XCTUnwrap(manager.window)
        let rootView = try XCTUnwrap(window.contentView)
        rootView.layoutSubtreeIfNeeded()

        XCTAssertEqual(window.title, "Macdora")

        func findLockup(in view: NSView) -> MacdoraBrandLockupView? {
            if let lockup = view as? MacdoraBrandLockupView { return lockup }
            for sub in view.subviews {
                if let found = findLockup(in: sub) { return found }
            }
            return nil
        }
        let lockup = try XCTUnwrap(findLockup(in: rootView))
        let lockupInWindow = lockup.convert(lockup.bounds, to: nil)
        XCTAssertLessThanOrEqual(lockupInWindow.minX, 24, "Macdora logo must sit in the top-left sidebar")
        XCTAssertGreaterThanOrEqual(lockupInWindow.maxY, window.frame.height - 40)

        if let closeBtn = window.standardWindowButton(.closeButton) {
            let closeInWindow = closeBtn.convert(closeBtn.bounds, to: nil)
            XCTAssertFalse(closeInWindow.intersects(lockupInWindow), "Top-left Macdora logo must not overlap window traffic lights")
        }

        func collectTextFields(in view: NSView) -> [String] {
            var result: [String] = []
            if let tf = view as? NSTextField {
                result.append(tf.stringValue)
            }
            for sub in view.subviews {
                result.append(contentsOf: collectTextFields(in: sub))
            }
            return result
        }
        let allTexts = collectTextFields(in: rootView)
        XCTAssertFalse(allTexts.contains(where: { $0.contains("按需秒开待命") }), "Unrestrained standby slogan must be removed")
        XCTAssertFalse(allTexts.contains("启动"), "No separate TFButton with '启动' text should exist outside TFRuntimeControlButton")
        XCTAssertFalse(allTexts.contains("停止"), "No separate TFButton with '停止' text should exist")

        func collectRuntimeButtons(in view: NSView) -> [TFRuntimeControlButton] {
            var result: [TFRuntimeControlButton] = []
            if let btn = view as? TFRuntimeControlButton {
                result.append(btn)
            }
            for sub in view.subviews {
                result.append(contentsOf: collectRuntimeButtons(in: sub))
            }
            return result
        }
        let initialBtns = collectRuntimeButtons(in: rootView)
        XCTAssertEqual(initialBtns.count, 1)
        XCTAssertEqual(initialBtns.first?.mode, .start)

        manager.update(.starting)
        rootView.layoutSubtreeIfNeeded()
        let startingBtn = try XCTUnwrap(collectRuntimeButtons(in: rootView).first)
        if case .progress(let fraction, let statusText, let isStopping) = startingBtn.mode {
            XCTAssertGreaterThan(fraction, 0.3)
            XCTAssertFalse(statusText.isEmpty)
            XCTAssertFalse(isStopping)
        } else {
            XCTFail("Expected .progress mode while starting")
        }

        manager.update(.ready)
        rootView.layoutSubtreeIfNeeded()
        let readyBtn = try XCTUnwrap(collectRuntimeButtons(in: rootView).first)
        XCTAssertEqual(readyBtn.mode, .stop)
    }

    @MainActor
    func testExplicitAndRuntimeClosePreserveWindowControllerAndResetCloseGuard() throws {
        _ = NSApplication.shared
        let controller = ApplicationWindow(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let window = try XCTUnwrap(controller.window)
        var managementPresented = 0
        controller.onManagement = { managementPresented += 1 }

        controller.performRuntimeOperationClose()
        XCTAssertTrue(window.windowController === controller, "Reused ApplicationWindow must keep its NSWindowController attached")
        XCTAssertFalse(controller.windowShouldClose(window), "allowExplicitClose must reset after performExplicitClose")
        XCTAssertEqual(managementPresented, 1, "Red close button miniaturize should surface ManagementWindow")
    }
}
