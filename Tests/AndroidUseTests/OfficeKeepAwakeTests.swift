import AppKit
import XCTest
@testable import AndroidUse

@MainActor
final class OfficeKeepAwakeTests: XCTestCase {
    func testPreferenceIsOffByDefaultAndIsolatedByCanonicalRoot() throws {
        let name = "office-keep-awake-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let office = root.appendingPathComponent("office")
        try FileManager.default.createDirectory(at: office, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("office-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: office)
        let selected = OfficeKeepAwakePreferences(rootURL: office, defaults: defaults)
        let ordinary = OfficeKeepAwakePreferences(rootURL: root.appendingPathComponent("ordinary"), defaults: defaults)
        XCTAssertFalse(selected.enabled)
        XCTAssertFalse(ordinary.enabled)
        selected.enabled = true
        selected.original = OfficeFreezerSnapshot(setting: .deviceDefault, inUse: true)
        let reopened = OfficeKeepAwakePreferences(rootURL: alias, defaults: defaults)
        XCTAssertTrue(reopened.enabled)
        XCTAssertEqual(reopened.original, selected.original)
        XCTAssertFalse(ordinary.enabled)
        XCTAssertFalse(ordinary.hasOriginal)
        XCTAssertFalse(selected.key.contains(root.path))
    }

    func testUnknownOrMalformedFreezerStateIsRejected() {
        for text in ["enabled\n", "custom\ntrue\n", "enabled\nyes\n", "enabled\ntrue\nextra\n"] {
            XCTAssertNil(OfficeFreezerSnapshot(output: Data(text.utf8)))
        }
    }

    func testGlobalSettingsNeverExposePluginKeepAwake() throws {
        _ = NSApplication.shared
        let manager = ManagementWindow()
        let window = try XCTUnwrap(manager.window)
        defer { window.orderOut(nil) }
        manager.selectSection(.settings)
        for status in [OfficeKeepAwakeStatus.off, .init(enabled: true, phase: .active), .init(enabled: false, phase: .failed)] {
            manager.updatePreferences(cameraEnabled: true, canChangeCamera: true,
                rootPath: "/tmp/example-office", preferences: .default, readiness: [], officeKeepAwake: status)
            let controls = descendants(try XCTUnwrap(window.contentView))
            XCTAssertFalse(controls.contains { $0 is PluginKeepAwakeView })
            XCTAssertFalse(controls.contains { ($0 as? NSTextField)?.stringValue.contains("唤醒") == true })
            XCTAssertFalse(controls.contains { $0.identifier?.rawValue.contains("keep-awake") == true })
        }
    }

    func testPluginKeepAwakeStartsOffAndBlocksChangesWhileApplyingOrRuntimeBusy() throws {
        _ = NSApplication.shared
        let view = PluginKeepAwakeView()
        let toggle = try XCTUnwrap(descendants(view).first {
            $0.identifier?.rawValue == "plugin-keep-awake-toggle"
        } as? TFToggleSwitch)
        XCTAssertFalse(toggle.isOn)
        XCTAssertTrue(toggle.isAccessibilityElement())
        var selected: Bool?
        view.update(status: .off, runtimeBusy: false) { selected = $0 }
        XCTAssertTrue(toggle.accessibilityPerformPress())
        XCTAssertEqual(selected, true)
        for (status, busy) in [(OfficeKeepAwakeStatus.off, true), (.init(enabled: true, phase: .applying), false)] {
            view.update(status: status, runtimeBusy: busy) { selected = $0 }
            XCTAssertFalse(toggle.isEnabled)
            XCTAssertFalse(toggle.accessibilityPerformPress())
        }
    }

    func testGuestCommandsUnfreezeAndRestoreThroughIsolatedShellStubs() async throws {
        let fixture = try OfficeGuestShellFixture()
        defer { fixture.remove() }
        let inspected = try await fixture.run(OfficeKeepAwakeCommands.inspect)
        XCTAssertEqual(inspected.exitCode, 0)
        XCTAssertEqual(OfficeFreezerSnapshot(output: inspected.stdout), .init(setting: .absent, inUse: true))
        let applied = try await fixture.run(OfficeKeepAwakeCommands.apply)
        XCTAssertEqual(applied.exitCode, 0)
        XCTAssertEqual(String(decoding: applied.stdout, as: UTF8.self), "MACDORA_OFFICE_AWAKE_APPLIED\n")
        XCTAssertEqual(try fixture.read("setting"), "disabled")
        XCTAssertEqual(try fixture.read("mainFrozen"), "0")
        let restored = try await fixture.run(OfficeKeepAwakeCommands.restore(.init(setting: .absent, inUse: true)))
        XCTAssertEqual(restored.exitCode, 0)
        XCTAssertEqual(try fixture.read("setting"), "null")
        XCTAssertEqual(String(decoding: restored.stdout, as: UTF8.self), "MACDORA_OFFICE_AWAKE_RESTORED\n")
        try fixture.write("setting", "enabled")
        let external = try await fixture.run(OfficeKeepAwakeCommands.restore(.init(setting: .absent, inUse: true)))
        XCTAssertEqual(String(decoding: external.stdout, as: UTF8.self), "MACDORA_OFFICE_AWAKE_EXTERNAL\n")
        XCTAssertEqual(try fixture.read("setting"), "enabled")
    }

    func testFailedPluginRetryKeepsOriginalIntentAndToggleCanStillCancelIt() throws {
        _ = NSApplication.shared
        let view = PluginKeepAwakeView()
        for enabled in [true, false] {
            var requested: Bool?
            view.update(status: .init(enabled: enabled, phase: .failed), runtimeBusy: false) { requested = $0 }
            let retry = try XCTUnwrap(descendants(view).first {
                $0.identifier?.rawValue == "plugin-keep-awake-retry"
            } as? TFButton)
            XCTAssertFalse(retry.isHidden)
            XCTAssertTrue(retry.accessibilityPerformPress())
            XCTAssertEqual(requested, enabled, "重试必须保留原来的开启或恢复意图。")
            let toggle = try XCTUnwrap(descendants(view).first {
                $0.identifier?.rawValue == "plugin-keep-awake-toggle"
            } as? TFToggleSwitch)
            XCTAssertEqual(toggle.isOn, enabled)
            XCTAssertTrue(toggle.accessibilityPerformPress())
            XCTAssertEqual(requested, !enabled)
        }
    }

    func testGuestCommandsHandleLargeProcessDumpWithoutArgumentOverflow() async throws {
        let fixture = try OfficeGuestShellFixture()
        defer { fixture.remove() }
        try fixture.write("largeDump", "1")
        let applied = try await fixture.run(OfficeKeepAwakeCommands.apply)
        XCTAssertEqual(applied.exitCode, 0)
        XCTAssertEqual(String(decoding: applied.stdout, as: UTF8.self), "MACDORA_OFFICE_AWAKE_APPLIED\n")
    }

    func testGuestCommandsRejectFrozenOrPendingRendererAndMissingDumpSupport() async throws {
        for failure in ["childFrozen", "childPending", "unsupported"] {
            let fixture = try OfficeGuestShellFixture()
            defer { fixture.remove() }
            try fixture.write(failure, "1")
            let applied = try await fixture.run(OfficeKeepAwakeCommands.apply)
            XCTAssertNotEqual(applied.exitCode, 0, failure)
            XCTAssertFalse(String(decoding: applied.stdout, as: UTF8.self).contains("MACDORA_OFFICE_AWAKE_APPLIED"))
        }
    }

    func testExportPluginSettingsScreenshotsWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["MACDORA_OFFICE_QA_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let oldTheme = TFTheme.isDark
        defer { TFTheme.isDark = oldTheme }
        for dark in [false, true] {
            TFTheme.isDark = dark
            let view = PluginKeepAwakeView()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
            defer { window.orderOut(nil) }
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 660, height: 180))
            root.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
                view.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
                view.topAnchor.constraint(equalTo: root.topAnchor, constant: 12)
            ])
            window.contentView = root
            window.orderFront(nil)
            for failed in [false, true] {
                view.update(status: .init(enabled: dark, phase: failed ? .failed : (dark ? .active : .off)), runtimeBusy: false, onToggle: { _ in })
                root.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                root.cacheDisplay(in: root.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("plugin-awake-\(dark ? "dark" : "light")-\(failed ? "failed" : "normal").png"))
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

/// Executes the actual remote shell payload against synthetic Android commands.
/// No ADB, emulator, application, account or private development directory is used.
private struct OfficeGuestShellFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("office-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, value) in [("setting", "null"), ("mainFrozen", "1"), ("childFrozen", "0"), ("childPending", "0"), ("unsupported", "0")] {
            try write(name, value)
        }
        let commands = [
            "su": "[ \"$1\" = 0 ] || exit 1\nshift\nexec \"$@\"",
            "sleep": ":",
            "settings": """
            case "$1" in
              get) cat "$OFFICE_FIXTURE_STATE/setting";;
              put) printf '%s' "$4" > "$OFFICE_FIXTURE_STATE/setting";;
              delete) printf null > "$OFFICE_FIXTURE_STATE/setting";;
              *) exit 1;;
            esac
            """,
            "am": """
            [ "$1" = unfreeze ] || exit 1
            [ "$2" = example.office ] || exit 1
            printf 0 > "$OFFICE_FIXTURE_STATE/mainFrozen"
            """,
            "dumpsys": """
            if [ "$(cat "$OFFICE_FIXTURE_STATE/unsupported")" = 1 ]; then exit 0; fi
            if [ -f "$OFFICE_FIXTURE_STATE/largeDump" ]; then
              awk 'BEGIN { for (i = 0; i < 10000; i++) print "synthetic unrelated activity manager diagnostic padding line" }'
            fi
            setting=$(cat "$OFFICE_FIXTURE_STATE/setting")
            main=$(cat "$OFFICE_FIXTURE_STATE/mainFrozen")
            child=$(cat "$OFFICE_FIXTURE_STATE/childFrozen")
            pending=$(cat "$OFFICE_FIXTURE_STATE/childPending")
            if [ "$setting" = disabled ]; then printf '  use_freezer=false\\n'; else printf '  use_freezer=true\\n'; fi
            printf '  Apps frozen: %s\\n' "$((main + child))"
            printf '  *APP* UID 10001 ProcessRecord{abcd 123:example.office/u0a1}\\n'
            printf '    isPendingFreeze=false\\n'
            printf '  *APP* UID 90001 ProcessRecord{cdef 124:example.webview:renderer/u0i1}\\n'
            if [ "$pending" = 1 ]; then printf '    isPendingFreeze=true\\n'; else printf '    isPendingFreeze=false\\n'; fi
            """
        ]
        for (name, body) in commands {
            let file = root.appendingPathComponent(name)
            try Data(("#!/bin/sh\nset -eu\n" + body + "\n").utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
    }

    func write(_ name: String, _ value: String) throws {
        try Data(value.utf8).write(to: root.appendingPathComponent(name))
    }

    func read(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    func run(_ script: String) async throws -> ProcessResult {
        try await ProcessRunner().run(ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", OfficeKeepAwakeCommands.arguments(script)[1]],
            environment: ["PATH": root.path + ":/usr/bin:/bin", "OFFICE_FIXTURE_STATE": root.path],
            timeout: 10, captureOutput: true
        ))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
