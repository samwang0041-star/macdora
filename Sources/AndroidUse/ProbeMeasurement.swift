import Foundation

/// Driven on the main queue; the watchdog runs independently of frame delivery.
final class ProbeMeasurement {
    struct WindowState: Equatable {
        let visible: Bool
        let minimized: Bool
        let occluded: Bool
        let applicationActive: Bool
        var presentable: Bool { visible && !minimized && !occluded }
    }

    private var started: Double?
    private var began: Double?
    private var lastPresentation: Double?
    private var presentations: [Double] = []
    private var lastMarker: UInt32?
    private var lastInput: UInt16?
    private var pendingInput: (expected: UInt16, sent: Double)?
    private var latencies: [Double] = []
    private var tapTimes: [Double] = []
    private var inputDeadlines: [Double] = []
    private var dispatchDelays: [Double] = []
    private var firingDeadline: Double?
    private var windowStates: [(time: Double, state: WindowState)] = []
    private var presentationOrderSamples: [[String: Any]] = []
    private var stages: [String: [Double]] = [:]
    private var nextTap: Double = 0
    private var completed = false
    private var invalidTimestamps = 0
    private var skippedPresentations = 0
    private var outOfOrderPresentations = 0
    private var coincidentPresentations = 0
    private var missingTiming = 0
    private var renderPaths: [String: Int] = [:]
    private var tapSeed: UInt32 = 0xA17D_0060
    private var timedOutInputs = 0
    private let duration: Double
    var onTap: (() -> Void)?
    var onScheduleTap: ((Double) -> Void)?
    var onComplete: (([String: Any]) -> Void)?
    var hardwareDecoder = false
    var metadata: [String: Any] = [:]

    init(duration: Double = 32) { self.duration = max(32, duration) }

    func start(at time: Double) { if started == nil { started = time } }

    func sent(at time: Double) {
        guard !completed, pendingInput == nil, let lastInput else { return }
        pendingInput = (lastInput &+ 1, time)
        tapTimes.append(time)
        if let firingDeadline {
            inputDeadlines.append(firingDeadline)
            dispatchDelays.append(max(0, time - firingDeadline) * 1000)
        }
        tapSeed = tapSeed &* 1_664_525 &+ 1_013_904_223
        nextTap = time + 0.55 + Double(tapSeed % 201) / 1_000
        if tapTimes.count < 40 { onScheduleTap?(nextTap) }
    }

    func fireInput(at time: Double) {
        guard !completed, began != nil, time >= nextTap, tapTimes.count < 40, pendingInput == nil else { return }
        if expire(at: time) { return }
        firingDeadline = nextTap
        defer { firingDeadline = nil }
        onTap?()
    }

    func rendered(using path: String) { if !completed { renderPaths[path, default: 0] += 1 } }

    func renderTiming(_ name: String, seconds: Double) {
        guard !completed else { return }
        record(name == "nextDrawableSeconds" ? "nextDrawableWaitMs" : name == "gpuExecutionSeconds" ? "gpuExecutionMs" : name, seconds)
    }

    func observedWindow(_ state: WindowState, at time: Double) {
        guard !completed, time.isFinite, windowStates.last?.state != state else { return }
        windowStates.append((time, state))
    }

    func invalidPresentation(at time: Double) {
        guard !completed else { return }
        if time == 0 { skippedPresentations += 1 }
        else { invalidTimestamps += 1 }
    }

    func presented(_ frame: DecodedFrame, at time: Double) {
        guard !completed else { return }
        guard time.isFinite, time > 0 else {
            invalidPresentation(at: time); return
        }
        if let lastPresentation, time <= lastPresentation {
            // WindowServer can coalesce startup drawables onto one refresh.
            // Count that refresh once; an older timestamp is a separate error.
            if time == lastPresentation { coincidentPresentations += 1 }
            else { outOfOrderPresentations += 1 }
            let kind = time == lastPresentation ? "coincident" : "out-of-order"
            if presentationOrderSamples.filter({ $0["kind"] as? String == kind }).count < 4 {
                presentationOrderSamples.append(["kind": kind, "time": time, "previousTime": lastPresentation,
                                                 "deltaMs": (time - lastPresentation) * 1000,
                                                 "frame": frame.marker.map { Int($0.frame) } ?? -1,
                                                 "previousFrame": lastMarker.map(Int.init) ?? -1])
            }
            return
        }
        if expire(at: time) { return }
        guard let marker = frame.marker else { return }
        start(at: time)
        if began == nil { began = time; nextTap = time + 2; onScheduleTap?(nextTap) }
        lastPresentation = time
        lastInput = marker.input
        if lastMarker != marker.frame {
            presentations.append(time)
            lastMarker = marker.frame
            if let timing = frame.timing, let submitted = frame.submittedAt {
                record("receiveToDecodeMs", timing.decoded - timing.received)
                record("decodeToSubmitMs", submitted - timing.decoded)
                record("submitToPresentMs", time - submitted)
                record("receiveToPresentMs", time - timing.received)
            } else { missingTiming += 1 }
        }
        if let pending = pendingInput, marker.input == pending.expected {
            if time >= pending.sent { latencies.append((time - pending.sent) * 1000) }
            else { invalidTimestamps += 1 }
            pendingInput = nil
            if tapTimes.count < 40 { onScheduleTap?(nextTap) }
        }
    }

    func tick(at time: Double) {
        if expire(at: time) { return }
        if onScheduleTap == nil { fireInput(at: time) }
    }

