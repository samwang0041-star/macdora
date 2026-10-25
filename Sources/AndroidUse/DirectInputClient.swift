import Foundation

struct InputLease: Equatable {
    let connection: UUID
    let epoch: UInt64
    let pointerSequence: UInt64
    let displayId: Int32
    init(connection: UUID, epoch: UInt64, pointerSequence: UInt64 = 0, displayId: Int32 = -1) {
        self.connection = connection; self.epoch = epoch; self.pointerSequence = pointerSequence; self.displayId = displayId
    }
    func hasSameEditor(as other: InputLease) -> Bool { connection == other.connection && epoch == other.epoch }
}

struct InputFocus: Equatable {
    let lease: InputLease
    let active: Bool
    let sensitive: Bool
}

enum DirectInputWire {
    static func commit(_ text: String, epoch: UInt64, sequence: UInt32, pointerSequence: UInt64 = 0, displayId: Int32 = -1) throws -> Data {
        let bytes = Data(text.utf8)
        guard !bytes.isEmpty, bytes.count <= 4_096 else { throw DirectInputFailure.tooLong }
        return request(operation: 1, sequence: sequence, epoch: epoch, pointerSequence: pointerSequence, displayId: displayId, bytes: bytes)
    }
    static func confirm(sequence: UInt32, pointerSequence: UInt64, displayId: Int32) -> Data {
        request(operation: 2, sequence: sequence, epoch: 0, pointerSequence: pointerSequence, displayId: displayId, bytes: Data())
    }
    private static func request(operation: UInt8, sequence: UInt32, epoch: UInt64, pointerSequence: UInt64, displayId: Int32, bytes: Data) -> Data {
        Data([0x41, 0x55, 2, operation]) + Wire.integer(sequence) + Wire.integer(epoch)
            + Wire.integer(pointerSequence) + Wire.integer(displayId) + Wire.integer(UInt16(bytes.count)) + bytes
    }
}

enum DirectInputFailure: LocalizedError {
    case noFocus, expired, tooLong, unconfirmed, protocolMismatch
    var errorDescription: String? {
        switch self {
        case .noFocus: return "请先在应用中选择文字输入框。应用自带的安全键盘请直接点击操作。"
        case .expired: return "输入框已切换，本次未提交的文字已取消。请在当前输入框重新输入。"
        case .tooLong: return "这次文字超出本地输入长度限制，请分段输入或明确使用粘贴。"
        case .unconfirmed: return "本次文字提交未获确认，请核对应用中的内容后再继续。软件不会自动重发。"
        case .protocolMismatch: return "本地输入组件连接不匹配，请停止环境后重新打开。"
        }
    }
}

/// Focus-only state and bounded direct commits; no editor text is read back.
final class DirectInputClient {
    private struct Reply { let status: Int; let focus: InputFocus? }
    private let port: UInt16
    private let reader = DispatchQueue(label: "local.androiduse.ime-state", qos: .userInitiated)
    private let stateLock = NSLock()
    private let acknowledgement = NSCondition()
    private var socket: LocalSocket?
    private var observedFocus: InputFocus?
    private var confirmedFocus: InputFocus?
    private var activePointer: UInt64 = 0
    private var stopped = false
    private var sequence: UInt32 = 0 // Only the serial VideoStream input queue writes.
    private var waiting: (connection: UUID, sequence: UInt32, operation: UInt8)?
    private var outcome: Reply?
    var onFocus: ((InputFocus?) -> Void)?

    init(port: UInt16) { self.port = port }

    func invalidatePointer(_ pointerSequence: UInt64) {
        stateLock.lock(); activePointer = pointerSequence; confirmedFocus = nil; stateLock.unlock()
        acknowledgement.lock()
        if waiting?.operation == 2 {
            outcome = Reply(status: 2, focus: nil)
            acknowledgement.broadcast()
        }
        acknowledgement.unlock()
    }

