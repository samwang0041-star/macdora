import AppKit
import CryptoKit
import Foundation
import XCTest
@testable import AndroidUse

@MainActor
final class AgentWorkspaceAssetsTests: XCTestCase {
    func testCopyAuthorizationStatesUseOneStepAndKeepWithdrawalVisible() throws {
        _ = NSApplication.shared
        let fixture = try AgentAssetFixture(copyToken: true)
        defer { fixture.remove() }
        let instance = try XCTUnwrap(fixture.plugin.agentRuntimeContext()?.instanceID)
        let states: [(String, Bool, Bool, Bool, HostServiceAgentState, String)] = [
            ("manual", false, false, true, .waitingForAgent, "由你操作"),
            ("approved", true, false, false, .ready, "已授权，待接入"),
            ("connected-idle", true, true, false, .ready, "已授权，待处理"),
            ("preparing", true, true, false, .recovering, "正在准备"),
            ("restore-wait", true, false, true, .waitingForAgent, "接入待恢复"),
            ("login-wait", true, false, false, .waitingForLogin, "需要登录"),
            ("permission", true, false, true, .needsAttention, "接入受限")
        ]
        for width in [CGFloat(720), CGFloat(360)] {
            for (name, approved, connected, runtimeManual, state, title) in states {
                let status = HostServiceAgentStatus(pluginId: fixture.plugin.manifest.id,
                    instanceId: instance, state: state, agentConnected: connected,
                    businessReady: false, taskRunning: false, manual: runtimeManual,
                    errorCode: state == .waitingForLogin ? .loginRequired
                        : state == .needsAttention ? .permissionDenied : nil)
                let view = HostServiceAgentWorkspaceView(testingWith: fixture.plugin, status: status)
                view.controller.setLoadedStatusForTesting(status, persistedManual: !approved, loaded: true)
                view.frame.size.width = width - 40
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 480),
                    styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let host = NSView()
                window.contentView = host
                host.addSubview(view)
                NSLayoutConstraint.activate([
                    view.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 20),
                    view.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -20),
                    view.topAnchor.constraint(equalTo: host.topAnchor, constant: 20)
                ])
                host.layoutSubtreeIfNeeded()
                host.layoutSubtreeIfNeeded()
                let buttons = descendants(of: view).compactMap { $0 as? TFButton }
                let copy = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "agent-copy-configuration" })
                let withdraw = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "agent-primary-action" })
                let test = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "agent-test-connection" })
                XCTAssertFalse(copy.isHidden)
                XCTAssertTrue(copy.isEnabled)
                XCTAssertTrue(test.isHidden)
                XCTAssertEqual(withdraw.isHidden, !approved)
                if approved {
                    XCTAssertTrue(withdraw.isEnabled)
                    XCTAssertEqual(withdraw.title, "我来操作")
                }
                XCTAssertTrue(labels(in: view).contains(title))
                if state == .recovering {
                    XCTAssertTrue(labels(in: view).contains("准备中"))
                    XCTAssertFalse(labels(in: view).contains("需要处理"))
                }
                if state == .waitingForLogin {
                    XCTAssertTrue(labels(in: view).contains { $0.contains("登录对应应用") })
                    XCTAssertFalse(labels(in: view).contains("需要处理"))
                }
                if state == .needsAttention {
                    XCTAssertTrue(labels(in: view).contains { $0.contains("系统权限") })
                }
                XCTAssertTrue(labels(in: view).contains { $0.contains("复制即授权只读访问") })
                for button in buttons where !button.isHidden {
                    let bounds = button.convert(button.bounds, to: view)
                    XCTAssertGreaterThanOrEqual(bounds.minX, -1)
                    XCTAssertLessThanOrEqual(bounds.maxX, view.bounds.width + 1)
                }
                try snapshot(view, to: try exportDirectory(),
                    name: "copy-\(name)-\(Int(width)).png")
                window.orderOut(nil)
            }
        }
    }
    func testNeutralStatesRenderWideAndNarrowWithKeyboardActions() throws {
        _ = NSApplication.shared
        let fixture = try AgentAssetFixture()
        defer { fixture.remove() }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.title = "Agent QA"
        window.isReleasedWhenClosed = false
        let host = NSView()
        window.contentView = host

        let states: [(String, HostServiceAgentStatus?, String?)] = [
            ("waitingForAgent", .waitingForAgent, nil),
            ("ready-managed", .readyManaged, nil),
            ("manual", .manual, nil),
            ("needsLogin", .needsLogin, nil),
            ("failed-revocable", nil, "连接检查失败")
        ]
        for width in [CGFloat(720), CGFloat(360)] {
            for (name, status, failure) in states {
                host.subviews.forEach { $0.removeFromSuperview() }
                window.setContentSize(NSSize(width: width, height: 700))
                let view: HostServiceAgentWorkspaceView
                if var status {
                    status.instanceId = try XCTUnwrap(fixture.plugin.agentRuntimeContext()?.instanceID)
                    view = HostServiceAgentWorkspaceView(
                        testingWith: fixture.plugin,
                        status: status
                    )
                } else {
                    view = HostServiceAgentWorkspaceView(
                        testingWith: fixture.plugin,
                        failure: try XCTUnwrap(failure)
                    )
                }
                host.addSubview(view)
                NSLayoutConstraint.activate([
                    view.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 20),
                    view.widthAnchor.constraint(equalToConstant: width - 40),
                    view.topAnchor.constraint(equalTo: host.topAnchor, constant: 20)
                ])
                host.layoutSubtreeIfNeeded()
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(view.bounds.width, width - 40, accuracy: 2)

                let buttons = descendants(of: view).compactMap { $0 as? TFButton }
                let actionButtons = [
                    "agent-primary-action",
                    "agent-test-connection",
                    "agent-copy-configuration"
                ].compactMap { identifier in
                    buttons.first { $0.identifier?.rawValue == identifier }
                }
                XCTAssertEqual(actionButtons.count, 3)
                let frames = actionButtons.map {
                    $0.convert($0.bounds, to: view)
                }
                if width >= 560 {
                    XCTAssertEqual(frames[0].midY, frames[1].midY, accuracy: 2)
                    XCTAssertEqual(frames[1].midY, frames[2].midY, accuracy: 2)
                    XCTAssertLessThan(frames[0].minX, frames[1].minX)
                    XCTAssertLessThan(frames[1].minX, frames[2].minX)
                } else {
                    XCTAssertEqual(frames[0].minX, frames[1].minX, accuracy: 2)
                    XCTAssertEqual(frames[1].minX, frames[2].minX, accuracy: 2)
                    XCTAssertGreaterThan(frames[0].minY, frames[1].maxY)
                    XCTAssertGreaterThan(frames[1].minY, frames[2].maxY)
                }
                XCTAssertTrue(buttons.contains { $0.identifier?.rawValue == "agent-primary-action" })
                XCTAssertTrue(buttons.contains { $0.identifier?.rawValue == "agent-test-connection" })
                XCTAssertTrue(buttons.contains { $0.identifier?.rawValue == "agent-copy-configuration" })
                XCTAssertTrue(labels(in: view).contains { $0.contains("只读计数") })
                XCTAssertTrue(labels(in: view).contains { $0.contains("不返回正文") })
                XCTAssertTrue(labels(in: view).contains { $0.contains("不写业务") })
                XCTAssertFalse(labels(in: view).contains { $0.contains("/tmp/") })
                XCTAssertFalse(labels(in: view).contains { $0.contains("consumerId") })
                XCTAssertFalse(labels(in: view).contains { $0.contains("instanceId") })

                for button in buttons {
                    XCTAssertTrue(button.isAccessibilityElement())
                    XCTAssertEqual(button.accessibilityRole(), .button)
                    XCTAssertFalse((button.accessibilityLabel() ?? "").isEmpty)
                    if button.isEnabled {
                        XCTAssertTrue(button.acceptsFirstResponder)
                    }
                }

                if name == "ready-managed"
                    || name == "failed-revocable"
                    || name == "needsLogin" {
                    let revoke = try XCTUnwrap(
                        buttons.first {
                            $0.identifier?.rawValue == "agent-primary-action"
                        }
                    )
                    XCTAssertTrue(revoke.isEnabled)
                    XCTAssertEqual(revoke.title, "我来操作")
                }
                if name == "ready-managed" {
                    XCTAssertTrue(labels(in: view).contains("Agent 已托管"))
                    XCTAssertFalse(labels(in: view).contains { $0.contains("可以交给") })
                }
                if name == "needsLogin" {
                    XCTAssertTrue(labels(in: view).contains("需要先登录"))
                    XCTAssertFalse(labels(in: view).contains("由你操作"))
                }
                if name == "failed-revocable" {
                    XCTAssertTrue(
                        labels(in: view).contains {
                            $0.contains("点「我来操作」可立即保存手动状态")
                        }
                    )
                    XCTAssertFalse(labels(in: view).contains { $0.contains("手动意图已保存") })
                }
                if name == "waitingForAgent" || name == "manual" {
                    let primary = try XCTUnwrap(
                        buttons.first {
                            $0.identifier?.rawValue == "agent-primary-action"
                        }
                    )
                    if name == "manual" {
                        XCTAssertTrue(primary.isEnabled)
                        XCTAssertEqual(primary.title, "交给 Agent")
                    } else {
                        XCTAssertFalse(primary.isEnabled)
                    }
                }
                if name == "ready-managed" || name == "failed-revocable" {
                    let test = try XCTUnwrap(
                        buttons.first {
                            $0.identifier?.rawValue == "agent-test-connection"
                        }
                    )
                    XCTAssertFalse(test.isEnabled)
                }
                let export = try XCTUnwrap(
                    buttons.first {
                        $0.identifier?.rawValue == "agent-copy-configuration"
                    }
                )
                XCTAssertTrue(export.isEnabled)

                try snapshot(
                    view,
                    to: try exportDirectory(),
                    name: "\(name)-\(Int(width)).png"
                )
            }
        }
    }

    func testPrimaryActionAcceptsKeyboardActivation() async throws {
        _ = NSApplication.shared
        let fixture = try AgentAssetFixture()
        defer { fixture.remove() }
        let context = try XCTUnwrap(fixture.plugin.agentRuntimeContext())
        let before = try fixture.plugin.agentControlStore.loadOrCreate()
        let view = HostServiceAgentWorkspaceView(
            testingWith: fixture.plugin,
            status: HostServiceAgentStatus(
                pluginId: fixture.plugin.manifest.id,
                instanceId: context.instanceID,
                state: .waitingForApproval,
                agentConnected: true,
                businessReady: true,
                taskRunning: false,
                manual: true,
                consumerId: UUID()
            )
        )
        let button = try XCTUnwrap(
            descendants(of: view)
                .compactMap { $0 as? TFButton }
                .first { $0.identifier?.rawValue == "agent-primary-action" }
        )
        XCTAssertTrue(button.isEnabled)
        let space = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: " ",
                charactersIgnoringModifiers: " ",
                isARepeat: false,
                keyCode: 49
            )
        )
        XCTAssertTrue(button.acceptsFirstResponder)
        button.keyDown(with: space)
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            let current = try fixture.plugin.agentControlStore.reload()
            if current.generation != before.generation, !view.controller.isSubmitting {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let after = try fixture.plugin.agentControlStore.reload()
        XCTAssertNotEqual(after.generation, before.generation)
        XCTAssertTrue(after.manual, "An unavailable fixture must roll back the keyboard grant")
        XCTAssertFalse(view.controller.isSubmitting)
    }

    private func exportDirectory() throws -> URL? {
        guard let path = ProcessInfo.processInfo.environment["MACDORA_AGENT_QA_SNAPSHOTS"] else {
            return nil
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func snapshot(
        _ view: NSView,
        to directory: URL?,
        name: String
    ) throws {
        guard let directory else { return }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private func descendants(of root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants)
    }

    private func labels(in root: NSView) -> [String] {
        (root as? NSTextField).map { [$0.stringValue] }
            ?? root.subviews.flatMap(labels)
    }
}

@MainActor
private struct AgentAssetFixture {
    let root: URL
    let plugin: HostServiceSystemPlugin

    init(copyToken: Bool = false) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macdora-agent-assets-\(UUID().uuidString)")
        let bundle = root.appendingPathComponent("neutral-agent", isDirectory: true)
        let bin = bundle.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bin,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let source = bin.appendingPathComponent("fixture.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)
        for name in ["service", "agent"] {
            let output = bin.appendingPathComponent(name)
            try Self.compileAndSign(source: source, output: output)
        }
        var manifest = SystemPluginManifest(
            schemaVersion: 1,
            id: "dev.example.readonly-agent",
            name: "只读 Agent",
            subtitle: "中性示例",
            version: "1.0.0",
            author: "fixture",
            category: "example",
            iconSymbol: "person.crop.circle.badge.checkmark",
            accentHex: 0x0F766E,
            minHostVersion: "0.2.0",
            capabilities: ["host.service", "agent.readonly"] + (copyToken ? ["agent.readonly.token.v1"] : []),
            driverType: "host_service",
            entrypoints: SystemPluginEntrypoints(
                hostService: "bin/service",
                agentMCP: "bin/agent"
            )
        )
        manifest.agentSummary = copyToken ? "权限：只读；具体能力由插件提供" : "只读计数；不返回正文，不写业务"
        manifest.agentInstructions = "Discover the fixture's tools and verify the current state."
        try JSONEncoder().encode(manifest).write(
            to: bundle.appendingPathComponent("manifest.json")
        )
        try SystemPluginPackageFactory.writeSignature(
            forPluginDirectory: bundle,
            pluginID: manifest.id,
            version: manifest.version
        )
        plugin = HostServiceSystemPlugin(
            manifest: manifest,
            bundleDirectoryURL: bundle,
            rootURL: root
        )
        plugin.installAgentTestRuntime(handle: AgentAssetProcessHandle())
    }

    func remove() {
        plugin.retire()
        try? FileManager.default.removeItem(at: root)
    }

    private static func compileAndSign(source: URL, output: URL) throws {
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = ["clang", "-O0", source.path, "-o", output.path]
        compile.standardOutput = FileHandle.nullDevice
        compile.standardError = FileHandle.nullDevice
        try compile.run()
        compile.waitUntilExit()
        XCTAssertEqual(compile.terminationStatus, 0)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int(0o700))],
            ofItemAtPath: output.path
        )
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", output.path]
        sign.standardOutput = FileHandle.nullDevice
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0)
    }
}

