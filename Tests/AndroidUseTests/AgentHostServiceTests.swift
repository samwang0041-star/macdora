import AppKit
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import AndroidUse

@Suite("Agent Host Service", .serialized)
struct AgentHostServiceTests {
    @Test("A prior copy can bind a new service instance while withdrawal wins")
    func copyAuthorizationRestartUsesExistingDigest() throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HostServiceAgentControlStore(rootURL: root, pluginID: "dev.agent.restore")
        let original = try store.loadOrCreate()
        let token = HostServiceAgentCopyToken.generate()
        let granted = try #require(try store.authorizeCopy(ifUnchanged: original,
            instanceID: UUID(), tokenDigest: token.digest))
        let instance = UUID()
        let rebound = try #require(try store.rebindCopyAuthorization(ifUnchanged: granted, toInstance: instance))
        #expect(rebound.authorization?.instanceId == instance)
        #expect(rebound.authorization?.tokenSHA256 == token.digest)
        #expect(rebound.generation != granted.generation)
        #expect(try store.rebindCopyAuthorization(ifUnchanged: rebound, toInstance: instance) == rebound)
        let manual = try store.setManual(true)
        #expect(try store.rebindCopyAuthorization(ifUnchanged: rebound, toInstance: UUID()) == nil)
        #expect(try store.rebindCopyAuthorization(ifUnchanged: manual, toInstance: UUID()) == nil)
        #expect(try store.reload() == manual)
    }

    @Test("A trusted service restart restores the old copy after login without opening the workspace")
    @MainActor
    func restartRestoresCopyWithoutWorkspace() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeAgentRuntimeFixture(root: root, id: "dev.agent.restart",
            publishEndpointOnLaunch: true, copyToken: true)
        defer { fixture.launcher.stopAll() }
        let store = HostServiceAgentControlStore(rootURL: root, pluginID: fixture.manifest.id)
        let initial = try store.loadOrCreate()
        let token = HostServiceAgentCopyToken.generate()
        let previous = try #require(try store.authorizeCopy(ifUnchanged: initial,
            instanceID: UUID(), tokenDigest: token.digest))
        let rpc = AgentRecoveryRPCClient()
        let plugin = HostServiceSystemPlugin(manifest: fixture.manifest,
            bundleDirectoryURL: fixture.bundleURL, rootURL: root,
            processExecuter: fixture.launcher, processTerminator: AgentStartupTerminator(),
            healthClient: { _, _, _ in .success(()) }, agentRPCClient: rpc,
            agentRestoreRetryDelay: .milliseconds(5))
        defer { plugin.retire() }
        await plugin.activate(bridge: AgentEnvironmentTestBridge())
        try await rpc.waitForCallCount(2)
        let calls = await rpc.callsSnapshot()
        let restored = try store.reload()
        let instance = try #require(plugin.agentRuntimeContext()?.instanceID)
        #expect(plugin.healthState == .healthy)
        #expect(restored.authorization?.instanceId == instance)
        #expect(restored.authorization?.tokenSHA256 == token.digest)
        #expect(restored.generation != previous.generation)
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0 == restored })
    }

    @Test("Restart recovery stops after a runtime permission denial")
    @MainActor
    func restartDoesNotRetryPermissionDenial() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeAgentRuntimeFixture(root: root, id: "dev.agent.restart-denied",
            publishEndpointOnLaunch: true, copyToken: true)
        defer { fixture.launcher.stopAll() }
        let store = HostServiceAgentControlStore(rootURL: root, pluginID: fixture.manifest.id)
        let token = HostServiceAgentCopyToken.generate()
        _ = try #require(try store.authorizeCopy(ifUnchanged: store.loadOrCreate(),
            instanceID: UUID(), tokenDigest: token.digest))
        let rpc = AgentRecordingRPCClient(response: .failure(.server(.permissionDenied)))
        let plugin = HostServiceSystemPlugin(manifest: fixture.manifest,
            bundleDirectoryURL: fixture.bundleURL, rootURL: root,
            processExecuter: fixture.launcher, processTerminator: AgentStartupTerminator(),
            healthClient: { _, _, _ in .success(()) }, agentRPCClient: rpc,
            agentRestoreRetryDelay: .milliseconds(5))
        defer { plugin.retire() }
        await plugin.activate(bridge: AgentEnvironmentTestBridge())
        try await Task.sleep(for: .milliseconds(80))
        #expect(await rpc.callsSnapshot().map(\.method) == [.authorize])
    }

    @Test("Manual withdrawal wins while a restart authorization reply is pending")
    @MainActor
    func restartRestoreCannotUndoWithdrawal() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeAgentRuntimeFixture(root: root, id: "dev.agent.restart-race",
            publishEndpointOnLaunch: true, copyToken: true)
        defer { fixture.launcher.stopAll() }
        let store = HostServiceAgentControlStore(rootURL: root, pluginID: fixture.manifest.id)
        let initial = try store.loadOrCreate()
        let token = HostServiceAgentCopyToken.generate()
        _ = try #require(try store.authorizeCopy(ifUnchanged: initial,
            instanceID: UUID(), tokenDigest: token.digest))
        let rpc = AgentControlledRPCClient(gatedMethods: [.authorize])
        let plugin = HostServiceSystemPlugin(manifest: fixture.manifest,
            bundleDirectoryURL: fixture.bundleURL, rootURL: root,
            processExecuter: fixture.launcher, processTerminator: AgentStartupTerminator(),
            healthClient: { _, _, _ in .success(()) }, agentRPCClient: rpc,
            agentRestoreRetryDelay: .milliseconds(5))
        defer { plugin.retire() }
        await plugin.activate(bridge: AgentEnvironmentTestBridge())
        await rpc.waitForCallCount(1)
        let instance = try #require(plugin.agentRuntimeContext()?.instanceID)
        let manual = try store.setManual(true)
        await rpc.resolve(.authorize, with: .success(agentStatus(pluginID: fixture.manifest.id,
            instanceID: instance, manual: false, businessReady: false, state: .ready)))
        try await Task.sleep(for: .milliseconds(25))
        #expect(try store.reload() == manual)
    }

    @Test("Copy authorization exports an executable cross-language wire fixture",
          .enabled(if: ProcessInfo.processInfo.environment["MACDORA_AGENT_COPY_WIRE_EXPORT"] != nil,
                   "Set MACDORA_AGENT_COPY_WIRE_EXPORT for the private protocol acceptance fixture."))
    func copyTokenCrossLanguageExport() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MACDORA_AGENT_COPY_WIRE_EXPORT"])
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HostServiceAgentControlStore(rootURL: root, pluginID: "dev.example.copy")
        let initial = try store.loadOrCreate()
        let instance = try #require(UUID(uuidString: "19B4C6BE-2182-44EE-9D4C-B5A5E91F931D"))
        let token = HostServiceAgentCopyToken(value: String(repeating: "f", count: 64))
        let record = try #require(try store.authorizeCopy(ifUnchanged: initial,
            instanceID: instance, tokenDigest: token.digest))
        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL))
        let request = HostServiceAgentWire.request(method: .authorize, requestID: 41,
            instanceID: instance, generation: record.generation, authorization: record.authorization)
        let config = try HostServiceAgentMCPConfiguration.document(pluginID: "dev.example.copy",
            agentExecutableURL: URL(fileURLWithPath: "/tmp/Sample Plugin/bin/agent"),
            endpointURL: URL(fileURLWithPath: "/tmp/Sample Plugin/endpoint.json"), token: token.value)
        let configuration = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config))
        let data = try JSONSerialization.data(withJSONObject: ["control": persisted,
            "request": request, "configuration": configuration], options: [.sortedKeys, .prettyPrinted])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    @Test("Copy token mode commits authorization only after clipboard success")
    @MainActor
    func copyTokenClipboardFailure() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.clipboard", copyToken: true)
        defer { plugin.retire() }
        try writeCopyEndpoint(plugin)
        let rpc = AgentRecordingRPCClient(response: .failure(.unavailable))
        let controller = HostServiceAgentWorkspaceController(plugin: plugin, rpcClient: rpc)
        let before = try plugin.agentControlStore.reload()
        do {
            try await controller.copyAgentHandoff(writeToClipboard: { _ in false })
            Issue.record("A failed clipboard write must fail the action")
        } catch {}
        #expect(try plugin.agentControlStore.reload() == before)
        #expect(await rpc.callsSnapshot().isEmpty)
        #expect(!controller.isSubmitting)
    }

    @Test("Copy alone authorizes without an Agent connection and preserves manual withdrawal")
    @MainActor
    func copyTokenAuthorizesWithoutConsumer() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.copy-authorize", copyToken: true)
        defer { plugin.retire() }
        try writeCopyEndpoint(plugin)
        let context = try #require(plugin.agentRuntimeContext())
        var response = agentStatus(pluginID: plugin.manifest.id, instanceID: context.instanceID,
            manual: false, consumerId: nil, businessReady: false, state: .ready)
        response.agentConnected = false
        let rpc = AgentRecordingRPCClient(response: .success(response))
        let controller = HostServiceAgentWorkspaceController(plugin: plugin, rpcClient: rpc)
        var copied = ""
        try await controller.copyAgentHandoff(writeToClipboard: { copied = $0; return true })
        let record = try plugin.agentControlStore.reload()
        #expect(record.schemaVersion == 2 && !record.manual)
        #expect(copied.contains("MACDORA_AGENT_TOKEN"))
        #expect(!copied.contains("测试连接"))
        #expect(await rpc.callsSnapshot().map(\.method) == [.authorize])
        #expect(controller.primaryAction == .revoke)
        #expect(!controller.canTestConnection)
        #expect(controller.statusText == "已授权，待接入")
        #expect(!controller.isSubmitting)
    }

    @Test("Copy before login keeps the grant and restores it after login")
    @MainActor
    func copyBeforeLoginRecoversAutomatically() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = AgentRecoveryRPCClient()
        let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.copy-before-login",
            copyToken: true, rpcClient: rpc, restoreRetryDelay: .milliseconds(5))
        defer { plugin.retire() }
        try writeCopyEndpoint(plugin)
        let controller = HostServiceAgentWorkspaceController(plugin: plugin, rpcClient: rpc)
        var copied = false
        try await controller.copyAgentHandoff(writeToClipboard: { _ in copied = true; return true })
        #expect(copied)
        #expect(controller.statusText == "需要登录")
        #expect(controller.primaryAction == .revoke)
        let record = try plugin.agentControlStore.reload()
        #expect(!record.manual)
        try await rpc.waitForCallCount(2)
        let calls = await rpc.callsSnapshot()
        #expect(calls[0] == record)
        #expect(calls[1] == record)
        #expect(try plugin.agentControlStore.reload() == record)
    }

    @Test("Copy also recovers from a temporarily busy or unavailable business session")
    @MainActor
    func copyTemporaryBusinessFailureRecovers() async throws {
        for (index, failure) in [HostServiceAgentFailure.server(.businessNotReady),
                                  .server(.recoveryRequired), .busy].enumerated() {
            let root = try agentTemporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let rpc = AgentRecoveryRPCClient(firstFailure: failure)
            let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.copy-busy-\(index)",
                copyToken: true, rpcClient: rpc, restoreRetryDelay: .milliseconds(5))
            defer { plugin.retire() }
            try writeCopyEndpoint(plugin)
            let controller = HostServiceAgentWorkspaceController(plugin: plugin, rpcClient: rpc)
            try await controller.copyAgentHandoff(writeToClipboard: { _ in true })
            #expect(controller.statusText == "接入待恢复")
            let record = try plugin.agentControlStore.reload()
            #expect(!record.manual)
            try await rpc.waitForCallCount(2)
            let calls = await rpc.callsSnapshot()
            #expect(calls[0] == record && calls[1] == record)
        }
    }

    @Test("Permission failure during copy does not leave a usable grant")
    @MainActor
    func copyPermissionFailureRollsBack() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.copy-denied", copyToken: true)
        defer { plugin.retire() }
        try writeCopyEndpoint(plugin)
        let rpc = AgentRecordingRPCClient(response: .failure(.server(.permissionDenied)))
        let controller = HostServiceAgentWorkspaceController(plugin: plugin, rpcClient: rpc)
        do {
            try await controller.copyAgentHandoff(writeToClipboard: { _ in true })
            Issue.record("A denied authorization must not succeed")
        } catch {}
        #expect(try plugin.agentControlStore.reload().manual)
        #expect(await rpc.callsSnapshot().count == 1)
    }

    @Test("Manual withdrawal wins while first-copy login recovery is pending")
    @MainActor
    func copyBeforeLoginWithdrawalWins() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = AgentControlledRPCClient(gatedMethods: [.authorize])
        let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.copy-login-withdraw",
            copyToken: true, rpcClient: rpc, restoreRetryDelay: .milliseconds(5))
        defer { plugin.retire() }
        try writeCopyEndpoint(plugin)
        let controller = HostServiceAgentWorkspaceController(plugin: plugin, rpcClient: rpc)
        let copy = Task { @MainActor in
            try await controller.copyAgentHandoff(writeToClipboard: { _ in true })
        }
        await rpc.waitForCallCount(1)
        await rpc.resolve(.authorize, with: .failure(.server(.loginRequired)))
        try await copy.value
        await rpc.waitForCallCount(2)
        let instance = try #require(plugin.agentRuntimeContext()?.instanceID)
        await controller.performPrimaryAction()
        let manual = try plugin.agentControlStore.reload()
        #expect(manual.manual)
        await rpc.resolve(.authorize, with: .success(agentStatus(pluginID: plugin.manifest.id,
            instanceID: instance, manual: false, businessReady: false, state: .ready)))
        try await Task.sleep(for: .milliseconds(25))
        #expect(try plugin.agentControlStore.reload() == manual)
        #expect(controller.primaryAction != .revoke)
    }

    @Test("An authorized idle connection does not claim preparation is running")
    @MainActor
    func copyTokenConnectedIdleIsNotPreparing() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.connected-idle", copyToken: true)
        defer { plugin.retire() }
        try writeCopyEndpoint(plugin)
        let instance = try #require(plugin.agentRuntimeContext()?.instanceID)
        let response = agentStatus(pluginID: plugin.manifest.id, instanceID: instance,
            manual: false, consumerId: UUID(), businessReady: false, state: .ready)
        let controller = HostServiceAgentWorkspaceController(plugin: plugin,
            rpcClient: AgentRecordingRPCClient(response: .success(response)))
        try await controller.copyAgentHandoff(writeToClipboard: { _ in true })
        #expect(controller.statusText == "已授权，待处理")
        #expect(controller.primaryAction == .revoke)
        #expect(!controller.canTestConnection)
    }

    @Test("Copy authorization waiting for recovery does not demand another copy")
    @MainActor
    func copyTokenWaitingForRecovery() throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.restore-ui", copyToken: true)
        defer { plugin.retire() }
        let instance = try #require(plugin.agentRuntimeContext()?.instanceID)
        let controller = HostServiceAgentWorkspaceController(plugin: plugin)
        let waiting = agentStatus(pluginID: plugin.manifest.id, instanceID: instance,
            manual: true, businessReady: false, state: .waitingForAgent)
        controller.setLoadedStatusForTesting(waiting, persistedManual: false, loaded: true)
        #expect(controller.statusText == "接入待恢复")
        #expect(!controller.detailText.contains("重新复制接入内容后即可继续"))
        #expect(controller.primaryAction == .revoke)
        let login = agentStatus(pluginID: plugin.manifest.id, instanceID: instance,
            manual: false, businessReady: false, state: .waitingForLogin, errorCode: .loginRequired)
        controller.setLoadedStatusForTesting(login, persistedManual: false, loaded: true)
        #expect(controller.statusText == "需要登录")
        #expect(controller.detailText.contains("登录"))
        #expect(controller.handoffPillText == "需要登录")
        #expect(controller.primaryAction == .revoke)
    }

    @Test("An open copy workspace refreshes after background authorization recovery")
    @MainActor
    func copyWorkspaceRefreshesAfterBackgroundRecovery() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.restore-open-ui", copyToken: true)
        defer { plugin.retire() }
        let instance = try #require(plugin.agentRuntimeContext()?.instanceID)
        let store = plugin.agentControlStore
        let previous = try store.loadOrCreate()
        let token = HostServiceAgentCopyToken.generate()
        _ = try #require(try store.authorizeCopy(ifUnchanged: previous,
            instanceID: instance, tokenDigest: token.digest))
        let restored = agentStatus(pluginID: plugin.manifest.id, instanceID: instance,
            manual: false, businessReady: false, state: .ready)
        let rpc = AgentRecordingRPCClient(response: .success(restored))
        let controller = HostServiceAgentWorkspaceController(plugin: plugin, rpcClient: rpc)
        let pending = agentStatus(pluginID: plugin.manifest.id, instanceID: instance,
            manual: true, businessReady: false, state: .waitingForAgent)
        controller.setLoadedStatusForTesting(pending, persistedManual: false, loaded: true)
        controller.setRefreshingForTesting(false)
        controller.hostStateDidChange()
        try await Task.sleep(for: .milliseconds(80))
        let calls = await rpc.callsSnapshot()
        #expect(calls.map(\.method) == [.status])
        #expect(controller.status == restored)
        #expect(controller.statusText == "已授权，待接入")
        #expect(controller.primaryAction == .revoke)
    }

    @Test("An open copy workspace refreshes after the runtime or control record changed")
    @MainActor
    func copyWorkspaceRecoversFromFailedState() async throws {
        for message in ["运行实例已改变，请重新检查连接。", "控制权已更新，请重新检查。"] {
            let root = try agentTemporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.failed-restore", copyToken: true)
            defer { plugin.retire() }
            let instance = try #require(plugin.agentRuntimeContext()?.instanceID)
            let store = plugin.agentControlStore
            let token = HostServiceAgentCopyToken.generate()
            _ = try #require(try store.authorizeCopy(ifUnchanged: store.loadOrCreate(),
                instanceID: instance, tokenDigest: token.digest))
            let restored = agentStatus(pluginID: plugin.manifest.id, instanceID: instance,
                manual: false, businessReady: false, state: .ready)
            let rpc = AgentRecordingRPCClient(response: .success(restored))
            let controller = HostServiceAgentWorkspaceController(plugin: plugin, rpcClient: rpc)
            controller.ingestFailureForTesting(message, persistedManual: false)
            controller.setViewLoadedForTesting(true)
            controller.hostStateDidChange()
            try await Task.sleep(for: .milliseconds(80))
            #expect(await rpc.callsSnapshot().map(\.method) == [.status])
            #expect(controller.status == restored)
            #expect(controller.primaryAction == .revoke)
        }
    }

    @Test("An open copy workspace refreshes after a real runtime instance replacement")
    @MainActor
    func copyWorkspaceRefreshesAfterInstanceReplacement() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.instance-refresh", copyToken: true)
        defer { plugin.retire() }
        let oldInstance = try #require(plugin.agentRuntimeContext()?.instanceID)
        let store = plugin.agentControlStore
        let token = HostServiceAgentCopyToken.generate()
        let previous = try #require(try store.authorizeCopy(ifUnchanged: store.loadOrCreate(),
            instanceID: oldInstance, tokenDigest: token.digest))
        let rpc = AgentControlledRPCClient(gatedMethods: [.status])
        let controller = HostServiceAgentWorkspaceController(plugin: plugin, rpcClient: rpc)
        let oldStatus = agentStatus(pluginID: plugin.manifest.id, instanceID: oldInstance,
            manual: false, businessReady: false, state: .ready)
        controller.setLoadedStatusForTesting(oldStatus, persistedManual: false, loaded: true)
        controller.setRefreshingForTesting(false)
        let nextLauncher = AgentTestProcessLauncher()
        plugin.installAgentTestRuntime(handle: nextLauncher.currentHandle)
        let newInstance = try #require(plugin.agentRuntimeContext()?.instanceID)
        #expect(newInstance != oldInstance)
        _ = try #require(try store.rebindCopyAuthorization(ifUnchanged: previous, toInstance: newInstance))
        controller.hostStateDidChange()
        try await Task.sleep(for: .milliseconds(80))
        let calls = await rpc.callsSnapshot()
        #expect(calls.map(\.method) == [.status])
        guard !calls.isEmpty else { return }
        let restored = agentStatus(pluginID: plugin.manifest.id, instanceID: newInstance,
            manual: false, businessReady: false, state: .ready)
        await rpc.resolve(.status, with: .success(restored))
        try await Task.sleep(for: .milliseconds(30))
        #expect(controller.status == restored)
        #expect(controller.primaryAction == .revoke)
    }

    @Test("An open copy workspace retries after a control generation changes during refresh")
    @MainActor
    func copyWorkspaceRetriesAfterControlGenerationRace() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.refresh-race", copyToken: true)
        defer { plugin.retire() }
        let instance = try #require(plugin.agentRuntimeContext()?.instanceID)
        let store = plugin.agentControlStore
        let token = HostServiceAgentCopyToken.generate()
        let first = try #require(try store.authorizeCopy(ifUnchanged: store.loadOrCreate(),
            instanceID: instance, tokenDigest: token.digest))
        let rpc = AgentControlledRPCClient(gatedMethods: [.status])
        let controller = HostServiceAgentWorkspaceController(plugin: plugin, rpcClient: rpc)
        controller.setViewLoadedForTesting(true)
        let refresh = Task { @MainActor in await controller.refresh() }
        await rpc.waitForCallCount(1)
        let replacement = HostServiceAgentCopyToken.generate()
        _ = try #require(try store.authorizeCopy(ifUnchanged: first,
            instanceID: instance, tokenDigest: replacement.digest))
        let restored = agentStatus(pluginID: plugin.manifest.id, instanceID: instance,
            manual: false, businessReady: false, state: .ready)
        await rpc.resolve(.status, with: .success(restored))
        await refresh.value
        #expect(controller.status == nil)
        controller.hostStateDidChange()
        try await Task.sleep(for: .milliseconds(80))
        let calls = await rpc.callsSnapshot()
        #expect(calls.map(\.method) == [.status, .status])
        guard calls.count == 2 else { return }
        await rpc.resolve(.status, with: .success(restored))
        try await Task.sleep(for: .milliseconds(30))
        #expect(controller.status == restored)
    }

    @Test("An open failed workspace does not restore after the user takes control")
    @MainActor
    func copyWorkspaceDoesNotRestoreAfterWithdrawal() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.failed-manual", copyToken: true)
        defer { plugin.retire() }
        let instance = try #require(plugin.agentRuntimeContext()?.instanceID)
        let rpc = AgentRecordingRPCClient(response: .success(agentStatus(pluginID: plugin.manifest.id,
            instanceID: instance, manual: false, businessReady: false, state: .ready)))
        let controller = HostServiceAgentWorkspaceController(plugin: plugin, rpcClient: rpc)
        controller.ingestFailureForTesting("控制权已更新，请重新检查。", persistedManual: false)
        controller.setViewLoadedForTesting(true)
        _ = try plugin.agentControlStore.setManual(true)
        controller.hostStateDidChange()
        try await Task.sleep(for: .milliseconds(30))
        #expect(await rpc.callsSnapshot().isEmpty)
        #expect(controller.primaryAction == nil)
    }

    @Test("A runtime permission failure is not displayed as an automatic business recovery")
    @MainActor
    func copyWorkspaceShowsPermissionFailure() throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.permission-ui", copyToken: true)
        defer { plugin.retire() }
        let instance = try #require(plugin.agentRuntimeContext()?.instanceID)
        let controller = HostServiceAgentWorkspaceController(plugin: plugin)
        let denied = agentStatus(pluginID: plugin.manifest.id, instanceID: instance,
            manual: true, businessReady: false, state: .needsAttention, errorCode: .permissionDenied)
        controller.setLoadedStatusForTesting(denied, persistedManual: false, loaded: true)
        #expect(controller.statusText == "接入受限")
        #expect(controller.detailText.contains("权限"))
        #expect(controller.primaryAction == .revoke)
    }

    @Test("Unconfirmed copy authorization rolls back only its generation")
    @MainActor
    func copyTokenUncertainAuthorizationRollsBack() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.copy-rollback", copyToken: true)
        defer { plugin.retire() }
        try writeCopyEndpoint(plugin)
        let controller = HostServiceAgentWorkspaceController(plugin: plugin, rpcClient: AgentFailingRPCClient())
        do {
            try await controller.copyAgentHandoff(writeToClipboard: { _ in true })
            Issue.record("An unconfirmed authorization must fail")
        } catch {}
        let record = try plugin.agentControlStore.reload()
        #expect(record.manual && record.authorization == nil)
        #expect(controller.primaryAction == nil)
        #expect(!controller.isSubmitting)
    }

    @Test("A late copy authorization cannot undo the user's newer manual withdrawal")
    @MainActor
    func copyTokenLateAuthorizationLosesToWithdrawal() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.copy-race", copyToken: true)
        defer { plugin.retire() }
        try writeCopyEndpoint(plugin)
        let instance = try #require(plugin.agentRuntimeContext()?.instanceID)
        let rpc = AgentControlledRPCClient(gatedMethods: [.authorize])
        let controller = HostServiceAgentWorkspaceController(plugin: plugin, rpcClient: rpc)
        let copying = Task { @MainActor in
            try? await controller.copyAgentHandoff(writeToClipboard: { _ in true })
        }
        await rpc.waitForCallCount(1)
        await controller.performPrimaryAction()
        let manual = try plugin.agentControlStore.reload()
        await rpc.resolve(.authorize, with: .success(agentStatus(pluginID: plugin.manifest.id,
            instanceID: instance, manual: false, consumerId: nil, businessReady: false)))
        await copying.value
        #expect(manual.manual)
        #expect(try plugin.agentControlStore.reload() == manual)
        #expect(!controller.isSubmitting)
        #expect(!controller.showsAgentManaged)
    }

    @Test("Copy authorization stores only a scoped token digest and explicit revoke invalidates it")
    func copyTokenControlLifecycle() throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HostServiceAgentControlStore(rootURL: root, pluginID: "dev.agent.copy")
        let initial = try store.loadOrCreate()
        let token = HostServiceAgentCopyToken.generate()
        let instance = UUID()
        let granted = try #require(try store.authorizeCopy(
            ifUnchanged: initial, instanceID: instance, tokenDigest: token.digest
        ))
        #expect(granted.schemaVersion == 2)
        #expect(!granted.manual)
        #expect(granted.authorization?.scope == "readOnly")
        #expect(granted.authorization?.instanceId == instance)
        #expect(granted.authorization?.tokenSHA256 == token.digest)
        #expect(try store.reload() == granted)
        let persisted = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!persisted.contains(token.value))
        #expect(token.value.count == 64)
        #expect(HostServiceAgentCopyToken.generate().value != token.value)
        let revoked = try store.setManual(true)
        #expect(revoked.authorization == nil)
        #expect(revoked.generation != granted.generation)
        #expect(try store.authorizeCopy(ifUnchanged: granted, instanceID: instance,
            tokenDigest: token.digest) == nil)
        #expect(try store.reload() == revoked)
    }

    @Test("A copied credential travels in structured MCP environment rather than process arguments")
    func copyTokenStructuredEnvironment() throws {
        let token = HostServiceAgentCopyToken.generate()
        let data = try HostServiceAgentMCPConfiguration.data(
            pluginID: "dev.agent.copy", agentExecutableURL: URL(fileURLWithPath: "/tmp/Sample Plugin/bin/agent"),
            endpointURL: URL(fileURLWithPath: "/tmp/Sample Plugin/endpoint.json"), token: token.value
        )
        let document = try JSONDecoder().decode(HostServiceAgentMCPConfiguration.Document.self, from: data)
        let server = try #require(document.mcpServers["dev.agent.copy"])
        #expect(server.env?["MACDORA_AGENT_TOKEN"] == token.value)
        #expect(server.args == ["--endpoint", "/tmp/Sample Plugin/endpoint.json"])
        #expect(!server.args.contains(token.value))
        let handoff = try HostServiceAgentMCPConfiguration.handoff(instructions: nil, configuration: data)
        #expect(handoff.contains("本次复制已授权"))
        #expect(!handoff.contains("需要人工确认时"))
    }

    @Test("An explicitly selected development bundle passes the actual host verifier without installation",
          .enabled(if: ProcessInfo.processInfo.environment["MACDORA_AGENT_DEVELOPMENT_BUNDLE"] != nil,
                   "Set MACDORA_AGENT_DEVELOPMENT_BUNDLE for a local artifact check."))
    func localDevelopmentBundlePassesHostVerifier() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MACDORA_AGENT_DEVELOPMENT_BUNDLE"])
        let manifest = try SystemPluginPackageFactory.verifyPluginDirectory(
            URL(fileURLWithPath: path), trustPolicy: .developerLocalImport
        )
        #expect(manifest.driverType == "host_service")
        #expect(manifest.capabilities.contains("agent.readonly"))
        #expect(manifest.entrypoints.agentMCP != nil)
    }

    @Test("Agent capability stays opt-in and legacy manifests remain compatible")
    func agentManifestOptIn() throws {
        let plain = agentFixtureManifest(
            capabilities: ["host.service"],
            agentMCP: nil
        )
        #expect(SystemPluginCatalogItem(
            id: plain.id,
            name: plain.name,
            subtitle: "",
            version: plain.version,
            availableUpdateVersion: nil,
            author: "",
            category: "",
            iconSymbol: "",
            accentHex: 0,
            isOfficialPreset: false,
            packageSizeLabel: "",
            capabilities: plain.capabilities,
            driverType: plain.driverType,
            state: .installed(isEnabled: false),
            healthState: .inactive,
            statusDetail: "",
            lastErrorDetail: nil,
            downloadSourceDescription: ""
        ).hasDedicatedWorkspace == false)

        let agent = agentFixtureManifest(
            capabilities: ["host.service", "agent.readonly"],
            agentMCP: "bin/agent"
        )
        #expect(SystemPluginCatalogItem(
            id: agent.id,
            name: agent.name,
            subtitle: "",
            version: agent.version,
            availableUpdateVersion: nil,
            author: "",
            category: "",
            iconSymbol: "",
            accentHex: 0,
            isOfficialPreset: false,
            packageSizeLabel: "",
            capabilities: agent.capabilities,
            driverType: agent.driverType,
            state: .installed(isEnabled: false),
            healthState: .inactive,
            statusDetail: "",
            lastErrorDetail: nil,
            downloadSourceDescription: ""
        ).hasDedicatedWorkspace)

        let legacy = Data("""
        {
          "schemaVersion": 1,
          "id": "dev.legacy.agent",
          "name": "Legacy",
          "subtitle": "",
          "version": "1.0.0",
          "author": "test",
          "category": "test",
          "iconSymbol": "puzzlepiece",
          "accentHex": 0,
          "minHostVersion": "0.2.0",
          "capabilities": ["guest.shell"],
          "driverType": "external_script",
          "entrypoints": {}
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(SystemPluginManifest.self, from: legacy)
        #expect(decoded.entrypoints.agentMCP == nil)
        #expect(!decoded.entrypoints.allRelativePaths.contains("bin/agent"))
        #expect(decoded.driverType == "external_script")
        #expect(SystemPluginManifest.supportedCapabilities.contains("agent.readonly"))
    }

    @Test("Agent manifest verification rejects unsafe paths, unsigned entries and malformed combinations")
    func agentManifestPathAndSignatureValidation() throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let malicious = try makeAgentPackage(
            root: root,
            id: "dev.agent.malicious",
            agentPath: "../outside",
            createExecutable: false
        )
        #expect(throws: SystemPluginPackageError.self) {
            _ = try SystemPluginPackageFactory.verifyPluginDirectory(
                malicious,
                trustPolicy: .developerLocalImport
            )
        }

        let unsigned = try makeAgentPackage(
            root: root,
            id: "dev.agent.unsigned",
            agentPath: "bin/agent",
            createExecutable: false
        )
        #expect(throws: SystemPluginPackageError.self) {
            _ = try SystemPluginPackageFactory.verifyPluginDirectory(
                unsigned,
                trustPolicy: .developerLocalImport
            )
        }

        let wrongCapability = try makeAgentPackage(
            root: root,
            id: "dev.agent.wrong-capability",
            capabilities: ["host.service"],
            agentPath: "bin/agent",
            createExecutable: true
        )
        #expect(throws: SystemPluginPackageError.self) {
            _ = try SystemPluginPackageFactory.verifyPluginDirectory(
                wrongCapability,
                trustPolicy: .developerLocalImport
            )
        }

        let missingEntrypoint = try makeAgentPackage(
            root: root,
            id: "dev.agent.missing-entrypoint",
            capabilities: ["host.service", "agent.readonly"],
            agentPath: nil,
            createExecutable: false
        )
        #expect(throws: SystemPluginPackageError.self) {
            _ = try SystemPluginPackageFactory.verifyPluginDirectory(
                missingEntrypoint,
                trustPolicy: .developerLocalImport
            )
        }

        let entrypointWithoutCapability = try makeAgentPackage(
            root: root,
            id: "dev.agent.entrypoint-without-capability",
            capabilities: ["host.service"],
            agentPath: "bin/agent",
            createExecutable: true
        )
        #expect(throws: SystemPluginPackageError.self) {
            _ = try SystemPluginPackageFactory.verifyPluginDirectory(
                entrypointWithoutCapability,
                trustPolicy: .developerLocalImport
            )
        }
    }

    @Test("Plugin setup knowledge is signed metadata and stays opt-in")
    func signedAgentSetupMetadata() throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeAgentPackage(
            root: root, id: "dev.agent.setup", agentPath: "bin/agent",
            createExecutable: true, agentInstructions: "Discover the provider's declared tools.",
            agentSummary: "只读计数；不返回正文，不写业务"
        )
        let accepted = try SystemPluginPackageFactory.verifyPluginDirectory(
            bundle, trustPolicy: .developerLocalImport
        )
        #expect(accepted.agentInstructions == "Discover the provider's declared tools.")
        #expect(accepted.agentSummary?.contains("只读计数") == true)
        let manifestURL = bundle.appendingPathComponent("manifest.json")
        var modified = accepted
        modified.agentInstructions = "A changed setup instruction."
        try JSONEncoder().encode(modified).write(to: manifestURL)
        #expect(throws: SystemPluginPackageError.self) {
            _ = try SystemPluginPackageFactory.verifyPluginDirectory(bundle, trustPolicy: .developerLocalImport)
        }
        for invalid in [" ", String(repeating: "x", count: 16_385), "hidden\u{0000}instruction"] {
            modified.agentInstructions = invalid
            try JSONEncoder().encode(modified).write(to: manifestURL)
            try SystemPluginPackageFactory.writeSignature(
                forPluginDirectory: bundle, pluginID: modified.id, version: modified.version
            )
            #expect(throws: SystemPluginPackageError.self) {
                _ = try SystemPluginPackageFactory.verifyPluginDirectory(bundle, trustPolicy: .developerLocalImport)
            }
        }
        modified.agentInstructions = "Valid setup guidance."
        modified.agentSummary = String(repeating: "x", count: 241)
        try JSONEncoder().encode(modified).write(to: manifestURL)
        try SystemPluginPackageFactory.writeSignature(
            forPluginDirectory: bundle, pluginID: modified.id, version: modified.version
        )
        #expect(throws: SystemPluginPackageError.self) {
            _ = try SystemPluginPackageFactory.verifyPluginDirectory(bundle, trustPolicy: .developerLocalImport)
        }
    }

    @Test("Agent handoff contains provider knowledge and preserves structured launch arguments")
    func agentHandoffPreservesStructuredConfiguration() throws {
        let executable = URL(fileURLWithPath: "/Applications/Example ' $(sample)/bin/agent")
        let endpoint = URL(fileURLWithPath: "/Users/example/Library/Application Support/Sample/endpoint.json")
        let configuration = try HostServiceAgentMCPConfiguration.data(
            pluginID: "dev.example.agent", agentExecutableURL: executable, endpointURL: endpoint
        )
        let handoff = try HostServiceAgentMCPConfiguration.handoff(
            instructions: "Discover sample_status, then follow the plugin's workflow.", configuration: configuration
        )
        #expect(handoff.contains("sample_status"))
        #expect(handoff.contains("保留已有服务"))
        #expect(handoff.contains("连接成功不代表用户已经授权"))
        let embedded = try #require(handoff.components(separatedBy: "```json\n").last?
            .components(separatedBy: "\n```").first)
        let parsed = try JSONDecoder().decode(HostServiceAgentMCPConfiguration.Document.self, from: Data(embedded.utf8))
        #expect(parsed.mcpServers["dev.example.agent"]?.command == executable.path)
        #expect(parsed.mcpServers["dev.example.agent"]?.args == ["--endpoint", endpoint.path])
        let legacy = try HostServiceAgentMCPConfiguration.handoff(instructions: nil, configuration: configuration)
        #expect(legacy.contains("工具发现"))
        #expect(!legacy.contains("sample_status"))
    }

    @Test("Control state remains manual across reload and each explicit change rotates generation")
    func controlStatePersistenceAndGeneration() throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let rootMarker = root.appendingPathComponent("root-marker")
        try Data("neutral".utf8).write(to: rootMarker)
        let firstStore = HostServiceAgentControlStore(
            rootURL: root,
            pluginID: "dev.agent.control"
        )
        let initial = try firstStore.loadOrCreate()
        #expect(initial.manual)
        #expect(try firstStore.reload() == initial)
        #expect(FileManager.default.fileExists(atPath: rootMarker.path))

        let granted = try firstStore.setManual(false)
        #expect(!granted.manual)
        #expect(granted.generation != initial.generation)

        let reopened = try HostServiceAgentControlStore(
            rootURL: root,
            pluginID: "dev.agent.control"
        ).loadOrCreate()
        #expect(reopened == granted)

        let revoked = try firstStore.setManual(true)
        #expect(revoked.manual)
        #expect(revoked.generation != granted.generation)

        let secondRevoke = try firstStore.setManual(true)
        #expect(secondRevoke.generation != revoked.generation)

        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: firstStore.directoryURL.path
        )
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: firstStore.fileURL.path
        )
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("Wire fixture matches Python lowercase consumer, host instance and generation")
    func crossLanguageWireFixture() throws {
        let instance = try #require(
            UUID(uuidString: "19B4C6BE-2182-44EE-9D4C-B5A5E91F931D")
        )
        let generation = try #require(
            UUID(uuidString: "c1f58fda-222c-42a7-a354-ea6288dce9a1")
        )
        let consumer = try #require(
            UUID(uuidString: "0f5d5d2c-3f37-4c58-a4a2-d8dca58f5e2a")
        )
        let fixture = try #require(
            String(
                data: HostServiceAgentWire.encodedRequest(
                    .grant,
                    requestID: 17,
                    instanceID: instance,
                    generation: generation,
                    consumerId: consumer
                ),
                encoding: .utf8
            )
        )
        #expect(fixture == HostServiceAgentWire.crossLanguageFixture)
        let decoded = try JSONDecoder().decode(
            HostServiceAgentWireFixture.self,
            from: Data(fixture.utf8)
        )
        #expect(decoded.params.consumerId == "0f5d5d2c-3f37-4c58-a4a2-d8dca58f5e2a")
        #expect(decoded.params.generation == "c1f58fda-222c-42a7-a354-ea6288dce9a1")
        #expect(decoded.params.instanceId == "19B4C6BE-2182-44EE-9D4C-B5A5E91F931D")

        let script = """
        import json, sys, uuid
        request = json.load(sys.stdin)
        params = request["params"]
        assert str(uuid.UUID(params["consumerId"])) == params["consumerId"]
        assert str(uuid.UUID(params["generation"])) == params["generation"]
        assert params["instanceId"] == "19B4C6BE-2182-44EE-9D4C-B5A5E91F931D"
        print(request["method"])
        """
        let python = try runCrossLanguagePython(script, input: Data(fixture.utf8))
        #expect(python.status == 0)
        #expect(String(decoding: python.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "macdora.agent.grant")
    }

    @Test("Control CAS cannot overwrite a newer explicit generation")
    func controlCASDoesNotOverwriteNewerAction() throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HostServiceAgentControlStore(
            rootURL: root,
            pluginID: "dev.agent.cas"
        )
        let initial = try store.loadOrCreate()
        let pending = try store.setManual(false)
        let newer = try store.setManual(false)
        #expect(newer.generation != pending.generation)

        let rollback = try store.compareAndSetManual(
            expectedGeneration: pending.generation,
            manual: true
        )
        #expect(rollback == nil)
        #expect(try store.reload() == newer)
        #expect(try store.reload().generation != initial.generation)
    }

    @Test("Manual withdrawal atomically repairs safe malformed or empty control files")
    func manualWithdrawalRepairsMalformedControlFile() throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HostServiceAgentControlStore(
            rootURL: root,
            pluginID: "dev.agent.malformed"
        )
        _ = try store.loadOrCreate()

        for contents in [Data(), Data("{not-json".utf8), Data("{}".utf8)] {
            try contents.write(to: store.fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int(0o600))],
                ofItemAtPath: store.fileURL.path
            )
            #expect(throws: HostServiceAgentControlStoreError.invalidRecord) {
                _ = try store.setManual(false)
            }
            let repaired = try store.setManual(true)
            #expect(repaired.manual)
            #expect(try store.reload() == repaired)
            #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
        }
    }

    @Test("Control store rejects hard links and unsafe permissions")
    func controlStoreRejectsHardLinkAndUnsafePermissions() throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HostServiceAgentControlStore(
            rootURL: root,
            pluginID: "dev.agent.hardlink"
        )
        _ = try store.loadOrCreate()
        let outside = root.appendingPathComponent("outside-control.json")
        try FileManager.default.linkItem(at: store.fileURL, to: outside)

        #expect(throws: HostServiceAgentControlStoreError.self) {
            _ = try store.setManual(true)
        }
        #expect(try Data(contentsOf: outside).count > 0)

        try FileManager.default.removeItem(at: outside)
        try FileManager.default.removeItem(at: store.fileURL)
        _ = try store.loadOrCreate()
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int(0o644))],
            ofItemAtPath: store.fileURL.path
        )
        #expect(throws: HostServiceAgentControlStoreError.self) {
            _ = try store.setManual(false)
        }
    }

    @Test("Symlinked control paths are refused without overwriting the target")
    func controlStoreRejectsSymlink() throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let outside = root.appendingPathComponent("outside.json")
        try Data("{\"manual\":false}".utf8).write(to: outside)
        let store = HostServiceAgentControlStore(
            rootURL: root,
            pluginID: "dev.agent.symlink"
        )
        try FileManager.default.createDirectory(
            at: store.directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(
            at: store.fileURL,
            withDestinationURL: outside
        )

        #expect(throws: HostServiceAgentControlStoreError.self) {
            _ = try store.setManual(false)
        }
        #expect(try Data(contentsOf: outside) == Data("{\"manual\":false}".utf8))
    }

    @Test("Offline revoke persists manual even when RPC is unavailable")
    @MainActor
    func offlineRevokePersistsManual() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = HostServiceSystemPlugin(
            manifest: agentFixtureManifest(
                capabilities: ["host.service", "agent.readonly"],
                agentMCP: "bin/agent"
            ),
            bundleDirectoryURL: root.appendingPathComponent("bundle", isDirectory: true),
            rootURL: root
        )
        let initial = try plugin.agentControlStore.loadOrCreate()
        _ = try plugin.agentControlStore.setManual(false)

        let controller = HostServiceAgentWorkspaceController(
            plugin: plugin,
            rpcClient: AgentFailingRPCClient()
        )
        let status = agentStatus(manual: false)
        controller.ingestStatusForTesting(status)
        await controller.performPrimaryAction()

        let stored = try plugin.agentControlStore.loadOrCreate()
        #expect(stored.manual)
        #expect(stored.generation != initial.generation)
        #expect(controller.display == .failed("已切回手动；插件当前离线，连接时会按手动模式运行。"))
    }

    @Test("Grant stays manual without a consumer handshake; tests must match the host instance")
    @MainActor
    func grantPreconditionsAndSuccess() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.grant")
        defer { plugin.retire() }
        _ = try plugin.agentControlStore.loadOrCreate()

        let runtimeInstanceID = try #require(plugin.agentRuntimeContext()?.instanceID)
        let consumer = UUID()
        let rpc = AgentRecordingRPCClient(
            response: .success(
                agentStatus(
                    pluginID: plugin.manifest.id,
                    instanceID: runtimeInstanceID,
                    manual: false,
                    consumerId: consumer,
                    businessReady: true
                )
            )
        )
        let controller = HostServiceAgentWorkspaceController(plugin: plugin, rpcClient: rpc)
        controller.setViewLoadedForTesting(true)

        controller.ingestStatusForTesting(agentStatus(manual: true, consumerId: nil, businessReady: true))
        #expect(controller.primaryAction == nil)
        await controller.performPrimaryAction()
        #expect(try plugin.agentControlStore.loadOrCreate().manual)
        #expect(await rpc.callsSnapshot().isEmpty)

        controller.ingestStatusForTesting(
            agentStatus(manual: true, consumerId: UUID(), businessReady: false)
        )
        #expect(controller.primaryAction == nil)
        await controller.performPrimaryAction()
        #expect(try plugin.agentControlStore.loadOrCreate().manual)
        #expect(await rpc.callsSnapshot().isEmpty)

        controller.ingestStatusForTesting(
            agentStatus(
                pluginID: plugin.manifest.id,
                instanceID: runtimeInstanceID,
                manual: true,
                consumerId: consumer,
                businessReady: true
            )
        )
        #expect(controller.primaryAction == .grant)
        await controller.performPrimaryAction()
        let stored = try plugin.agentControlStore.loadOrCreate()
        #expect(stored.manual == false)
        let calls = await rpc.callsSnapshot()
        #expect(calls.count == 1)
        #expect(calls.first?.method == .grant)
        #expect(calls.first?.consumerId == consumer)
        #expect(calls.first?.generation == stored.generation)
    }

    @Test("Grant RPC failure restores manual through CAS without stealing a newer action")
    @MainActor
    func grantFailureRestoresManual() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.grant-failure")
        defer { plugin.retire() }
        let initial = try plugin.agentControlStore.loadOrCreate()
        let rpc = AgentRecordingRPCClient(response: .failure(.unavailable))
        let controller = HostServiceAgentWorkspaceController(plugin: plugin, rpcClient: rpc)
        controller.setViewLoadedForTesting(true)
        controller.ingestStatusForTesting(
            agentStatus(
                pluginID: plugin.manifest.id,
                instanceID: plugin.agentRuntimeContext()?.instanceID ?? UUID(),
                manual: true,
                consumerId: UUID(),
                businessReady: true
            )
        )
        await controller.performPrimaryAction()

        let stored = try plugin.agentControlStore.loadOrCreate()
        #expect(stored.manual)
        #expect(stored.generation == initial.generation || stored.generation != initial.generation)
    }

    @Test("Invalid values, wrong instance and unknown state are rejected")
    func strictAgentResponseValidation() throws {
        let instance = UUID()
        let pluginID = "dev.agent.strict"
        let statusJSON = """
        {
          "schemaVersion": 1,
          "pluginId": "\(pluginID)",
          "instanceId": "\(instance.uuidString)",
          "state": "ready",
          "agentConnected": true,
          "businessReady": true,
          "taskRunning": false,
          "manual": true,
          "consumerId": "\(UUID().uuidString.lowercased())"
        }
        """
        let envelope = """
        {"jsonrpc":"2.0","id":42,"result":\(statusJSON)}
        """
        #expect(agentDecode(envelope, requestID: 42, pluginID: pluginID, instanceID: instance) != nil)

        let wrongInstance = """
        {"jsonrpc":"2.0","id":42,"result":\(statusJSON.replacingOccurrences(of: instance.uuidString, with: UUID().uuidString))}
        """
        #expect(agentDecode(wrongInstance, requestID: 42, pluginID: pluginID, instanceID: instance) == nil)

        let wrongID = envelope.replacingOccurrences(of: "\"id\":42", with: "\"id\":7")
        #expect(agentDecode(wrongID, requestID: 42, pluginID: pluginID, instanceID: instance) == nil)

        let wrongTypeEnvelope = """
        {"jsonrpc":"2.0","id":42,"result":{"schemaVersion":"1","pluginId":"\(pluginID)","instanceId":"\(instance.uuidString)","state":"ready","agentConnected":true,"businessReady":true,"taskRunning":false,"manual":true}}
        """
        #expect(agentDecode(wrongTypeEnvelope, requestID: 42, pluginID: pluginID, instanceID: instance) == nil)

        let unknownState = envelope.replacingOccurrences(of: "\"ready\"", with: "\"invented\"")
        #expect(agentDecode(unknownState, requestID: 42, pluginID: pluginID, instanceID: instance) == nil)

        let unknownError = statusJSON.replacingOccurrences(
            of: "\"consumerId\"",
            with: "\"errorCode\":\"raw_detail\",\"consumerId\""
        )
        let unknownErrorEnvelope = """
        {"jsonrpc":"2.0","id":42,"result":\(unknownError)}
        """
        #expect(agentDecode(unknownErrorEnvelope, requestID: 42, pluginID: pluginID, instanceID: instance) == nil)

        let invalidTimestamp = statusJSON.replacingOccurrences(
            of: "\"consumerId\"",
            with: "\"lastSuccessAt\":\"not-a-date\",\"consumerId\""
        )
        let invalidTimestampEnvelope = """
        {"jsonrpc":"2.0","id":42,"result":\(invalidTimestamp)}
        """
        #expect(agentDecode(
            invalidTimestampEnvelope,
            requestID: 42,
            pluginID: pluginID,
            instanceID: instance
        ) == nil)

        let uppercaseConsumer = statusJSON.replacingOccurrences(
            of: "\"consumerId\": \"[^\"]*\"",
            with: "\"consumerId\": \"\(UUID().uuidString)\"",
            options: .regularExpression
        )
        #expect(agentDecode(
            "{\"jsonrpc\":\"2.0\",\"id\":42,\"result\":\(uppercaseConsumer)}",
            requestID: 42,
            pluginID: pluginID,
            instanceID: instance
        ) == nil)
    }

    @Test("RPC errors are classified without treating every failure as bad JSON")
    func rpcErrorClassification() {
        let instance = UUID()
        let pluginID = "dev.agent.error"
        let busy = """
        {"jsonrpc":"2.0","id":7,"error":{"code":-32000,"message":"PROVIDER_BUSY","data":{"bridgeCode":"PROVIDER_BUSY","errorCode":"busy"}}}
        """
        #expect(
            HostServiceAgentRPCClient.decode(
                Data(busy.utf8),
                requestID: 7,
                expectedPluginID: pluginID,
                expectedInstanceID: instance
            ) == .failure(.busy)
        )
        let login = """
        {"jsonrpc":"2.0","id":7,"error":{"code":-32000,"message":"PROVIDER_LOGIN","data":{"bridgeCode":"PROVIDER_LOGIN","errorCode":"loginRequired"}}}
        """
        #expect(
            HostServiceAgentRPCClient.decode(
                Data(login.utf8),
                requestID: 7,
                expectedPluginID: pluginID,
                expectedInstanceID: instance
            ) == .failure(.server(.loginRequired))
        )
        let raw = """
        {"jsonrpc":"2.0","id":7,"error":{"code":"-32603","message":"raw detail"}}
        """
        #expect(
            HostServiceAgentRPCClient.decode(
                Data(raw.utf8),
                requestID: 7,
                expectedPluginID: pluginID,
                expectedInstanceID: instance
            ) == .failure(.invalidResponse)
        )
        let stringCode = busy.replacingOccurrences(of: "\"code\":-32000", with: "\"code\":\"-32000\"")
        #expect(HostServiceAgentRPCClient.decode(
            Data(stringCode.utf8), requestID: 7,
            expectedPluginID: pluginID, expectedInstanceID: instance
        ) == .failure(.invalidResponse))
    }

    @Test("Peer close fails safely for both control and startup-health sockets", arguments: [false, true])
    func peerCloseFailsWithoutSIGPIPE(healthSocket: Bool) async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketURL = root.appendingPathComponent("peer-close.sock")
        let server = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(server >= 0)
        guard server >= 0 else { return }
        defer {
            Darwin.close(server)
            try? FileManager.default.removeItem(at: socketURL)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8)
        #expect(pathBytes.count < MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            raw.copyBytes(from: pathBytes)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bound == 0)
        #expect(Darwin.listen(server, 1) == 0)
        #expect(Darwin.chmod(socketURL.path, 0o600) == 0)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int(0o700))],
            ofItemAtPath: root.path
        )

        let clientFD = try #require(
            (healthSocket ? HostServiceHealthClient.connectForTesting : HostServiceAgentSocketTestSupport.connect)(
                socketURL,
                .now() + .seconds(2)
            )
        )
        defer { Darwin.close(clientFD) }
        var noSignal: Int32 = 0
        var optionSize = socklen_t(MemoryLayout<Int32>.size)
        #expect(getsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, &optionSize) == 0)
        #expect(noSignal == 1)
        let accepted = Darwin.accept(server, nil, nil)
        #expect(accepted >= 0)
        guard accepted >= 0 else { return }
        Darwin.close(accepted)

        try await Task.sleep(for: .milliseconds(20))
        let payload = Data(repeating: 0x41, count: 4 * 1024 * 1024)
        let sent = HostServiceAgentSocketTestSupport.sendAll(
            fd: clientFD,
            data: payload,
            deadline: .now() + .seconds(1)
        )
        #expect(!sent, "A closed peer must return a fixed send failure, not SIGPIPE.")
        #expect(Darwin.getpid() == getpid())
    }

    @Test("Tampered Agent entry invalidates the owned runtime snapshot")
    @MainActor
    func tamperedAgentEntryInvalidatesRuntime() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.tamper")
        defer { plugin.retire() }
        let context = try #require(plugin.agentRuntimeContext())
        #expect(context.securityStateCheck.validateForTesting())
        try Data("tampered\n".utf8).write(
            to: plugin.agentMCPExecutableURL,
            options: .atomic
        )
        #expect(!context.securityStateCheck.validateForTesting())
        #expect(plugin.agentRuntimeContext() == nil || !context.securityStateCheck.validateForTesting())
    }

    @Test("Configuration export and grant fail closed after package tamper")
    @MainActor
    func tamperBlocksExportAndGrant() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.tamper-actions")
        defer { plugin.retire() }
        let runtime = try #require(plugin.agentRuntimeContext())
        let controller = HostServiceAgentWorkspaceController(
            plugin: plugin,
            rpcClient: AgentFailingRPCClient()
        )
        let consumer = UUID()
        controller.ingestStatusForTesting(
            agentStatus(
                pluginID: plugin.manifest.id,
                instanceID: runtime.instanceID,
                manual: true,
                consumerId: consumer,
                businessReady: true
            )
        )
        #expect(controller.primaryAction == .grant)
        let beforeTamper = try plugin.agentControlStore.loadOrCreate()

        try Data("tampered\n".utf8).write(
            to: plugin.agentMCPExecutableURL,
            options: .atomic
        )
        do {
            _ = try await controller.configurationData()
            Issue.record("configuration export must fail after tamper")
        } catch is HostServiceAgentFailure {
        } catch {
            Issue.record("unexpected export error: \(error)")
        }
        await controller.performPrimaryAction()
        let afterTamper = try plugin.agentControlStore.loadOrCreate()
        #expect(afterTamper == beforeTamper)
        #expect(afterTamper.manual)
    }

    @Test("Exported MCP configuration contains only stable plugin entry and endpoint")
    func configurationExportHasNoSecretsOrBuildPaths() throws {
        let pluginID = "dev.agent.example"
        let agentURL = URL(fileURLWithPath: "/Applications/Macdora.app/Contents/Resources/plugins/dev.agent.example/bin/agent-mcp")
        let endpointURL = URL(fileURLWithPath: "/Users/example/Library/Application Support/AndroidUse/private/plugin-state/dev.agent.example/endpoint.json")
        let data = try HostServiceAgentMCPConfiguration.data(
            pluginID: pluginID,
            agentExecutableURL: agentURL,
            endpointURL: endpointURL
        )
        let document = try JSONDecoder().decode(HostServiceAgentMCPConfiguration.Document.self, from: data)
        #expect(document.mcpServers[pluginID]?.command == agentURL.path)
        #expect(document.mcpServers[pluginID]?.args == ["--endpoint", endpointURL.path])

        let raw = String(decoding: data, as: UTF8.self)
        for forbidden in ["token", "secret", "cookie", "password", NSHomeDirectory(), "/.build/", "/tmp/"] {
            #expect(!raw.localizedCaseInsensitiveContains(forbidden))
        }
    }

    @Test("Late responses cannot replace another request or instance")
    @MainActor
    func lateResponseGate() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.late")
        defer { plugin.retire() }
        let instance = UUID()
        let status = agentStatus(pluginID: plugin.manifest.id, instanceID: instance)

        typealias Gate = HostServiceAgentWorkspaceController.ResponseGate
        #expect(!Gate(
            loaded: true,
            requestGeneration: 2,
            currentGeneration: 3,
            requestedInstanceID: instance,
            currentInstanceID: instance
        ).accepts(status, pluginID: plugin.manifest.id))
        #expect(!Gate(
            loaded: false,
            requestGeneration: 3,
            currentGeneration: 3,
            requestedInstanceID: instance,
            currentInstanceID: instance
        ).accepts(status, pluginID: plugin.manifest.id))
        #expect(!Gate(
            loaded: true,
            requestGeneration: 3,
            currentGeneration: 3,
            requestedInstanceID: instance,
            currentInstanceID: UUID()
        ).accepts(status, pluginID: plugin.manifest.id))
        #expect(!Gate(
            loaded: true,
            requestGeneration: 3,
            currentGeneration: 3,
            requestedInstanceID: instance,
            currentInstanceID: instance
        ).accepts(
            agentStatus(pluginID: "dev.agent.other", instanceID: instance),
            pluginID: plugin.manifest.id
        ))
        #expect(Gate(
            loaded: true,
            requestGeneration: 3,
            currentGeneration: 3,
            requestedInstanceID: instance,
            currentInstanceID: instance
        ).accepts(status, pluginID: plugin.manifest.id))

        let delayed = AgentDelayedRPCClient(
            response: .success(status),
            delay: .milliseconds(200)
        )
        let controller = HostServiceAgentWorkspaceController(
            plugin: plugin,
            rpcClient: delayed
        )
        controller.viewDidLoad()
        let deadline = ContinuousClock.now + .seconds(10)
        while await delayed.callCountSnapshot() == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await delayed.callCountSnapshot() == 1)
        controller.viewDidUnload()
        try await Task.sleep(for: .milliseconds(350))
        #expect(controller.display == .loading)
        #expect(!controller.isRefreshing)
    }

    @Test("Agent-only registration receives controlled environment while plain host service does not")
    @MainActor
    func controlledEnvironmentIsAgentOnly() throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = try makeRunningAgentPlugin(root: root, id: "dev.agent.env")
        defer { agent.retire() }
        let plain = HostServiceSystemPlugin(
            manifest: agentFixtureManifest(
                id: "dev.agent.plain",
                capabilities: ["host.service"],
                agentMCP: nil
            ),
            bundleDirectoryURL: root.appendingPathComponent("plain", isDirectory: true),
            rootURL: root
        )
        defer { plain.retire() }

        #expect(agent.agentControlPath == agent.agentControlStore.fileURL)
        #expect(plain.agentControlPath == nil)
        let bridge = AgentEnvironmentTestBridge()
        let agentEnvironment = agent.agentServiceEnvironmentForTesting(bridge: bridge)
        let plainEnvironment = plain.agentServiceEnvironmentForTesting(bridge: bridge)
        #expect(agentEnvironment["MACDORA_AGENT_CONTROL_PATH"] == agent.agentControlStore.fileURL.path)
        #expect(plainEnvironment["MACDORA_AGENT_CONTROL_PATH"] == nil)
        #expect(!agentEnvironment.keys.contains("HOME"))
        #expect(!agentEnvironment.keys.contains("PATH"))
    }

    @Test("Every activation gets its own bounded startup budget, including late enable", arguments: [0, 1000])
    @MainActor
    func agentStartupBudgetIsOptIn(startSeconds: Int) async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeAgentRuntimeFixture(
            root: root, id: "dev.agent.slow-start", publishEndpointOnLaunch: true
        )
        defer { fixture.launcher.stopAll() }
        let timing = AgentControlledStartupTiming()
        timing.advanceAutomatically(by: .seconds(startSeconds))
        let plugin = HostServiceSystemPlugin(
            manifest: fixture.manifest,
            bundleDirectoryURL: fixture.bundleURL,
            rootURL: root,
            processExecuter: fixture.launcher,
            processTerminator: AgentStartupTerminator(),
            healthClient: { _, _, _ in
                timing.noteHealthProbe()
                if timing.elapsed >= .seconds(startSeconds + 6) {
                    return .success(())
                }
                return .failure(.protocolFailure)
            },
            startupTiming: timing.timing
        )
        let bridge = AgentEnvironmentTestBridge()
        bridge.currentRuntimeState = .ready
        await plugin.activate(bridge: bridge)
        #expect(plugin.healthState == .healthy)
        #expect(timing.elapsed > .seconds(startSeconds + 5))
        #expect(timing.elapsed <= .seconds(startSeconds + 35))
        #expect(timing.healthProbeCount >= 2)
        #expect(fixture.manifest.capabilities.contains("agent.readonly"))
        #expect(plugin.startupHealthBudgetForTesting() == 35)

        let plain = HostServiceSystemPlugin(
            manifest: agentFixtureManifest(
                id: "dev.agent.plain-budget",
                capabilities: ["host.service"],
                agentMCP: nil
            ),
            bundleDirectoryURL: root.appendingPathComponent("plain-budget", isDirectory: true),
            rootURL: root
        )
        #expect(plain.startupHealthBudgetForTesting() == 5)
    }

    @Test("Agent startup wait is canceled immediately by disable and cannot resurrect")
    @MainActor
    func agentStartupWaitCancelsWithoutResurrection() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeAgentRuntimeFixture(root: root, id: "dev.agent.slow-cancel")
        defer { fixture.launcher.stopAll() }
        let timing = AgentControlledStartupTiming()
        let healthGate = AgentStartupHealthGate()
        let plugin = HostServiceSystemPlugin(
            manifest: fixture.manifest,
            bundleDirectoryURL: fixture.bundleURL,
            rootURL: root,
            processExecuter: fixture.launcher,
            processTerminator: AgentStartupTerminator(),
            healthClient: { _, _, _ in
                await healthGate.wait()
            },
            startupTiming: timing.timing
        )
        let bridge = AgentEnvironmentTestBridge()
        bridge.currentRuntimeState = .ready
        let activation = Task { @MainActor in
            await plugin.activate(bridge: bridge)
        }
        try await fixture.launcher.waitForInvocationCount(1)
        let invocation = try #require(fixture.launcher.invocationSnapshot().first)
        try writeAgentEndpoint(invocation: invocation, manifest: fixture.manifest)
        await healthGate.waitUntilEntered()

        let stopStarted = ContinuousClock.now
        let deactivated = await plugin.deactivate(bridge: bridge)
        let stopDuration = stopStarted.duration(to: .now)
        #expect(deactivated)
        #expect(stopDuration < .seconds(2))
        #expect(!plugin.isEnabled)
        #expect(fixture.launcher.runningHandleCount() == 0)

        await healthGate.release(.success(()))
        await activation.value
        #expect(plugin.healthState != .healthy)
        #expect(!plugin.isEnabled)
        #expect(fixture.launcher.runningHandleCount() == 0)
        #expect(fixture.launcher.invocationSnapshot().count == 1)
    }

    @Test("Grant and revoke requests survive view unload without becoming page-bound")
    @MainActor
    func actionsSurviveViewUnload() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.unload-actions")
        defer { plugin.retire() }
        let instanceID = try #require(plugin.agentRuntimeContext()?.instanceID)
        let consumer = UUID()
        let rpc = AgentControlledRPCClient(gatedMethods: [.grant, .revoke])
        let controller = HostServiceAgentWorkspaceController(plugin: plugin, rpcClient: rpc)
        controller.setViewLoadedForTesting(true)
        controller.ingestStatusForTesting(
            agentStatus(
                pluginID: plugin.manifest.id,
                instanceID: instanceID,
                manual: true,
                consumerId: consumer
            )
        )

        let granted = Task { @MainActor in
            await controller.performPrimaryAction()
        }
        await rpc.waitForCallCount(1)
        controller.viewDidUnload()
        #expect(controller.isSubmitting)
        #expect(controller.isPreparing == false)
        await rpc.resolve(
            .grant,
            with: .success(
                agentStatus(
                    pluginID: plugin.manifest.id,
                    instanceID: instanceID,
                    manual: false,
                    consumerId: consumer
                )
            )
        )
        await granted.value
        let storedAfterGrant = try plugin.agentControlStore.reload()
        #expect(!storedAfterGrant.manual)
        #expect(!controller.isSubmitting)

        let revoked = Task { @MainActor in
            await controller.performPrimaryAction()
        }
        await rpc.waitForCallCount(2)
        await rpc.resolve(
            .revoke,
            with: .success(
                agentStatus(
                    pluginID: plugin.manifest.id,
                    instanceID: instanceID,
                    manual: true,
                    consumerId: consumer
                )
            )
        )
        await revoked.value
        #expect(try plugin.agentControlStore.reload().manual)
        #expect(!controller.isSubmitting)
    }

    @Test("Late old-generation grant cannot overwrite a newer revoke")
    @MainActor
    func lateGrantCannotUndoNewerRevoke() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.late-generation")
        defer { plugin.retire() }
        let instanceID = try #require(plugin.agentRuntimeContext()?.instanceID)
        let consumer = UUID()
        let rpc = AgentControlledRPCClient(gatedMethods: [.grant, .revoke])
        let controller = HostServiceAgentWorkspaceController(plugin: plugin, rpcClient: rpc)
        controller.setViewLoadedForTesting(true)
        controller.ingestStatusForTesting(
            agentStatus(
                pluginID: plugin.manifest.id,
                instanceID: instanceID,
                manual: true,
                consumerId: consumer
            )
        )

        let pendingAction = Task { @MainActor in
            await controller.performPrimaryAction()
        }
        await rpc.waitForCallCount(1)
        let pendingGrant = try plugin.agentControlStore.reload()
        #expect(!pendingGrant.manual)
        let newerRevoke = try plugin.agentControlStore.setManual(true)
        #expect(newerRevoke.manual)
        #expect(newerRevoke.generation != pendingGrant.generation)

        await rpc.resolve(
            .grant,
            with: .success(
                agentStatus(
                    pluginID: plugin.manifest.id,
                    instanceID: instanceID,
                    manual: false,
                    consumerId: consumer
                )
            )
        )
        await pendingAction.value
        #expect(try plugin.agentControlStore.reload() == newerRevoke)
        #expect(controller.isSubmitting == false)
    }

    @Test("Managed status remains revocable while loading, failed or preparing")
    @MainActor
    func managedStateAlwaysOffersManualWithdrawal() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.withdrawal")
        defer { plugin.retire() }
        let instanceID = try #require(plugin.agentRuntimeContext()?.instanceID)
        let rpc = AgentControlledRPCClient(gatedMethods: [])
        let controller = HostServiceAgentWorkspaceController(plugin: plugin, rpcClient: rpc)
        controller.setViewLoadedForTesting(true)
        controller.ingestStatusForTesting(
            agentStatus(
                pluginID: plugin.manifest.id,
                instanceID: instanceID,
                manual: false,
                consumerId: UUID()
            )
        )
        controller.setRefreshingForTesting(true)
        #expect(controller.primaryAction == .revoke)
        controller.setRefreshingForTesting(false)
        controller.setPreparingForTesting(true)
        #expect(controller.primaryAction == .revoke)
        controller.setPreparingForTesting(false)

        controller.ingestFailureForTesting(
            "连接检查失败",
            instanceID: instanceID,
            persistedManual: false
        )
        #expect(controller.primaryAction == .revoke)
        #expect(controller.statusText == "托管状态待确认")
        #expect(controller.detailText.contains("点「我来操作」可立即保存手动状态"))
        #expect(!controller.detailText.contains("手动意图已保存"))
        #expect(controller.primaryActionTitle == "我来操作")
        #expect(!controller.canTestConnection)

        let beforeRevoke = try plugin.agentControlStore.reload()
        await controller.performPrimaryAction()
        let afterRevoke = try plugin.agentControlStore.reload()
        #expect(afterRevoke.manual)
        #expect(afterRevoke.generation != beforeRevoke.generation)
        #expect(!controller.isSubmitting)
    }

    @Test("Service pause cannot remove the persisted owner's manual withdrawal")
    @MainActor
    func pausedServiceKeepsManualWithdrawal() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.paused-intent")
        defer { plugin.retire() }
        let intent = try plugin.agentControlStore.setManual(false)
        let instance = try #require(plugin.agentRuntimeContext()?.instanceID)
        let rpc = AgentControlledRPCClient(gatedMethods: [.status])
        let controller = HostServiceAgentWorkspaceController(plugin: plugin, rpcClient: rpc)
        controller.setViewLoadedForTesting(true)
        let refresh = Task { @MainActor in await controller.refresh() }
        await rpc.waitForCallCount(1)
        await rpc.resolve(.status, with: .success(agentStatus(
            pluginID: plugin.manifest.id, instanceID: instance,
            manual: true, consumerId: UUID(), state: .waitingForApproval
        )))
        await refresh.value
        #expect(try plugin.agentControlStore.reload() == intent)
        #expect(controller.primaryAction == .revoke)
        #expect(!controller.showsAgentManaged)
        #expect(controller.handoffPillText == "待确认")
        #expect(controller.detailText.contains("先点「我来操作」"))
        #expect(!controller.detailText.contains("已托管"))
    }

    @Test("A real refresh arriving after manual withdrawal cannot restore managed UI")
    @MainActor
    func lateRefreshCannotUndoManualWithdrawal() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.refresh-revoke")
        defer { plugin.retire() }
        _ = try plugin.agentControlStore.setManual(false)
        let instance = try #require(plugin.agentRuntimeContext()?.instanceID)
        let rpc = AgentControlledRPCClient(gatedMethods: [.status])
        let controller = HostServiceAgentWorkspaceController(plugin: plugin, rpcClient: rpc)
        controller.setViewLoadedForTesting(true)
        let refresh = Task { @MainActor in await controller.refresh() }
        await rpc.waitForCallCount(1)
        await controller.performPrimaryAction()
        let manual = try plugin.agentControlStore.reload()
        #expect(manual.manual)
        await rpc.resolve(.status, with: .success(agentStatus(
            pluginID: plugin.manifest.id, instanceID: instance,
            manual: false, consumerId: UUID()
        )))
        await refresh.value
        #expect(try plugin.agentControlStore.reload() == manual)
        #expect(!controller.isSubmitting)
        #expect(!controller.showsAgentManaged)
        #expect(controller.status == nil)
        #expect(await rpc.callsSnapshot().map(\.method) == [.status, .revoke])
    }

    @Test("Revoke from managed UI settles and discards a retired instance", arguments: [false, true])
    @MainActor
    func retiredRevokeAlwaysSettlesAction(lateSuccess: Bool) async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.retired-revoke")
        _ = try plugin.agentControlStore.setManual(false)
        let instance = try #require(plugin.agentRuntimeContext()?.instanceID)
        let rpc = AgentControlledRPCClient(gatedMethods: [.revoke])
        let controller = HostServiceAgentWorkspaceController(plugin: plugin, rpcClient: rpc)
        controller.ingestStatusForTesting(agentStatus(
            pluginID: plugin.manifest.id, instanceID: instance,
            manual: false, consumerId: UUID()
        ))
        #expect(controller.showsAgentManaged)
        let revoke = Task { @MainActor in await controller.performPrimaryAction() }
        await rpc.waitForCallCount(1)
        plugin.retire()
        await rpc.resolve(.revoke, with: lateSuccess ? .success(agentStatus(
            pluginID: plugin.manifest.id, instanceID: instance, manual: true
        )) : .failure(.unavailable))
        await revoke.value
        #expect(try plugin.agentControlStore.reload().manual)
        #expect(!controller.isSubmitting)
        #expect(controller.activePrimaryAction == nil)
        #expect(controller.status == nil)
        #expect(!controller.showsAgentManaged)
        #expect(controller.detailText.contains("已切回手动"))
        #expect(await rpc.callsSnapshot().count == 1)
    }

    @Test("Manual withdrawal wins over an in-flight grant and its late success")
    @MainActor
    func manualWithdrawalSupersedesPendingGrant() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.pending-grant")
        defer { plugin.retire() }
        let instance = try #require(plugin.agentRuntimeContext()?.instanceID)
        let consumer = UUID()
        let rpc = AgentControlledRPCClient(gatedMethods: [.grant, .revoke])
        let controller = HostServiceAgentWorkspaceController(plugin: plugin, rpcClient: rpc)
        controller.ingestStatusForTesting(agentStatus(
            pluginID: plugin.manifest.id, instanceID: instance,
            manual: true, consumerId: consumer
        ))
        var reservedBeforeAuthorization = false
        controller.onDisplayChanged = { _ in
            if controller.isSubmitting,
               (try? plugin.agentControlStore.reload().manual) == true,
               controller.activePrimaryAction == .grant {
                reservedBeforeAuthorization = true
                #expect(controller.primaryAction == nil)
            }
        }
        let grant = Task { @MainActor in await controller.performPrimaryAction() }
        await rpc.waitForCallCount(1)
        #expect(reservedBeforeAuthorization)
        #expect(controller.primaryAction == .revoke)
        let revoke = Task { @MainActor in await controller.performPrimaryAction() }
        await rpc.waitForCallCount(2)
        let manual = try plugin.agentControlStore.reload()
        await rpc.resolve(.revoke, with: .success(agentStatus(
            pluginID: plugin.manifest.id, instanceID: instance,
            manual: true, consumerId: consumer
        )))
        await revoke.value
        await rpc.resolve(.grant, with: .success(agentStatus(
            pluginID: plugin.manifest.id, instanceID: instance,
            manual: false, consumerId: consumer
        )))
        await grant.value
        #expect(try plugin.agentControlStore.reload() == manual)
        #expect(manual.manual)
        #expect(!controller.isSubmitting)
        #expect(!controller.showsAgentManaged)
        #expect(await rpc.callsSnapshot().map(\.method) == [.grant, .revoke])
        controller.onDisplayChanged = nil
    }

    @Test("Status copy reflects login, recovery, attention and running states")
    @MainActor
    func statusCopyUsesServerStateBeforeManual() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.status-copy")
        defer { plugin.retire() }
        let instanceID = try #require(plugin.agentRuntimeContext()?.instanceID)
        let controller = HostServiceAgentWorkspaceController(
            plugin: plugin,
            rpcClient: AgentFailingRPCClient()
        )

        controller.ingestStatusForTesting(
            agentStatus(
                pluginID: plugin.manifest.id,
                instanceID: instanceID,
                manual: true,
                state: .waitingForLogin,
                errorCode: .loginRequired
            )
        )
        #expect(controller.statusText == "需要先登录")
        #expect(controller.statusText != "由你操作")
        #expect(controller.detailText.contains("完成登录"))

        controller.ingestStatusForTesting(
            agentStatus(
                pluginID: plugin.manifest.id,
                instanceID: instanceID,
                manual: true,
                state: .recovering,
                errorCode: .recoveryRequired
            )
        )
        #expect(controller.statusText == "正在恢复连接")
        #expect(controller.statusText != "由你操作")

        controller.ingestStatusForTesting(
            agentStatus(
                pluginID: plugin.manifest.id,
                instanceID: instanceID,
                manual: true,
                state: .needsAttention
            )
        )
        #expect(controller.statusText == "需要处理连接")
        #expect(controller.detailText.contains("我来操作"))

        let running = agentStatus(
            pluginID: plugin.manifest.id,
            instanceID: instanceID,
            manual: false,
            consumerId: UUID(),
            businessReady: true,
            state: .running
        )
        controller.ingestStatusForTesting(running)
        #expect(controller.statusText == "Agent 正在处理")
        #expect(controller.detailText.contains("立即接回"))
        #expect(!controller.detailText.contains("完成后可切手动"))
        #expect(controller.primaryAction == .revoke)
        #expect(!controller.canTestConnection)
    }

    @Test("Managed and failed states use factual manual withdrawal copy")
    @MainActor
    func managedCopyDoesNotClaimManualWasAlreadySaved() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = try makeRunningAgentPlugin(root: root, id: "dev.agent.copy")
        defer { plugin.retire() }
        let instanceID = try #require(plugin.agentRuntimeContext()?.instanceID)
        let controller = HostServiceAgentWorkspaceController(
            plugin: plugin,
            rpcClient: AgentFailingRPCClient()
        )
        controller.ingestStatusForTesting(
            agentStatus(
                pluginID: plugin.manifest.id,
                instanceID: instanceID,
                manual: false,
                consumerId: UUID(),
                businessReady: true,
                state: .ready
            )
        )
        #expect(controller.statusText == "Agent 已托管")
        #expect(!controller.statusText.contains("可以交给"))
        #expect(controller.detailText.contains("随时接回"))

        controller.ingestFailureForTesting(
            "连接检查失败",
            instanceID: instanceID,
            persistedManual: false
        )
        #expect(controller.statusText == "托管状态待确认")
        #expect(controller.detailText.contains("点「我来操作」可立即保存手动状态"))
        #expect(!controller.detailText.contains("已保存"))
        #expect(controller.primaryAction == .revoke)
        #expect(!controller.canTestConnection)
    }

    @Test("Agent workspace is only reachable for an opt-in Agent package")
    @MainActor
    func agentWorkspaceRegistrationIsOptIn() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try #require(UserDefaults(suiteName: "AgentHostServiceTests.\(UUID().uuidString)"))

        let agentSource = root.appendingPathComponent("agent-source", isDirectory: true)
        try installAgentFixturePackage(
            at: agentSource,
            id: "dev.agent.workspace",
            capabilities: ["host.service", "agent.readonly"],
            agentMCP: "bin/agent"
        )
        let plainSource = root.appendingPathComponent("plain-source", isDirectory: true)
        try installAgentFixturePackage(
            at: plainSource,
            id: "dev.agent.workspace.plain",
            capabilities: ["host.service"],
            agentMCP: nil
        )
        let manager = SystemPluginManager(
            rootURL: root,
            defaults: defaults,
            hostServiceHealthClient: { _, _, _ in .success(()) }
        )
        _ = try await manager.importDeveloperPlugin(from: agentSource)
        _ = try await manager.importDeveloperPlugin(from: plainSource)
        let window = ManagementWindow()
        window.bindPluginManager(manager)
        window.selectSection(.plugins)
        window.refreshPluginsSection()
        let content = try #require(window.window?.contentView)

        let agentItem = try #require(
            manager.catalogItems().first { $0.id == "dev.agent.workspace" }
        )
        let plainItem = try #require(
            manager.catalogItems().first { $0.id == "dev.agent.workspace.plain" }
        )
        #expect(agentItem.hasDedicatedWorkspace)
        #expect(!plainItem.hasDedicatedWorkspace)
        #expect(manager.hostServicePlugin(for: agentItem.id)?.agentControlPath != nil)
        #expect(manager.hostServicePlugin(for: plainItem.id)?.agentControlPath == nil)
        #expect(!descendants(of: content).contains { $0 is HostServiceAgentWorkspaceView })
        await manager.setPluginEnabled(id: agentItem.id, enabled: true)
        window.openPluginDetailPage(id: agentItem.id)
        let workspace = try #require(
            descendants(of: content).compactMap { $0 as? HostServiceAgentWorkspaceView }.first
        )
        let buttons = descendants(of: workspace).compactMap { $0 as? TFButton }
        #expect(buttons.contains { $0.identifier?.rawValue == "agent-primary-action" })
        #expect(buttons.contains { $0.identifier?.rawValue == "agent-test-connection" })
        #expect(buttons.contains { $0.identifier?.rawValue == "agent-copy-configuration" })
        #expect(!labels(in: workspace).contains { $0.contains("/tmp/") })
        await manager.setPluginEnabled(id: agentItem.id, enabled: false)
        window.refreshPluginsSection()
        #expect(!descendants(of: content).contains { $0 is HostServiceAgentWorkspaceView })
        await manager.setPluginEnabled(id: agentItem.id, enabled: true)
        window.openPluginDetailPage(id: agentItem.id)
        let replacement = try #require(
            descendants(of: content).compactMap { $0 as? HostServiceAgentWorkspaceView }.first
        )
        #expect(replacement !== workspace)
    }

    @Test("Keep-awake control belongs only to an explicitly opted-in plugin workspace")
    @MainActor
    func keepAwakeControlIsPluginScoped() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try #require(UserDefaults(suiteName: "AgentKeepAwake.\(UUID().uuidString)"))
        let manager = SystemPluginManager(rootURL: root, defaults: defaults, hostServiceHealthClient: { _, _, _ in .success(()) })
        let opted = try makeAgentPackage(root: root, id: "dev.agent.awake", capabilities: ["host.service", "agent.readonly", "guest.shell", "runtime.keep-awake"], agentPath: "bin/agent", createExecutable: true)
        let ordinary = try makeAgentPackage(root: root, id: "dev.agent.ordinary", agentPath: "bin/agent", createExecutable: true)
        _ = try await manager.importDeveloperPlugin(from: opted)
        _ = try await manager.importDeveloperPlugin(from: ordinary)
        await manager.setPluginEnabled(id: "dev.agent.awake", enabled: true)
        await manager.setPluginEnabled(id: "dev.agent.ordinary", enabled: true)
        let window = ManagementWindow()
        defer { window.window?.orderOut(nil) }
        window.bindPluginManager(manager)
        window.updatePreferences(cameraEnabled: false, canChangeCamera: false, rootPath: root.path, preferences: .default, readiness: [], officeKeepAwake: .init(enabled: true, phase: .active))
        let content = try #require(window.window?.contentView)
        window.selectSection(.settings)
        #expect(!descendants(of: content).contains { $0 is PluginKeepAwakeView })
        window.openPluginDetailPage(id: "dev.agent.ordinary")
        #expect(!descendants(of: content).contains { $0 is PluginKeepAwakeView })
        window.openPluginDetailPage(id: "dev.agent.awake")
        let toggle = try #require(descendants(of: content).first { $0.identifier?.rawValue == "plugin-keep-awake-toggle" } as? TFToggleSwitch)
        #expect(toggle.isOn)
        var requested: (String, Bool)?
        window.onTogglePluginKeepAwake = { requested = ($0, $1) }
        #expect(toggle.accessibilityPerformPress())
        #expect(requested?.0 == "dev.agent.awake")
        #expect(requested?.1 == false)
        window.update(.starting)
        #expect(!toggle.isEnabled)
        #expect(!toggle.accessibilityPerformPress())
        window.update(.ready)
        window.updatePreferences(cameraEnabled: false, canChangeCamera: false, rootPath: root.path, preferences: .default, readiness: [], officeKeepAwake: .init(enabled: false, phase: .failed))
        let retry = try #require(descendants(of: content).first { $0.identifier?.rawValue == "plugin-keep-awake-retry" } as? TFButton)
        requested = nil
        #expect(retry.accessibilityPerformPress())
        #expect(requested?.1 == false)
        await manager.setPluginEnabled(id: "dev.agent.awake", enabled: false)
        window.refreshPluginsSection()
        requested = nil
        _ = toggle.accessibilityPerformPress()
        #expect(requested == nil, "停用后遗留的控件不能修改运行策略。")
        #expect(!descendants(of: content).contains { $0 is PluginKeepAwakeView })
        window.updatePreferences(cameraEnabled: false, canChangeCamera: false, rootPath: root.path, preferences: .default, readiness: [], officeKeepAwake: .init(enabled: true, phase: .active))
        let orphanedRestore = try #require(descendants(of: content).first { $0.identifier?.rawValue == "plugin-orphaned-keep-awake-restore" } as? TFButton)
        var restored = false
        window.onRestoreOrphanedKeepAwake = { restored = true }
        #expect(orphanedRestore.accessibilityPerformPress())
        #expect(restored)
        try await manager.deletePlugin(id: "dev.agent.awake")
        window.refreshPluginsSection()
        #expect(descendants(of: content).contains { $0.identifier?.rawValue == "plugin-orphaned-keep-awake-restore" })
        window.updatePreferences(cameraEnabled: false, canChangeCamera: false, rootPath: root.path, preferences: .default, readiness: [], officeKeepAwake: .off)
        #expect(!descendants(of: content).contains { $0.identifier?.rawValue == "plugin-orphaned-keep-awake-restore" })
        window.selectSection(.settings)
        #expect(!descendants(of: content).contains { $0.identifier?.rawValue.contains("keep-awake") == true })
    }

    @Test("Hot reload replaces a same-ID package and the old Agent view identity")
    @MainActor
    func hotReloadKeepsPackageIdentity() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try #require(UserDefaults(suiteName: "AgentHostServiceTests.\(UUID().uuidString)"))
        let source = root.appendingPathComponent("identity-v1", isDirectory: true)
        try installAgentFixturePackage(
            at: source,
            id: "dev.agent.identity",
            capabilities: ["host.service", "agent.readonly"],
            agentMCP: "bin/agent"
        )
        let manager = SystemPluginManager(
            rootURL: root,
            defaults: defaults,
            hostServiceHealthClient: { _, _, _ in .success(()) }
        )
        _ = try await manager.importDeveloperPlugin(from: source)
        await manager.setPluginEnabled(id: "dev.agent.identity", enabled: true)
        let firstPlugin = try #require(manager.hostServicePlugin(for: "dev.agent.identity"))
        let firstIdentity = try #require(manager.pluginPackageIdentity(for: "dev.agent.identity"))
        #expect(firstIdentity.manifest.version == "1.0.0")

        let window = ManagementWindow()
        window.bindPluginManager(manager)
        window.openPluginDetailPage(id: "dev.agent.identity")
        let content = try #require(window.window?.contentView)
        let firstView = try #require(
            descendants(of: content).compactMap { $0 as? HostServiceAgentWorkspaceView }.first
        )
        #expect(firstView.pluginIdentity == ObjectIdentifier(firstPlugin))

        let updatedSource = root.appendingPathComponent("identity-v2", isDirectory: true)
        try installAgentFixturePackage(
            at: updatedSource,
            id: "dev.agent.identity",
            capabilities: ["host.service", "agent.readonly"],
            agentMCP: "bin/agent",
            version: "2.0.0"
        )
        _ = try await manager.importDeveloperPlugin(from: updatedSource)
        await manager.setPluginEnabled(id: "dev.agent.identity", enabled: true)
        let secondPlugin = try #require(manager.hostServicePlugin(for: "dev.agent.identity"))
        let secondIdentity = try #require(manager.pluginPackageIdentity(for: "dev.agent.identity"))
        #expect(secondIdentity.manifest.version == "2.0.0")
        #expect(ObjectIdentifier(secondPlugin) != ObjectIdentifier(firstPlugin))
        window.refreshPluginsSection()
        let secondView = try #require(
            descendants(of: content).compactMap { $0 as? HostServiceAgentWorkspaceView }.first
        )
        #expect(secondView.pluginIdentity == ObjectIdentifier(secondPlugin))
        #expect(secondView.pluginIdentity != firstView.pluginIdentity)
    }

    @Test("Workspace recovers automatically when startup runtime becomes ready and deduplicates copy confirmations")
    @MainActor
    func startupContextRecoveryAndCopyConfirmationDeduplication() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("startup-recovery", isDirectory: true)
        try installAgentFixturePackage(
            at: bundle,
            id: "dev.agent.startup-recovery",
            capabilities: ["host.service", "agent.readonly"],
            agentMCP: "bin/agent"
        )
        let manifest = try SystemPluginPackageFactory.verifyPluginDirectory(
            bundle,
            trustPolicy: .developerLocalImport
        )
        let launcher = AgentTestProcessLauncher()
        let plugin = HostServiceSystemPlugin(
            manifest: manifest,
            bundleDirectoryURL: bundle,
            rootURL: root,
            processExecuter: launcher,
            processTerminator: AgentTestTerminator(),
            supervisor: HostServiceSupervisorRegistry(),
            healthClient: { _, _, _ in .success(()) }
        )
        defer { plugin.retire() }
        plugin.setNotificationBridge(nil)
        #expect(plugin.agentRuntimeContext() == nil)

        let rpc = AgentControlledRPCClient(gatedMethods: [.status])
        let controller = HostServiceAgentWorkspaceController(plugin: plugin, rpcClient: rpc)
        controller.setViewLoadedForTesting(true)
        await controller.refresh()
        #expect(controller.display == .failed(HostServiceAgentFailure.unavailable.userMessage))
        #expect(await rpc.callsSnapshot().isEmpty)

        plugin.installAgentTestRuntime(handle: launcher.currentHandle)
        let instanceID = try #require(plugin.agentRuntimeContext()?.instanceID)
        controller.hostStateDidChange()
        await rpc.waitForCallCount(1)
        let expected = agentStatus(
            pluginID: plugin.manifest.id,
            instanceID: instanceID,
            manual: true
        )
        await rpc.resolve(.status, with: .success(expected))
        let deadline = ContinuousClock.now + .seconds(2)
        while controller.status != expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(controller.display == .available(expected))
        #expect(controller.status == expected)

        let view = HostServiceAgentWorkspaceView(testingWith: plugin, status: expected)
        view.showCopyConfirmationForTesting()
        view.showCopyConfirmationForTesting()
        view.showCopyConfirmationForTesting()
        let confirmations = descendants(of: view).filter {
            $0.identifier?.rawValue == "agent-copy-confirmation"
        }
        #expect(confirmations.count == 1)

        plugin.retire()
        controller.hostStateDidChange()
        #expect(controller.status == nil)
        #expect(controller.display == .failed("运行实例已改变，请重新检查连接。"))
    }

    @Test("Enabling location plugin after Agent plugin keeps each plugin title and status isolated")
    @MainActor
    func enablingLocationAfterAgentKeepsCatalogAndDetailLabelsIsolated() async throws {
        let root = try agentTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "AgentHostServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let (_, locationHarness) = try SignedArchiveTestHarness.buildSignedLocationPackage(in: root)
        let fetcher = DefaultSystemPluginPackageFetcher(
            httpTransport: MockGitHubHTTPTransport(
                registryData: locationHarness.registryData,
                archiveData: locationHarness.archiveData
            ),
            trustedPublicKeys: [locationHarness.keyID: locationHarness.publicKeyBase64]
        )
        let agentSource = root.appendingPathComponent("agent-office-source", isDirectory: true)
        try installAgentFixturePackage(
            at: agentSource,
            id: "dev.agent.office",
            capabilities: ["host.service", "agent.readonly"],
            agentMCP: "bin/agent"
        )

        let manager = SystemPluginManager(
            rootURL: root,
            defaults: defaults,
            packageFetcher: fetcher,
            additionalTrustedPublicKeys: [locationHarness.keyID: locationHarness.publicKeyBase64],
            locationConsoleTransport: MockLocationConsoleTransport(),
            hostServiceHealthClient: { _, _, _ in .success(()) }
        )
        let locationID = SystemPluginCatalogItem.developerLocationID
        _ = try await manager.downloadAndInstallPlugin(id: locationID)
        _ = try await manager.importDeveloperPlugin(from: agentSource)

        let window = ManagementWindow()
        window.bindPluginManager(manager)
        window.selectSection(.plugins)
        let content = try #require(window.window?.contentView)

        await manager.setPluginEnabled(id: "dev.agent.office", enabled: true)
        await manager.setPluginEnabled(id: locationID, enabled: true)

        let locationPlugin = try #require(manager.locationPlugin(for: locationID))
        locationPlugin.selectLocation(
            GeoCoordinate(latitude: 31.230416, longitude: 121.473701, name: "定位测试点", subtitle: "测试")
        )
        _ = await locationPlugin.injectSingleTick()

        func textField(_ id: String) -> NSTextField? {
            descendants(of: content)
                .compactMap { $0 as? NSTextField }
                .first { $0.identifier?.rawValue == id }
        }

        let locationTitle = try #require(textField("plugin-title-\(locationID)"))
        let locationStatus = try #require(textField("plugin-status-\(locationID)"))
        let agentTitle = try #require(textField("plugin-title-dev.agent.office"))
        let agentStatus = try #require(textField("plugin-status-dev.agent.office"))

        #expect(locationTitle.stringValue == "开发者虚拟定位")
        #expect(locationStatus.stringValue.contains("定位测试点"))
        #expect(agentTitle.stringValue == "Agent Fixture")
        #expect(agentStatus.stringValue == manager.pluginStatusText(for: "dev.agent.office"))
        #expect(!agentStatus.stringValue.contains("当前位置"))
        #expect(!agentStatus.stringValue.contains("定位测试点"))

        window.openPluginDetailPage(id: "dev.agent.office")
        _ = await locationPlugin.injectSingleTick()
        let detailTitle = try #require(textField("plugin-detail-title-dev.agent.office"))
        let detailStatus = try #require(textField("plugin-detail-status-dev.agent.office"))
        #expect(detailTitle.stringValue == "Agent Fixture")
        #expect(detailStatus.stringValue == manager.pluginStatusText(for: "dev.agent.office"))
        #expect(!detailStatus.stringValue.contains("当前位置"))
    }
}

private struct AgentRPCCall: Equatable, Sendable {
    let method: HostServiceAgentControlMethod
    let instanceID: UUID
    let generation: UUID?
    let consumerId: UUID?
}

private struct AgentProcessOutput {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

private func runCrossLanguagePython(
    _ script: String,
    input: Data
) throws -> AgentProcessOutput {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-wire-\(UUID().uuidString).py")
    try Data(script.utf8).write(to: temporary, options: .atomic)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [temporary.path]
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    try process.run()
    stdinPipe.fileHandleForWriting.write(input)
    try stdinPipe.fileHandleForWriting.close()
    process.waitUntilExit()
    return AgentProcessOutput(
        status: process.terminationStatus,
        stdout: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
        stderr: stderrPipe.fileHandleForReading.readDataToEndOfFile()
    )
}

@MainActor
private final class AgentEnvironmentTestBridge: SystemPluginHostBridge {
    var currentRuntimeState: RuntimeState = .ready
    var currentActivePackage: String?
    var emulatorConsolePort: UInt16 = 5554
    var emulatorAuthTokenURLs: [URL] = []
    var hostServiceEnvironment: [String: String] = [
        "MACDORA_ADB_PATH": "/neutral/adb",
        "MACDORA_ADB_SERIAL": "neutral-serial",
        "ANDROID_ADB_SERVER_PORT": "5037",
        "ADB_SERVER_SOCKET": "tcp:127.0.0.1:5037",
        "UNRELATED_VALUE": "not-copied"
    ]

    func executeGuestShell(
        _ script: String,
        operation: String,
        timeout: TimeInterval
    ) async -> Bool {
        true
    }

    func sendEmulatorGeoFix(
        longitude: Double,
        latitude: Double,
        altitude: Double,
        satellites: Int,
        velocityKnots: Double
    ) async -> Bool {
        true
    }

    func notifyPluginBanner(_ message: String) {}
    func notifyPluginStateDidChange() {}
}

private actor AgentRecoveryRPCClient: HostServiceAgentRPCPerforming {
    private var calls: [HostServiceAgentControlRecord] = []
    private let firstFailure: HostServiceAgentFailure

    init(firstFailure: HostServiceAgentFailure = .server(.loginRequired)) {
        self.firstFailure = firstFailure
    }

    func authorize(context: HostServiceAgentRuntimeContext,
                   record: HostServiceAgentControlRecord) async -> Result<HostServiceAgentStatus, HostServiceAgentFailure> {
        calls.append(record)
        if calls.count == 1 { return .failure(firstFailure) }
        return .success(agentStatus(pluginID: context.pluginID, instanceID: context.instanceID,
            manual: false, businessReady: false, state: .ready))
    }

    func request(_ method: HostServiceAgentControlMethod, context: HostServiceAgentRuntimeContext,
                 generation: UUID?, consumerId: UUID?) async -> Result<HostServiceAgentStatus, HostServiceAgentFailure> {
        .failure(.unavailable)
    }

    func callsSnapshot() -> [HostServiceAgentControlRecord] { calls }

    func waitForCallCount(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while calls.count < count {
            guard ContinuousClock.now < deadline else { throw AgentTestError.compileFailed }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor AgentRecordingRPCClient: HostServiceAgentRPCPerforming {
    let response: Result<HostServiceAgentStatus, HostServiceAgentFailure>
    private var calls: [AgentRPCCall] = []

    init(response: Result<HostServiceAgentStatus, HostServiceAgentFailure>) {
        self.response = response
    }

    func request(
        _ method: HostServiceAgentControlMethod,
        context: HostServiceAgentRuntimeContext,
        generation: UUID?,
        consumerId: UUID?
    ) async -> Result<HostServiceAgentStatus, HostServiceAgentFailure> {
        calls.append(
            AgentRPCCall(
                method: method,
                instanceID: context.instanceID,
                generation: generation,
                consumerId: consumerId
            )
        )
        return response
    }

    func callsSnapshot() -> [AgentRPCCall] {
        calls
    }
}

private actor AgentControlledRPCClient: HostServiceAgentRPCPerforming {
    private struct PendingResponse {
        let method: HostServiceAgentControlMethod
        let generation: UUID?
        let consumerId: UUID?
        let continuation: CheckedContinuation<
            Result<HostServiceAgentStatus, HostServiceAgentFailure>,
            Never
        >
    }

    private var calls: [AgentRPCCall] = []
    private var pending: [UUID: PendingResponse] = [:]
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private let gatedMethods: Set<HostServiceAgentControlMethod>

    init(gatedMethods: Set<HostServiceAgentControlMethod>) {
        self.gatedMethods = gatedMethods
    }

    func request(
        _ method: HostServiceAgentControlMethod,
        context: HostServiceAgentRuntimeContext,
        generation: UUID?,
        consumerId: UUID?
    ) async -> Result<HostServiceAgentStatus, HostServiceAgentFailure> {
        calls.append(
            AgentRPCCall(
                method: method,
                instanceID: context.instanceID,
                generation: generation,
                consumerId: consumerId
            )
        )
        guard gatedMethods.contains(method) else {
            return .failure(.unavailable)
        }
        let id = UUID()
        let waiters = gateWaiters
        gateWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            pending[id] = PendingResponse(
                method: method,
                generation: generation,
                consumerId: consumerId,
                continuation: continuation
            )
        }
    }

    func waitForCallCount(_ count: Int) async {
        if calls.count >= count { return }
        await withCheckedContinuation { continuation in
            gateWaiters.append(continuation)
        }
    }

    func callsSnapshot() -> [AgentRPCCall] {
        calls
    }

    func resolve(
        _ method: HostServiceAgentControlMethod,
        with result: Result<HostServiceAgentStatus, HostServiceAgentFailure>
    ) {
        guard let entry = pending.first(where: { $0.value.method == method }) else {
            return
        }
        pending.removeValue(forKey: entry.key)
        entry.value.continuation.resume(returning: result)
    }
}

private actor AgentDelayedRPCClient: HostServiceAgentRPCPerforming {
    let response: Result<HostServiceAgentStatus, HostServiceAgentFailure>
    let delay: Duration
    private var callCount = 0

    init(
        response: Result<HostServiceAgentStatus, HostServiceAgentFailure>,
        delay: Duration
    ) {
        self.response = response
        self.delay = delay
    }

    func request(
        _ method: HostServiceAgentControlMethod,
        context: HostServiceAgentRuntimeContext,
        generation: UUID?,
        consumerId: UUID?
    ) async -> Result<HostServiceAgentStatus, HostServiceAgentFailure> {
        callCount += 1
        try? await Task.sleep(for: delay)
        return response
    }

    func callCountSnapshot() -> Int {
        callCount
    }
}

private final class AgentControlledStartupTiming: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Duration.zero
    private(set) var healthProbeCount = 0

    var elapsed: Duration {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    var timing: HostServiceStartupTiming {
        HostServiceStartupTiming(
            now: { [weak self] in
                self?.elapsed ?? .seconds(36)
            },
            sleep: { [weak self] duration in
                guard let self else { throw CancellationError() }
                self.advanceAutomatically(by: duration)
            }
        )
    }

    func noteHealthProbe() {
        lock.lock()
        healthProbeCount += 1
        lock.unlock()
    }

    func advanceAutomatically(by step: Duration) {
        lock.lock()
        current += step
        lock.unlock()
    }
}

private actor AgentStartupHealthGate {
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var resultWaiter: CheckedContinuation<Result<Void, HostServiceHealthError>, Never>?
    private var pendingResult: Result<Void, HostServiceHealthError>?

    func wait() async -> Result<Void, HostServiceHealthError> {
        entered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        if let pendingResult {
            self.pendingResult = nil
            return pendingResult
        }
        return await withCheckedContinuation { continuation in
            resultWaiter = continuation
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiter = continuation
        }
    }

    func release(_ result: Result<Void, HostServiceHealthError>) {
        if let waiter = resultWaiter {
            resultWaiter = nil
            waiter.resume(returning: result)
        } else {
            pendingResult = result
        }
    }
}

private struct AgentFailingRPCClient: HostServiceAgentRPCPerforming {
    func request(
        _ method: HostServiceAgentControlMethod,
        context: HostServiceAgentRuntimeContext,
        generation: UUID?,
        consumerId: UUID?
    ) async -> Result<HostServiceAgentStatus, HostServiceAgentFailure> {
        .failure(.unavailable)
    }
}

private final class AgentTestProcessHandle: OwnedProcessHandle, @unchecked Sendable {
    let processIdentifier: Int32 = 4242
    var isRunning = true

    func terminate() {
        isRunning = false
    }

    func kill() {
        isRunning = false
    }
}

private final class AgentTestProcessLauncher: ProcessExecuting, @unchecked Sendable {
    private var handle = AgentTestProcessHandle()
    private let lock = NSLock()
    private var recordedInvocations: [ProcessInvocation] = []
    private let onLaunch: (@Sendable (ProcessInvocation) throws -> Void)?

    init(onLaunch: (@Sendable (ProcessInvocation) throws -> Void)? = nil) {
        self.onLaunch = onLaunch
    }

    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: Data(), timedOut: false)
    }

    func launch(
        _ invocation: ProcessInvocation,
        operation: String,
        onExit: @escaping @Sendable (ProcessExit) -> Void
    ) async throws -> any OwnedProcessHandle {
        let handle = recordLaunch(invocation)
        try onLaunch?(invocation)
        return handle
    }

    private func recordLaunch(
        _ invocation: ProcessInvocation
    ) -> any OwnedProcessHandle {
        lock.lock()
        recordedInvocations.append(invocation)
        let currentHandle = handle
        lock.unlock()
        return currentHandle
    }

    func invocationSnapshot() -> [ProcessInvocation] {
        lock.lock()
        defer { lock.unlock() }
        return recordedInvocations
    }

    func waitForInvocationCount(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while invocationSnapshot().count < count {
            guard ContinuousClock.now < deadline else {
                throw AgentTestError.compileFailed
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func runningHandleCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return handle.isRunning ? 1 : 0
    }

    func stopAll() {
        handle.terminate()
    }

    var currentHandle: AgentTestProcessHandle {
        lock.lock()
        defer { lock.unlock() }
        return handle
    }

    func createProcessHandle() -> AgentTestProcessHandle {
        let newHandle = AgentTestProcessHandle()
        lock.lock()
        handle = newHandle
        lock.unlock()
        return newHandle
    }
}

private func agentTemporaryRoot() throws -> URL {
    let root = URL(
        fileURLWithPath: "/tmp/macdora-agent-\(UUID().uuidString.prefix(8).lowercased())",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    return root
}

private func agentFixtureManifest(
    id: String = "dev.agent.fixture",
    capabilities: [String] = ["host.service"],
    agentMCP: String?,
    version: String = "1.0.0"
) -> SystemPluginManifest {
    SystemPluginManifest(
        schemaVersion: 1,
        id: id,
        name: "Agent Fixture",
        subtitle: "",
        version: version,
        author: "test",
        category: "test",
        iconSymbol: "person.crop.circle",
        accentHex: 0,
        minHostVersion: "0.2.0",
        capabilities: capabilities,
        driverType: "host_service",
        entrypoints: SystemPluginEntrypoints(
            hostService: "bin/service",
            agentMCP: agentMCP
        )
    )
}

private func makeAgentPackage(
    root: URL,
    id: String,
    capabilities: [String] = ["host.service", "agent.readonly"],
    agentPath: String?,
    createExecutable: Bool,
    agentInstructions: String? = nil,
    agentSummary: String? = nil
) throws -> URL {
    let bundle = root.appendingPathComponent("packages/\(id)", isDirectory: true)
    let bin = bundle.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(
        at: bin,
        withIntermediateDirectories: true
    )
    let source = bin.appendingPathComponent("fixture.c")
    try Data("int main(void) { return 0; }\n".utf8).write(to: source)
    let service = bin.appendingPathComponent("service")
    try compileAndSign(source: source, output: service)
    if createExecutable, agentPath == "bin/agent" {
        let agent = bin.appendingPathComponent("agent")
        try compileAndSign(source: source, output: agent)
    }
    var manifest = agentFixtureManifest(
        id: id,
        capabilities: capabilities,
        agentMCP: agentPath
    )
    manifest.agentInstructions = agentInstructions
    manifest.agentSummary = agentSummary
    try JSONEncoder().encode(manifest).write(
        to: bundle.appendingPathComponent("manifest.json")
    )
    try SystemPluginPackageFactory.writeSignature(
        forPluginDirectory: bundle,
        pluginID: id,
        version: manifest.version
    )
    return bundle
}

private struct AgentRuntimeFixture {
    let bundleURL: URL
    let manifest: SystemPluginManifest
    let launcher: AgentTestProcessLauncher
}

@MainActor
private func makeAgentRuntimeFixture(
    root: URL,
    id: String,
    publishEndpointOnLaunch: Bool = false,
    copyToken: Bool = false
) throws -> AgentRuntimeFixture {
    let compileLock = AgentFixtureCompileLock.shared
    compileLock.lock.lock()
    defer { compileLock.lock.unlock() }
    let bundle = root.appendingPathComponent("runtime/\(id)", isDirectory: true)
    let bin = bundle.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(to: bin)
    let source = bin.appendingPathComponent("fixture.c")
    try Data("int main(void) { return 0; }\n".utf8).write(to: source)
    let service = bin.appendingPathComponent("service")
    let agent = bin.appendingPathComponent("agent")
    try compileAndSign(source: source, output: service)
    try compileAndSign(source: source, output: agent)
    let manifest = agentFixtureManifest(
        id: id,
        capabilities: ["host.service", "agent.readonly"] + (copyToken ? ["agent.readonly.token.v1"] : []),
        agentMCP: "bin/agent"
    )
    try JSONEncoder().encode(manifest).write(
        to: bundle.appendingPathComponent("manifest.json")
    )
    try SystemPluginPackageFactory.writeSignature(
        forPluginDirectory: bundle,
        pluginID: id,
        version: manifest.version
    )
    let onLaunch: (@Sendable (ProcessInvocation) throws -> Void)?
    if publishEndpointOnLaunch {
        onLaunch = { try writeAgentEndpoint(invocation: $0, manifest: manifest) }
    } else {
        onLaunch = nil
    }
    return AgentRuntimeFixture(
        bundleURL: bundle,
        manifest: manifest,
        launcher: AgentTestProcessLauncher(onLaunch: onLaunch)
    )
}

private final class AgentFixtureCompileLock: @unchecked Sendable {
    static let shared = AgentFixtureCompileLock()
    let lock = NSLock()
}

private func writeAgentEndpoint(
    invocation: ProcessInvocation,
    manifest: SystemPluginManifest
) throws {
    let stateDirectory = try #require(
        invocation.environment["MACDORA_PLUGIN_STATE_DIR"]
    )
    let socketPath = try #require(
        invocation.environment["MACDORA_PLUGIN_SOCKET_PATH"]
    )
    let instanceID = try #require(
        invocation.environment["MACDORA_PLUGIN_INSTANCE_ID"]
    )
    let endpoint = HostServiceEndpointRecord(
        schemaVersion: 1,
        pluginId: manifest.id,
        instanceId: instanceID,
        pid: getpid(),
        socketPath: socketPath,
        protocol: "json-rpc-2.0"
    )
    let endpointURL = URL(fileURLWithPath: stateDirectory, isDirectory: true)
        .appendingPathComponent("endpoint.json")
    try JSONEncoder().encode(endpoint).write(to: endpointURL, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int(0o600))],
        ofItemAtPath: endpointURL.path
    )

    let socketURL = URL(fileURLWithPath: socketPath)
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw AgentTestError.socketPathFailed }
    defer { Darwin.close(fd) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw AgentTestError.socketPathFailed
    }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.initializeMemory(as: UInt8.self, repeating: 0)
        raw.copyBytes(from: bytes)
    }
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else { throw AgentTestError.socketBindFailed }
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int(0o600))],
        ofItemAtPath: socketURL.path
    )
}

private func compileAndSign(source: URL, output: URL) throws {
    let compile = Process()
    compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    compile.arguments = ["clang", "-O0", source.path, "-o", output.path]
    compile.standardOutput = FileHandle.nullDevice
    compile.standardError = FileHandle.nullDevice
    try compile.run()
    compile.waitUntilExit()
    guard compile.terminationStatus == 0 else {
        throw AgentTestError.compileFailed
    }
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: output.path
    )
    let sign = Process()
    sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    sign.arguments = ["--force", "--sign", "-", output.path]
    sign.standardOutput = FileHandle.nullDevice
    sign.standardError = FileHandle.nullDevice
    try sign.run()
    sign.waitUntilExit()
    guard sign.terminationStatus == 0 else {
        throw AgentTestError.signFailed
    }
}

@MainActor
private func makeRunningAgentPlugin(root: URL, id: String, copyToken: Bool = false,
    rpcClient: (any HostServiceAgentRPCPerforming)? = nil,
    restoreRetryDelay: Duration = .seconds(5)) throws -> HostServiceSystemPlugin {
    let compileLock = AgentFixtureCompileLock.shared
    compileLock.lock.lock()
    defer { compileLock.lock.unlock() }
    let bundle = root.appendingPathComponent("running/\(id)", isDirectory: true)
    let bin = bundle.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(to: bin)
    let source = bin.appendingPathComponent("fixture.c")
    try Data("int main(void) { return 0; }\n".utf8).write(to: source)
    let service = bin.appendingPathComponent("service")
    let agent = bin.appendingPathComponent("agent")
    try compileAndSign(source: source, output: service)
    try compileAndSign(source: source, output: agent)
    let manifest = agentFixtureManifest(
        id: id,
        capabilities: ["host.service", "agent.readonly"] + (copyToken ? ["agent.readonly.token.v1"] : []),
        agentMCP: "bin/agent"
    )
    try JSONEncoder().encode(manifest).write(
        to: bundle.appendingPathComponent("manifest.json")
    )
    try SystemPluginPackageFactory.writeSignature(
        forPluginDirectory: bundle,
        pluginID: id,
        version: manifest.version
    )

    let launcher = AgentTestProcessLauncher()
    let plugin = HostServiceSystemPlugin(
        manifest: manifest,
        bundleDirectoryURL: bundle,
        rootURL: root,
        processExecuter: launcher,
        processTerminator: AgentTestTerminator(),
        supervisor: HostServiceSupervisorRegistry(),
        healthClient: { _, _, _ in .success(()) },
        agentRPCClient: rpcClient, agentRestoreRetryDelay: restoreRetryDelay
    )
    plugin.setNotificationBridge(nil)
    plugin.installAgentTestRuntime(handle: launcher.currentHandle)
    return plugin
}

@MainActor
private func writeCopyEndpoint(_ plugin: HostServiceSystemPlugin) throws {
    let configuration = try #require(plugin.agentRuntimeContext()?.configuration)
    try FileManager.default.createDirectory(at: configuration.endpointURL.deletingLastPathComponent(),
        withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try JSONEncoder().encode(configuration.endpoint).write(to: configuration.endpointURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configuration.endpointURL.path)
}

private func installAgentFixturePackage(
    at bundle: URL,
    id: String,
    capabilities: [String],
    agentMCP: String?,
    version: String = "1.0.0"
) throws {
    let bin = bundle.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(to: bin)
    let source = bin.appendingPathComponent("fixture.c")
    try Data("int main(void) { return 0; }\n".utf8).write(to: source)
    let service = bin.appendingPathComponent("service")
    try compileAndSign(source: source, output: service)
    if agentMCP != nil {
        try compileAndSign(source: source, output: bin.appendingPathComponent("agent"))
    }
    let manifest = agentFixtureManifest(
        id: id,
        capabilities: capabilities,
        agentMCP: agentMCP,
        version: version
    )
    try JSONEncoder().encode(manifest).write(
        to: bundle.appendingPathComponent("manifest.json")
    )
    try SystemPluginPackageFactory.writeSignature(
        forPluginDirectory: bundle,
        pluginID: id,
        version: manifest.version
    )
}

private func descendants(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap { descendants(of: $0) }
}

private func labels(in root: NSView) -> [String] {
    if let label = root as? NSTextField {
        return [label.stringValue]
    }
    return root.subviews.flatMap { labels(in: $0) }
}

private struct AgentTestTerminator: OwnedProcessTerminating {
    func terminateAndWait(
        _ handle: any OwnedProcessHandle,
        timeout: TimeInterval
    ) async -> Bool {
        handle.terminate()
        return !handle.isRunning
    }
}

private struct AgentStartupTerminator: OwnedProcessTerminating {
    func terminateAndWait(
        _ handle: any OwnedProcessHandle,
        timeout: TimeInterval
    ) async -> Bool {
        handle.terminate()
        for _ in 0..<20 {
            if !handle.isRunning { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !handle.isRunning
    }
}

private func agentStatus(
    pluginID: String = "dev.agent.fixture",
    instanceID: UUID = UUID(),
    manual: Bool = true,
    consumerId: UUID? = nil,
    businessReady: Bool = true,
    state: HostServiceAgentState? = nil,
    agentConnected: Bool? = nil,
    taskRunning: Bool = false,
    errorCode: HostServiceAgentErrorCode? = nil
) -> HostServiceAgentStatus {
    HostServiceAgentStatus(
        pluginId: pluginID,
        instanceId: instanceID,
        state: state ?? (manual ? .manual : .ready),
        agentConnected: agentConnected ?? (consumerId != nil),
        businessReady: businessReady,
        taskRunning: taskRunning,
        manual: manual,
        consumerId: consumerId,
        errorCode: errorCode,
        lastSuccessAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func agentDecode(
    _ string: String,
    requestID: Int,
    pluginID: String,
    instanceID: UUID
) -> HostServiceAgentStatus? {
    switch HostServiceAgentRPCClient.decode(
        Data(string.utf8),
        requestID: requestID,
        expectedPluginID: pluginID,
        expectedInstanceID: instanceID
    ) {
    case .success(let status):
        return status
    case .failure:
        return nil
    }
}

private enum AgentTestError: Error {
    case compileFailed
    case signFailed
    case socketPathFailed
    case socketBindFailed
}

private extension FileManager {
    func createDirectory(to url: URL) throws {
        try createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
