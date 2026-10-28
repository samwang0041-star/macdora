import XCTest
@testable import AndroidUse

final class DisplayReconfigurationTests: XCTestCase {
    private let configuration = DisplayStreamConfiguration(
        nativeWidth: 1600,
        nativeHeight: 2560,
        density: 400,
        maxSize: 1920,
        maxFPS: 45
    )

    func testDisplayConfigurationWireLayoutIsExact() {
        let packet = Wire.displayConfiguration(configuration, sequence: 0x0102_0304)

        XCTAssertEqual(packet.count, 25)
        XCTAssertEqual(Array(packet), [
            129,
            1, 2, 3, 4,
            0, 0, 6, 0x40,
            0, 0, 0x0A, 0x00,
            0, 0, 0x01, 0x90,
            0, 0, 0x07, 0x80,
            0, 0, 0, 0x2D,
        ])
    }

    func testDisplayConfigurationValidationUsesDeclaredBounds() {
        XCTAssertTrue(configuration.isValid)
        XCTAssertTrue(DisplayStreamConfiguration(
            nativeWidth: 320,
            nativeHeight: 4096,
            density: 320,
            maxSize: 1280,
            maxFPS: 30
        ).isValid)
        XCTAssertFalse(DisplayStreamConfiguration(
            nativeWidth: 319,
            nativeHeight: 2560,
            density: 400,
            maxSize: 1920,
            maxFPS: 45
        ).isValid)
        XCTAssertFalse(DisplayStreamConfiguration(
            nativeWidth: 1600,
            nativeHeight: 2560,
            density: 360,
            maxSize: 1920,
            maxFPS: 45
        ).isValid)
        XCTAssertFalse(DisplayStreamConfiguration(
            nativeWidth: 1600,
            nativeHeight: 2560,
            density: 400,
            maxSize: 1600,
            maxFPS: 45
        ).isValid)
        XCTAssertFalse(DisplayStreamConfiguration(
            nativeWidth: 1600,
            nativeHeight: 2560,
            density: 400,
            maxSize: 1920,
            maxFPS: 50
        ).isValid)
    }

    func testDisplayConfigurationAcknowledgementStatusAndType() throws {
        let success = try DisplayConfigurationAcknowledgement(
            payload: Data([4, 1, 2, 3, 4, 0])
        )
        XCTAssertEqual(success, DisplayConfigurationAcknowledgement(sequence: 0x0102_0304, success: true))

        let failure = try DisplayConfigurationAcknowledgement(
            payload: Data([4, 1, 2, 3, 4, 1])
        )
        XCTAssertFalse(failure.success)
        XCTAssertThrowsError(try DisplayConfigurationAcknowledgement(payload: Data([3, 1, 2, 3, 4, 0])))
        XCTAssertThrowsError(try DisplayConfigurationAcknowledgement(payload: Data([4, 1, 2, 3, 4, 2])))
        XCTAssertThrowsError(try DisplayConfigurationAcknowledgement(payload: Data([4, 1, 2, 3, 4])))
    }

    func testRegistryAcknowledgesOnlyMatchingSequenceOnce() throws {
        let completed = expectation(description: "configuration acknowledged")
        let registry = DisplayUpdateRegistry(timeout: 1, callbackQueue: DispatchQueue(label: "display-registry-ack"))
        var results: [Bool] = []
        let sequence = try XCTUnwrap(registry.begin {
            results.append($0)
            completed.fulfill()
        })

        XCTAssertFalse(registry.acknowledge(sequence: sequence &+ 1, success: true))
        XCTAssertTrue(registry.acknowledge(sequence: sequence, success: true))
        XCTAssertFalse(registry.acknowledge(sequence: sequence, success: false))
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(results, [true])
    }

    func testRegistryRejectsConcurrentRequestWithoutDisturbingFirst() throws {
        let firstCompleted = expectation(description: "first completed")
        let secondCompleted = expectation(description: "second rejected")
        let registry = DisplayUpdateRegistry(timeout: 1, callbackQueue: DispatchQueue(label: "display-registry-concurrent"))
        var firstResult: Bool?
        var secondResult: Bool?
        let firstSequence = try XCTUnwrap(registry.begin {
            firstResult = $0
            firstCompleted.fulfill()
        })

        XCTAssertNil(registry.begin {
            secondResult = $0
            secondCompleted.fulfill()
        })
        XCTAssertTrue(registry.acknowledge(sequence: firstSequence, success: true))
        wait(for: [firstCompleted, secondCompleted], timeout: 1)
        XCTAssertEqual(firstResult, true)
        XCTAssertEqual(secondResult, false)
    }

    func testRegistryTimesOutWithExactlyOneFailure() throws {
        let completed = expectation(description: "configuration timed out")
        let registry = DisplayUpdateRegistry(timeout: 0.05, callbackQueue: DispatchQueue(label: "display-registry-timeout"))
        var results: [Bool] = []
        let sequence = try XCTUnwrap(registry.begin {
            results.append($0)
            completed.fulfill()
        })

        wait(for: [completed], timeout: 1)
        XCTAssertFalse(registry.acknowledge(sequence: sequence, success: true))
        XCTAssertEqual(results, [false])
    }

    func testControlAcknowledgementWaitsForMatchingVideoMetadata() throws {
        let completed = expectation(description: "control and video both confirmed")
        let queue = DispatchQueue(label: "display-control-video")
        let registry = DisplayUpdateRegistry(timeout: 1, callbackQueue: queue)
        var results: [Bool] = []
        let sequence = try XCTUnwrap(registry.begin(expectedVideoSize: CGSize(width: 1280, height: 800)) {
            results.append($0)
            completed.fulfill()
        })
        XCTAssertTrue(registry.acknowledge(sequence: sequence, success: true))
        queue.sync {}
        XCTAssertTrue(results.isEmpty, "控制通道确认不能早于视频通道确认新尺寸")
        registry.receiveVideoSize(CGSize(width: 1920, height: 1200))
        queue.sync {}
        XCTAssertTrue(results.isEmpty)
        registry.receiveVideoSize(CGSize(width: 1280, height: 800))
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(results, [true])
    }

    func testRegistryStopFailsPendingUpdateAndIgnoresLateAcknowledgement() throws {
        let completed = expectation(description: "configuration stopped")
        let registry = DisplayUpdateRegistry(timeout: 1, callbackQueue: DispatchQueue(label: "display-registry-stop"))
        var results: [Bool] = []
        let sequence = try XCTUnwrap(registry.begin {
            results.append($0)
            completed.fulfill()
        })

        registry.stop()
        XCTAssertFalse(registry.acknowledge(sequence: sequence, success: true))
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(results, [false])
    }
}
