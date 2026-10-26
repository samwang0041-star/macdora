import XCTest
import CoreVideo
import CoreMedia
@testable import AndroidUse

final class DisplayFailureTests: XCTestCase {
    func testPresentationDeadlinePausesWhileHostApplicationIsInactive() {
        var deadline = DisplayStartupDeadline(at: 0)
        XCTAssertFalse(deadline.expired(at: 1, decoded: true, targetVisible: true, presentable: true, applicationActive: false))
        XCTAssertFalse(deadline.expired(at: 120, decoded: true, targetVisible: true, presentable: true, applicationActive: false))
        XCTAssertFalse(deadline.expired(at: 121, decoded: true, targetVisible: true, presentable: true, applicationActive: true))
        XCTAssertFalse(deadline.expired(at: 155, decoded: true, targetVisible: true, presentable: true, applicationActive: true))
        XCTAssertTrue(deadline.expired(at: 156, decoded: true, targetVisible: true, presentable: true, applicationActive: true))
    }

    func testMissingDecodeStillTimesOutWhileHostApplicationIsInactive() {
        var deadline = DisplayStartupDeadline(at: 0)
        XCTAssertTrue(deadline.expired(at: 35, decoded: false, targetVisible: true, presentable: true, applicationActive: false))
    }

    func testOneShotInputDoesNotDependOnWatchdogOrDuplicateWakeups() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixelBuffer = try XCTUnwrap(buffer)
        let measurement = ProbeMeasurement()
        var deadlines: [Double] = []
        var sent = 0
        var now = 100.0
        measurement.onScheduleTap = { deadlines.append($0) }
        measurement.onTap = { sent += 1; measurement.sent(at: now) }
        measurement.start(at: now)
        measurement.presented(DecodedFrame(buffer: pixelBuffer, pts: 0, marker: ProbeMarker(frame: 0, input: 0)), at: now)
        XCTAssertEqual(deadlines, [102])
        now = 101.99
        measurement.fireInput(at: now)
        XCTAssertEqual(sent, 0)
        // Frames keep the stream alive; the watchdog never triggers the tap.
        measurement.presented(DecodedFrame(buffer: pixelBuffer, pts: 1, marker: ProbeMarker(frame: 1, input: 0)), at: now)
        now = 102.01
        measurement.tick(at: now)
        XCTAssertEqual(sent, 0)
        measurement.fireInput(at: now)
        measurement.fireInput(at: now)
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(deadlines.count, 2)
        measurement.presented(DecodedFrame(buffer: pixelBuffer, pts: 2, marker: ProbeMarker(frame: 2, input: 1)), at: 102.04)
        now = deadlines[1]
        measurement.fireInput(at: now)
        measurement.fireInput(at: now)
        XCTAssertEqual(sent, 2)
        measurement.fail(at: now, reason: "test_complete")
        now += 1
        measurement.fireInput(at: now)
        XCTAssertEqual(sent, 2)
    }

    func testOcclusionDuringMeasurementIsRecordedAndDisqualifiesRun() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer)
        let measurement = ProbeMeasurement()
        var report: [String: Any]?
        measurement.onComplete = { report = $0 }
        measurement.start(at: 100)
        measurement.observedWindow(.init(visible: true, minimized: false, occluded: true, applicationActive: false), at: 100)
        measurement.observedWindow(.init(visible: true, minimized: false, occluded: false, applicationActive: true), at: 101)
        measurement.presented(DecodedFrame(buffer: try XCTUnwrap(buffer), pts: 0, marker: ProbeMarker(frame: 0, input: 0)), at: 102)
        measurement.observedWindow(.init(visible: true, minimized: false, occluded: true, applicationActive: false), at: 102.5)
        measurement.observedWindow(.init(visible: true, minimized: false, occluded: false, applicationActive: false), at: 102.75)
        measurement.fail(at: 103, reason: "test_complete")
        XCTAssertEqual(report?["windowUnavailableSeconds"] as? Double, 0.25)
        XCTAssertEqual((report?["gates"] as? [String: Bool])?["unoccludedWindow"], false)
        XCTAssertEqual((report?["windowStateEvents"] as? [[String: Any]])?.count, 4)
    }

    func testFirstPresentationDeadlinePausesWhileMinimizedButMissingFramesStillFail() {
        var deadline = DisplayStartupDeadline(at: 100)
        XCTAssertFalse(deadline.expired(at: 101, decoded: true, targetVisible: true, presentable: true))
        XCTAssertFalse(deadline.expired(at: 102, decoded: true, targetVisible: true, presentable: false))
        XCTAssertFalse(deadline.expired(at: 180, decoded: true, targetVisible: true, presentable: false))
        XCTAssertFalse(deadline.expired(at: 181, decoded: true, targetVisible: true, presentable: true))
        XCTAssertFalse(deadline.expired(at: 210, decoded: true, targetVisible: true, presentable: true))
        XCTAssertTrue(deadline.expired(at: 217, decoded: true, targetVisible: true, presentable: true))
        var missing = DisplayStartupDeadline(at: 100)
        XCTAssertTrue(missing.expired(at: 136, decoded: false, targetVisible: false, presentable: false))
    }
    func testAsyncDecoderFailureEndsStreamOnceAndNormalDroppedFrameDoesNot() {
        let stream = VideoStream()
        var failures: [Error] = []
        stream.onError = { failures.append($0) }
        stream.decoder.receiveOutput(status: 0, image: nil, pts: .zero)
        XCTAssertTrue(failures.isEmpty)
        stream.decoder.receiveOutput(status: -12909, image: nil, pts: .zero)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].localizedDescription.contains("12909"))
        stream.decoder.receiveOutput(status: -12909, image: nil, pts: .zero)
        XCTAssertEqual(failures.count, 1, "A stopped display must report one failure.")
    }

    func testPendingInputCannotPassEvenAfterThirtySuccessfulSamples() throws {
        let report = try simulateProbe(dropAfter: 30)
        XCTAssertEqual(report["inputCount"] as? Int, 30)
        XCTAssertEqual(report["inputAttempts"] as? Int, 31)
        XCTAssertEqual(report["timedOutInputs"] as? Int, 1)
        XCTAssertEqual(report["passed"] as? Bool, false)
    }

    func testCompletedInputSequenceCanPassWithoutCountingDuplicateFrames() throws {
        let report = try simulateProbe(dropAfter: nil)
        XCTAssertEqual(report["inputCount"] as? Int, 40)
        XCTAssertEqual(report["inputAttempts"] as? Int, 40)
        XCTAssertEqual(report["timedOutInputs"] as? Int, 0)
        XCTAssertEqual(report["passed"] as? Bool, true)
        XCTAssertLessThan(report["newPresentedFrames"] as? Int ?? .max, 1_925)
    }

    func testThirtyFPSDoesNotPassSixtyFPSGate() throws {
        let report = try simulateProbe(dropAfter: nil, fps: 30)
        XCTAssertEqual(report["passed"] as? Bool, false)
        XCTAssertEqual((report["gates"] as? [String: Bool])?["sixtyFPS"], false)
    }

    func testTailStallsCannotPassAfterAllInputsCompleted() throws {
        for stopAt in [30.1, 31.8] {
            let report = try simulateProbe(dropAfter: nil, stopAt: stopAt)
            XCTAssertEqual(report["inputCount"] as? Int, 40)
            XCTAssertEqual(report["passed"] as? Bool, false)
            XCTAssertEqual((report["gates"] as? [String: Bool])?["framePacing"], false)
            XCTAssertGreaterThan(report["tailGapMs"] as? Double ?? 0, 190)
        }
    }

    func testLateEventsCannotEraseDeadlinesBeforeWatchdogRuns() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixelBuffer = try XCTUnwrap(buffer)
        for timerFirst in [false, true] {
            let startup = ProbeMeasurement()
            var startupReport: [String: Any]?
            startup.onComplete = { startupReport = $0 }
            startup.start(at: 100)
            if timerFirst { startup.tick(at: 115.01) }
            startup.presented(DecodedFrame(buffer: pixelBuffer, pts: 0, marker: ProbeMarker(frame: 0, input: 0)), at: 115.01)
            startup.tick(at: 115.02)
            XCTAssertEqual(startupReport?["completionReason"] as? String, "no_first_frame")

            let input = ProbeMeasurement()
            var inputReport: [String: Any]?
            input.onComplete = { inputReport = $0 }
            input.start(at: 100)
            input.presented(DecodedFrame(buffer: pixelBuffer, pts: 0, marker: ProbeMarker(frame: 0, input: 0)), at: 100)
            input.sent(at: 100.1)
            for i in 1...125 {
                input.presented(DecodedFrame(buffer: pixelBuffer, pts: Int64(i), marker: ProbeMarker(frame: UInt32(i), input: 0)), at: 100 + Double(i) / 60)
            }
            if timerFirst { input.tick(at: 102.11) }
            input.presented(DecodedFrame(buffer: pixelBuffer, pts: 126, marker: ProbeMarker(frame: 126, input: 1)), at: 102.11)
            input.tick(at: 102.12)
            XCTAssertEqual(inputReport?["completionReason"] as? String, "input_timeout")
            XCTAssertEqual(inputReport?["inputCount"] as? Int, 0)
            XCTAssertEqual(inputReport?["timedOutInputs"] as? Int, 1)
        }
    }

    func testSkippedFrameDoesNotInvalidateOtherwisePassingRun() throws {
        let report = try simulateProbe(dropAfter: nil, includeSkipped: true)
        XCTAssertEqual(report["skippedPresentations"] as? Int, 1)
        XCTAssertEqual(report["invalidPresentationTimestamps"] as? Int, 0)
        XCTAssertEqual(report["passed"] as? Bool, true)
    }

    func testCoalescedDrawablesCountOneRefreshWithoutInvalidatingTime() throws {
        let report = try simulateProbe(dropAfter: nil, includeCoincident: true)
        let reference = try simulateProbe(dropAfter: nil)
        XCTAssertEqual(report["coincidentPresentations"] as? Int, 1)
        XCTAssertEqual(report["outOfOrderPresentations"] as? Int, 0)
        XCTAssertEqual(report["passed"] as? Bool, true)
        XCTAssertEqual(report["newPresentedFrames"] as? Int, reference["newPresentedFrames"] as? Int)
        XCTAssertEqual(report["newPresentedFPS"] as? Double, reference["newPresentedFPS"] as? Double)
        XCTAssertEqual(report["framePresentationTimesSeconds"] as? [Double], reference["framePresentationTimesSeconds"] as? [Double])
    }

    func testCoincidentCallbackCannotAcknowledgeInputBeforeANewerRefresh() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer)
        let image = try XCTUnwrap(buffer)
        let measurement = ProbeMeasurement()
        var report: [String: Any]?
        measurement.onComplete = { report = $0 }
        measurement.start(at: 100)
        measurement.presented(DecodedFrame(buffer: image, pts: 0, marker: .init(frame: 0, input: 0)), at: 100)
        measurement.sent(at: 100.1)
        measurement.presented(DecodedFrame(buffer: image, pts: 1, marker: .init(frame: 1, input: 0)), at: 100.2)
        measurement.presented(DecodedFrame(buffer: image, pts: 2, marker: .init(frame: 2, input: 1)), at: 100.2)
        measurement.presented(DecodedFrame(buffer: image, pts: 3, marker: .init(frame: 3, input: 1)), at: 100.3)
        measurement.fail(at: 100.4, reason: "test_complete")
        XCTAssertEqual(report?["inputCount"] as? Int, 1)
        XCTAssertEqual((report?["inputLatencySamplesMs"] as? [Double])?.first ?? -1, 200, accuracy: 0.001)
    }

    func testWatchdogCompletesWhenNoFramesEverArrive() {
        let measurement = ProbeMeasurement()
        var reports: [[String: Any]] = []
        measurement.onComplete = { reports.append($0) }
        measurement.start(at: 100)
        measurement.tick(at: 116)
        measurement.tick(at: 120)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?["completionReason"] as? String, "no_first_frame")
        XCTAssertEqual(reports.first?["passed"] as? Bool, false)
    }

    func testZeroAndBackwardsTimestampsAreExcluded() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer)
        let frame = DecodedFrame(buffer: try XCTUnwrap(buffer), pts: 0, marker: ProbeMarker(frame: 1, input: 0))
        let measurement = ProbeMeasurement()
        var report: [String: Any]?
        measurement.onComplete = { report = $0 }
        measurement.start(at: 99)
        measurement.presented(frame, at: 0)
        measurement.presented(frame, at: 100)
        measurement.presented(frame, at: 99)
        measurement.tick(at: 103)
        XCTAssertEqual(report?["newPresentedFrames"] as? Int, 1)
        XCTAssertEqual(report?["invalidPresentationTimestamps"] as? Int, 0)
        XCTAssertEqual(report?["outOfOrderPresentations"] as? Int, 1)
        XCTAssertEqual(report?["skippedPresentations"] as? Int, 1)
        XCTAssertEqual(report?["completionReason"] as? String, "presentation_stall")
    }

    func testProbeMarkerReadsBothBGRAAndNV12BiPlanarBuffers() throws {
        let expectedFrame: UInt32 = 0xA55A_3C96
        let expectedInput: UInt16 = 0x5AA5

        var bgraBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(kCFAllocatorDefault, 820, 96, kCVPixelFormatType_32BGRA, nil, &bgraBuffer),
            kCVReturnSuccess
        )
        let bgra = try XCTUnwrap(bgraBuffer)
        CVPixelBufferLockBaseAddress(bgra, [])
        if let base = CVPixelBufferGetBaseAddress(bgra)?.assumingMemoryBound(to: UInt8.self) {
            let stride = CVPixelBufferGetBytesPerRow(bgra)
            memset(base, 0, stride * 96)
            for i in 0..<32 where ((expectedFrame >> i) & 1) == 1 {
                let offset = 28 * stride + (16 + 24 * i + 12) * 4
                base[offset] = 255; base[offset + 1] = 255; base[offset + 2] = 255; base[offset + 3] = 255
            }
            for i in 0..<16 where ((expectedInput >> i) & 1) == 1 {
                let offset = 60 * stride + (16 + 24 * i + 12) * 4
                base[offset] = 255; base[offset + 1] = 255; base[offset + 2] = 255; base[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(bgra, [])
        let bgraMarker = try XCTUnwrap(ProbeMarker.read(bgra))
        XCTAssertEqual(bgraMarker.frame, expectedFrame)
        XCTAssertEqual(bgraMarker.input, expectedInput)

        var nv12Buffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                820,
                96,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                nil,
                &nv12Buffer
            ),
            kCVReturnSuccess
        )
        let nv12 = try XCTUnwrap(nv12Buffer)
        CVPixelBufferLockBaseAddress(nv12, [])
        if let yBase = CVPixelBufferGetBaseAddressOfPlane(nv12, 0)?.assumingMemoryBound(to: UInt8.self) {
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(nv12, 0)
            memset(yBase, 16, yStride * 96)
            for i in 0..<32 where ((expectedFrame >> i) & 1) == 1 {
                yBase[28 * yStride + (16 + 24 * i + 12)] = 235
            }
            for i in 0..<16 where ((expectedInput >> i) & 1) == 1 {
                yBase[60 * yStride + (16 + 24 * i + 12)] = 235
            }
        }
        CVPixelBufferUnlockBaseAddress(nv12, [])
        let nv12Marker = try XCTUnwrap(ProbeMarker.read(nv12))
        XCTAssertEqual(nv12Marker.frame, expectedFrame)
        XCTAssertEqual(nv12Marker.input, expectedInput)
    }

    private func simulateProbe(dropAfter: Int?, fps: Double = 60, stopAt: Double = 32, includeSkipped: Bool = false, includeCoincident: Bool = false) throws -> [String: Any] {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        let measurement = ProbeMeasurement()
        measurement.hardwareDecoder = true
        measurement.start(at: 100)
        var now = 100.0
        var attempts = 0
        var input: UInt16 = 0
        var feedbackFrame: Int?
        var index = 0
        var result: [String: Any]?
        measurement.onTap = {
            attempts += 1
            measurement.sent(at: now)
            if dropAfter == nil || attempts <= dropAfter! { feedbackFrame = index + 2 }
        }
        measurement.onComplete = { result = $0 }
        for frame in 0...4_000 {
            index = frame; now = 100 + Double(frame) / (fps * 2)
            if feedbackFrame == frame { input &+= 1; feedbackFrame = nil }
            // Two adjacent redraws share a frame ID, so only one should count.
            let marker = ProbeMarker(frame: UInt32(frame / 2), input: input)
            if includeSkipped && frame == 10 { measurement.invalidPresentation(at: 0) }
            if now - 100 <= stopAt { measurement.presented(DecodedFrame(buffer: pixelBuffer, pts: 0, marker: marker), at: now) }
            if includeCoincident && frame == 10 {
                measurement.presented(DecodedFrame(buffer: pixelBuffer, pts: 1, marker: ProbeMarker(frame: 7, input: input)), at: now)
            }
            measurement.tick(at: now)
            if result != nil { break }
        }
        return try XCTUnwrap(result)
    }
}
