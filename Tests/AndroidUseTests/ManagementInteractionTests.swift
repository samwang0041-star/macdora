import AppKit
import XCTest
@testable import AndroidUse

@MainActor
final class ManagementInteractionTests: XCTestCase {
    func testIdlePagesKeepUncheckedAndUnmeasuredStatesExplicit() throws {
        _ = NSApplication.shared
        let manager = ManagementWindow()
        let window = try XCTUnwrap(manager.window)
        defer { window.orderOut(nil) }
        let root = try XCTUnwrap(window.contentView)
        func text() -> String {
            descendants(root).compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: "\n")
        }

        manager.selectSection(.about)
        XCTAssertFalse(text().contains("已是最新版本"), "An unchecked feed cannot establish that this version is current.")
        manager.updateAppUpdateState(.upToDate(checkedAt: Date(), detail: "已是最新版本"))
        XCTAssertTrue(text().contains("已是最新版本"))

        manager.selectSection(.monitor)
        XCTAssertTrue(text().contains("环境未启动"))
        XCTAssertFalse(text().contains("按需刷新"), "A stopped environment has no frame activity to describe.")
        XCTAssertFalse(text().contains("0.08 GB"), "Missing measurements must not become fabricated memory usage.")
        XCTAssertEqual(descendants(root).compactMap { ($0 as? NSTextField)?.stringValue }.filter { $0 == "—" }.count, 3)

        manager.selectSection(.serving)
        XCTAssertTrue(text().contains("等待检查"))
        XCTAssertFalse(text().contains("检查已通过"), "An empty result set cannot establish readiness.")

