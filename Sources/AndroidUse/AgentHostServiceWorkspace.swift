import AppKit
import Foundation

@MainActor
final class HostServiceAgentWorkspaceController {
    enum PrimaryAction: Equatable {
        case grant
        case revoke
    }

    enum Display: Equatable {
        case loading
        case available(HostServiceAgentStatus)
        case failed(String)
    }

    let pluginID: String
    private let plugin: HostServiceSystemPlugin
    private let rpcClient: any HostServiceAgentRPCPerforming

    private(set) var display: Display = .loading
    private(set) var isRefreshing = false
    private(set) var isSubmitting = false
    private(set) var isPreparing = false
    private var storedManualIntent = true
    private var lastStatus: HostServiceAgentStatus?
    private var lastFailure: HostServiceAgentFailure?
    private(set) var activePrimaryAction: PrimaryAction?

    private var requestSequence: UInt64 = 0
    private var activeRefresh: Task<Void, Never>?
    private var activeAction: Task<Void, Never>?
    private var activeInstanceID: UUID?
    private var actionToken: UUID?
    private var viewIsLoaded = false
    private var awaitsRuntimeContextRefresh = false
    #if DEBUG
    private var testConnectionAllowedOverride: Bool?
    #endif

    var onDisplayChanged: ((Display) -> Void)?
    var usesCopyTokenAuthorization: Bool { plugin.manifest.usesCopyTokenAuthorization }

    init(
        plugin: HostServiceSystemPlugin,
        rpcClient: any HostServiceAgentRPCPerforming? = nil
    ) {
        self.pluginID = plugin.manifest.id
        self.plugin = plugin
        self.rpcClient = rpcClient ?? plugin.agentRPCClient
        if let record = try? plugin.agentControlStore.loadOrCreate() {
            storedManualIntent = record.manual
        }
    }

    deinit {
        activeRefresh?.cancel()
        activeAction?.cancel()
    }

    #if DEBUG
    func ingestStatusForTesting(_ status: HostServiceAgentStatus) {
        guard status.pluginId == pluginID else { return }
        storedManualIntent = status.manual
        lastStatus = status
        lastFailure = nil
        awaitsRuntimeContextRefresh = false
        isRefreshing = false
        isPreparing = false
        activeRefresh = nil
        display = .available(status)
        notify()
    }

    func ingestFailureForTesting(
        _ message: String,
        instanceID: UUID? = nil,
        persistedManual: Bool
    ) {
        self.storedManualIntent = persistedManual
        lastStatus = nil
        lastFailure = nil
        awaitsRuntimeContextRefresh = false
        display = .failed(message)
        notify()
    }

    func setViewLoadedForTesting(_ loaded: Bool) {
        viewIsLoaded = loaded
    }

    func setCanTestConnectionForTesting(_ canTest: Bool) {
        testConnectionAllowedOverride = canTest
    }

    func setLoadedStatusForTesting(
        _ status: HostServiceAgentStatus,
        persistedManual: Bool,
        loaded: Bool
    ) {
        guard status.pluginId == pluginID else { return }
        viewIsLoaded = loaded
        storedManualIntent = persistedManual
        lastStatus = status
        lastFailure = nil
        awaitsRuntimeContextRefresh = false
        isRefreshing = true
        display = .available(status)
        notify()
    }

    func setRefreshingForTesting(_ refreshing: Bool) {
        isRefreshing = refreshing
        notify()
    }

    func setPreparingForTesting(_ preparing: Bool) {
        isPreparing = preparing
        notify()
    }

    func setSubmittingForTesting(
        _ submitting: Bool,
        action: PrimaryAction?
    ) {
        isSubmitting = submitting
        activePrimaryAction = action
        notify()
    }
    #endif

    var status: HostServiceAgentStatus? {
        guard case .available(let status) = display,
              plugin.agentRuntimeContext()?.instanceID == status.instanceId else { return nil }
        return status
    }

    var showsAgentManaged: Bool {
        guard let status, !status.manual, !effectiveManualIntent else { return false }
        return status.agentConnected
            && status.businessReady
            && status.consumerId != nil
            && !status.taskRunning
            && status.state != .needsAttention
            && status.state != .recovering
            && status.errorCode == nil
    }

    var handoffPillText: String {
        guard let status else {
            return storedManualIntent ? "需要你操作" : "确认托管中"
        }
        if usesCopyTokenAuthorization, !storedManualIntent, !status.manual,
           status.state == .recovering, status.errorCode == nil {
            return "准备中"
        }
        if usesCopyTokenAuthorization, status.state == .waitingForLogin {
            return "需要登录"
        }
        if status.errorCode != nil
            || status.state == .needsAttention
            || status.state == .recovering {
            return "需要处理"
        }
        if status.state == .waitingForLogin {
            return "需要登录"
        }
        if status.taskRunning || status.state == .running {
            return "Agent 运行中"
        }
        if !status.agentConnected { return "待接入" }
        if !status.businessReady { return "待就绪" }
        if status.manual && !effectiveManualIntent { return "待确认" }
        return effectiveManualIntent ? "需要你操作" : "Agent 托管"
    }

    var primaryAction: PrimaryAction? {
        if activePrimaryAction == .revoke { return nil }
        if !storedManualIntent {
            return .revoke
        }
        if usesCopyTokenAuthorization { return nil }
        if isSubmitting || activePrimaryAction != nil { return nil }
        guard !isRefreshing,
              !isPreparing,
              activeAction == nil,
              let status = candidateStatus,
              status.manual,
              status.agentConnected,
              status.businessReady,
              status.consumerId != nil,
              [.ready, .waitingForApproval, .manual].contains(status.state) else {
            return nil
        }
        return .grant
    }

