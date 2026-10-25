import XCTest
import Metal
@testable import AndroidUse

final class OrderedInputTests: XCTestCase {
    func testTouchBarrierAndFocusConfirmationCarryNoText() throws {
        let sequence: UInt64 = 0x0102030405060708
        XCTAssertEqual(Array(Wire.touchFinished(sequence)), [128,1,2,3,4,5,6,7,8])
        let response = Wire.integer(sequence) + Wire.integer(Int32(2)) + Data([1])
        let acknowledgement = try TouchFinishedAcknowledgement(payload: response)
        XCTAssertEqual(acknowledgement.sequence, sequence); XCTAssertEqual(acknowledgement.displayId, 2); XCTAssertTrue(acknowledgement.success)
        XCTAssertThrowsError(try TouchFinishedAcknowledgement(payload: response.dropLast()))
        XCTAssertThrowsError(try TouchFinishedAcknowledgement(payload: Wire.integer(sequence) + Wire.integer(Int32(-1)) + Data([1])))
        let request = DirectInputWire.confirm(sequence: 3, pointerSequence: sequence, displayId: 2)
        XCTAssertEqual(request.count, 30); XCTAssertEqual(Array(request.prefix(4)), [0x41,0x55,2,2])
        XCTAssertEqual(Wire.read(request, at: 16, as: UInt64.self), sequence)
        XCTAssertEqual(Wire.read(request, at: 28, as: UInt16.self), 0)
    }

    @MainActor
    func testDelayAndUnsolicitedOldFocusCannotRearmChineseInput() async throws {
        let surface = AndroidSurfaceView(frame: .zero, device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let lease = InputLease(connection: UUID(), epoch: 1, displayId: 2)
        let oldFocus = InputFocus(lease: lease, active: true, sensitive: false)
        var commits = 0; var issues = 0
        surface.sendDirectText = { _, _ in commits += 1 }; surface.onInputIssue = { _ in issues += 1 }
        surface.setInputFocus(oldFocus); surface.confirmInputFocus(oldFocus, pointerSequence: 0)
        surface.beginPointerInteraction()
        surface.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        surface.setInputFocus(oldFocus)
        try await Task.sleep(nanoseconds: 180_000_000)
        surface.insertText("中", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(commits, 0); XCTAssertEqual(issues, 1)
    }

    @MainActor
    func testFreshCompositionNeedsCurrentPointerConfirmationAndSameFieldCanRecover() throws {
        let surface = AndroidSurfaceView(frame: .zero, device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let connection = UUID(); let old = InputFocus(lease: InputLease(connection: connection, epoch: 4, displayId: 2), active: true, sensitive: false)
        surface.setInputFocus(old)
        let first = surface.beginPointerInteraction()
        let second = surface.beginPointerInteraction()
        var commits: [(String, InputLease)] = []
        surface.sendDirectText = { commits.append(($0, $1)) }
        surface.setMarkedText("hao", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        surface.confirmInputFocus(InputFocus(lease: InputLease(connection: connection, epoch: 4, pointerSequence: first, displayId: 2), active: true, sensitive: false), pointerSequence: first)
        let confirmed = InputLease(connection: connection, epoch: 4, pointerSequence: second, displayId: 2)
        surface.confirmInputFocus(InputFocus(lease: confirmed, active: true, sensitive: false), pointerSequence: second)
        surface.insertText("好", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(commits.count, 1); XCTAssertEqual(commits.first?.0, "好"); XCTAssertEqual(commits.first?.1, confirmed)
    }

    @MainActor
    func testSensitiveFocusImmediatelyDiscardsExistingCompositionPreview() throws {
        let surface = AndroidSurfaceView(frame: .zero, device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let connection = UUID()
        surface.setInputFocus(InputFocus(lease: InputLease(connection: connection, epoch: 1, displayId: 2), active: true, sensitive: false))
        surface.beginPointerInteraction()
        surface.setMarkedText("synthetic-preview", selectedRange: NSRange(location: 17, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(surface.hasMarkedText())
        surface.setInputFocus(InputFocus(lease: InputLease(connection: connection, epoch: 2, displayId: 2), active: true, sensitive: true))
        XCTAssertFalse(surface.hasMarkedText())
        XCTAssertTrue(surface.subviews.compactMap { $0 as? NSTextField }.allSatisfy { $0.isHidden && $0.stringValue.isEmpty })
    }

    @MainActor
    func testFailedReconfirmationRevokesAnExistingLease() throws {
        let surface = AndroidSurfaceView(frame: .zero, device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let focus = InputFocus(lease: InputLease(connection: UUID(), epoch: 1, displayId: 2), active: true, sensitive: false)
        var commits = 0; var issues = 0
        surface.sendDirectText = { _, _ in commits += 1 }; surface.onInputIssue = { _ in issues += 1 }
        surface.setInputFocus(focus); surface.confirmInputFocus(focus, pointerSequence: 0)
        surface.confirmInputFocus(nil, pointerSequence: 0)
        surface.insertText("中", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(commits, 0); XCTAssertEqual(issues, 1)
    }

    @MainActor
    func testASCIIPacketIsAtomicAndNeverFallsBackAfterDirectAttempt() throws {
        let surface = AndroidSurfaceView(frame: .zero, device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var packets: [Data] = []; var commits = 0; var issues = 0
        surface.sendInput = { packets.append($0) }; surface.sendDirectText = { _, _ in commits += 1 }; surface.onInputIssue = { _ in issues += 1 }
        surface.insertText(String(repeating: "a", count: 251), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(packets.isEmpty); XCTAssertEqual(issues, 1)
        surface.insertText("abc", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(packets, [Wire.text("abc")]); XCTAssertEqual(commits, 0)
        surface.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(packets.count, 1); XCTAssertEqual(issues, 2)
    }
}
