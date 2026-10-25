import XCTest
import Metal
@testable import AndroidUse

final class InputContextTests: XCTestCase {
    @MainActor
    func testVirtualCompositionDocumentProvidesValidUTF16SelectionWithoutGuestText() throws {
        let surface = AndroidSurfaceView(frame: .zero, device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        XCTAssertEqual(surface.selectedRange(), NSRange(location: 0, length: 0))
        surface.setMarkedText("中🙂文", selectedRange: NSRange(location: 1, length: 2), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(surface.selectedRange(), NSRange(location: 1, length: 2))
        var actual = NSRange(location: NSNotFound, length: 0)
        let part = surface.attributedSubstring(forProposedRange: NSRange(location: 1, length: 2), actualRange: &actual)
        XCTAssertEqual(part?.string, "🙂"); XCTAssertEqual(actual, NSRange(location: 1, length: 2))
        surface.unmarkText()
        XCTAssertEqual(surface.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertNil(surface.attributedSubstring(forProposedRange: NSRange(location: 1, length: 2), actualRange: &actual))
    }
}