    var primaryActionTitle: String {
        if primaryAction == .revoke { return "我来操作" }
        if let activePrimaryAction {
            return activePrimaryAction == .grant ? "正在交给 Agent…" : "正在切回…"
        }
        switch primaryAction {
        case .grant:
            return "交给 Agent"
        case .revoke:
            return "我来操作"
        case nil:
            if !storedManualIntent { return "我来操作" }
            return "等待就绪"
        }
    }

    var canTestConnection: Bool {
        if usesCopyTokenAuthorization { return false }
        if candidateStatus?.manual == false || !storedManualIntent {
            return false
        }
        #if DEBUG
        if let testConnectionAllowedOverride {
            return testConnectionAllowedOverride
        }
        #endif
        return !isSubmitting
            && activeRefresh == nil
            && plugin.agentRuntimeContext() != nil
    }

    var canExportConfiguration: Bool {
        !isSubmitting
            && plugin.agentRuntimeContext() != nil
            && FileManager.default.isExecutableFile(atPath: plugin.agentMCPExecutableURL.path)
    }

    var statusText: String {
        switch display {
        case .loading:
            if !storedManualIntent { return "正在确认托管状态" }
            return isRefreshing ? "正在检查连接" : "等待检查"
        case .failed:
            return storedManualIntent ? "连接检查未完成" : "托管状态待确认"
        case .available(let status):
            guard self.status != nil else { return "连接状态待确认" }
            if usesCopyTokenAuthorization {
                if storedManualIntent { return "由你操作" }
                if status.errorCode == .permissionDenied { return "接入受限" }
                if status.state == .waitingForLogin { return "需要登录" }
                if status.manual { return "接入待恢复" }
                if status.errorCode != nil { return "已授权，等待业务恢复" }
                if status.taskRunning { return "Agent 正在处理" }
                if !status.agentConnected { return "已授权，待接入" }
                if !status.businessReady {
                    return status.state == .recovering ? "正在准备" : "已授权，待处理"
                }
                return "Agent 已就绪"
            }
            return Self.statusText(for: status, effectiveManual: effectiveManualIntent)
        }
    }

    var detailText: String {
        switch display {
        case .loading:
            if !storedManualIntent {
                return "正在确认托管状态；点「我来操作」即可置为手动。"
            }
            return "正在核对插件连接，你仍可随时接回控制。"
        case .failed(let message):
            if !storedManualIntent {
                return message + " 点「我来操作」可立即保存手动状态。"
            }
            return message + " 默认仍由你操作。"
        case .available(let status):
            guard self.status != nil else {
                return storedManualIntent
                    ? "已保存手动状态；运行实例已改变，请重新检查连接。"
                    : "运行实例已改变；点「我来操作」可立即保存手动状态。"
            }
            if usesCopyTokenAuthorization {
                if storedManualIntent { return "点「复制给 Agent」即可授权只读访问。" }
                if status.errorCode == .permissionDenied {
                    return "无法验证运行环境，请检查系统权限或插件状态。你可随时点「我来操作」。"
                }
                if status.state == .waitingForLogin {
                    return "登录对应应用后可继续。你可随时点「我来操作」。"
                }
                if status.manual {
                    return "请确认对应应用已登录；若仍无法接入，可重新复制。你可随时点「我来操作」。"
                }
                if status.errorCode != nil { return "授权仍有效；业务恢复后自动继续。你可随时点「我来操作」。" }
                return "只读授权已保存，你可随时点「我来操作」接回控制。"
            }
            return Self.detailText(
                for: status,
                effectiveManual: effectiveManualIntent
            )
        }
    }

    var workflowText: String {
        usesCopyTokenAuthorization
            ? "复制即授权只读访问，将接入内容发给你的 Agent。"
            : "复制接入说明发给自己的 Agent，由它完成配置并引导你确认授权。"
    }

    var scopeText: String {
        plugin.manifest.agentSummary ?? "权限：只读；具体能力通过插件工具发现。"
    }

