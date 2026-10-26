import Foundation
import XCTest
@testable import AndroidUse

final class GuestAuthenticationPreservationTests: XCTestCase {
    func testGuestIdentityIsTabletRegardlessOfDisplayLayout() {
        let verticalScript = RuntimeSoftwareDefaults.guestDeviceIdentityScript()
        XCTAssertTrue(verticalScript.contains("target_model=\"SM-F926U\""))
        XCTAssertTrue(verticalScript.contains("target_chars=\"tablet\""))
        XCTAssertTrue(verticalScript.contains("target_density=\"240\""))
        XCTAssertTrue(verticalScript.contains(
            "target_fingerprint=\"Samsung/SM-F926U/SM-F926U:12/V417IR/eng.nioh.20241225.154630:user/release-keys\""
        ))
        XCTAssertFalse(verticalScript.contains("target_model=\"Android SDK built for arm64\""))
    }

    func testSharedEnvironmentRecoveryDoesNotForceStopAnyApplication() throws {
        let fixture = try GuestIdentityShellFixture(stalePID: true)
        defer { fixture.remove() }
        try fixture.runSetup()
        fixture.assertNoApplicationForceStopped()
        fixture.assertGuestIdentityIsTablet()
    }

    func testColdBootPreservesApplicationAuthentication() throws {
        let fixture = try GuestIdentityShellFixture(marker: nil)
        defer { fixture.remove() }
        try fixture.runSetup()
        fixture.assertGuestIdentityIsTablet()
        fixture.assertAuthenticationPreserved()
        try fixture.runSetup()
        fixture.assertGuestIdentityIsTablet()
        fixture.assertAuthenticationPreserved()
    }

    func testReplacedZygotePreservesApplicationAuthentication() throws {
        let fixture = try GuestIdentityShellFixture(stalePID: true)
        defer { fixture.remove() }
        try fixture.runSetup()
        fixture.assertGuestIdentityIsTablet()
        fixture.assertAuthenticationPreserved()
    }

    func testUnknownPrivateCacheFormatIsLeftToTheApplication() throws {
        let fixture = try GuestIdentityShellFixture(cacheContents: Data([0, 0xff, 0x80, 0x0a]))
        defer { fixture.remove() }
        try fixture.runSetup()
        fixture.assertGuestIdentityIsTablet()
        fixture.assertAuthenticationPreserved()
    }

    func testPendingIdentityRecoveryPreservesApplicationAuthentication() throws {
        let fixture = try GuestIdentityShellFixture(marker: "pending")
        defer { fixture.remove() }
        try fixture.runSetup()
        fixture.assertGuestIdentityIsTablet()
        fixture.assertAuthenticationPreserved()
    }

    func testFailedIdentitySetupPreservesApplicationAuthentication() throws {
        let fixture = try GuestIdentityShellFixture(stalePID: true, restartFails: true)
        defer { fixture.remove() }
        try fixture.runSetup(expectedStatus: 1)
        fixture.assertAuthenticationPreserved()
    }

    func testLegacyPhoneIdentityMigrationDoesNotDeleteApplicationAuthentication() throws {
        let previousModel = GuestDeviceIdentity.phone.model
        let fixture = try GuestIdentityShellFixture(marker: previousModel, cacheModel: previousModel)
        defer { fixture.remove() }
        try fixture.runSetup()
        fixture.assertGuestIdentityIsTablet()
        fixture.assertAuthenticationPreserved()
    }

    func testWarmReopenPreservesApplicationAuthentication() throws {
        let fixture = try GuestIdentityShellFixture()
        defer { fixture.remove() }
        try fixture.runSetup()
        try fixture.runSetup()
        fixture.assertGuestIdentityIsTablet()
        fixture.assertAuthenticationPreserved()
        fixture.assertNoZygoteRestart()
    }
}

/// Executes the generated guest shell against a temporary filesystem and small
/// Android command stubs. No emulator, real application data or account is used.
private final class GuestIdentityShellFixture {
    let root: URL
    private let bin: URL
    private let properties: URL
    private let authenticationFiles: [(url: URL, contents: Data)]
    private let identity = GuestDeviceIdentity.tablet

