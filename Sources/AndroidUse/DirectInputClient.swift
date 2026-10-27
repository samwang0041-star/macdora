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

fileprivate struct DirectInputReply {
    let status: Int
    let focus: InputFocus?
}

/// Multiplexes a single Android DirectCommitImeService socket across multiple host windows on the same port.
fileprivate final class DirectInputPortHub {
    private static let registryLock = NSLock()
    private static var hubs: [UInt16: DirectInputPortHub] = [:]

    static func acquire(port: UInt16, client: DirectInputClient) -> DirectInputPortHub {
        registryLock.lock()
        let hub: DirectInputPortHub
        if let existing = hubs[port] {
            hub = existing
        } else {
            hub = DirectInputPortHub(port: port)
            hubs[port] = hub
        }
        registryLock.unlock()
        hub.addClient(client)
        return hub
    }

    static func release(port: UInt16, client: DirectInputClient) {
        registryLock.lock()
        guard let hub = hubs[port] else {
            registryLock.unlock()
            return
        }
        let isEmpty = hub.removeClient(client)
        if isEmpty {
            hubs.removeValue(forKey: port)
        }
        registryLock.unlock()
        if isEmpty {
            hub.shutdown()
        }
    }

    private let port: UInt16
    private let reader: DispatchQueue
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var clients: [ObjectIdentifier: DirectInputClient] = [:]
    private var socket: LocalSocket?
    private var observedFocus: InputFocus?
    private var sequence: UInt32 = 0
    private var running = false
    private var stopped = false

    private init(port: UInt16) {
        self.port = port
        self.reader = DispatchQueue(label: "local.androiduse.ime-hub.\(port)", qos: .userInitiated)
    }

    private func addClient(_ client: DirectInputClient) {
        var initialFocus: InputFocus?
        var initialSocket: LocalSocket?
        var shouldStartReader = false
        lock.lock()
        clients[ObjectIdentifier(client)] = client
        initialFocus = observedFocus
        initialSocket = socket
        if !running && !stopped {
            running = true
            shouldStartReader = true
        }
        lock.unlock()

        if let initialSocket, let initialFocus {
            client.handleHubFocus(initialFocus, socket: initialSocket)
        }
        if shouldStartReader {
            startReaderLoop()
        }
    }

    private func removeClient(_ client: DirectInputClient) -> Bool {
        lock.lock()
        clients.removeValue(forKey: ObjectIdentifier(client))
        let empty = clients.isEmpty
        if empty {
            stopped = true
        }
        lock.unlock()
        return empty
    }

    func shutdown() {
        lock.lock()
        stopped = true
        let activeSocket = socket
        socket = nil
        observedFocus = nil
        let remainingClients = Array(clients.values)
        clients.removeAll()
        lock.unlock()
        activeSocket?.close()
        for client in remainingClients {
            client.handleHubDisconnect(closedSocket: activeSocket)
        }
    }

    func nextSequence() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        sequence &+= 1
        return sequence
    }

    func send(_ data: Data, on expectedSocket: LocalSocket) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        lock.lock()
        let active = !stopped && socket === expectedSocket
        lock.unlock()
        guard active else { throw DirectInputFailure.unconfirmed }
        try expectedSocket.send(data)
    }

    private func startReaderLoop() {
        reader.async { [weak self] in
            guard let self else { return }
            while true {
                self.lock.lock()
                let done = self.stopped || self.clients.isEmpty
                self.lock.unlock()
                if done { return }

                var connected: LocalSocket?
                do {
                    let sock = try LocalSocket(port: self.port)
                    connected = sock
                    let connection = UUID()
                    self.lock.lock()
                    if self.stopped || self.clients.isEmpty {
                        self.lock.unlock()
                        sock.close()
                        return
                    }
                    self.socket = sock
                    self.lock.unlock()

                    let hello = try sock.receive(6)
                    let uid: UInt32 = Wire.read(hello, at: 2)
                    guard hello[0] == 0, hello[1] == 2, uid == 0 || uid == 2000 else {
                        throw DirectInputFailure.protocolMismatch
                    }
                    while true {
                        let type = try sock.receive(1)[0]
                        switch type {
                        case 1:
                            let state = try sock.receive(10)
                            guard state[0] <= 1, state[1] <= 1 else { throw DirectInputFailure.protocolMismatch }
                            let epoch: UInt64 = Wire.read(state, at: 2)
                            let focus = InputFocus(
                                lease: InputLease(connection: connection, epoch: epoch),
                                active: state[0] == 1,
                                sensitive: state[1] == 1
                            )
                            self.lock.lock()
                            let active = !self.stopped && self.socket === sock
                            let currentClients: [DirectInputClient]
                            if active {
                                self.observedFocus = focus
                                currentClients = Array(self.clients.values)
                            } else {
                                currentClients = []
                            }
                            self.lock.unlock()
                            for client in currentClients {
                                client.handleHubFocus(focus, socket: sock)
                            }
                        case 2:
                            let reply = try sock.receive(5)
                            let replySequence: UInt32 = Wire.read(reply, at: 1)
                            let outcome = DirectInputReply(status: Int(reply[0]), focus: nil)
                            self.lock.lock()
                            let currentClients = Array(self.clients.values)
                            self.lock.unlock()
                            for client in currentClients {
                                client.deliver(outcome, sequence: replySequence, connection: connection, operation: 1)
                            }
                        case 3:
                            let reply = try sock.receive(26)
                            let replySequence: UInt32 = Wire.read(reply)
                            let status = Int(reply[4])
                            let epoch: UInt64 = Wire.read(reply, at: 5)
                            let pointer: UInt64 = Wire.read(reply, at: 13)
                            let display = Int32(bitPattern: Wire.read(reply, at: 21, as: UInt32.self))
                            guard reply[25] <= 1, status != 0 || display > 0 else {
                                throw DirectInputFailure.protocolMismatch
                            }
                            let focus = status == 0 ? InputFocus(
                                lease: InputLease(connection: connection, epoch: epoch, pointerSequence: pointer, displayId: display),
                                active: true,
                                sensitive: reply[25] == 1
                            ) : nil
                            let outcome = DirectInputReply(status: status, focus: focus)
                            self.lock.lock()
                            let currentClients = Array(self.clients.values)
                            self.lock.unlock()
                            for client in currentClients {
                                client.deliver(outcome, sequence: replySequence, connection: connection, operation: 2)
                            }
                        default:
                            throw DirectInputFailure.protocolMismatch
                        }
                    }
                } catch {
                    /* Reconnect state only. User text is never replayed. */
                }
                self.lock.lock()
                let wasCurrent = connected != nil && self.socket === connected
                if wasCurrent {
                    self.socket = nil
                    self.observedFocus = nil
                }
                let currentClients = wasCurrent ? Array(self.clients.values) : []
                let doneNow = self.stopped || self.clients.isEmpty
                self.lock.unlock()
                connected?.close()
                if wasCurrent {
                    for client in currentClients {
                        client.handleHubDisconnect(closedSocket: connected)
                    }
                }
                if doneNow { return }
                Thread.sleep(forTimeInterval: 0.15)
            }
        }
    }
}