    var lastSuccessText: String {
        guard let status, let lastSuccessAt = status.lastSuccessAt else {
            return "暂无成功记录"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return "最近成功 \(formatter.string(from: lastSuccessAt))"
    }

    func viewDidLoad() {
        guard !viewIsLoaded else { return }
        viewIsLoaded = true
        guard status == nil, !isRefreshing, activeRefresh == nil else { return }
        Task { @MainActor [weak self] in
            await self?.refresh()
        }
    }

    func viewDidUnload() {
        // Explicit grant/revoke actions are not tied to the view's presence.
        // Their token, instance and control generation still gate late results.
        viewIsLoaded = false
        activeRefresh?.cancel()
        activeRefresh = nil
        isRefreshing = false
        isPreparing = false
    }

    func hostStateDidChange() {
        reloadPersistedManual()
        let currentInstanceID = plugin.agentRuntimeContext()?.instanceID
        if let activeInstanceID, activeInstanceID != currentInstanceID {
            invalidateRefresh()
            lastStatus = nil
            awaitsRuntimeContextRefresh = false
            display = .failed("运行实例已改变，请重新检查连接。")
        } else if case .available = display, status == nil {
            invalidateRefresh()
            lastStatus = nil
            awaitsRuntimeContextRefresh = false
            display = .failed("运行实例已改变，请重新检查连接。")
        }
        notify()
        let needsRecoveryRefresh = usesCopyTokenAuthorization && !storedManualIntent
            && (status == nil || status?.manual == true)
        if ((awaitsRuntimeContextRefresh && status == nil) || needsRecoveryRefresh),
           currentInstanceID != nil,
           viewIsLoaded,
           activeRefresh == nil,
           activeAction == nil,
           !isSubmitting,
           !isPreparing {
            awaitsRuntimeContextRefresh = false
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        guard viewIsLoaded else { return }
        reloadPersistedManual()
        await runRequest(showLoading: status == nil, method: .status)
    }

    func testConnection() async {
        guard canTestConnection else { return }
        isPreparing = true
        notify()
        defer {
            isPreparing = false
            notify()
        }
        await runRequest(showLoading: false, method: .prepare)
    }

    func performPrimaryAction() async {
        switch primaryAction {
        case .grant:
            await grantToAgent()
        case .revoke:
            await returnToManual()
        case nil:
            break
        }
    }

    func configurationData() async throws -> Data {
        guard let context = plugin.agentRuntimeContext(),
              await context.securityStateCheck.validate() else {
            throw HostServiceAgentFailure.unavailable
        }
        _ = try HostServiceEndpointReader.read(
            at: context.configuration.endpointURL,
            expected: context.configuration.endpoint
        )
        guard plugin.agentRuntimeContext()?.instanceID == context.instanceID else {
            throw HostServiceAgentFailure.stale
        }
        return try HostServiceAgentMCPConfiguration.data(
            pluginID: plugin.manifest.id,
            agentExecutableURL: plugin.agentMCPExecutableURL,
            endpointURL: context.configuration.endpointURL
        )
    }

    func agentHandoffText() async throws -> String {
        let data = try await configurationData()
        return try HostServiceAgentMCPConfiguration.handoff(
            instructions: plugin.manifest.agentInstructions,
            configuration: data
        )
    }

    func copyAgentHandoff(
        writeToClipboard: (String) -> Bool = { text in
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(text, forType: .string)
        }
    ) async throws {
        guard canExportConfiguration else { throw HostServiceAgentFailure.unavailable }
        if !usesCopyTokenAuthorization {
            let text = try await agentHandoffText()
            guard writeToClipboard(text) else { throw HostServiceAgentFailure.unavailable }
            return
        }
        guard let context = plugin.agentRuntimeContext() else { throw HostServiceAgentFailure.unavailable }
        let expected = try plugin.agentControlStore.reload()
        invalidateRefresh()
        let actionID = UUID()
        actionToken = actionID
        isSubmitting = true
        notify()
        defer { clearAction(token: actionID) }

        guard await context.securityStateCheck.validate(), actionToken == actionID,
              plugin.agentRuntimeContext()?.instanceID == context.instanceID else {
            throw HostServiceAgentFailure.stale
        }
        _ = try HostServiceEndpointReader.read(at: context.configuration.endpointURL,
            expected: context.configuration.endpoint)
        let credential = HostServiceAgentCopyToken.generate()
        let data = try HostServiceAgentMCPConfiguration.data(pluginID: pluginID,
            agentExecutableURL: plugin.agentMCPExecutableURL,
            endpointURL: context.configuration.endpointURL, token: credential.value)
        let text = try HostServiceAgentMCPConfiguration.handoff(
            instructions: plugin.manifest.agentInstructions, configuration: data)
        guard writeToClipboard(text) else { throw HostServiceAgentFailure.unavailable }
        guard actionToken == actionID,
              let record = try plugin.agentControlStore.authorizeCopy(ifUnchanged: expected,
                instanceID: context.instanceID, tokenDigest: credential.digest) else {
            throw HostServiceAgentFailure.stale
        }
        storedManualIntent = false
        notify()
        let result = await rpcClient.authorize(context: context, record: record)
        let securityValid = await context.securityStateCheck.validate()
        if actionToken == actionID, securityValid,
           plugin.agentRuntimeContext()?.instanceID == context.instanceID,
           (try? plugin.agentControlStore.reload()) == record {
            switch result {
            case .success(let response) where response.pluginId == pluginID
                && response.instanceId == context.instanceID && !response.manual:
                lastStatus = response
                lastFailure = nil
                display = .available(response)
                return
            case .failure(let failure):
                let waitingForLogin = failure == .server(.loginRequired)
                if waitingForLogin || failure == .server(.businessNotReady)
                    || failure == .server(.recoveryRequired) || failure == .busy {
                    let pending = HostServiceAgentStatus(pluginId: pluginID,
                        instanceId: context.instanceID,
                        state: waitingForLogin ? .waitingForLogin : .recovering,
                        agentConnected: false, businessReady: false, taskRunning: false,
                        manual: true, errorCode: waitingForLogin ? .loginRequired : .businessNotReady)
                    lastStatus = pending
                    lastFailure = nil
                    display = .available(pending)
                    plugin.scheduleAgentAuthorizationRestore()
                    return
                }
            default:
                break
            }
        }
        // An uncertain response never leaves a newly issued credential usable.
        // CAS preserves any newer copy or manual action, including an offline withdrawal.
        _ = try? plugin.agentControlStore.compareAndSetManual(
            expectedGeneration: record.generation, manual: true)
        if actionToken == actionID {
            reloadPersistedManual()
            lastStatus = nil
            display = .failed("接入未完成，请重新复制。")
        }
        throw HostServiceAgentFailure.stale
    }

    private func reloadPersistedManual() {
        if let record = try? plugin.agentControlStore.loadOrCreate() {
            storedManualIntent = record.manual
        }
    }

    private func invalidateRefresh() {
        requestSequence &+= 1
        activeRefresh?.cancel()
        activeRefresh = nil
        activeInstanceID = nil
        isRefreshing = false
        isPreparing = false
    }

    private func grantToAgent() async {
        guard let rawStatus,
              rawStatus.manual,
              rawStatus.agentConnected,
              rawStatus.businessReady,
              let consumerId = rawStatus.consumerId,
              let context = plugin.agentRuntimeContext(),
              context.instanceID == rawStatus.instanceId else {
            display = .failed("连接尚未就绪，仍由你操作")
            notify()
            return
        }

        invalidateRefresh()
        let token = UUID()
        actionToken = token
        isSubmitting = true
        activePrimaryAction = .grant
        notify()
        defer { clearAction(token: token) }

        let record: HostServiceAgentControlRecord
        do {
            let expected = try plugin.agentControlStore.reload()
            let validated = await context.securityStateCheck.validate()
            guard actionToken == token else { return }
            guard validated,
                  plugin.agentRuntimeContext()?.instanceID == context.instanceID,
                  let granted = try plugin.agentControlStore.grant(ifUnchanged: expected) else {
                reloadPersistedManual()
                display = .failed("连接或控制权已改变，请重新检查。")
                return
            }
            record = granted
        } catch {
            display = .failed("无法保存交给 Agent 的状态，仍由你操作。")
            notify()
            return
        }

        storedManualIntent = false
        notify()

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.rpcClient.request(
                .grant,
                context: context,
                generation: record.generation,
                consumerId: consumerId
            )
            await self.applyGrantResult(
                result,
                token: token,
                record: record,
                context: context,
                consumerId: consumerId
            )
        }
        activeAction = task
        await task.value
    }

    private func applyGrantResult(
        _ result: Result<HostServiceAgentStatus, HostServiceAgentFailure>,
        token: UUID,
        record: HostServiceAgentControlRecord,
        context: HostServiceAgentRuntimeContext,
        consumerId: UUID
    ) async {
        guard actionToken == token else { return }
        defer { clearAction(token: token) }
        let persisted = try? plugin.agentControlStore.reload()
        let sameInstance = plugin.agentRuntimeContext()?.instanceID == context.instanceID

        if persisted?.generation == record.generation,
           persisted?.manual == false,
           sameInstance,
           case .success(let response) = result,
           response.pluginId == plugin.manifest.id,
           response.instanceId == context.instanceID,
           response.manual == false,
           response.consumerId == consumerId,
           response.agentConnected,
           response.businessReady {
            storedManualIntent = false
            lastStatus = response
            lastFailure = nil
            display = .available(response)
            return
        }

        let rollback: HostServiceAgentControlRecord?
        do {
            rollback = try plugin.agentControlStore.compareAndSetManual(
                expectedGeneration: record.generation,
                manual: true
            )
        } catch {
            rollback = nil
        }
        guard actionToken == token else { return }
        if rollback?.generation == record.generation {
            storedManualIntent = true
            lastStatus = nil
            lastFailure = nil
            display = .failed("切换未确认，已恢复为你操作")
        } else {
            reloadPersistedManual()
            lastStatus = nil
            display = .failed("控制权已更新，请重新检查。")
        }
    }

    private func returnToManual() async {
        let record: HostServiceAgentControlRecord
        do {
            record = try plugin.agentControlStore.setManual(true)
        } catch {
            display = .failed("无法保存手动状态，请检查本地存储后重试。")
            notify()
            return
        }

        invalidateRefresh()
        activeAction?.cancel()
        storedManualIntent = true
        isSubmitting = true
        activePrimaryAction = .revoke
        let token = UUID()
        actionToken = token
        notify()

        let requestedContext = plugin.agentRuntimeContext()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var accepted = false
            if let context = requestedContext {
                if case .success(let response) = await self.rpcClient.request(
                    .revoke,
                    context: context,
                    generation: record.generation,
                    consumerId: nil
                ),
                response.pluginId == self.plugin.manifest.id,
                response.instanceId == context.instanceID,
                response.manual {
                    accepted = true
                    await self.applyRevokeResult(
                        response,
                        token: token,
                        record: record,
                        context: context
                    )
                }
            }
            if !accepted {
                await self.applyOfflineRevoke(
                    token: token,
                    record: record,
                    instanceID: requestedContext?.instanceID
                )
            }
        }
        activeAction = task
        await task.value
    }

