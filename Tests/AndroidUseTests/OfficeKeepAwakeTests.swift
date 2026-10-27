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

    func testSettingsExposeADisabledByDefaultOfficeKeepAwakeSwitch() throws {
        _ = NSApplication.shared
        let manager = ManagementWindow()
        let window = try XCTUnwrap(manager.window)
        defer { window.orderOut(nil) }
        manager.updatePreferences(cameraEnabled: true, canChangeCamera: true,
                                  rootPath: "/tmp/example-office", preferences: .default, readiness: [])
        manager.selectSection(.settings)
        let root = try XCTUnwrap(window.contentView)
        let toggle = try XCTUnwrap(descendants(root).first {
            $0.identifier?.rawValue == "office-keep-awake-toggle"
        } as? TFToggleSwitch)
        XCTAssertFalse(toggle.isOn)
        XCTAssertTrue(toggle.isAccessibilityElement())
        XCTAssertFalse((toggle.accessibilityLabel() ?? "").isEmpty)
        var selected: Bool?
        manager.onToggleOfficeKeepAwake = { selected = $0 }
        XCTAssertTrue(toggle.accessibilityPerformPress())
        XCTAssertEqual(selected, true)
        manager.update(.starting)
        let disabled = try XCTUnwrap(descendants(root).first {
            $0.identifier?.rawValue == "office-keep-awake-toggle"
        } as? TFToggleSwitch)
        XCTAssertFalse(disabled.isEnabled)
        XCTAssertFalse(disabled.accessibilityPerformPress())
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

    func testFailedSettingsRetryKeepsOriginalIntentAndToggleCanStillCancelIt() throws {
        _ = NSApplication.shared
        let manager = ManagementWindow()
        let window = try XCTUnwrap(manager.window)
        defer { window.orderOut(nil) }
        manager.selectSection(.settings)
        for enabled in [true, false] {
            manager.updatePreferences(cameraEnabled: true, canChangeCamera: true,
                rootPath: "/tmp/example-office", preferences: .default, readiness: [],
                officeKeepAwake: .init(enabled: enabled, phase: .failed))
            let root = try XCTUnwrap(window.contentView)
            let retry = try XCTUnwrap(descendants(root).first {
                $0.identifier?.rawValue == "office-keep-awake-retry"
            } as? TFButton)
            var requested: Bool?
            manager.onToggleOfficeKeepAwake = { requested = $0 }
            XCTAssertTrue(retry.accessibilityPerformPress())
            XCTAssertEqual(requested, enabled, "Retry must repeat the failed enable OR restore.")
            let toggle = try XCTUnwrap(descendants(root).first {
                $0.identifier?.rawValue == "office-keep-awake-toggle"
            } as? TFToggleSwitch)
            XCTAssertEqual(toggle.isOn, enabled)
            XCTAssertTrue(toggle.accessibilityPerformPress())
            XCTAssertEqual(requested, !enabled, "The normal toggle must still allow changing the saved intent.")
        }
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

    func testExportOfficeSettingsScreenshotsWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["MACDORA_OFFICE_QA_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let oldTheme = TFTheme.isDark
        defer { TFTheme.isDark = oldTheme }
        for dark in [false, true] {
            TFTheme.isDark = dark
            let manager = ManagementWindow()
            let window = try XCTUnwrap(manager.window)
            defer { window.orderOut(nil) }
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.setContentSize(NSSize(width: 1060, height: 700))
            manager.updatePreferences(cameraEnabled: true, canChangeCamera: true,
                rootPath: "/tmp/example-office", preferences: .default, readiness: [],
                officeKeepAwake: .init(enabled: dark, phase: dark ? .active : .off))
            manager.selectSection(.settings)
            let root = try XCTUnwrap(window.contentView)
            root.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(dark ? "office-settings-dark.png" : "office-settings-light.png"))
            manager.updatePreferences(cameraEnabled: true, canChangeCamera: true,
                rootPath: "/tmp/example-office", preferences: .default, readiness: [],
                officeKeepAwake: .init(enabled: dark, phase: .failed))
            root.layoutSubtreeIfNeeded()
            let failedBitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: failedBitmap)
            try XCTUnwrap(failedBitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(dark ? "office-settings-failed-dark.png" : "office-settings-failed-light.png"))
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