/// Focus-only state and bounded direct commits; no editor text is read back.
final class DirectInputClient {
    private let port: UInt16
    private let stateLock = NSLock()
    private let acknowledgement = NSCondition()
    private var hub: DirectInputPortHub?
    private var socket: LocalSocket?
    private var observedFocus: InputFocus?
    private var confirmedFocus: InputFocus?
    private var activePointer: UInt64 = 0
    private var stopped = false
    private var waiting: (connection: UUID, sequence: UInt32, operation: UInt8)?
    private var outcome: DirectInputReply?
    var onFocus: ((InputFocus?) -> Void)?

    init(port: UInt16) { self.port = port }

    func invalidatePointer(_ pointerSequence: UInt64) {
        stateLock.lock(); activePointer = pointerSequence; confirmedFocus = nil; stateLock.unlock()
        acknowledgement.lock()
        if waiting?.operation == 2 {
            outcome = DirectInputReply(status: 2, focus: nil)
            acknowledgement.broadcast()
        }
        acknowledgement.unlock()
    }

    func start() {
        stateLock.lock()
        if stopped || hub != nil {
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        let acquiredHub = DirectInputPortHub.acquire(port: port, client: self)
        stateLock.lock()
        if stopped {
            stateLock.unlock()
            DirectInputPortHub.release(port: port, client: self)
            return
        }
        hub = acquiredHub
        stateLock.unlock()
    }

    fileprivate func handleHubFocus(_ focus: InputFocus, socket: LocalSocket) {
        stateLock.lock()
        let active = !stopped
        if active {
            self.socket = socket
            if observedFocus?.lease.hasSameEditor(as: focus.lease) != true || !focus.active {
                confirmedFocus = nil
            }
            observedFocus = focus
        }
        stateLock.unlock()
        if active {
            onFocus?(focus)
        }
    }

    fileprivate func handleHubDisconnect(closedSocket: LocalSocket?) {
        stateLock.lock()
        let wasCurrent = closedSocket == nil || self.socket === closedSocket || self.socket != nil
        if wasCurrent {
            self.socket = nil
            self.observedFocus = nil
            self.confirmedFocus = nil
        }
        let active = !stopped
        stateLock.unlock()
        if wasCurrent {
            wakeFailure()
            if active {
                onFocus?(nil)
            }
        }
    }

    /// Called only after the ordered touch-finished ACK, or a system focus event
    /// with no outstanding pointer transition.
    func confirm(pointerSequence: UInt64, displayId: Int32) throws -> InputFocus? {
        let (socket, observed, hub) = try snapshot()
        stateLock.lock()
        let pointerMatches = activePointer == pointerSequence
        if pointerMatches { confirmedFocus = nil }
        stateLock.unlock()
        guard pointerMatches else { throw DirectInputFailure.expired }
        let seq = hub.nextSequence()
        let reply = try request(
            DirectInputWire.confirm(sequence: seq, pointerSequence: pointerSequence, displayId: displayId),
            sequence: seq,
            socket: socket,
            hub: hub,
            connection: observed.lease.connection,
            operation: 2
        )
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
        let (socket, _, hub) = try snapshot()
        stateLock.lock(); let valid = confirmedFocus?.lease == lease && activePointer == lease.pointerSequence; stateLock.unlock()
        guard valid else { throw DirectInputFailure.expired }
        let seq = hub.nextSequence()
        let data = try DirectInputWire.commit(text, epoch: lease.epoch, sequence: seq, pointerSequence: lease.pointerSequence, displayId: lease.displayId)
        let reply = try request(data, sequence: seq, socket: socket, hub: hub, connection: lease.connection, operation: 1)
        switch reply.status {
        case 0: return
        case 2: throw DirectInputFailure.expired
        case 1: throw DirectInputFailure.protocolMismatch
        default: throw DirectInputFailure.unconfirmed
        }
    }

    private func snapshot() throws -> (LocalSocket, InputFocus, DirectInputPortHub) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !stopped, let socket, let observedFocus, observedFocus.active, let hub else { throw DirectInputFailure.noFocus }
        return (socket, observedFocus, hub)
    }

