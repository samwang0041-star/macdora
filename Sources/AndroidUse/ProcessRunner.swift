import Darwin
import Foundation

struct ProcessInvocation: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectoryURL: URL?
    let timeout: TimeInterval
    let captureOutput: Bool
    let outputLimit: Int

    init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String],
        workingDirectoryURL: URL? = nil,
        timeout: TimeInterval,
        captureOutput: Bool = false,
        outputLimit: Int = 64 * 1024
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryURL = workingDirectoryURL
        self.timeout = timeout
        self.captureOutput = captureOutput
        self.outputLimit = max(0, outputLimit)
    }
}

struct ProcessResult: Equatable, Sendable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
    let timedOut: Bool

    init(
        exitCode: Int32,
        stdout: Data,
        stderr: Data = Data(),
        timedOut: Bool
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    var combinedOutputUTF8: String {
        let out = String(decoding: stdout, as: UTF8.self)
        let err = String(decoding: stderr, as: UTF8.self)
        if out.isEmpty { return err }
        if err.isEmpty { return out }
        return out + "\n" + err
    }
}

enum ProcessRunnerError: LocalizedError, Equatable {
    case launchFailed(String)
    case missingExecutable(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let operation): return "无法启动\(operation)。"
        case .missingExecutable(let operation): return "缺少\(operation)。"
        }
    }
}

protocol OwnedProcessHandle: AnyObject, Sendable {
    var isRunning: Bool { get }
    var processIdentifier: Int32 { get }
    func terminate()
    func kill()
}

struct ProcessExit: Sendable {
    let status: Int32
    let reply: String
    let replyError: String
    init(status: Int32, reply: String = "", replyError: String = "") {
        self.status = status
        self.reply = reply
        self.replyError = replyError
    }
}

protocol ProcessExecuting: AnyObject, Sendable {
    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult
    func launch(
        _ invocation: ProcessInvocation,
        operation: String,
        onExit: @escaping @Sendable (ProcessExit) -> Void
    ) async throws -> any OwnedProcessHandle
}

protocol OwnedProcessTerminating: Sendable {
    func terminateAndWait(
        _ handle: any OwnedProcessHandle,
        timeout: TimeInterval
    ) async -> Bool
}

final class OwnedProcess: OwnedProcessHandle, @unchecked Sendable {
    let process: Process
    private let lock = NSLock()
    private var terminated = false

    init(process: Process) {
        self.process = process
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process.isRunning
    }

    var processIdentifier: Int32 {
        process.processIdentifier
    }

    func terminate() {
        lock.lock()
        guard !terminated, process.isRunning else {
            lock.unlock()
            return
        }
        terminated = true
        lock.unlock()
        process.terminate()
    }

    func kill() {
        lock.lock()
        let identifier = process.processIdentifier
        let shouldKill = process.isRunning && identifier > 0
        terminated = true
        lock.unlock()
        if shouldKill {
            _ = Darwin.kill(identifier, SIGKILL)
        }
    }
}