        manager.update(.starting)
        manager.selectSection(.apps)
        let working = try XCTUnwrap(descendants(root).compactMap { $0 as? TFRuntimeControlButton }.first)
        XCTAssertEqual(working.accessibilityLabel(), "正在启动…")
        XCTAssertFalse(working.isEnabled, "Repeated start actions must stay blocked while startup is pending.")
    }

    func testSearchKeepsItsEditorWhileTypingClearingAndRefreshingApps() throws {
        _ = NSApplication.shared
        let manager = ManagementWindow()
        let window = try XCTUnwrap(manager.window)
        defer { window.orderOut(nil) }
        let apps = [ContainerApp.metadata(for: "com.tencent.mm"), ContainerApp.metadata(for: "com.android.settings")]
        manager.updateApps(apps, activePackage: nil)
        manager.presentWindow()
        let root = try XCTUnwrap(window.contentView)
        let search = try XCTUnwrap(descendants(root).compactMap { $0 as? NSSearchField }.first)
        XCTAssertTrue(window.makeFirstResponder(search))
        let editor = try XCTUnwrap(search.currentEditor() as? NSTextView)

        for query in ["微", "微信", "", "com.tencent.mm"] {
            search.stringValue = query
            manager.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
            XCTAssertTrue(search.isDescendant(of: root), "Typing must not replace the focused search field.")
            XCTAssertTrue(window.firstResponder === editor, "Typing must preserve the field editor for Chinese composition and subsequent keys.")
            XCTAssertTrue(descendants(root).contains { $0.identifier?.rawValue == "app-row-com.tencent.mm" })
            XCTAssertEqual(descendants(root).contains { $0.identifier?.rawValue == "app-row-com.android.settings" }, query.isEmpty)
        }

        editor.setMarkedText("wei", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertTrue(editor.hasMarkedText())
        manager.updateApps(apps, activePackage: "com.tencent.mm")
        XCTAssertTrue(search.isDescendant(of: root), "An app refresh must not interrupt an in-progress search.")
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertTrue(editor.hasMarkedText(), "An app refresh must preserve Chinese marked text.")
        manager.update(.ready)
        manager.show(detail: "应用状态已刷新")
        XCTAssertTrue(search.isDescendant(of: root), "Background status and banner changes must also preserve the search field.")
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertTrue(editor.hasMarkedText())
        editor.unmarkText()

        search.stringValue = ""
        let action = try XCTUnwrap(search.action, "The native clear button sends a search action even without an active editor.")
        XCTAssertTrue(NSApp.sendAction(action, to: search.target, from: search))
        XCTAssertTrue(descendants(root).contains { $0.identifier?.rawValue == "app-row-com.android.settings" }, "The clear action must restore all results.")
    }

    func testManagementActionsAreNamedAccessibilityElements() throws {
        _ = NSApplication.shared
        let manager = ManagementWindow()
        let window = try XCTUnwrap(manager.window)
        defer { window.orderOut(nil) }
        manager.updateApps([ContainerApp.metadata(for: "com.tencent.mm")], activePackage: nil)
        let root = try XCTUnwrap(window.contentView)
        let controls = descendants(root)
        let open = try XCTUnwrap(controls.first { $0.identifier?.rawValue == "open-com.tencent.mm" } as? TFButton)
        XCTAssertTrue(open.isAccessibilityElement())
        XCTAssertEqual(open.accessibilityRole(), .button)
        XCTAssertFalse(try XCTUnwrap(open.accessibilityLabel()).isEmpty)
        var opened: String?
        manager.onOpenApp = { opened = $0 }
        XCTAssertTrue(open.accessibilityPerformPress())
        XCTAssertEqual(opened, "com.tencent.mm")
        open.isEnabled = false
        XCTAssertFalse(open.accessibilityPerformPress())

        for button in controls.compactMap({ $0 as? NSButton }) where button.title.isEmpty {
            XCTAssertFalse((button.accessibilityLabel() ?? "").isEmpty, "Navigation, categories and mode controls need spoken names.")
        }
    }

    func testDisplayLayoutLabelsStaySeparateFromGuestIdentity() throws {
        _ = NSApplication.shared
        let manager = ManagementWindow()
        let window = try XCTUnwrap(manager.window)
        defer { window.orderOut(nil) }
        manager.updatePreferences(
            cameraEnabled: true,
            canChangeCamera: true,
            rootPath: "/tmp/macdora",
            preferences: .default,
            readiness: []
        )
        manager.selectSection(.settings)
        manager.presentWindow()

        let controls = descendants(try XCTUnwrap(window.contentView))
        let accessibilityLabels = controls.compactMap { $0.accessibilityLabel() }
        XCTAssertTrue(accessibilityLabels.contains("横屏布局"))
        XCTAssertTrue(accessibilityLabels.contains("竖屏布局"))
        XCTAssertFalse(accessibilityLabels.contains("平板模式"))
        XCTAssertFalse(accessibilityLabels.contains("手机模式"))
        let text = controls.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: "\n")
        XCTAssertTrue(text.contains("始终使用同一平板，仅调整显示方向"))
    }

    func testCategoryAndThemeChangesKeepSearchAndSelectionSynchronized() throws {
        _ = NSApplication.shared
        let manager = ManagementWindow()
        let window = try XCTUnwrap(manager.window)
        let wasDark = TFTheme.isDark
        defer { TFTheme.isDark = wasDark; window.orderOut(nil) }
        manager.updateApps([ContainerApp.metadata(for: "com.tencent.mm"), ContainerApp.metadata(for: "com.android.settings")], activePackage: nil)
        manager.presentWindow()
        let root = try XCTUnwrap(window.contentView)
        let search = try XCTUnwrap(descendants(root).compactMap { $0 as? NSSearchField }.first)
        XCTAssertTrue(window.makeFirstResponder(search))
        let editor = try XCTUnwrap(search.currentEditor())
        let system = try XCTUnwrap(descendants(root).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "系统" })
        let all = try XCTUnwrap(descendants(root).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "全部" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(system.action), to: system.target, from: system))
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(system.accessibilityValue() as? NSNumber, NSNumber(value: true))
        XCTAssertEqual(all.accessibilityValue() as? NSNumber, NSNumber(value: false))
        XCTAssertFalse(descendants(root).contains { $0.identifier?.rawValue == "app-row-com.tencent.mm" })

        let theme = try XCTUnwrap(descendants(root).compactMap { $0 as? TFButton }.first { $0.symbolName == "moon" || $0.symbolName == "sun.max" })
        XCTAssertTrue(theme.accessibilityPerformPress())
        XCTAssertEqual(TFTheme.isDark, !wasDark)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertTrue(search.isDescendant(of: root))
        XCTAssertEqual(system.accessibilityValue() as? NSNumber, NSNumber(value: true))
        let systemLabel = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTextField }.first { $0.stringValue == "系统" })
        XCTAssertEqual(systemLabel.textColor, TFTheme.ink)
    }

    func testToggleSupportsKeyboardAndAccessibilityWithoutChangingDisabledState() throws {
        _ = NSApplication.shared
        let toggle = TFToggleSwitch(isOn: false)
        var changes: [Bool] = []
        toggle.onToggle = { changes.append($0) }
        XCTAssertTrue(toggle.isAccessibilityElement())
        XCTAssertTrue(toggle.acceptsFirstResponder)
        XCTAssertTrue(toggle.accessibilityPerformPress())
        XCTAssertTrue(toggle.isOn)
        XCTAssertEqual(toggle.accessibilityValue() as? NSNumber, NSNumber(value: true))
        let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        toggle.keyDown(with: space)
        XCTAssertFalse(toggle.isOn)
        XCTAssertEqual(changes, [true, false])
        toggle.isEnabled = false
        XCTAssertFalse(toggle.accessibilityPerformPress())
        toggle.keyDown(with: space)
        XCTAssertFalse(toggle.isOn)
        XCTAssertEqual(changes, [true, false])
    }


    func testDisplaySizeAndQualityControlsAreIndependentAndRestoreAppOverrides() throws {
        _ = NSApplication.shared
        let manager = ManagementWindow()
        let window = try XCTUnwrap(manager.window)
        defer { window.orderOut(nil) }
        var updatedPrefs: ContainerPreferences?
        manager.onUpdatePreferences = { updatedPrefs = $0 }
        var preferences = ContainerPreferences.default
        preferences.appDisplayOverrides["com.example.notes"] = AppDisplayPreference(resolutionPreset: "720p", tabletMode: false, interfaceScale: .large)
        manager.updateApps([ContainerApp.metadata(for: "com.example.notes")], activePackage: "com.example.notes")
        manager.updatePreferences(cameraEnabled: true, canChangeCamera: true, rootPath: "/tmp/macdora", preferences: preferences, readiness: [])
        manager.selectSection(.settings)
        manager.presentWindow()
        let root = try XCTUnwrap(window.contentView)
        let scale = try XCTUnwrap(descendants(root).first { $0.identifier?.rawValue == "settings-interface-scale" })
        let larger = try XCTUnwrap(descendants(scale).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "较大 125%" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(larger.action), to: larger.target, from: larger))
        XCTAssertEqual(updatedPrefs?.interfaceScale, .large)
        XCTAssertEqual(updatedPrefs?.resolutionPreset, "1080p")

        let quality = try XCTUnwrap(descendants(root).first { $0.identifier?.rawValue == "settings-display-quality" })
        let finer = try XCTUnwrap(descendants(quality).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "精细" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(finer.action), to: finer.target, from: finer))
        XCTAssertEqual(updatedPrefs?.resolutionPreset, "1440p")
        XCTAssertEqual(updatedPrefs?.interfaceScale, .large)
        let restore = try XCTUnwrap(descendants(root).first { $0.identifier?.rawValue == "settings-display-restore" } as? TFButton)
        XCTAssertTrue(restore.accessibilityPerformPress())
        XCTAssertEqual(updatedPrefs?.resolutionPreset, "1080p")
        XCTAssertEqual(updatedPrefs?.interfaceScale, .standard)
        XCTAssertEqual(updatedPrefs?.appDisplayOverrides["com.example.notes"], AppDisplayPreference(resolutionPreset: "1080p", tabletMode: false))

        manager.selectSection(.apps)
        let runtimeDisplay = try XCTUnwrap(descendants(root).first { $0.identifier?.rawValue == "runtime-bar-resolution-switch" } as? TFButton)
        XCTAssertEqual(runtimeDisplay.title, "显示 · 100% ▾")
    }

    func testWindowDisplayMenuAppliesSizeQualityAndRecommendedSettingsSeparately() throws {
        _ = NSApplication.shared
        let app = ApplicationWindow(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        defer { app.performExplicitClose() }
        app.applyDisplayMode(tabletMode: false, preferredPixelSize: CGSize(width: 1200, height: 1920))
        var selectedScale: DisplayInterfaceScale?
        var selectedQuality: String?
        var restoreCalls = 0
        app.onSelectInterfaceScale = { selectedScale = $0 }
        app.onSelectResolutionPreset = { selectedQuality = $0 }
        app.onRestoreRecommendedDisplay = { restoreCalls += 1 }
        let beforeSize = app.surface.pixelSize
        var menu = app.makeDisplaySettingsMenu()
        XCTAssertEqual(menu.items.first?.title, "仅当前应用")
        let sizeIndex = try XCTUnwrap(menu.items.firstIndex { $0.representedObject as? String == "large" })
        menu.performActionForItem(at: sizeIndex)
        XCTAssertEqual(selectedScale, .large)
        XCTAssertEqual(app.surface.pixelSize, beforeSize)
        menu = app.makeDisplaySettingsMenu()
        let qualityIndex = try XCTUnwrap(menu.items.firstIndex { $0.representedObject as? String == "720p" })
        menu.performActionForItem(at: qualityIndex)
        XCTAssertEqual(selectedQuality, "720p")
        XCTAssertEqual(app.currentInterfaceScale, .large)
        XCTAssertEqual(app.surface.pixelSize, beforeSize, "坐标须等显示服务确认后再更新")
        menu = app.makeDisplaySettingsMenu()
        menu.performActionForItem(at: menu.items.count - 1)
        XCTAssertEqual(restoreCalls, 1)
        XCTAssertEqual(app.currentInterfaceScale, .standard)
        XCTAssertEqual(app.currentResolutionPreset, "1080p")
        XCTAssertFalse(app.isHorizontalLayout)
        XCTAssertEqual(app.surface.pixelSize, beforeSize)
    }

    func testMultiAppConcurrentActiveRowsProvideIndependentCloseAndSwitchControls() throws {
        _ = NSApplication.shared
        let manager = ManagementWindow()
        let window = try XCTUnwrap(manager.window)
        defer { window.orderOut(nil) }
        let apps = [
            ContainerApp.metadata(for: "com.tencent.mm"),
            ContainerApp.metadata(for: "com.sankuai.meituan"),
            ContainerApp.metadata(for: "com.coolapk.market"),
            ContainerApp.metadata(for: "com.android.settings")
        ]
        let activeSet: Set<String> = ["com.tencent.mm", "com.sankuai.meituan", "com.coolapk.market", "com.android.settings"]
        manager.update(.running)
        manager.updateApps(apps, activePackage: "com.tencent.mm", activePackages: activeSet)
        manager.presentWindow()

        let root = try XCTUnwrap(window.contentView)
        var closedPackages: [String] = []
        manager.onCloseApp = { closedPackages.append($0) }

        for pkg in activeSet {
            let openBtn = try XCTUnwrap(descendants(root).first { $0.identifier?.rawValue == "focus-\(pkg)" } as? TFButton)
            XCTAssertEqual(openBtn.title, "切回窗口")
            let closeBtn = try XCTUnwrap(descendants(root).first { $0.identifier?.rawValue == "close-window-\(pkg)" } as? TFButton)
            XCTAssertEqual(closeBtn.title, "关闭窗口")
            XCTAssertTrue(closeBtn.accessibilityPerformPress())
        }
        XCTAssertEqual(Set(closedPackages), activeSet)
    }

    func testRunningInterfaceSizeCanBeCancelledBeforePreferencesChange() async throws {
        _ = NSApplication.shared
        let manager = ManagementWindow()
        let window = try XCTUnwrap(manager.window)
        defer { window.orderOut(nil) }
        manager.update(.running)
        manager.updateApps([ContainerApp.metadata(for: "dev.example.notes")], activePackage: "dev.example.notes")
        manager.presentWindow()
        var updated: ContainerPreferences?
        manager.onUpdatePreferences = { updated = $0 }

        manager.selectInterfaceScale(.large)
        XCTAssertNil(updated, "未确认时不能写入设置或触发页面重建")
        let sheet = try XCTUnwrap(window.attachedSheet)
        let cancel = try XCTUnwrap(descendants(try XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSButton }.first { $0.title == "取消" })
        cancel.performClick(nil)
        for _ in 0..<20 where window.attachedSheet != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(updated)
        manager.selectSection(.settings)
        let scale = try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).first { $0.identifier?.rawValue == "settings-interface-scale" } as? TFSegmentedControl)
        XCTAssertEqual(scale.selectedValue, "standard")

        manager.selectResolutionPreset("720p")
        XCTAssertNil(window.attachedSheet, "单独更改清晰度不会重建应用页面")
        XCTAssertEqual(updated?.resolutionPreset, "720p")
    }

    func testRunningWindowScaleAndRecommendedRestoreWaitForConfirmation() async throws {
        _ = NSApplication.shared
        let app = ApplicationWindow(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let window = try XCTUnwrap(app.window)
        defer { app.performExplicitClose() }
        app.applyDisplayMode(tabletMode: true, preferredPixelSize: CGSize(width: 1920, height: 1200), resolutionPreset: "1080p", interfaceScale: .standard)
        app.presentWindow()
        app.ready()
        var changes: [DisplayInterfaceScale] = []
        app.onSelectInterfaceScale = { changes.append($0) }

        app.selectInterfaceScale(.large)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(app.currentInterfaceScale, .standard)
        let sheet = try XCTUnwrap(window.attachedSheet)
        let confirm = try XCTUnwrap(descendants(try XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSButton }.first { $0.title == "仍然调整" })
        confirm.performClick(nil)
        for _ in 0..<20 where changes.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(changes, [.large])
        XCTAssertEqual(app.currentInterfaceScale, .large)
        XCTAssertEqual(app.surface.pixelSize, CGSize(width: 1920, height: 1200))

        var restores = 0
        app.onRestoreRecommendedDisplay = { restores += 1 }
        app.restoreRecommendedDisplay()
        XCTAssertEqual(restores, 0)
        let restoreSheet = try XCTUnwrap(window.attachedSheet)
        let cancel = try XCTUnwrap(descendants(try XCTUnwrap(restoreSheet.contentView)).compactMap { $0 as? NSButton }.first { $0.title == "取消" })
        cancel.performClick(nil)
        for _ in 0..<20 where window.attachedSheet != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(restores, 0)
        XCTAssertEqual(app.currentInterfaceScale, .large)
    }

    func testDisplayUpdateInputPauseCannotBypassLayoutConfirmation() throws {
        _ = NSApplication.shared
        let app = ApplicationWindow(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let window = try XCTUnwrap(app.window)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
            app.performExplicitClose()
        }
        app.presentWindow()
        app.ready()
        app.surface.inputEnabled = false
        var requested = false
        app.onSelectInterfaceScale = { _ in requested = true }

        app.selectInterfaceScale(.large)
        XCTAssertFalse(requested, "显示更新暂停输入时也不能绕过未保存内容保护")
        XCTAssertNotNil(window.attachedSheet)
        XCTAssertEqual(app.currentInterfaceScale, .standard)
    }

    private func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { descendants($0) }
    }
}
