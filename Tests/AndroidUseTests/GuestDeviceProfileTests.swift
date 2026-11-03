import XCTest
@testable import AndroidUse

final class GuestDeviceProfileTests: XCTestCase {
    func testXiaomiProfileUsesTheObservedFoldableIdentity() {
        let identity = GuestDeviceProfile.xiaomiFold.identity
        XCTAssertEqual(identity.brand, "Xiaomi")
        XCTAssertEqual(identity.model, "2308CPXD0C")
        XCTAssertEqual(identity.characteristics, "nosdcard")
        XCTAssertEqual(identity.density, "360")
        XCTAssertEqual(identity.boardPlatform, "kalama")
        XCTAssertEqual(identity.socModel, "SM8550")
        XCTAssertEqual(identity.firstAPILevel, "32")
        XCTAssertEqual(identity.buildID, "W528JS")
        XCTAssertEqual(identity.buildIncremental, "1243")
        XCTAssertEqual(identity.serial, "9F7A3C2D8E1B")
        XCTAssertEqual(
            identity.fingerprint,
            "Xiaomi/2308CPXD0C/2308CPXD0C:12/W528JS/1243:user/release-keys"
        )

        let script = RuntimeSoftwareDefaults.guestDeviceIdentityScript(profile: .xiaomiFold)
        XCTAssertTrue(script.contains("target_model=\"2308CPXD0C\""))
        XCTAssertTrue(script.contains("target_brand=\"Xiaomi\""))
        XCTAssertTrue(script.contains("target_density=\"360\""))
        XCTAssertTrue(script.contains("target_board_platform=\"kalama\""))
        XCTAssertTrue(script.contains("target_build_id=\"W528JS\""))
        XCTAssertTrue(script.contains("target_build_incremental=\"1243\""))
        let early = RuntimeSoftwareDefaults.earlyDeviceIdentityScript(profile: .xiaomiFold)
        XCTAssertTrue(early.contains("androiduse.early_profile \"xiaomi_fold\""))
    }

    func testLegacyPreferencesKeepTheSamsungTabletProfile() throws {
        let decoded = try JSONDecoder().decode(
            ContainerPreferences.self,
            from: Data(#"{"resolutionPreset":"1080p","targetFPS":60,"tabletMode":true}"#.utf8)
        )
        XCTAssertEqual(decoded.deviceProfile, .samsungTablet)
    }
}