final class ProcessRunner: ProcessExecuting, OwnedProcessTerminating, @unchecked Sendable {
    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        let task = Task.detached(priority: .userInitiated) {
            try Self.runBlocking(invocation)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func launch(
        _ invocation: ProcessInvocation,
        operation: String,
        onExit: @escaping @Sendable (ProcessExit) -> Void
    ) async throws -> any OwnedProcessHandle {
        let task = Task.detached(priority: .userInitiated) {
            try Self.launchBlocking(invocation, operation: operation, onExit: onExit)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func terminateAndWait(
        _ handle: any OwnedProcessHandle,
        timeout: TimeInterval
    ) async -> Bool {
        guard handle.isRunning else { return true }
        handle.terminate()
        if await Self.wait(handle, until: timeout) {
            return true
        }
        handle.kill()
        return await Self.wait(handle, until: max(0.2, timeout))
    }

    private static func wait(
        _ handle: any OwnedProcessHandle,
        until timeout: TimeInterval
    ) async -> Bool {
        await Task.detached(priority: .utility) {
            let deadline = Date().addingTimeInterval(timeout)
            while processIsRunning(handle), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            return !processIsRunning(handle)
        }.value
    }

    private static func processIsRunning(
        _ handle: any OwnedProcessHandle
    ) -> Bool {
        if let owned = handle as? OwnedProcess {
            return owned.process.isRunning
        }
        return handle.isRunning
    }

    private static func runBlocking(_ invocation: ProcessInvocation) throws -> ProcessResult {
        try Task.checkCancellation()
        let process = try makeProcess(invocation)
        let outputCapture = LimitedOutput(limit: invocation.captureOutput ? invocation.outputLimit : 0)
        let errorCapture = LimitedOutput(limit: invocation.captureOutput ? invocation.outputLimit : 0)
        let drained = DispatchSemaphore(value: 0)
        let errorDrained = DispatchSemaphore(value: 0)

        if let outputPipe = process.standardOutput as? Pipe {
            drain(outputPipe, into: outputCapture, completion: drained)
        } else {
            drained.signal()
        }
        if let errorPipe = process.standardError as? Pipe {
            drain(errorPipe, into: errorCapture, completion: errorDrained)
        } else {
            errorDrained.signal()
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(invocation.executableURL.lastPathComponent)
        }

        var timedOut = false
        var wasCancelled = false
        let deadline = DispatchTime.now() + max(0.05, invocation.timeout)
        while true {
            if exited.wait(timeout: .now() + 0.05) == .success {
                break
            }
            if Task.isCancelled {
                wasCancelled = true
                terminateOwnedProcess(process, wait: exited)
                break
            }
            if DispatchTime.now() >= deadline {
                timedOut = true
                terminateOwnedProcess(process, wait: exited)
                break
            }
        }

        if drained.wait(timeout: .now() + 0.15) == .timedOut {
            try? (process.standardOutput as? Pipe)?.fileHandleForReading.close()
        }
        if errorDrained.wait(timeout: .now() + 0.15) == .timedOut {
            try? (process.standardError as? Pipe)?.fileHandleForReading.close()
        }
        if wasCancelled || Task.isCancelled {
            throw CancellationError()
        }

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: outputCapture.data,
            stderr: errorCapture.data,
            timedOut: timedOut
        )
    }

    private static func launchBlocking(
        _ invocation: ProcessInvocation,
        operation: String,
        onExit: @escaping @Sendable (ProcessExit) -> Void
    ) throws -> any OwnedProcessHandle {
        try Task.checkCancellation()
        let process = try makeProcess(invocation)
        let outputCapture = LimitedOutput(
            limit: invocation.captureOutput ? invocation.outputLimit : 0
        )
        let errorCapture = LimitedOutput(
            limit: invocation.captureOutput ? invocation.outputLimit : 0
        )
        let drained = DispatchSemaphore(value: 0)
        let errorDrained = DispatchSemaphore(value: 0)
        if let outputPipe = process.standardOutput as? Pipe {
            drain(outputPipe, into: outputCapture, completion: drained)
        } else {
            drained.signal()
        }
        if let errorPipe = process.standardError as? Pipe {
            drain(errorPipe, into: errorCapture, completion: errorDrained)
        } else {
            errorDrained.signal()
        }
        process.terminationHandler = { finished in
            DispatchQueue.global(qos: .utility).async {
                if drained.wait(timeout: .now() + 0.15) == .timedOut {
                    try? (finished.standardOutput as? Pipe)?.fileHandleForReading.close()
                }
                if errorDrained.wait(timeout: .now() + 0.15) == .timedOut {
                    try? (finished.standardError as? Pipe)?.fileHandleForReading.close()
                }
                let reply = String(
                    decoding: outputCapture.data,
                    as: UTF8.self
                )
                let replyError = String(
                    decoding: errorCapture.data,
                    as: UTF8.self
                )
                onExit(ProcessExit(
                    status: finished.terminationStatus,
                    reply: reply,
                    replyError: replyError
                ))
            }
        }
        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(operation)
        }
        if Task.isCancelled {
            process.terminate()
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                let identifier = process.processIdentifier
                if identifier > 0 { _ = Darwin.kill(identifier, SIGKILL) }
            }
            throw CancellationError()
        }
        return OwnedProcess(process: process)
    }

    private static func makeProcess(_ invocation: ProcessInvocation) throws -> Process {
        guard FileManager.default.isExecutableFile(atPath: invocation.executableURL.path) else {
            throw ProcessRunnerError.missingExecutable(invocation.executableURL.lastPathComponent)
        }

        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.currentDirectoryURL = invocation.workingDirectoryURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = invocation.captureOutput ? Pipe() : FileHandle.nullDevice
        process.standardError = invocation.captureOutput ? Pipe() : FileHandle.nullDevice
        return process
    }

    private static func drain(
        _ pipe: Pipe,
        into output: LimitedOutput,
        completion: DispatchSemaphore
    ) {
        let reader = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            while true {
                let data: Data
                do {
                    data = try reader.read(upToCount: 8 * 1024) ?? Data()
                } catch {
                    break
                }
                if data.isEmpty {
                    break
                }
                output.append(data)
            }
            try? reader.close()
            completion.signal()
        }
    }

    private static func terminateOwnedProcess(
        _ process: Process,
        wait semaphore: DispatchSemaphore
    ) {
        guard process.isRunning else { return }
        process.terminate()
        if semaphore.wait(timeout: .now() + 1) == .success {
            return
        }
        let identifier = process.processIdentifier
        if process.isRunning, identifier > 0 {
            _ = Darwin.kill(identifier, SIGKILL)
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }
}

private final class LimitedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()

    init(limit: Int) {
        self.limit = limit
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        guard limit > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - storage.count)
        if remaining > 0 {
            storage.append(data.prefix(remaining))
        }
    }
}