    private func request(
        _ data: Data,
        sequence: UInt32,
        socket: LocalSocket,
        hub: DirectInputPortHub,
        connection: UUID,
        operation: UInt8
    ) throws -> DirectInputReply {
        acknowledgement.lock(); waiting = (connection, sequence, operation); outcome = nil; acknowledgement.unlock()
        do { try hub.send(data, on: socket) }
        catch { clearWaiting(); throw DirectInputFailure.unconfirmed }
        acknowledgement.lock()
        let deadline = Date().addingTimeInterval(0.45)
        while outcome == nil { if !acknowledgement.wait(until: deadline) { break } }
        let reply = outcome; waiting = nil; outcome = nil; acknowledgement.unlock()
        guard let reply else { throw DirectInputFailure.unconfirmed }
        return reply
    }

    fileprivate func deliver(_ reply: DirectInputReply, sequence: UInt32, connection: UUID, operation: UInt8) {
        acknowledgement.lock(); defer { acknowledgement.unlock() }
        if waiting?.connection == connection, waiting?.sequence == sequence, waiting?.operation == operation {
            outcome = reply
            acknowledgement.broadcast()
        }
    }

    private func clearWaiting() { acknowledgement.lock(); waiting = nil; outcome = nil; acknowledgement.unlock() }
    private func wakeFailure() { acknowledgement.lock(); outcome = DirectInputReply(status: -1, focus: nil); acknowledgement.broadcast(); acknowledgement.unlock() }

    func stop() {
        stateLock.lock()
        let alreadyStopped = stopped
        stopped = true
        self.socket = nil
        self.observedFocus = nil
        self.confirmedFocus = nil
        self.hub = nil
        stateLock.unlock()
        if !alreadyStopped {
            DirectInputPortHub.release(port: port, client: self)
        }
        wakeFailure()
    }

    deinit { stop() }
}