    init(marker: String? = "current", stalePID: Bool = false, cacheModel: String? = nil, cacheContents: Data? = nil, restartFails: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("macdora-guest-auth-\(UUID().uuidString)")
        bin = root.appendingPathComponent("bin")
        properties = root.appendingPathComponent("properties")
        let authRoot = root.appendingPathComponent("data/data/com.tencent.mm/.auth_cache")
        authenticationFiles = [
            (authRoot.appendingPathComponent("7a03bac2-692f-3d17-a2cd-a1b0721ffd0e/0"), cacheContents ?? Data("\(cacheModel ?? identity.model),synthetic-device-record\n".utf8)),
            (authRoot.appendingPathComponent("8fa14cdd-754f-31cc-a554-c9e71929cce7/0"), Data("synthetic-authentication-record\n".utf8))
        ]
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: properties, withIntermediateDirectories: true)
        for file in authenticationFiles {
            try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.contents.write(to: file.url)
        }
        var values = [
            "ro.product.board": identity.board,
            "ro.build.characteristics": identity.characteristics,
            "qemu.sf.lcd_density": identity.density,
            "ro.build.fingerprint": identity.fingerprint,
            "live_zygote_pid": "100"
        ]
        if let marker {
            values["sys.androiduse.zygote_model"] = marker == "current" ? identity.model : marker
            values["sys.androiduse.zygote_pid"] = stalePID ? "99" : "100"
            values["sys.androiduse.winext_patch"] = "v2"
        }
        for namespace in ["", "system.", "product.", "system_ext.", "vendor.", "vendor_dlkm.", "odm."] {
            for (key, value) in ["brand": identity.brand, "manufacturer": identity.manufacturer, "model": identity.model, "device": identity.device, "name": identity.name] {
                values["ro.product.\(namespace)\(key)"] = value
            }
        }
        for (key, value) in values {
            try Data(value.utf8).write(to: properties.appendingPathComponent(key))
        }
        try stub("getprop", """
        if [ -f "$GUEST_TEST_PROPERTIES/$1" ]; then cat "$GUEST_TEST_PROPERTIES/$1"; fi
        """)
        try stub("setprop", """
        printf '%s' "$2" > "$GUEST_TEST_PROPERTIES/$1"
        if [ "$1" = "ctl.restart" ] && [ "$2" = "zygote" ]; then
          \(restartFails ? "exit 1" : ":")
          printf '101' > "$GUEST_TEST_PROPERTIES/live_zygote_pid"
        fi
        """)
        try stub("pidof", """
        case "$1" in
          zygote64|zygote) cat "$GUEST_TEST_PROPERTIES/live_zygote_pid" ;;
          com.android.systemui) printf '200' ;;
        esac
        """)
        try stub("dumpsys", "if [ \"$1\" = connectivity ]; then echo CONNECTED; fi")
        try stub("settings", "echo 1")
        try stub("am", "printf '%s\\n' \"$*\" >> \"$GUEST_TEST_EVENTS\"")
        for name in ["sleep", "ip6tables", "chown"] { try stub(name, "exit 0") }
    }

    func runSetup(expectedStatus: Int32 = 0) throws {
        let script = RuntimeSoftwareDefaults.guestDeviceIdentityScript()
        let prefix = "su 0 sh -c '\n"
        let suffix = "\n' || exit 1"
        guard script.hasPrefix(prefix) && script.hasSuffix(suffix) else {
            XCTFail("The fixture must recognize the complete guest-shell wrapper before execution.")
            return
        }
        var body = String(script.dropFirst(prefix.count).dropLast(suffix.count))
        for path in ["/data", "/system_ext", "/dev/__properties__", "/apex", "/proc/sys"] {
            // Include the trailing slash so /data/data is remapped once, rather
            // than treating both of its path components as absolute roots.
            body = body.replacingOccurrences(of: path + "/", with: root.path + path + "/")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", body]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = bin.path + ":/usr/bin:/bin"
        environment["GUEST_TEST_PROPERTIES"] = properties.path
        environment["GUEST_TEST_EVENTS"] = root.appendingPathComponent("commands").path
        process.environment = environment
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let diagnostic = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, expectedStatus, diagnostic)
    }

    func assertAuthenticationPreserved(file: StaticString = #filePath, line: UInt = #line) {
        for entry in authenticationFiles {
            XCTAssertEqual(try? Data(contentsOf: entry.url), entry.contents, "Guest setup must leave the application's existing authentication files intact.", file: file, line: line)
        }
    }

    func assertGuestIdentityIsTablet(file: StaticString = #filePath, line: UInt = #line) {
        let values = [
            "ro.product.model": identity.model,
            "ro.product.brand": identity.brand,
            "ro.product.manufacturer": identity.manufacturer,
            "ro.build.characteristics": identity.characteristics,
            "qemu.sf.lcd_density": identity.density,
            "ro.build.fingerprint": identity.fingerprint,
            "sys.androiduse.zygote_model": identity.model
        ]
        for (key, expected) in values {
            XCTAssertEqual(
                try? String(contentsOf: properties.appendingPathComponent(key), encoding: .utf8),
                expected,
                "Guest identity property \(key) must remain Tablet.",
                file: file,
                line: line
            )
        }
    }

    func assertNoZygoteRestart(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("properties/ctl.restart").path),
            "A warm setup with the same Tablet identity must not restart zygote.",
            file: file,
            line: line
        )
    }

    func assertNoApplicationForceStopped(file: StaticString = #filePath, line: UInt = #line) {
        let commands = (try? String(contentsOf: root.appendingPathComponent("commands"), encoding: .utf8)) ?? ""
        XCTAssertFalse(commands.components(separatedBy: .newlines).contains { $0.hasPrefix("force-stop ") },
                       "Shared environment preparation must not mark an unrelated application as stopped.", file: file, line: line)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    private func stub(_ name: String, _ body: String) throws {
        let url = bin.appendingPathComponent(name)
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
