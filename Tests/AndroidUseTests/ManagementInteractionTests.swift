import AppKit
import XCTest
@testable import AndroidUse

@MainActor
final class ManagementInteractionTests: XCTestCase {
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

    private func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { descendants($0) }
    }
}
