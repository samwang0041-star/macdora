import Foundation

/// A serial, latest-value render queue.
///
/// At most one operation runs at a time. While it runs, decoded frames replace
/// older pending decoded frames, and cached redraws never replace a newer one.
final class FrameRenderQueue<Payload> {
    enum Demand {
        case decoded
        case cached
    }

    struct Job {
        let payload: Payload
        let session: UUID
        let demand: Demand
        let sequence: UInt64
        let frameSequence: UInt64
    }

    private let lock = NSLock()
    private let workerQueue: DispatchQueue
    private let operation: (Job) throws -> Void
    private var activeSession: UUID
    private var pending: Job?
    private var draining = false
    private var nextSequence: UInt64 = 0

    init(
        label: String,
        session: UUID,
        qos: DispatchQoS = .userInteractive,
        operation: @escaping (Job) throws -> Void
    ) {
        activeSession = session
        workerQueue = DispatchQueue(label: label, qos: qos)
        self.operation = operation
    }

    @discardableResult
    func submitDecoded(_ payload: Payload, session: UUID, frameSequence: UInt64) -> Bool {
        submit(payload, session: session, demand: .decoded, frameSequence: frameSequence)
    }

    @discardableResult
    func submitCached(_ payload: Payload, session: UUID, frameSequence: UInt64) -> Bool {
        submit(payload, session: session, demand: .cached, frameSequence: frameSequence)
    }

    func beginSession(_ session: UUID) {
        lock.lock()
        activeSession = session
        pending = nil
        lock.unlock()
    }

    func isCurrent(session: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeSession == session
    }

    /// Serializes a short commit with `beginSession`. The body must not call
    /// back into this queue.
    @discardableResult
    func commitIfCurrent(session: UUID, _ body: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeSession == session else { return false }
        body()
        return true
    }

    /// A worker checks this after acquiring a drawable. A pending decoded frame
    /// is always newer than the current job and makes the selected frame stale.
    func shouldAbandon(_ job: Job) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeSession == job.session else { return true }
        guard let pending, pending.session == job.session else {
            return false
        }
        return pending.frameSequence > job.frameSequence
    }

    private func submit(_ payload: Payload, session: UUID, demand: Demand, frameSequence: UInt64) -> Bool {
        lock.lock()
        guard session == activeSession else {
            lock.unlock()
            return false
        }
        if let pending, frameSequence < pending.frameSequence {
            lock.unlock()
            return false
        }
        // A redraw of the same/newer frame refreshes geometry without losing
        // the decoded presentation that was already waiting to be counted.
        let mergedDemand = pending?.demand == .decoded ? Demand.decoded : demand

        nextSequence &+= 1
        pending = Job(
            payload: payload,
            session: session,
            demand: mergedDemand,
            sequence: nextSequence,
            frameSequence: frameSequence
        )
        let shouldSchedule = !draining
        if shouldSchedule { draining = true }
        lock.unlock()

        if shouldSchedule {
            workerQueue.async { [weak self] in self?.drain() }
        }
        return true
    }

    private func drain() {
        while true {
            lock.lock()
            guard let job = pending else {
                draining = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()

            do {
                try operation(job)
            } catch {
                // A failed drawable or command must not leave the queue busy.
            }
        }
    }
}