    private func applyRevokeResult(
        _ status: HostServiceAgentStatus,
        token: UUID,
        record: HostServiceAgentControlRecord,
        context: HostServiceAgentRuntimeContext
    ) async {
        guard actionToken == token else { return }
        defer { clearAction(token: token) }
        reloadPersistedManual()
        guard (try? plugin.agentControlStore.reload())?.generation == record.generation else {
            return
        }
        guard plugin.agentRuntimeContext()?.instanceID == context.instanceID else {
            lastStatus = nil
            display = .failed("已切回手动；运行实例已改变，请重新检查连接。")
            return
        }
        storedManualIntent = true
        lastStatus = status
        lastFailure = nil
        display = .available(status)
    }

    private func applyOfflineRevoke(
        token: UUID,
        record: HostServiceAgentControlRecord,
        instanceID: UUID?
    ) async {
        guard actionToken == token else { return }
        defer { clearAction(token: token) }
        reloadPersistedManual()
        guard
              let persisted = try? plugin.agentControlStore.reload(),
              persisted.generation == record.generation,
              persisted.manual else {
            return
        }
        storedManualIntent = true
        lastStatus = nil
        lastFailure = .unavailable
        display = .failed("已切回手动；插件当前离线，连接时会按手动模式运行。")
    }

    private func clearAction(token: UUID) {
        guard actionToken == token else { return }
        isSubmitting = false
        activePrimaryAction = nil
        activeAction = nil
        actionToken = nil
        notify()
    }

    #if DEBUG
    func applyGrantResultForTesting(
        _ result: Result<HostServiceAgentStatus, HostServiceAgentFailure>,
        token: UUID,
        record: HostServiceAgentControlRecord,
        context: HostServiceAgentRuntimeContext,
        consumerId: UUID
    ) async {
        await applyGrantResult(
            result,
            token: token,
            record: record,
            context: context,
            consumerId: consumerId
        )
    }
    #endif

