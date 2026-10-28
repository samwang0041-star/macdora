import Foundation
import XCTest
@testable import AndroidUse

final class RuntimeConnectionPortsTests: XCTestCase {
    func testIsolatedConnectionTargetsEveryGuestCommandAtItsOwnInstance() async throws {
        let runner = ConnectionRecordingRunner()
        let environment = SystemControllerEnvironment(runner: runner, ports: .init(adb: 5051, emulator: 5590))
        let adb = URL(fileURLWithPath: "/tmp/owned-qa/platform-tools/adb")
        let allocation = try await environment.allocateForward(adbURL: adb, environment: [:], requestedPort: 45185, scid: 73)
        XCTAssertEqual(allocation.serial, "emulator-5590")
        try await environment.secureCopy(adbURL: adb, localURL: URL(fileURLWithPath: "/tmp/fixture.jar"), remotePath: "/data/local/tmp/fixture.jar", environment: [:])
        try await environment.removeForward(adbURL: adb, environment: [:], allocation: allocation)
        let invocations = runner.snapshot()
        XCTAssertEqual(invocations.count, 3)
        for invocation in invocations {
            XCTAssertEqual(Array(invocation.arguments.prefix(6)), ["-H", "127.0.0.1", "-P", "5051", "-s", "emulator-5590"])
            XCTAssertFalse(invocation.arguments.contains("5043"))
            XCTAssertFalse(invocation.arguments.contains("emulator-5584"))
        }
        XCTAssertEqual(RuntimeConnectionPorts.default.adb, 5043)
        XCTAssertEqual(RuntimeConnectionPorts.default.serial, "emulator-5584")
    }
}

private final class ConnectionRecordingRunner: ProcessExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var invocations: [ProcessInvocation] = []

    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        record(invocation)
        return ProcessResult(exitCode: 0, stdout: Data(), timedOut: false)
    }

    func launch(_ invocation: ProcessInvocation, operation: String, onExit: @escaping @Sendable (ProcessExit) -> Void) async throws -> any OwnedProcessHandle {
        throw RuntimeError.unexpected("此检查不启动进程")
    }

    private func record(_ invocation: ProcessInvocation) {
        lock.lock(); defer { lock.unlock() }
        invocations.append(invocation)
    }

    func snapshot() -> [ProcessInvocation] {
        lock.lock(); defer { lock.unlock() }
        return invocations
    }
}
