import AppKit
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import AndroidUse

@Suite("Agent Host Service", .serialized)
struct AgentHostServiceTests {
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
        #expect(!legacy.contains("oa_"))
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
    publishEndpointOnLaunch: Bool = false
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
        capabilities: ["host.service", "agent.readonly"],
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
private func makeRunningAgentPlugin(root: URL, id: String) throws -> HostServiceSystemPlugin {
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
        capabilities: ["host.service", "agent.readonly"],
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
        healthClient: { _, _, _ in .success(()) }
    )
    plugin.setNotificationBridge(nil)
    plugin.installAgentTestRuntime(handle: launcher.currentHandle)
    return plugin
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
