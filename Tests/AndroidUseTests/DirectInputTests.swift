import XCTest
import Metal
@testable import AndroidUse

final class DirectInputTests: XCTestCase {
    func testDirectCommitHasBoundedUTF8AndFocusLease() throws {
        let bytes = try DirectInputWire.commit("中文abc", epoch: 123, sequence: 8, pointerSequence: 7, displayId: 2)
        XCTAssertEqual(Array(bytes.prefix(4)), [0x41, 0x55, 2, 1])
        XCTAssertEqual(Wire.read(bytes, at: 4, as: UInt32.self), 8)
        XCTAssertEqual(Wire.read(bytes, at: 8, as: UInt64.self), 123)
        XCTAssertEqual(Wire.read(bytes, at: 16, as: UInt64.self), 7)
        XCTAssertEqual(Wire.read(bytes, at: 24, as: UInt32.self), 2)
        XCTAssertEqual(Wire.read(bytes, at: 28, as: UInt16.self), 9)
        XCTAssertEqual(String(data: bytes.dropFirst(30), encoding: .utf8), "中文abc")
        XCTAssertThrowsError(try DirectInputWire.commit(String(repeating: "中", count: 1_400), epoch: 123, sequence: 8))
    }

    func testSingleCommitKeepsUnicodeCharactersAtomic() throws {
        let text = String(repeating: "中文👨‍👩‍👧‍👦abc", count: 100)
        let bytes = try DirectInputWire.commit(text, epoch: 5, sequence: 1)
        XCTAssertEqual(String(data: bytes.dropFirst(30), encoding: .utf8), text)
        XCTAssertEqual(bytes.count, text.utf8.count + 30)
    }

    @MainActor
    func testOrdinaryChineseUsesDirectInputWithoutClipboardPackets() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let surface = AndroidSurfaceView(frame: .zero, device: device)
        let lease = InputLease(connection: UUID(), epoch: 12, displayId: 2)
        var packets: [Data] = []; var commits: [String] = []
        surface.sendInput = { packets.append($0) }
        surface.sendDirectText = { text, token in XCTAssertEqual(token, lease); commits.append(text) }
        surface.setInputFocus(InputFocus(lease: lease, active: true, sensitive: false))
        surface.confirmInputFocus(InputFocus(lease: lease, active: true, sensitive: false), pointerSequence: 0)
        surface.insertText("中文abc", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(commits, ["中文abc"])
        XCTAssertTrue(packets.isEmpty, "Ordinary input must never write the Guest clipboard.")
        surface.inputEnabled = false
        surface.insertText("加载期间", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(commits, ["中文abc"])
    }

    @MainActor
    func testChangingFocusCancelsCompositionAndMissingIMERejectsChinese() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let surface = AndroidSurfaceView(frame: .zero, device: device)
        let connection = UUID()
        surface.setInputFocus(InputFocus(lease: InputLease(connection: connection, epoch: 1), active: true, sensitive: false))
        surface.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(surface.hasMarkedText())
        surface.setInputFocus(InputFocus(lease: InputLease(connection: connection, epoch: 2), active: true, sensitive: false))
        XCTAssertFalse(surface.hasMarkedText())
        var packets: [Data] = []; var issues = 0
        surface.sendInput = { packets.append($0) }; surface.onInputIssue = { _ in issues += 1 }
        surface.insertText("旧组字", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(packets.isEmpty); XCTAssertEqual(issues, 0)
        let unfocused = AndroidSurfaceView(frame: .zero, device: device)
        unfocused.sendInput = { packets.append($0) }; unfocused.onInputIssue = { _ in issues += 1 }
        unfocused.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(packets.isEmpty); XCTAssertEqual(issues, 1)
    }
}