private final class AgentAssetProcessHandle: OwnedProcessHandle, @unchecked Sendable {
    let processIdentifier: Int32 = 4_242
    private(set) var isRunning = true

    func terminate() {
        isRunning = false
    }

    func kill() {
        isRunning = false
    }
}

private extension HostServiceAgentStatus {
    static let waitingForAgent = HostServiceAgentStatus(
        pluginId: "dev.example.readonly-agent",
        instanceId: UUID(),
        state: .waitingForAgent,
        agentConnected: false,
        businessReady: false,
        taskRunning: false,
        manual: true
    )

    static let readyManaged = HostServiceAgentStatus(
        pluginId: "dev.example.readonly-agent",
        instanceId: UUID(),
        state: .ready,
        agentConnected: true,
        businessReady: true,
        taskRunning: false,
        manual: false,
        consumerId: UUID()
    )

    static let manual = HostServiceAgentStatus(
        pluginId: "dev.example.readonly-agent",
        instanceId: UUID(),
        state: .manual,
        agentConnected: true,
        businessReady: true,
        taskRunning: false,
        manual: true,
        consumerId: UUID()
    )

    static let needsLogin = HostServiceAgentStatus(
        pluginId: "dev.example.readonly-agent",
        instanceId: UUID(),
        state: .waitingForLogin,
        agentConnected: false,
        businessReady: false,
        taskRunning: false,
        manual: false,
        errorCode: .loginRequired
    )
}
