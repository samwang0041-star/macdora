import XCTest
@testable import AndroidUse

final class DisplayPowerPolicyTests: XCTestCase {
    func testHiddenDisplayPowersOffAfterTheGracePeriod() {
        XCTAssertFalse(
            DisplayPowerPolicy.shouldPowerOff(
                backgroundSavingEnabled: true,
                hiddenFor: DisplayPowerPolicy.hiddenGrace - 0.1
            )
        )
        XCTAssertTrue(
            DisplayPowerPolicy.shouldPowerOff(
                backgroundSavingEnabled: true,
                hiddenFor: DisplayPowerPolicy.hiddenGrace
            )
        )
    }

    func testDisabledBackgroundSavingNeverPowersOffTheDisplay() {
        XCTAssertFalse(
            DisplayPowerPolicy.shouldPowerOff(
                backgroundSavingEnabled: false,
                hiddenFor: 60
            )
        )
    }
}
