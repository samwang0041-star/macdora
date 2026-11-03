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
        XCTAssertTrue(verticalScript.contains("\"ro.system.build.fingerprint\""))
        XCTAssertTrue(verticalScript.contains("\"ro.vendor.build.fingerprint\""))
        XCTAssertTrue(verticalScript.contains("setprop gsm.operator.numeric 46000"))
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
        fixture.assertZygoteWasNotStopped()
    }

    func testLegacyPhoneIdentityMigrationDoesNotDeleteApplicationAuthentication() throws {
        let previousModel = GuestDeviceIdentity.phone.model
        let fixture = try GuestIdentityShellFixture(marker: previousModel, cacheModel: previousModel)
        defer { fixture.remove() }
        try fixture.runSetup()
        fixture.assertGuestIdentityIsTablet()
        fixture.assertAuthenticationPreserved()
    }

    func testEarlyBootHookAppliesIdentityBeforeZygote() {
        let identity = RuntimeSoftwareDefaults.earlyDeviceIdentityScript()
        XCTAssertTrue(identity.contains("sys.androiduse.zygote_model"))
        XCTAssertTrue(identity.contains("androiduse.device_identity 1"))
        XCTAssertTrue(
            identity.contains("androiduse.device_identity_version \(RuntimeSoftwareDefaults.deviceIdentityVersion)")
        )
        XCTAssertTrue(identity.contains("setprop debug.egl.blobcache.multifile true"))
        XCTAssertTrue(identity.contains(
            "setprop debug.egl.blobcache.multifile_limit \(RuntimeSoftwareDefaults.angleBlobCacheLimitBytes)"
        ))
        for fingerprint in [
            "ro.system.build.fingerprint",
            "ro.product.build.fingerprint",
            "ro.system_ext.build.fingerprint",
            "ro.vendor.build.fingerprint",
            "ro.vendor_dlkm.build.fingerprint",
            "ro.system_dlkm.build.fingerprint",
            "ro.odm.build.fingerprint"
        ] {
            XCTAssertTrue(identity.contains(fingerprint), "Missing early fingerprint \(fingerprint)")
        }
        XCTAssertTrue(identity.contains("setprop gsm.operator.numeric 46000"))
        XCTAssertTrue(identity.contains("setprop gsm.sim.operator.numeric 460000"))
        XCTAssertTrue(identity.contains("\"ro.kernel.qemu\""))
        XCTAssertTrue(identity.contains("\"ro.boot.qemu\""))
        XCTAssertTrue(identity.contains("\"ro.hardware\""))
        XCTAssertTrue(identity.contains("\"ro.boot.hardware\""))
        XCTAssertTrue(identity.contains("\"ro.boot.hardware.vulkan\""))
        XCTAssertTrue(identity.contains("\"ro.product.system_dlkm.model\""))
        XCTAssertTrue(identity.contains("\"ro.soc.model\""))
        XCTAssertTrue(identity.contains("\"ro.soc.manufacturer\""))
        XCTAssertTrue(identity.contains("patch_prop \"u:object_r:serialno_prop:s0\" \"ro.serialno\""))
        XCTAssertTrue(identity.contains("patch_prop \"u:object_r:serialno_prop:s0\" \"ro.boot.serialno\""))
        XCTAssertFalse(identity.contains("ctl.restart zygote"))
        XCTAssertFalse(identity.contains("ctl.stop zygote"))

        let recovery = RuntimeSoftwareDefaults.guestDeviceIdentityScript()
        XCTAssertFalse(recovery.contains("ctl.stop zygote"))

        let identityRC = RuntimeSoftwareDefaults.earlyDeviceIdentityInitRC
        XCTAssertTrue(identityRC.contains("ANDROIDUSE_DEVICE_IDENTITY_V1"))
        XCTAssertTrue(identityRC.contains("on post-fs"))
        XCTAssertTrue(identityRC.contains("wait_for_prop androiduse.device_identity 1"))

        let winextRC = RuntimeSoftwareDefaults.earlyWindowExtensionsInitRC
        XCTAssertTrue(winextRC.contains("ANDROIDUSE_WINEXT_V1"))
        XCTAssertTrue(winextRC.contains("wait_for_prop androiduse.winext_ready 1"))

        let winext = RuntimeSoftwareDefaults.earlyWindowExtensionsScript()
        XCTAssertTrue(winext.contains("androidx.window.extensions.jar"))
        XCTAssertTrue(winext.contains("androiduse.winext_ready 1"))

        XCTAssertEqual(
            recovery.components(separatedBy: "cur_zygote_model=\"stale\"").count - 1,
            1,
            "Window-extension refresh must not masquerade as a device identity change."
        )
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
            "ro.product.first_api_level": identity.firstAPILevel,
            "ro.board.platform": identity.boardPlatform,
            "ro.soc.manufacturer": "Qualcomm",
            "ro.soc.model": identity.socModel,
            "ro.serialno": identity.serial,
            "ro.boot.serialno": identity.serial,
            "ro.build.characteristics": identity.characteristics,
            "ro.build.type": "user",
            "ro.build.tags": "release-keys",
            "ro.build.product": identity.device,
            "ro.build.id": identity.buildID,
            "ro.build.version.incremental": identity.buildIncremental,
            "ro.build.flavor": "\(identity.device)-user",
            "ro.build.description": "\(identity.device)-user 12 \(identity.buildID) \(identity.buildIncremental) release-keys",
            "ro.build.display.id": identity.buildID,
            "ro.hardware": "qcom",
            "ro.boot.hardware": "qcom",
            "ro.boot.hardware.vulkan": "qcom",
            "qemu.sf.lcd_density": identity.density,
            "ro.build.fingerprint": identity.fingerprint,
            "ro.system.build.fingerprint": identity.fingerprint,
            "ro.product.build.fingerprint": identity.fingerprint,
            "ro.system_ext.build.fingerprint": identity.fingerprint,
            "ro.vendor.build.fingerprint": identity.fingerprint,
            "ro.vendor_dlkm.build.fingerprint": identity.fingerprint,
            "ro.system_dlkm.build.fingerprint": identity.fingerprint,
            "ro.odm.build.fingerprint": identity.fingerprint,
            "live_zygote_pid": "100"
        ]
        if let marker {
            values["sys.androiduse.zygote_model"] = marker == "current" ? identity.model : marker
            values["sys.androiduse.zygote_pid"] = stalePID ? "99" : "100"
            values["sys.androiduse.winext_patch"] = "v2"
        }
        for namespace in ["", "system.", "product.", "system_ext.", "vendor.", "vendor_dlkm.", "system_dlkm.", "odm."] {
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

    func assertZygoteWasNotStopped(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("properties/ctl.stop").path),
            "Identity recovery must leave zygote alive until the single restart gate.",
            file: file,
            line: line
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    private func stub(_ name: String, _ body: String) throws {
        let url = bin.appendingPathComponent(name)
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
