import XCTest
@testable import AndroidUse

final class HostPerformanceProfileTests: XCTestCase {
    func testLowMemoryAppleSiliconKeepsTheConservativeGuestBudget() {
        XCTAssertEqual(
            HostPerformanceProfile.resolve(
                physicalMemoryBytes: 8 * 1024 * 1024 * 1024,
                performanceCores: 4
            ),
            HostPerformanceProfile(guestMemoryMB: 4096, guestCPUCount: 4, guestRefreshRate: 60)
        )
        XCTAssertEqual(
            HostPerformanceProfile.resolve(
                physicalMemoryBytes: 16 * 1024 * 1024 * 1024,
                performanceCores: 6
            ),
            HostPerformanceProfile(guestMemoryMB: 6144, guestCPUCount: 6, guestRefreshRate: 60)
        )
    }

    func testHighMemoryAppleSiliconGetsMoreGuestMemoryAndCores() {
        XCTAssertEqual(
            HostPerformanceProfile.resolve(
                physicalMemoryBytes: 32 * 1024 * 1024 * 1024,
                performanceCores: 8
            ),
            HostPerformanceProfile(guestMemoryMB: 12288, guestCPUCount: 8, guestRefreshRate: 120)
        )
        XCTAssertEqual(
            HostPerformanceProfile.resolve(
                physicalMemoryBytes: 128 * 1024 * 1024 * 1024,
                performanceCores: 12
            ),
            HostPerformanceProfile(guestMemoryMB: 12288, guestCPUCount: 8, guestRefreshRate: 120)
        )
    }

    func testGuestCoresNeverDropBelowFour() {
        XCTAssertEqual(
            HostPerformanceProfile.resolve(
                physicalMemoryBytes: 24 * 1024 * 1024 * 1024,
                performanceCores: 2
            ),
            HostPerformanceProfile(guestMemoryMB: 9216, guestCPUCount: 4, guestRefreshRate: 60)
        )
        XCTAssertEqual(
            HostPerformanceProfile.resolve(
                physicalMemoryBytes: 64 * 1024 * 1024 * 1024,
                performanceCores: 6
            ),
            HostPerformanceProfile(guestMemoryMB: 12288, guestCPUCount: 6, guestRefreshRate: 120)
        )
    }

    func testAppleSiliconTopologiesUsePerformanceCoresWithoutChipNameTables() {
        XCTAssertEqual(
            HostPerformanceProfile.resolve(
                physicalMemoryBytes: 18 * 1024 * 1024 * 1024,
                performanceCores: 6
            ),
            HostPerformanceProfile(guestMemoryMB: 6144, guestCPUCount: 6, guestRefreshRate: 60)
        )
        XCTAssertEqual(
            HostPerformanceProfile.resolve(
                physicalMemoryBytes: 24 * 1024 * 1024 * 1024,
                performanceCores: 4
            ),
            HostPerformanceProfile(guestMemoryMB: 9216, guestCPUCount: 4, guestRefreshRate: 60)
        )
        XCTAssertEqual(
            HostPerformanceProfile.resolve(
                physicalMemoryBytes: 36 * 1024 * 1024 * 1024,
                performanceCores: 12
            ),
            HostPerformanceProfile(guestMemoryMB: 12288, guestCPUCount: 8, guestRefreshRate: 120)
        )
    }
}
