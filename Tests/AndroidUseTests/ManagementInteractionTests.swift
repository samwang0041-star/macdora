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


    func testOneClickResolutionSwitchInSettingsTopBarAndAppWindow() throws {
        _ = NSApplication.shared
        let manager = ManagementWindow()
        let window = try XCTUnwrap(manager.window)
        defer { window.orderOut(nil) }
        var updatedPrefs: ContainerPreferences?
        manager.onUpdatePreferences = { updatedPrefs = $0 }
        manager.updatePreferences(
            cameraEnabled: true,
            canChangeCamera: true,
            rootPath: "/tmp/macdora",
            preferences: .default,
            readiness: []
        )

        manager.selectSection(.apps)
        manager.presentWindow()
        let root = try XCTUnwrap(window.contentView)
        let runtimeResBtn = try XCTUnwrap(
            descendants(root).first { $0.identifier?.rawValue == "runtime-bar-resolution-switch" } as? TFButton
        )
        XCTAssertEqual(runtimeResBtn.title, "1080p 标准 ▾")

        manager.selectSection(.settings)
        let settingsMenuBtn = try XCTUnwrap(
            descendants(root).first { $0.identifier?.rawValue == "settings-resolution-menu-button" } as? TFButton
        )
        XCTAssertTrue(settingsMenuBtn.isAccessibilityElement())

        manager.selectResolutionPreset("1280x800_comfortable")
        XCTAssertEqual(updatedPrefs?.resolutionPreset, "1280x800_comfortable")

        manager.selectSection(.apps)
        let refreshedRuntimeResBtn = try XCTUnwrap(
            descendants(root).first { $0.identifier?.rawValue == "runtime-bar-resolution-switch" } as? TFButton
        )
        XCTAssertEqual(refreshedRuntimeResBtn.title, "舒适大字 ▾")

        let appWin = ApplicationWindow(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        defer { appWin.performExplicitClose() }
        var selectedWindowPreset: String?
        appWin.onSelectResolutionPreset = { selectedWindowPreset = $0 }
        XCTAssertEqual(appWin.resolutionSwitchButton.identifier?.rawValue, "app-window-resolution-switch")
        appWin.selectResolutionPreset("960x600")
        XCTAssertEqual(selectedWindowPreset, "960x600")
        XCTAssertEqual(appWin.currentResolutionPreset, "960x600")
        XCTAssertEqual(appWin.resolutionSwitchButton.title, "紧凑大字")
        XCTAssertEqual(appWin.surface.pixelSize, CGSize(width: 960, height: 600))
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

    private func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { descendants($0) }
    }
}
