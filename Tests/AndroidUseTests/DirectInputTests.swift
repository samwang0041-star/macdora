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

    func testDirectInputPortHubMultiplexesConcurrentWindowClientsOnSingleSocket() throws {
        let serverFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(serverFD, 0)
        defer { Darwin.close(serverFD) }
        var reuse: Int32 = 1
        setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindRes, 0)
        XCTAssertEqual(Darwin.listen(serverFD, 4), 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(serverFD, $0, &len)
            }
        }
        let port = UInt16(bigEndian: addr.sin_port)

        let acceptedLock = NSLock()
        var acceptedCount = 0
        let serverDone = expectation(description: "Mock IME server processed both window clients on one connection")

        DispatchQueue.global(qos: .userInitiated).async {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let connFD = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(serverFD, $0, &clientLen)
                }
            }
            guard connFD >= 0 else { return }
            defer { Darwin.close(connFD) }
            acceptedLock.lock(); acceptedCount += 1; acceptedLock.unlock()

            func sendAll(_ data: Data) {
                _ = data.withUnsafeBytes { Darwin.send(connFD, $0.baseAddress!, data.count, 0) }
            }
            func recvExact(_ count: Int) -> Data? {
                var buf = [UInt8](repeating: 0, count: count)
                var got = 0
                while got < count {
                    let n = buf.withUnsafeMutableBytes { Darwin.recv(connFD, $0.baseAddress!.advanced(by: got), count - got, 0) }
                    if n <= 0 { return nil }
                    got += n
                }
                return Data(buf)
            }

            // Send hello (version 0,2, uid 2000) + initial active focus (type 1, active=1, sensitive=0, epoch=42)
            sendAll(Data([0, 2]) + Wire.integer(UInt32(2000)))
            sendAll(Data([1, 1, 0]) + Wire.integer(UInt64(42)))

            // Handle 4 requests (confirm + commit for window 1, confirm + commit for window 2)
            for _ in 0..<4 {
                guard let header = recvExact(30) else { break }
                let op = header[3]
                let seq: UInt32 = Wire.read(header, at: 4)
                let epoch: UInt64 = Wire.read(header, at: 8)
                let ptr: UInt64 = Wire.read(header, at: 16)
                let disp = Int32(bitPattern: Wire.read(header, at: 24, as: UInt32.self))
                let textLen = Int(Wire.read(header, at: 28, as: UInt16.self))
                if textLen > 0 { _ = recvExact(textLen) }
                if op == 2 {
                    // Reply type 3 (confirm ack)
                    let payload = Data([3]) + Wire.integer(seq) + Data([0]) + Wire.integer(UInt64(42))
                        + Wire.integer(ptr) + Wire.integer(UInt32(bitPattern: disp)) + Data([0])
                    sendAll(payload)
                } else if op == 1 {
                    let status: UInt8 = (epoch == 42) ? 0 : 2
                    sendAll(Data([2, status]) + Wire.integer(seq))
                }
            }
            serverDone.fulfill()
        }

        let focusReady1 = expectation(description: "Client 1 received initial focus")
        let focusReady2 = expectation(description: "Client 2 received initial focus")
        var fulfilled1 = false
        var fulfilled2 = false

        let client1 = DirectInputClient(port: port)
        let client2 = DirectInputClient(port: port)
        defer { client1.stop(); client2.stop() }

        client1.onFocus = { focus in
            if focus?.active == true, !fulfilled1 { fulfilled1 = true; focusReady1.fulfill() }
        }
        client2.onFocus = { focus in
            if focus?.active == true, !fulfilled2 { fulfilled2 = true; focusReady2.fulfill() }
        }

        client1.start()
        client2.start()
        wait(for: [focusReady1, focusReady2], timeout: 2.0)

        // Window 1 confirms on display 2 and commits text
        client1.invalidatePointer(101)
        let confirmed1 = try XCTUnwrap(try client1.confirm(pointerSequence: 101, displayId: 2))
        XCTAssertEqual(confirmed1.lease.displayId, 2)
        try client1.commit("微信窗口输入", lease: confirmed1.lease)

        // Window 2 confirms on display 3 and commits text without disconnecting Window 1
        client2.invalidatePointer(202)
        let confirmed2 = try XCTUnwrap(try client2.confirm(pointerSequence: 202, displayId: 3))
        XCTAssertEqual(confirmed2.lease.displayId, 3)
        try client2.commit("OA窗口输入", lease: confirmed2.lease)

        wait(for: [serverDone], timeout: 2.0)
        acceptedLock.lock()
        let totalAccepted = acceptedCount
        acceptedLock.unlock()
        XCTAssertEqual(totalAccepted, 1, "Multiple concurrent window clients must multiplex over a single guest IME socket.")
    }
}