    private func runRequest(
        showLoading: Bool,
        method: HostServiceAgentControlMethod
    ) async {
        guard viewIsLoaded,
              activeRefresh == nil,
              activeAction == nil,
              !isSubmitting,
              let intent = try? plugin.agentControlStore.loadOrCreate(),
              let context = plugin.agentRuntimeContext() else {
            if viewIsLoaded, activeRefresh == nil, activeAction == nil, !isSubmitting {
                if plugin.agentRuntimeContext() == nil {
                    awaitsRuntimeContextRefresh = true
                    lastFailure = .unavailable
                }
                display = .failed(HostServiceAgentFailure.unavailable.userMessage)
                notify()
            }
            return
        }

        awaitsRuntimeContextRefresh = false
        requestSequence &+= 1
        let sequence = requestSequence
        activeInstanceID = context.instanceID
        if showLoading { display = .loading }
        isRefreshing = true
        notify()

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.rpcClient.request(
                method,
                context: context,
                generation: nil,
                consumerId: nil
            )
            guard self.requestSequence == sequence,
                  (try? self.plugin.agentControlStore.reload()) == intent else {
                self.reloadPersistedManual()
                if self.requestSequence == sequence {
                    self.invalidateRefresh()
                    self.lastStatus = nil
                    self.display = .failed("控制权已更新，请重新检查。")
                    self.notify()
                }
                return
            }
            let gate = Self.ResponseGate(
                loaded: self.viewIsLoaded,
                requestGeneration: sequence,
                currentGeneration: self.requestSequence,
                requestedInstanceID: context.instanceID,
                currentInstanceID: self.activeInstanceID
            )
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let status):
                guard gate.accepts(status, pluginID: self.plugin.manifest.id) else {
                    if gate.acceptsCurrentAttempt(
                        pluginID: self.plugin.manifest.id,
                        instanceID: context.instanceID
                    ) {
                        self.display = .failed("插件返回了无法确认的结果，请稍后重试。")
                    } else {
                        return
                    }
                    break
                }
                self.lastStatus = status
                self.lastFailure = nil
                self.display = .available(status)
            case .failure(let failure):
                guard gate.acceptsCurrentAttempt(
                    pluginID: self.plugin.manifest.id,
                    instanceID: context.instanceID
                ) else {
                    return
                }
                guard failure != .stale else { break }
                self.lastFailure = failure
                self.display = .failed(Self.message(for: failure))
                if failure == .busy, self.storedManualIntent {
                    self.lastStatus = nil
                }
            }
            if self.requestSequence == sequence,
               self.activeInstanceID == context.instanceID {
                self.isRefreshing = false
                self.activeRefresh = nil
                self.activeInstanceID = nil
            }
            self.notify()
        }
        activeRefresh = task
        await task.value
        if requestSequence == sequence,
           activeInstanceID == context.instanceID {
            activeRefresh = nil
            isRefreshing = false
        }
    }

    private var rawStatus: HostServiceAgentStatus? {
        candidateStatus
    }

    private var candidateStatus: HostServiceAgentStatus? {
        if let status {
            return status
        }
        guard let lastStatus,
              plugin.agentRuntimeContext()?.instanceID == lastStatus.instanceId else {
            return nil
        }
        return lastStatus
    }

    private var effectiveManualIntent: Bool {
        return storedManualIntent
    }

    private func notify() {
        onDisplayChanged?(display)
    }

    struct ResponseGate: Equatable {
        let loaded: Bool
        let requestGeneration: UInt64
        let currentGeneration: UInt64
        let requestedInstanceID: UUID
        let currentInstanceID: UUID?

        func accepts(_ status: HostServiceAgentStatus, pluginID: String) -> Bool {
            loaded
                && requestGeneration == currentGeneration
                && requestedInstanceID == currentInstanceID
                && status.pluginId == pluginID
                && status.instanceId == requestedInstanceID
        }

        func acceptsCurrentAttempt(
            pluginID: String,
            instanceID: UUID
        ) -> Bool {
            loaded
                && requestGeneration == currentGeneration
                && requestedInstanceID == currentInstanceID
                && requestedInstanceID == instanceID
                && !pluginID.isEmpty
        }
    }

    private static func message(for failure: HostServiceAgentFailure) -> String {
        switch failure {
        case .server(.recoveryRequired):
            return "App 正在恢复；默认保持手动。"
        case .server(.loginRequired):
            return "需要先在 App 内登录；默认保持手动。"
        default:
            return failure.userMessage
        }
    }

    private static func statusText(
        for status: HostServiceAgentStatus,
        effectiveManual: Bool
    ) -> String {
        if let errorCode = status.errorCode {
            switch errorCode {
            case .loginRequired:
                return "需要先登录"
            case .recoveryRequired:
                return "正在恢复连接"
            case .businessNotReady:
                return "等待业务就绪"
            case .agentNotConnected, .consumerUnavailable:
                return "等待 Agent 接入"
            case .approvalRequired:
                return "等待你确认"
            case .manualMode:
                return effectiveManual ? "由你操作" : "托管已暂停"
            case .invalidRequest, .permissionDenied, .internalFailure:
                return "需要处理连接"
            }
        }
        if status.state == .needsAttention {
            return "需要处理连接"
        }
        if status.state == .waitingForLogin {
            return "需要先登录"
        }
        if status.state == .recovering {
            return "正在恢复连接"
        }
        if status.state == .waitingForApproval {
            return effectiveManual ? "等待你确认" : "托管已暂停"
        }
        if status.manual && !effectiveManual { return "托管已暂停" }
        if !status.agentConnected {
            return "等待 Agent 接入"
        }
        if !status.businessReady {
            return "业务尚未就绪"
        }
        if status.taskRunning || status.state == .running {
            return effectiveManual ? "已接回，正在收尾" : "Agent 正在处理"
        }
        if effectiveManual {
            return "由你操作"
        }
        return "Agent 已托管"
    }

    private static func detailText(
        for status: HostServiceAgentStatus,
        effectiveManual: Bool
    ) -> String {
        if !effectiveManual && (status.manual || !status.businessReady
            || status.errorCode != nil || [.waitingForLogin, .recovering, .waitingForApproval].contains(status.state)) {
            return "托管已暂停；先点「我来操作」，处理登录或页面状态后，再测试并重新授权。"
        }
        if status.state == .waitingForLogin || status.errorCode == .loginRequired {
            return "在 App 内完成登录后点「测试连接」。"
        }
        if status.state == .recovering || status.errorCode == .recoveryRequired {
            return "App 正在恢复，完成后再点「测试连接」。"
        }
        if status.state == .needsAttention || status.errorCode != nil {
            return "连接需要处理；点「我来操作」可立即保存手动状态。"
        }
        if !status.agentConnected {
            return "把接入说明发给自己的 Agent，由它完成连接。"
        }
        if !status.businessReady {
            return "点「测试连接」确认插件的只读连接是否可用。"
        }
        if status.taskRunning || status.state == .running {
            if effectiveManual { return "已停止新增操作，正在完成在途核验。" }
            return "Agent 正在处理只读检查；点「我来操作」可立即接回，后续步骤由你决定。"
        }
        if effectiveManual {
            return "只读检查已就绪，点「交给 Agent」后开始；可随时接回。"
        }
        return "Agent 已托管只读检查；点「我来操作」可随时接回。"
    }
}