    func start() {
        reader.async { [self] in
            while true {
                stateLock.lock(); let done = stopped; stateLock.unlock()
                if done { return }
                var connected: LocalSocket?
                do {
                    let socket = try LocalSocket(port: port); connected = socket
                    let connection = UUID()
                    stateLock.lock()
                    if stopped { stateLock.unlock(); socket.close(); return }
                    self.socket = socket; stateLock.unlock()
                    let hello = try socket.receive(6)
                    let uid: UInt32 = Wire.read(hello, at: 2)
                    guard hello[0] == 0, hello[1] == 2, uid == 0 || uid == 2000 else { throw DirectInputFailure.protocolMismatch }
                    while true {
                        let type = try socket.receive(1)[0]
                        switch type {
                        case 1:
                            let state = try socket.receive(10)
                            guard state[0] <= 1, state[1] <= 1 else { throw DirectInputFailure.protocolMismatch }
                            let epoch: UInt64 = Wire.read(state, at: 2)
                            let focus = InputFocus(lease: InputLease(connection: connection, epoch: epoch), active: state[0] == 1, sensitive: state[1] == 1)
                            stateLock.lock()
                            let active = !stopped && self.socket === socket
                            if active {
                                if observedFocus?.lease.hasSameEditor(as: focus.lease) != true || !focus.active { confirmedFocus = nil }
                                observedFocus = focus
                            }
                            stateLock.unlock()
                            if active { onFocus?(focus) }
                        case 2:
                            let reply = try socket.receive(5)
                            deliver(Reply(status: Int(reply[0]), focus: nil), sequence: Wire.read(reply, at: 1), connection: connection, operation: 1)
                        case 3:
                            let reply = try socket.receive(26)
                            let replySequence: UInt32 = Wire.read(reply)
                            let status = Int(reply[4])
                            let epoch: UInt64 = Wire.read(reply, at: 5)
                            let pointer: UInt64 = Wire.read(reply, at: 13)
                            let display = Int32(bitPattern: Wire.read(reply, at: 21, as: UInt32.self))
                            guard reply[25] <= 1, status != 0 || display > 0 else { throw DirectInputFailure.protocolMismatch }
                            let focus = status == 0 ? InputFocus(lease: InputLease(connection: connection, epoch: epoch, pointerSequence: pointer, displayId: display), active: true, sensitive: reply[25] == 1) : nil
                            deliver(Reply(status: status, focus: focus), sequence: replySequence, connection: connection, operation: 2)
                        default: throw DirectInputFailure.protocolMismatch
                        }
                    }
                } catch { /* Reconnect state only. User text is never replayed. */ }
                stateLock.lock()
                let wasCurrent = connected != nil && self.socket === connected
                if wasCurrent { socket = nil; observedFocus = nil; confirmedFocus = nil }
                let doneNow = stopped; stateLock.unlock()
                connected?.close()
                if wasCurrent { wakeFailure(); onFocus?(nil) }
                if doneNow { return }
                Thread.sleep(forTimeInterval: 0.15)
            }
        }
    }

    /// Called only after the ordered touch-finished ACK, or a system focus event
    /// with no outstanding pointer transition.
    func confirm(pointerSequence: UInt64, displayId: Int32) throws -> InputFocus? {
        let (socket, observed) = try snapshot()
        stateLock.lock()
        let pointerMatches = activePointer == pointerSequence
        if pointerMatches { confirmedFocus = nil }
        stateLock.unlock()
        guard pointerMatches else { throw DirectInputFailure.expired }
        sequence &+= 1
        let reply = try request(DirectInputWire.confirm(sequence: sequence, pointerSequence: pointerSequence, displayId: displayId), socket: socket, connection: observed.lease.connection, operation: 2)
        guard reply.status == 0, let focus = reply.focus else { return nil }
        stateLock.lock(); defer { stateLock.unlock() }
        guard !stopped, activePointer == pointerSequence, self.socket === socket,
              focus.lease.pointerSequence == pointerSequence,
              displayId < 0 || focus.lease.displayId == displayId,
              observedFocus?.active == true, observedFocus?.lease.hasSameEditor(as: focus.lease) == true else { throw DirectInputFailure.expired }
        confirmedFocus = focus
        return focus
    }

    func commit(_ text: String, lease: InputLease) throws {
        let (socket, _) = try snapshot()
        stateLock.lock(); let valid = confirmedFocus?.lease == lease && activePointer == lease.pointerSequence; stateLock.unlock()
        guard valid else { throw DirectInputFailure.expired }
        sequence &+= 1
        let data = try DirectInputWire.commit(text, epoch: lease.epoch, sequence: sequence, pointerSequence: lease.pointerSequence, displayId: lease.displayId)
        let reply = try request(data, socket: socket, connection: lease.connection, operation: 1)
        switch reply.status {
        case 0: return
        case 2: throw DirectInputFailure.expired
        case 1: throw DirectInputFailure.protocolMismatch
        default: throw DirectInputFailure.unconfirmed
        }
    }

    private func snapshot() throws -> (LocalSocket, InputFocus) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !stopped, let socket, let observedFocus, observedFocus.active else { throw DirectInputFailure.noFocus }
        return (socket, observedFocus)
    }
    private func request(_ data: Data, socket: LocalSocket, connection: UUID, operation: UInt8) throws -> Reply {
        acknowledgement.lock(); waiting = (connection, sequence, operation); outcome = nil; acknowledgement.unlock()
        do { try socket.send(data) }
        catch { clearWaiting(); throw DirectInputFailure.unconfirmed }
        acknowledgement.lock()
        let deadline = Date().addingTimeInterval(0.45)
        while outcome == nil { if !acknowledgement.wait(until: deadline) { break } }
        let reply = outcome; waiting = nil; outcome = nil; acknowledgement.unlock()
        guard let reply else { throw DirectInputFailure.unconfirmed }
        return reply
    }
    private func deliver(_ reply: Reply, sequence: UInt32, connection: UUID, operation: UInt8) {
        acknowledgement.lock(); defer { acknowledgement.unlock() }
        if waiting?.connection == connection, waiting?.sequence == sequence, waiting?.operation == operation { outcome = reply; acknowledgement.broadcast() }
    }
    private func clearWaiting() { acknowledgement.lock(); waiting = nil; outcome = nil; acknowledgement.unlock() }
    private func wakeFailure() { acknowledgement.lock(); outcome = Reply(status: -1, focus: nil); acknowledgement.broadcast(); acknowledgement.unlock() }
    func stop() {
        stateLock.lock(); stopped = true; let socket = self.socket; self.socket = nil; observedFocus = nil; confirmedFocus = nil; stateLock.unlock()
        socket?.close(); wakeFailure()
    }
    deinit { stop() }
}