    @discardableResult
    private func expire(at time: Double) -> Bool {
        guard !completed, let started else { return completed }
        guard let began else {
            if time - started >= 15 { finish(at: started + 15, reason: "no_first_frame") }
            return completed
        }
        let cutoff = began + duration
        let checked = min(time, cutoff)
        if let pending = pendingInput, checked - pending.sent >= 2 {
            timedOutInputs += 1
            finish(at: pending.sent + 2, reason: "input_timeout")
        } else if let last = presentations.last, checked - last >= 2 {
            finish(at: last + 2, reason: "presentation_stall")
        } else if time >= cutoff {
            finish(at: cutoff, reason: "duration_complete")
        }
        return completed
    }

    func fail(at time: Double, reason: String) {
        guard !completed else { return }
        finish(at: time, reason: reason)
    }

    private func record(_ key: String, _ seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { invalidTimestamps += 1; return }
        stages[key, default: []].append(seconds * 1000)
    }

    private func finish(at time: Double, reason: String) {
        guard !completed else { return }
        completed = true
        let elapsed = began.map { time - $0 } ?? 0
        let tail = presentations.last.map { max(0, time - $0) * 1000 } ?? 0
        let intervals = zip(presentations.dropFirst(), presentations).map { ($0 - $1) * 1000 } + [tail]
        let fps = elapsed > 0 ? Double(max(0, presentations.count - 1)) / elapsed : 0
        let windowStart = began ?? started ?? time
        var unavailableSeconds = 0.0
        for (index, sample) in windowStates.enumerated() where !sample.state.presentable {
            let next = index + 1 < windowStates.count ? windowStates[index + 1].time : time
            unavailableSeconds += max(0, min(time, next) - max(windowStart, sample.time))
        }
        var gates: [String: Bool] = [
            "completed": reason == "duration_complete" && elapsed >= duration,
            "validPresentationTimes": invalidTimestamps == 0 && outOfOrderPresentations == 0,
            "hardwareDecoder": hardwareDecoder,
            "sixtyFPS": fps >= 59.4,
            "framePacing": percentile(intervals, 0.95) <= 25.1 && (intervals.max() ?? .infinity) <= 100.1,
            "inputLatency": !latencies.isEmpty && percentile(latencies, 0.95) <= 70,
            "allInputsResponded": latencies.count == 40 && tapTimes.count == 40 && pendingInput == nil && timedOutInputs == 0
        ]
        if !windowStates.isEmpty { gates["unoccludedWindow"] = unavailableSeconds == 0 }
        let report: [String: Any] = [
            "schemaVersion": 3,
            "durationSeconds": elapsed,
            "completionReason": reason,
            "startupToFirstPresentationMs": began.flatMap { first in started.map { (first - $0) * 1000 } } ?? -1,
            "newPresentedFrames": presentations.count,
            "newPresentedFPS": fps,
            "frameIntervalsMs": distribution(intervals),
            "inputCount": latencies.count,
            "inputAttempts": tapTimes.count,
            "inputLatencyMs": distribution(latencies),
            "framePresentationTimesSeconds": presentations.map { $0 - (began ?? $0) },
            "inputLatencySamplesMs": latencies,
            "inputDispatchDelayMs": distribution(dispatchDelays),
            "inputSentTimesSeconds": tapTimes.map { $0 - (began ?? $0) },
            "inputDeadlineTimesSeconds": inputDeadlines.map { $0 - (began ?? $0) },
            "timedOutInputs": max(timedOutInputs, pendingInput == nil ? 0 : 1),
            "invalidPresentationTimestamps": invalidTimestamps,
            "skippedPresentations": skippedPresentations,
            "outOfOrderPresentations": outOfOrderPresentations,
            "coincidentPresentations": coincidentPresentations,
            "presentationOrderSamples": presentationOrderSamples,
            "windowUnavailableSeconds": unavailableSeconds,
            "windowStateEvents": windowStates.map { sample -> [String: Any] in
                ["sinceConnectionSeconds": sample.time - (started ?? sample.time),
                 "visible": sample.state.visible, "minimized": sample.state.minimized,
                 "occluded": sample.state.occluded, "applicationActive": sample.state.applicationActive]
            },
            "presentedFramesWithoutTiming": missingTiming,
            "renderAttemptsByPath": renderPaths,
            "tailGapMs": tail,
            "hardwareDecoder": hardwareDecoder,
            "hostPipelineMs": stages.mapValues(distribution),
            "gates": gates,
            "configuration": metadata,
            "inputSchedule": "One-shot host deadlines with deterministic jitter of 550-750 ms, seed 0xA17D0060; independent 50 ms watchdog",
            "method": "Unique guest frame/input markers; only valid CAMetalDrawable.presentedTime values. Independent host timer drives inputs and timeouts. Production decoder format and rendering path. Duplicate redraws are excluded.",
            "measurementUncertainty": "Host monotonic clock only; no guest/host clock subtraction. Input-to-present excludes physical mouse sensor delay. Presented callbacks are not a photodiode measurement. Startup starts at stream connection, not VM power-on.",
            "passed": gates.values.allSatisfy { $0 }
        ]
        onComplete?(report)
    }

    private func percentile(_ samples: [Double], _ p: Double) -> Double {
        guard !samples.isEmpty else { return -1 }
        let sorted = samples.sorted()
        return sorted[max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * p)) - 1))]
    }

    private func distribution(_ samples: [Double]) -> [String: Double] {
        ["count": Double(samples.count), "p50": percentile(samples, 0.5), "p95": percentile(samples, 0.95), "p99": percentile(samples, 0.99), "max": samples.max() ?? -1, "mean": samples.isEmpty ? -1 : samples.reduce(0, +) / Double(samples.count)]
    }
}