@MainActor
final class PluginKeepAwakeView: TFCardView {
    private let titleLabel = NSTextField(labelWithString: "后台保持唤醒")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let scopeLabel = NSTextField(wrappingLabelWithString: "此插件使用当前 Android 环境的防冻结策略，同一环境内的其他应用也会受影响。")
    private let toggle = TFToggleSwitch(isOn: false)
    private let retry = TFButton(title: "重试", variant: .secondary, size: .sm)
    private let controls = NSStackView()
    private var status: OfficeKeepAwakeStatus = .off
    private var onToggle: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        identifier = NSUserInterfaceItemIdentifier("plugin-keep-awake-settings")
        cornerRadius = 12
        hasCardShadow = true
        for label in [titleLabel, detailLabel, scopeLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        titleLabel.font = .systemFont(ofSize: 13.5, weight: .medium)
        detailLabel.font = .systemFont(ofSize: 12)
        scopeLabel.font = .systemFont(ofSize: 11.5)
        for label in [detailLabel, scopeLabel] {
            label.maximumNumberOfLines = 0
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.addArrangedSubview(retry)
        controls.addArrangedSubview(toggle)
        addSubview(controls)
        toggle.identifier = NSUserInterfaceItemIdentifier("plugin-keep-awake-toggle")
        toggle.setAccessibilityLabel("插件后台保持唤醒")
        toggle.onToggle = { [weak self] in self?.onToggle?($0) }
        retry.identifier = NSUserInterfaceItemIdentifier("plugin-keep-awake-retry")
        retry.setAccessibilityLabel("重试插件保持唤醒设置")
        retry.onClick = { [weak self] in
            guard let self else { return }
            self.onToggle?(self.status.enabled)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor, constant: -12),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            controls.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            scopeLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            scopeLabel.trailingAnchor.constraint(equalTo: detailLabel.trailingAnchor),
            scopeLabel.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 6),
            scopeLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18)
        ])
        update(status: .off, runtimeBusy: false, onToggle: { _ in })
        refreshTheme()
    }

    required init?(coder: NSCoder) { nil }

    func update(status: OfficeKeepAwakeStatus, runtimeBusy: Bool, onToggle: @escaping (Bool) -> Void) {
        self.status = status
        self.onToggle = onToggle
        toggle.isOn = status.enabled
        toggle.isEnabled = !runtimeBusy && status.phase != .applying
        retry.isHidden = status.phase != .failed
        retry.isEnabled = toggle.isEnabled
        detailLabel.stringValue = status.detail
    }

    func refreshTheme() {
        fillColor = TFTheme.card
        strokeColor = TFTheme.line
        titleLabel.textColor = TFTheme.ink
        detailLabel.textColor = TFTheme.ink2
        scopeLabel.textColor = TFTheme.ink3
        retry.refreshColors()
    }
}

@MainActor
final class HostServiceAgentWorkspaceView: NSView {
    let controller: HostServiceAgentWorkspaceController
    let pluginIdentity: ObjectIdentifier

    private let card = TFCardView(frame: .zero)
    private let primaryButton = TFButton(
        title: "等待就绪",
        variant: .secondary,
        size: .sm
    )
    private let testButton = TFButton(
        title: "测试连接",
        variant: .secondary,
        size: .sm
    )
    private let exportButton = TFButton(
        title: "复制给 Agent",
        variant: .subtle,
        size: .sm
    )
    private let statusLabel = NSTextField(labelWithString: "正在检查连接")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let scopeLabel = NSTextField(wrappingLabelWithString: "")
    private let workflowLabel = NSTextField(wrappingLabelWithString: "")
    private let recentLabel = NSTextField(labelWithString: "暂无成功记录")
    private let pillHost = NSView()
    private let actionStack = NSStackView()
    private let badge: TFIconBadgeView
    private let suppressesAutomaticRefresh: Bool
    private let keepAwakeView: PluginKeepAwakeView?
    private var copyConfirmationLabel: NSTextField?
    private var copyConfirmationDismissTask: Task<Void, Never>?

