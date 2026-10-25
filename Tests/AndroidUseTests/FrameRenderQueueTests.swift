import XCTest
@testable import AndroidUse

final class FrameRenderQueueTests: XCTestCase {
    func testRestoreReplacesOlderPendingFrameAndRefreshesGeometryWithoutNewDecode() {
        let started = expectation(description: "drawable wait started")
        let restored = expectation(description: "latest cached frame rendered")
        let gate = DispatchSemaphore(value: 0)
        let session = UUID()
        let jobLock = NSLock()
        var runningJob: FrameRenderQueue<String>.Job?
        let queue = FrameRenderQueue<String>(label: "local.androiduse.tests.restore", session: session) { job in
            if job.payload == "running" {
                jobLock.lock(); runningJob = job; jobLock.unlock()
                started.fulfill()
                XCTAssertEqual(gate.wait(timeout: .now() + 2), .success)
            } else {
                XCTAssertEqual(job.payload, "C-restored-geometry")
                XCTAssertEqual(job.demand, .decoded)
                restored.fulfill()
            }
        }
        XCTAssertTrue(queue.submitDecoded("running", session: session, frameSequence: 1))
        wait(for: [started], timeout: 1)
        XCTAssertTrue(queue.submitCached("same-frame-new-geometry", session: session, frameSequence: 1))
        jobLock.lock(); let activeJob = runningJob; jobLock.unlock()
        if let activeJob { XCTAssertFalse(queue.shouldAbandon(activeJob), "Redrawing the same frame must not starve the active render.") }
        else { XCTFail("No running render") }
        XCTAssertTrue(queue.submitDecoded("B-before-minimize", session: session, frameSequence: 2))
        XCTAssertTrue(queue.submitCached("C-during-minimize", session: session, frameSequence: 3))
        XCTAssertTrue(queue.submitCached("C-restored-geometry", session: session, frameSequence: 3))
        XCTAssertFalse(queue.submitCached("B-stale", session: session, frameSequence: 2))
        gate.signal()
        wait(for: [restored], timeout: 1)
    }

    func testFirstAndLatestCoalescingWithOneRunningJob() {
        let started = expectation(description: "first job started")
        let finished = expectation(description: "latest job completed")
        let gate = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var payloads: [String] = []
        var running = 0
        var maximumRunning = 0

        let queue = FrameRenderQueue<String>(
            label: "local.androiduse.tests.render-queue",
            session: UUID()
        ) { job in
            lock.lock()
            running += 1
            maximumRunning = max(maximumRunning, running)
            payloads.append(job.payload)
            lock.unlock()
            defer {
                lock.lock()
                running -= 1
                lock.unlock()
            }
            if job.payload == "first" {
                started.fulfill()
                XCTAssertEqual(gate.wait(timeout: .now() + 2), .success)
            }
            if job.payload == "last" { finished.fulfill() }
        }

        let session = UUID()
        queue.beginSession(session)
        XCTAssertTrue(queue.submitDecoded("first", session: session, frameSequence: 1))
        wait(for: [started], timeout: 1)
        XCTAssertTrue(queue.submitDecoded("second", session: session, frameSequence: 2))
        XCTAssertTrue(queue.submitDecoded("last", session: session, frameSequence: 3))
        XCTAssertFalse(queue.submitCached("cached", session: session, frameSequence: 0))
        gate.signal()

        wait(for: [finished], timeout: 1)

        lock.lock()
        let observed = payloads
        let peak = maximumRunning
        lock.unlock()
        XCTAssertEqual(observed, ["first", "last"])
        XCTAssertEqual(peak, 1)
    }

    func testOldSessionIsDroppedAndFailureReleasesBusy() {
        let calls = expectation(description: "callback calls")
        calls.expectedFulfillmentCount = 2
        let firstStarted = expectation(description: "failing job started")
        let gate = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var payloads: [String] = []
        let queue = FrameRenderQueue<String>(
            label: "local.androiduse.tests.render-queue-session",
            session: UUID()
        ) { job in
            lock.lock()
            payloads.append(job.payload)
            lock.unlock()
            calls.fulfill()
            if job.payload == "fails" {
                firstStarted.fulfill()
                _ = gate.wait(timeout: .now() + 2)
                throw TestFailure.expected
            }
        }

        let oldSession = UUID()
        let newSession = UUID()
        queue.beginSession(oldSession)
        XCTAssertTrue(queue.submitDecoded("fails", session: oldSession, frameSequence: 1))
        wait(for: [firstStarted], timeout: 1)
        queue.beginSession(newSession)
        XCTAssertFalse(queue.submitDecoded("old", session: oldSession, frameSequence: 2))
        XCTAssertTrue(queue.submitDecoded("new", session: newSession, frameSequence: 1))
        gate.signal()
        wait(for: [calls], timeout: 1)

        lock.lock()
        let observed = payloads
        lock.unlock()
        XCTAssertEqual(observed, ["fails", "new"])
        XCTAssertTrue(queue.isCurrent(session: newSession))
    }

    private enum TestFailure: Error {
        case expected
    }
}