    init(
        plugin: HostServiceSystemPlugin,
        testStatus: HostServiceAgentStatus? = nil,
        testFailure: String? = nil,
        suppressesAutomaticRefresh: Bool = false
    ) {
        controller = HostServiceAgentWorkspaceController(plugin: plugin)
        pluginIdentity = ObjectIdentifier(plugin)
        self.suppressesAutomaticRefresh = suppressesAutomaticRefresh
        keepAwakeView = plugin.manifest.supportsKeepAwakeControl ? PluginKeepAwakeView() : nil
        badge = TFIconBadgeView(
            symbol: "person.crop.circle.badge.checkmark",
            accentHex: 0x0F766E,
            size: 38,
            cornerRadius: 10
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        controller.onDisplayChanged = { [weak self] _ in
            self?.render()
        }
        #if DEBUG
        if let testStatus {
            controller.ingestStatusForTesting(testStatus)
        } else if let testFailure {
            controller.ingestFailureForTesting(
                testFailure,
                persistedManual: false
            )
        } else {
            controller.viewDidLoad()
        }
        #else
        controller.viewDidLoad()
        #endif
    }

    deinit {
        copyConfirmationDismissTask?.cancel()
    }

    #if DEBUG
    convenience init(
        testingWith plugin: HostServiceSystemPlugin,
        status: HostServiceAgentStatus
    ) {
        self.init(
            plugin: plugin,
            testStatus: status,
            testFailure: nil,
            suppressesAutomaticRefresh: true
        )
    }

    convenience init(
        testingWith plugin: HostServiceSystemPlugin,
        failure: String
    ) {
        self.init(
            plugin: plugin,
            testStatus: nil,
            testFailure: failure,
            suppressesAutomaticRefresh: true
        )
    }

    func showCopyConfirmationForTesting() {
        showCopyConfirmation()
    }
    #endif

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            copyConfirmationDismissTask?.cancel()
            copyConfirmationDismissTask = nil
            copyConfirmationLabel?.removeFromSuperview()
            copyConfirmationLabel = nil
            controller.viewDidUnload()
        } else if superview != nil, !suppressesAutomaticRefresh {
            controller.viewDidLoad()
        }
    }

    override func layout() {
        let compact = bounds.width < 560
        let orientation: NSUserInterfaceLayoutOrientation = compact ? .vertical : .horizontal
        if actionStack.orientation != orientation {
            actionStack.orientation = orientation
        }
        actionStack.alignment = compact ? .leading : .centerY
        actionStack.spacing = 8
        super.layout()
    }

    func updateKeepAwake(status: OfficeKeepAwakeStatus, runtimeBusy: Bool, onToggle: @escaping (Bool) -> Void) {
        keepAwakeView?.update(status: status, runtimeBusy: runtimeBusy, onToggle: onToggle)
    }

    func refreshTheme() {
        keepAwakeView?.refreshTheme()
        statusLabel.textColor = TFTheme.ink
        detailLabel.textColor = TFTheme.ink2
        scopeLabel.textColor = TFTheme.ink2
        workflowLabel.textColor = TFTheme.ink3
        recentLabel.textColor = TFTheme.ink3
        copyConfirmationLabel?.textColor = TFTheme.positive
        renderPill()
    }

    private func build() {
        card.identifier = NSUserInterfaceItemIdentifier("agent-workspace-card")
        card.translatesAutoresizingMaskIntoConstraints = false
        card.cornerRadius = 12
        card.fillColor = TFTheme.card
        card.strokeColor = TFTheme.line
        card.hasCardShadow = true
        addSubview(card)

        statusLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        statusLabel.textColor = TFTheme.ink
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setAccessibilityLabel("Agent 只读托管状态")
        statusLabel.identifier = NSUserInterfaceItemIdentifier("agent-status")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        pillHost.translatesAutoresizingMaskIntoConstraints = false
        pillHost.setContentHuggingPriority(.required, for: .horizontal)
        pillHost.setContentCompressionResistancePriority(.required, for: .horizontal)

        let header = NSStackView(views: [badge, statusLabel, spacer, pillHost])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(header)

        detailLabel.font = .systemFont(ofSize: 12.5, weight: .regular)
        detailLabel.textColor = TFTheme.ink2
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 2
        detailLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        detailLabel.setAccessibilityLabel("下一步")
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(detailLabel)

        scopeLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        scopeLabel.textColor = TFTheme.ink2
        scopeLabel.lineBreakMode = .byTruncatingTail
        scopeLabel.setAccessibilityLabel(controller.scopeText)
        scopeLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(scopeLabel)

        workflowLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        workflowLabel.textColor = TFTheme.ink3
        workflowLabel.lineBreakMode = .byWordWrapping
        workflowLabel.maximumNumberOfLines = 2
        workflowLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        workflowLabel.setAccessibilityLabel("接入步骤")
        workflowLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(workflowLabel)

        recentLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        recentLabel.textColor = TFTheme.ink3
        recentLabel.translatesAutoresizingMaskIntoConstraints = false
        recentLabel.setAccessibilityLabel("最近成功记录")
        card.addSubview(recentLabel)

        primaryButton.identifier = NSUserInterfaceItemIdentifier("agent-primary-action")
        primaryButton.onClick = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.controller.performPrimaryAction()
            }
        }

        testButton.identifier = NSUserInterfaceItemIdentifier("agent-test-connection")
        testButton.setAccessibilityLabel("测试只读连接")
        testButton.onClick = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.controller.testConnection()
            }
        }

        exportButton.identifier = NSUserInterfaceItemIdentifier("agent-copy-configuration")
        exportButton.setAccessibilityLabel("复制插件接入说明给 Agent")
        exportButton.onClick = { [weak self] in
            self?.copyConfiguration()
        }

        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = 8
        actionStack.addArrangedSubview(primaryButton)
        actionStack.addArrangedSubview(testButton)
        actionStack.addArrangedSubview(exportButton)
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(actionStack)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),

            header.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            header.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),

            detailLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 7),

            scopeLabel.leadingAnchor.constraint(equalTo: detailLabel.leadingAnchor),
            scopeLabel.trailingAnchor.constraint(equalTo: detailLabel.trailingAnchor),
            scopeLabel.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 8),

            workflowLabel.leadingAnchor.constraint(equalTo: detailLabel.leadingAnchor),
            workflowLabel.trailingAnchor.constraint(equalTo: detailLabel.trailingAnchor),
            workflowLabel.topAnchor.constraint(equalTo: scopeLabel.bottomAnchor, constant: 5),

            recentLabel.leadingAnchor.constraint(equalTo: detailLabel.leadingAnchor),
            recentLabel.trailingAnchor.constraint(equalTo: detailLabel.trailingAnchor),
            recentLabel.topAnchor.constraint(equalTo: workflowLabel.bottomAnchor, constant: 7),

            actionStack.leadingAnchor.constraint(equalTo: detailLabel.leadingAnchor),
            actionStack.trailingAnchor.constraint(lessThanOrEqualTo: detailLabel.trailingAnchor),
            actionStack.topAnchor.constraint(equalTo: recentLabel.bottomAnchor, constant: 14),
            actionStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),

            pillHost.heightAnchor.constraint(equalToConstant: 20),
            pillHost.widthAnchor.constraint(greaterThanOrEqualToConstant: 64)
        ])
        if let keepAwakeView {
            addSubview(keepAwakeView)
            NSLayoutConstraint.activate([
                keepAwakeView.leadingAnchor.constraint(equalTo: leadingAnchor),
                keepAwakeView.trailingAnchor.constraint(equalTo: trailingAnchor),
                keepAwakeView.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 14),
                keepAwakeView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        } else {
            card.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
        }
        render()
    }

    private func render() {
        statusLabel.stringValue = controller.statusText
        detailLabel.stringValue = controller.detailText
        scopeLabel.stringValue = controller.scopeText
        workflowLabel.stringValue = controller.workflowText
        recentLabel.stringValue = controller.lastSuccessText
        renderPill()

        primaryButton.title = controller.primaryActionTitle
        primaryButton.variant = controller.primaryAction == .grant ? .primary : .secondary
        primaryButton.isEnabled = controller.primaryAction != nil
        primaryButton.setAccessibilityLabel(accessiblePrimaryActionLabel)
        primaryButton.toolTip = controller.primaryAction == .revoke
            ? "立即切回手动；即使连接离线也会保存"
            : nil

        testButton.isEnabled = controller.canTestConnection
        testButton.isHidden = controller.usesCopyTokenAuthorization
        primaryButton.isHidden = controller.usesCopyTokenAuthorization && controller.primaryAction == nil
        testButton.title = controller.isPreparing ? "正在测试…" : "测试连接"
        exportButton.isEnabled = controller.canExportConfiguration
        exportButton.variant = controller.usesCopyTokenAuthorization ? .primary : .subtle
        exportButton.toolTip = controller.usesCopyTokenAuthorization
            ? "复制即授予只读访问；重新复制会使旧接入凭据失效" : nil

        if case .failed(let message) = controller.display {
            statusLabel.textColor = TFTheme.danger
            statusLabel.toolTip = message
        } else {
            statusLabel.textColor = TFTheme.ink
            statusLabel.toolTip = nil
        }
    }

    private var accessiblePrimaryActionLabel: String {
        if controller.isSubmitting {
            return controller.primaryActionTitle
        }
        switch controller.primaryAction {
        case .grant:
            return "交给 Agent"
        case .revoke:
            return "我来操作，切回手动"
        case nil:
            return "当前无可执行操作"
        }
    }

    private func renderPill() {
        pillHost.subviews.forEach { $0.removeFromSuperview() }
        let needsAttention: Bool = {
            if let status = controller.status {
                return status.state == .needsAttention
            }
            return false
        }()
        let tone: Tone
        if needsAttention {
            tone = .danger
        } else if controller.showsAgentManaged {
            tone = .positive
        } else {
            tone = .neutral
        }
        let pill = Self.makePill(text: controller.handoffPillText, tone: tone)
        pillHost.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: pillHost.leadingAnchor),
            pill.trailingAnchor.constraint(equalTo: pillHost.trailingAnchor),
            pill.topAnchor.constraint(equalTo: pillHost.topAnchor),
            pill.bottomAnchor.constraint(equalTo: pillHost.bottomAnchor)
        ])
    }

    private func copyConfiguration() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.controller.copyAgentHandoff()
                self.showCopyConfirmation()
            } catch {
                self.showCopyFailure()
            }
        }
    }

    private func showCopyConfirmation() {
        copyConfirmationDismissTask?.cancel()
        copyConfirmationLabel?.removeFromSuperview()

        let confirmation = NSTextField(labelWithString: "已复制，发给你的 Agent")
        confirmation.identifier = NSUserInterfaceItemIdentifier("agent-copy-confirmation")
        confirmation.font = .systemFont(ofSize: 11.5, weight: .medium)
        confirmation.textColor = TFTheme.positive
        confirmation.lineBreakMode = .byTruncatingTail
        confirmation.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(confirmation)
        NSLayoutConstraint.activate([
            confirmation.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            confirmation.topAnchor.constraint(equalTo: card.topAnchor, constant: 2)
        ])
        copyConfirmationLabel = confirmation
        copyConfirmationDismissTask = Task { @MainActor [weak self, weak confirmation] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            confirmation?.removeFromSuperview()
            if self?.copyConfirmationLabel === confirmation {
                self?.copyConfirmationLabel = nil
            }
        }
    }

    private func showCopyFailure() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法准备接入说明"
        alert.informativeText = "请确认插件、签名和当前实例仍然有效后重试。"
        alert.addButton(withTitle: "好")
        guard let window else {
            alert.runModal()
            return
        }
        alert.beginSheetModal(for: window)
    }

    private enum Tone {
        case positive
        case danger
        case neutral
    }

    private static func makePill(text: String, tone: Tone) -> NSView {
        let pill = TFCardView(frame: .zero)
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.cornerRadius = 6

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)

        switch tone {
        case .positive:
            pill.fillColor = TFTheme.positiveSoft
            label.textColor = TFTheme.positive
        case .danger:
            pill.fillColor = TFTheme.dangerSoft
            label.textColor = TFTheme.danger
        case .neutral:
            pill.fillColor = TFTheme.card2
            label.textColor = TFTheme.ink2
        }

        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor)
        ])
        return pill
    }
}
