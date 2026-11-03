import AppKit
import Foundation

struct AssistantRemoteTaskItem: Equatable {
    let taskId: String
    let status: String
    let goal: String
    let conversation: String
    let step: Int?
    let progress: String?
    let question: String?
    let answer: String?
    let reason: String?
    let note: String?

    init?(dictionary: [String: Any]) {
        guard let taskId = dictionary["task_id"] as? String,
              let status = dictionary["status"] as? String,
              let goal = dictionary["goal"] as? String else {
            return nil
        }
        self.taskId = taskId
        self.status = status
        self.goal = goal
        self.conversation = (dictionary["conversation"] as? String) ?? ""
        self.step = dictionary["step"] as? Int
        self.progress = dictionary["progress"] as? String
        self.question = dictionary["question"] as? String
        self.answer = dictionary["answer"] as? String
        self.reason = dictionary["reason"] as? String
        self.note = dictionary["note"] as? String
    }

    var isFinished: Bool {
        status == "done" || status == "failed" || status == "cancelled"
    }

    var statusLabel: String {
        switch status {
        case "starting": return "启动中"
        case "running": return "执行中"
        case "queued": return "排队中"
        case "paused": return "已暂停"
        case "waiting_for_answer": return "等待回答"
        case "waiting_on_phone": return "需人工确认"
        case "done": return "已完成"
        case "failed": return "未完成"
        case "cancelled": return "已停止"
        default: return status
        }
    }

    var statusSummary: String {
        if let question, !question.isEmpty {
            return "提问：\(question)"
        }
        if let answer, !answer.isEmpty {
            return answer
        }
        if let reason, !reason.isEmpty {
            return reason
        }
        if let progress, !progress.isEmpty {
            if let step {
                return "第 \(step) 步 · \(progress)"
            }
            return progress
        }
        if let note, !note.isEmpty {
            return note
        }
        if let step {
            return "第 \(step) 步执行中…"
        }
        return statusLabel
    }
}

@MainActor
final class AssistantPluginWorkspaceView: NSView, NSTextFieldDelegate {
    private(set) var plugin: HostServiceSystemPlugin
    var pluginIdentity: ObjectIdentifier { ObjectIdentifier(plugin) }

    private let rootStack = NSStackView()

    // Status header card
    private let statusCard = TFCardView(frame: .zero)
    private let statusTitleLabel = NSTextField(labelWithString: "系统会话通道")
    private let statusDetailLabel = NSTextField(labelWithString: "正在连接插件服务…")
    private let statusBadgeCard = TFCardView(frame: .zero)
    private let statusBadgeLabel = NSTextField(labelWithString: "连接中")
    private var refreshButton: TFButton!

    // Model configuration card
    private let modelCard = TFCardView(frame: .zero)
    private let modelHeading = NSTextField(labelWithString: "模型设置")
    private let modelHint = NSTextField(wrappingLabelWithString: "通过本机 Magpie 网关自动接入，模型与凭据由 Magpie 统一管理。")
    private let modelPopupButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let reasoningLabel = NSTextField(labelWithString: "思考等级")
    private let reasoningPopupButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelStatusLabel = NSTextField(labelWithString: "正在连接 Magpie…")
    private var modelChoices: [(id: String, name: String, efforts: [String])] = []
    private var effortChoices: [String] = []
    private var lastAppliedModelID = ""
    private var lastAppliedEffort = ""
    private var isApplyingModelConfig = false
    private var isSavingModel = false
    private var isSavingEffort = false

    // Main two-column split
    private let columnsStack = NSStackView()

    // Left column: Task composer, active task, history
    private let taskCard = TFCardView(frame: .zero)
    private let composerHeading = NSTextField(labelWithString: "下发任务")
    private let composerSubheading = NSTextField(labelWithString: "在独立后台显示上以标准输入操作目标应用，不打断当前前台窗口")
    private let goalInputField = NSTextField(frame: .zero)
    private var runTaskButton: TFButton!

    private let activeTaskBox = TFCardView(frame: .zero)
    private let activeTaskTitle = NSTextField(labelWithString: "当前任务")
    private let activeTaskBadge = NSTextField(labelWithString: "空闲")
    private let activeTaskGoalLabel = NSTextField(wrappingLabelWithString: "尚未发起任务")
    private let activeTaskDetailLabel = NSTextField(wrappingLabelWithString: "输入一句话目标后点击「执行」，例如：「给微信文件传输助手发送：测试消息」。")
    private let followUpStack = NSStackView()
    private let followUpField = NSTextField(frame: .zero)
    private var followUpSendButton: TFButton!
    private var cancelTaskButton: TFButton!

    private let historyHeading = NSTextField(labelWithString: "近期任务")
    private let historyStack = NSStackView()

    // Right column: Background display live observer
    private let observerCard = TFCardView(frame: .zero)
    private let observerTitle = NSTextField(labelWithString: "后台显示观察窗")
    private let observerBadgeLabel = NSTextField(labelWithString: "后台屏空闲")
    private let previewContainer = TFCardView(frame: .zero)
    private let previewImageView = NSImageView(frame: .zero)
    private let previewEmptyLabel = NSTextField(wrappingLabelWithString: "后台虚拟显示（macdora-background）当前空闲。\n当任务启动微信或其他应用时，将在此实时显示操作画面，不抢占主屏焦点。")
    private var togglePreviewButton: TFButton!

    private var pollTimer: Timer?
    private var isPolling = false
    private var isPreviewEnabled = true
    private var currentTasks: [AssistantRemoteTaskItem] = []
    private var selectedConversation: String?

    override var isFlipped: Bool { true }

    init(plugin: HostServiceSystemPlugin) {
        self.plugin = plugin
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI()
        refreshTheme()
        triggerPoll()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        pollTimer?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startPolling()
        } else {
            stopPolling()
        }
    }

    func bindPlugin(_ newPlugin: HostServiceSystemPlugin) {
        guard plugin !== newPlugin else {
            refreshTheme()
            triggerPoll()
            return
        }
        plugin = newPlugin
        refreshTheme()
        triggerPoll()
    }

    private func startPolling() {
        stopPolling()
        triggerPoll()
        if isPreviewEnabled {
            startPreviewDisplay()
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.triggerPoll()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func startPreviewDisplay() {
        guard let socketURL = plugin.activeSocketURL() else { return }
        Task { @MainActor in
            if let snap = try? await HostServiceHealthClient.performRPC(
                socketURL: socketURL,
                method: "mika.display.start",
                timeout: 20
            ) {
                self.applyDisplaySnapshot(snap)
            }
        }
    }

    private func buildUI() {
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 14
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        buildStatusCard()
        buildModelCard()
        buildMainColumns()
    }

    private func buildStatusCard() {
        statusCard.translatesAutoresizingMaskIntoConstraints = false
        statusCard.cornerRadius = 12
        statusCard.hasCardShadow = true

        statusTitleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        statusTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        statusBadgeCard.translatesAutoresizingMaskIntoConstraints = false
        statusBadgeCard.cornerRadius = 6
        statusBadgeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        statusBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        statusBadgeCard.addSubview(statusBadgeLabel)

        statusDetailLabel.font = .systemFont(ofSize: 12)
        statusDetailLabel.lineBreakMode = .byTruncatingTail
        statusDetailLabel.translatesAutoresizingMaskIntoConstraints = false

        refreshButton = TFButton(title: "刷新", symbolName: "arrow.clockwise", variant: .ghost, size: .sm)
        refreshButton.onClick = { [weak self] in
            self?.triggerPoll()
        }

        let buttonRow = NSStackView(views: [refreshButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        statusCard.addSubview(statusTitleLabel)
        statusCard.addSubview(statusBadgeCard)
        statusCard.addSubview(statusDetailLabel)
        statusCard.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            statusBadgeLabel.leadingAnchor.constraint(equalTo: statusBadgeCard.leadingAnchor, constant: 8),
            statusBadgeLabel.trailingAnchor.constraint(equalTo: statusBadgeCard.trailingAnchor, constant: -8),
            statusBadgeLabel.topAnchor.constraint(equalTo: statusBadgeCard.topAnchor, constant: 3),
            statusBadgeLabel.bottomAnchor.constraint(equalTo: statusBadgeCard.bottomAnchor, constant: -3),

            statusTitleLabel.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor, constant: 16),
            statusTitleLabel.topAnchor.constraint(equalTo: statusCard.topAnchor, constant: 14),

            statusBadgeCard.leadingAnchor.constraint(equalTo: statusTitleLabel.trailingAnchor, constant: 8),
            statusBadgeCard.centerYAnchor.constraint(equalTo: statusTitleLabel.centerYAnchor),

            statusDetailLabel.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor, constant: 16),
            statusDetailLabel.topAnchor.constraint(equalTo: statusTitleLabel.bottomAnchor, constant: 4),
            statusDetailLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttonRow.leadingAnchor, constant: -12),
            statusDetailLabel.bottomAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: -14),

            buttonRow.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor, constant: -16),
            buttonRow.centerYAnchor.constraint(equalTo: statusCard.centerYAnchor)
        ])

        rootStack.addArrangedSubview(statusCard)
        statusCard.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
    }

    private func buildModelCard() {
        modelCard.translatesAutoresizingMaskIntoConstraints = false
        modelCard.cornerRadius = 12
        modelCard.strokeColor = TFTheme.line

        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 8
        inner.translatesAutoresizingMaskIntoConstraints = false
        modelCard.addSubview(inner)

        modelHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        modelHint.font = .systemFont(ofSize: 11)

        modelPopupButton.font = .systemFont(ofSize: 12)
        modelPopupButton.controlSize = .small
        modelPopupButton.translatesAutoresizingMaskIntoConstraints = false
        modelPopupButton.target = self
        modelPopupButton.action = #selector(modelSelectionChanged(_:))
        modelPopupButton.isEnabled = false

        reasoningLabel.font = .systemFont(ofSize: 12)
        reasoningPopupButton.font = .systemFont(ofSize: 12)
        reasoningPopupButton.controlSize = .small
        reasoningPopupButton.translatesAutoresizingMaskIntoConstraints = false
        reasoningPopupButton.target = self
        reasoningPopupButton.action = #selector(reasoningSelectionChanged(_:))
        reasoningPopupButton.isEnabled = false

        let reasoningRow = NSStackView(views: [reasoningLabel, reasoningPopupButton])
        reasoningRow.orientation = .horizontal
        reasoningRow.alignment = .centerY
        reasoningRow.spacing = 8
        reasoningRow.translatesAutoresizingMaskIntoConstraints = false

        modelStatusLabel.font = .systemFont(ofSize: 11)
        modelStatusLabel.textColor = TFTheme.warn

        inner.addArrangedSubview(modelHeading)
        inner.addArrangedSubview(modelHint)
        inner.addArrangedSubview(modelPopupButton)
        inner.addArrangedSubview(reasoningRow)
        inner.addArrangedSubview(modelStatusLabel)
        modelPopupButton.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        reasoningRow.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        reasoningPopupButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: modelCard.leadingAnchor, constant: 16),
            inner.trailingAnchor.constraint(equalTo: modelCard.trailingAnchor, constant: -16),
            inner.topAnchor.constraint(equalTo: modelCard.topAnchor, constant: 12),
            inner.bottomAnchor.constraint(equalTo: modelCard.bottomAnchor, constant: -12)
        ])

        rootStack.addArrangedSubview(modelCard)
        modelCard.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
    }

    @objc private func modelSelectionChanged(_ sender: NSPopUpButton) {
        guard !isApplyingModelConfig,
              !isSavingModel,
              !isSavingEffort,
              let modelID = sender.selectedItem?.representedObject as? String,
              !modelID.isEmpty,
              modelID != lastAppliedModelID,
              let socketURL = plugin.activeSocketURL() else {
            return
        }
        isSavingModel = true
        sender.isEnabled = false
        reasoningPopupButton.isEnabled = false
        modelStatusLabel.stringValue = "正在切换模型…"
        modelStatusLabel.textColor = TFTheme.accent
        Task { @MainActor in
            do {
                let result = try await HostServiceHealthClient.performRPC(
                    socketURL: socketURL,
                    method: "mika.config.set",
                    params: ["model": modelID],
                    timeout: 10
                )
                self.isSavingModel = false
                self.applyModelConfig(result)
            } catch {
                self.isSavingModel = false
                self.modelPopupButton.isEnabled = !self.modelChoices.isEmpty
                self.reasoningPopupButton.isEnabled = !self.effortChoices.isEmpty
                self.modelStatusLabel.stringValue = "切换失败：\(error.localizedDescription)"
                self.modelStatusLabel.textColor = TFTheme.warn
            }
        }
    }

    @objc private func reasoningSelectionChanged(_ sender: NSPopUpButton) {
        guard !isApplyingModelConfig,
              !isSavingModel,
              !isSavingEffort,
              let effort = sender.selectedItem?.representedObject as? String,
              effort != lastAppliedEffort,
              let socketURL = plugin.activeSocketURL() else {
            return
        }
        isSavingEffort = true
        sender.isEnabled = false
        modelPopupButton.isEnabled = false
        modelStatusLabel.stringValue = "正在切换思考等级…"
        modelStatusLabel.textColor = TFTheme.accent
        Task { @MainActor in
            do {
                let result = try await HostServiceHealthClient.performRPC(
                    socketURL: socketURL,
                    method: "mika.config.set",
                    params: ["reasoning_effort": effort],
                    timeout: 10
                )
                self.isSavingEffort = false
                self.applyModelConfig(result)
            } catch {
                self.isSavingEffort = false
                self.modelPopupButton.isEnabled = !self.modelChoices.isEmpty
                self.reasoningPopupButton.isEnabled = !self.effortChoices.isEmpty
                self.modelStatusLabel.stringValue = "切换失败：\(error.localizedDescription)"
                self.modelStatusLabel.textColor = TFTheme.warn
            }
        }
    }

    private func reasoningTitle(_ effort: String) -> String {
        switch effort {
        case "none": return "关闭思考"
        case "minimal": return "极低"
        case "low": return "低"
        case "medium": return "中"
        case "high": return "高"
        case "xhigh": return "极高"
        case "max": return "最大"
        case "ultra": return "极致"
        default: return effort
        }
    }

    private func applyModelConfig(_ config: [String: Any]) {
        guard !isSavingModel, !isSavingEffort else { return }
        isApplyingModelConfig = true
        defer { isApplyingModelConfig = false }

        let models = (config["models"] as? [[String: Any]])?.compactMap { item -> (id: String, name: String, efforts: [String])? in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            return (id, (item["name"] as? String) ?? id, (item["reasoning_levels"] as? [String]) ?? [])
        } ?? []
        let selectedModel = (config["model"] as? String) ?? ""
        let selectedEffort = (config["reasoning_effort"] as? String) ?? ""
        let gatewayReady = (config["gateway_ready"] as? Bool) ?? false

        if models.map({ $0.id }) != modelChoices.map({ $0.id })
            || models.map({ $0.efforts }) != modelChoices.map({ $0.efforts }) {
            modelChoices = models
            let menu = NSMenu()
            for choice in models {
                let item = NSMenuItem(title: choice.name, action: nil, keyEquivalent: "")
                item.representedObject = choice.id
                menu.addItem(item)
            }
            modelPopupButton.menu = menu
        }

        let targetModel = selectedModel.isEmpty ? modelChoices.first?.id : selectedModel
        if let targetModel, let index = modelChoices.firstIndex(where: { $0.id == targetModel }) {
            modelPopupButton.selectItem(at: index)
        } else if !modelChoices.isEmpty {
            modelPopupButton.selectItem(at: 0)
        }
        lastAppliedModelID = selectedModel

        let modelEfforts = modelChoices.first(where: { $0.id == selectedModel })?.efforts ?? []
        let effectiveEffort = modelEfforts.contains(selectedEffort) ? selectedEffort : ""
        if effortChoices != modelEfforts {
            effortChoices = modelEfforts
            let menu = NSMenu()
            if modelEfforts.isEmpty {
                let item = NSMenuItem(title: "固定", action: nil, keyEquivalent: "")
                item.representedObject = ""
                menu.addItem(item)
            } else {
                let defaultItem = NSMenuItem(title: "默认", action: nil, keyEquivalent: "")
                defaultItem.representedObject = ""
                menu.addItem(defaultItem)
                for effort in modelEfforts {
                    let item = NSMenuItem(title: reasoningTitle(effort), action: nil, keyEquivalent: "")
                    item.representedObject = effort
                    menu.addItem(item)
                }
            }
            reasoningPopupButton.menu = menu
        }
        if let index = reasoningPopupButton.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == effectiveEffort
        }) {
            reasoningPopupButton.selectItem(at: index)
        }
        lastAppliedEffort = effectiveEffort

        let canAdjust = gatewayReady && !modelChoices.isEmpty
        modelPopupButton.isEnabled = canAdjust
        reasoningPopupButton.isEnabled = canAdjust && !modelEfforts.isEmpty
        if gatewayReady {
            if modelChoices.isEmpty {
                modelStatusLabel.stringValue = "Magpie 已连接 · 没有支持视觉与工具调用的模型"
                modelStatusLabel.textColor = TFTheme.warn
            } else {
                modelStatusLabel.stringValue = "Magpie 已连接 · \(modelChoices.count) 个可用模型"
                modelStatusLabel.textColor = TFTheme.positive
            }
        } else {
            modelStatusLabel.stringValue = "Magpie 网关未连接 · 启动 Magpie 后自动恢复"
            modelStatusLabel.textColor = TFTheme.warn
        }
    }

    private func buildMainColumns() {
        columnsStack.orientation = .horizontal
        columnsStack.alignment = .top
        columnsStack.distribution = .fill
        columnsStack.spacing = 14
        columnsStack.translatesAutoresizingMaskIntoConstraints = false

        buildTaskCard()
        buildObserverCard()

        columnsStack.addArrangedSubview(taskCard)
        columnsStack.addArrangedSubview(observerCard)

        rootStack.addArrangedSubview(columnsStack)
        columnsStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        observerCard.widthAnchor.constraint(equalToConstant: 300).isActive = true
    }

    private func buildTaskCard() {
        taskCard.translatesAutoresizingMaskIntoConstraints = false
        taskCard.cornerRadius = 12
        taskCard.hasCardShadow = true

        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 12
        inner.translatesAutoresizingMaskIntoConstraints = false
        taskCard.addSubview(inner)

        composerHeading.font = .systemFont(ofSize: 14, weight: .semibold)
        composerSubheading.font = .systemFont(ofSize: 12)

        goalInputField.placeholderString = "输入要完成的任务，例如：给微信文件传输助手发消息「下午三点开会」…"
        goalInputField.font = .systemFont(ofSize: 13)
        goalInputField.isBezeled = true
        goalInputField.bezelStyle = .roundedBezel
        goalInputField.delegate = self
        goalInputField.target = self
        goalInputField.action = #selector(goalInputSubmitted(_:))
        goalInputField.translatesAutoresizingMaskIntoConstraints = false

        runTaskButton = TFButton(title: "执行任务", symbolName: "paperplane.fill", variant: .primary, size: .md)
        runTaskButton.onClick = { [weak self] in
            self?.submitNewTask()
        }

        let inputRow = NSStackView(views: [goalInputField, runTaskButton])
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = 8
        inputRow.translatesAutoresizingMaskIntoConstraints = false
        goalInputField.heightAnchor.constraint(equalToConstant: 32).isActive = true

        // Active task card
        activeTaskBox.translatesAutoresizingMaskIntoConstraints = false
        activeTaskBox.cornerRadius = 10
        let activeStack = NSStackView()
        activeStack.orientation = .vertical
        activeStack.alignment = .leading
        activeStack.spacing = 8
        activeStack.translatesAutoresizingMaskIntoConstraints = false
        activeTaskBox.addSubview(activeStack)

        let activeHeader = NSStackView()
        activeHeader.orientation = .horizontal
        activeHeader.alignment = .centerY
        activeHeader.spacing = 8
        activeTaskTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        activeTaskBadge.font = .systemFont(ofSize: 11, weight: .medium)
        cancelTaskButton = TFButton(title: "停止", symbolName: "stop.fill", variant: .danger, size: .sm)
        cancelTaskButton.isHidden = true
        cancelTaskButton.onClick = { [weak self] in
            self?.cancelActiveTask()
        }
        let headerSpacer = NSView()
        activeHeader.addArrangedSubview(activeTaskTitle)
        activeHeader.addArrangedSubview(activeTaskBadge)
        activeHeader.addArrangedSubview(headerSpacer)
        activeHeader.addArrangedSubview(cancelTaskButton)

        activeTaskGoalLabel.font = .systemFont(ofSize: 13, weight: .medium)
        activeTaskGoalLabel.maximumNumberOfLines = 2
        activeTaskDetailLabel.font = .systemFont(ofSize: 12)
        activeTaskDetailLabel.maximumNumberOfLines = 6

        followUpStack.orientation = .horizontal
        followUpStack.alignment = .centerY
        followUpStack.spacing = 8
        followUpStack.isHidden = true
        followUpField.placeholderString = "补充说明或回答提问…"
        followUpField.font = .systemFont(ofSize: 12)
        followUpField.isBezeled = true
        followUpField.bezelStyle = .roundedBezel
        followUpSendButton = TFButton(title: "发送", symbolName: "arrow.up.circle.fill", variant: .secondary, size: .sm)
        followUpSendButton.onClick = { [weak self] in
            self?.submitFollowUp()
        }
        followUpStack.addArrangedSubview(followUpField)
        followUpStack.addArrangedSubview(followUpSendButton)

        activeStack.addArrangedSubview(activeHeader)
        activeStack.addArrangedSubview(activeTaskGoalLabel)
        activeStack.addArrangedSubview(activeTaskDetailLabel)
        activeStack.addArrangedSubview(followUpStack)
        activeHeader.widthAnchor.constraint(equalTo: activeStack.widthAnchor).isActive = true
        followUpStack.widthAnchor.constraint(equalTo: activeStack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            activeStack.leadingAnchor.constraint(equalTo: activeTaskBox.leadingAnchor, constant: 12),
            activeStack.trailingAnchor.constraint(equalTo: activeTaskBox.trailingAnchor, constant: -12),
            activeStack.topAnchor.constraint(equalTo: activeTaskBox.topAnchor, constant: 10),
            activeStack.bottomAnchor.constraint(equalTo: activeTaskBox.bottomAnchor, constant: -10)
        ])

        // History list
        historyHeading.font = .systemFont(ofSize: 12, weight: .semibold)
        historyStack.orientation = .vertical
        historyStack.alignment = .leading
        historyStack.spacing = 6
        historyStack.translatesAutoresizingMaskIntoConstraints = false

        inner.addArrangedSubview(composerHeading)
        inner.addArrangedSubview(composerSubheading)
        inner.addArrangedSubview(inputRow)
        inner.addArrangedSubview(activeTaskBox)
        inner.addArrangedSubview(historyHeading)
        inner.addArrangedSubview(historyStack)

        inputRow.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        activeTaskBox.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        historyStack.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: taskCard.leadingAnchor, constant: 16),
            inner.trailingAnchor.constraint(equalTo: taskCard.trailingAnchor, constant: -16),
            inner.topAnchor.constraint(equalTo: taskCard.topAnchor, constant: 16),
            inner.bottomAnchor.constraint(equalTo: taskCard.bottomAnchor, constant: -16)
        ])
    }

    private func buildObserverCard() {
        observerCard.translatesAutoresizingMaskIntoConstraints = false
        observerCard.cornerRadius = 12
        observerCard.hasCardShadow = true

        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 10
        inner.translatesAutoresizingMaskIntoConstraints = false
        observerCard.addSubview(inner)

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 6
        observerTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        observerBadgeLabel.font = .systemFont(ofSize: 11, weight: .medium)
        let spacer = NSView()
        togglePreviewButton = TFButton(title: "暂停预览", symbolName: "eye", variant: .ghost, size: .sm)
        togglePreviewButton.onClick = { [weak self] in
            guard let self else { return }
            self.isPreviewEnabled.toggle()
            self.togglePreviewButton.title = self.isPreviewEnabled ? "暂停预览" : "开启预览"
            if self.isPreviewEnabled {
                self.startPreviewDisplay()
            } else {
                self.triggerPoll()
            }
        }
        headerRow.addArrangedSubview(observerTitle)
        headerRow.addArrangedSubview(observerBadgeLabel)
        headerRow.addArrangedSubview(spacer)
        headerRow.addArrangedSubview(togglePreviewButton)

        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.cornerRadius = 10

        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.isHidden = true

        previewEmptyLabel.font = .systemFont(ofSize: 12)
        previewEmptyLabel.alignment = .center
        previewEmptyLabel.translatesAutoresizingMaskIntoConstraints = false

        previewContainer.addSubview(previewImageView)
        previewContainer.addSubview(previewEmptyLabel)

        NSLayoutConstraint.activate([
            previewContainer.heightAnchor.constraint(equalToConstant: 420),
            previewImageView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 6),
            previewImageView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -6),
            previewImageView.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 6),
            previewImageView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -6),
            previewEmptyLabel.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 18),
            previewEmptyLabel.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -18),
            previewEmptyLabel.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor)
        ])

        inner.addArrangedSubview(headerRow)
        inner.addArrangedSubview(previewContainer)
        headerRow.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        previewContainer.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: observerCard.leadingAnchor, constant: 14),
            inner.trailingAnchor.constraint(equalTo: observerCard.trailingAnchor, constant: -14),
            inner.topAnchor.constraint(equalTo: observerCard.topAnchor, constant: 14),
            inner.bottomAnchor.constraint(equalTo: observerCard.bottomAnchor, constant: -14)
        ])
    }

    func refreshTheme() {
        statusCard.fillColor = TFTheme.card
        statusCard.strokeColor = TFTheme.line
        statusTitleLabel.textColor = TFTheme.ink
        statusDetailLabel.textColor = TFTheme.ink2

        modelCard.fillColor = TFTheme.card
        modelCard.strokeColor = TFTheme.line
        modelHeading.textColor = TFTheme.ink
        modelHint.textColor = TFTheme.ink3
        reasoningLabel.textColor = TFTheme.ink2

        taskCard.fillColor = TFTheme.card
        taskCard.strokeColor = TFTheme.line
        composerHeading.textColor = TFTheme.ink
        composerSubheading.textColor = TFTheme.ink3

        activeTaskBox.fillColor = TFTheme.card2
        activeTaskBox.strokeColor = TFTheme.line
        activeTaskTitle.textColor = TFTheme.ink2
        activeTaskGoalLabel.textColor = TFTheme.ink
        activeTaskDetailLabel.textColor = TFTheme.ink2
        historyHeading.textColor = TFTheme.ink2

        observerCard.fillColor = TFTheme.card
        observerCard.strokeColor = TFTheme.line
        observerTitle.textColor = TFTheme.ink
        observerBadgeLabel.textColor = TFTheme.ink3
        previewContainer.fillColor = TFTheme.card2
        previewContainer.strokeColor = TFTheme.line
        previewEmptyLabel.textColor = TFTheme.ink3

        refreshButton?.refreshColors()
        runTaskButton?.refreshColors()
        followUpSendButton?.refreshColors()
        cancelTaskButton?.refreshColors()
        togglePreviewButton?.refreshColors()
    }

    @objc private func goalInputSubmitted(_ sender: NSTextField) {
        submitNewTask()
    }

    private func submitNewTask() {
        let goal = goalInputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, let socketURL = plugin.activeSocketURL() else { return }
        goalInputField.stringValue = ""
        runTaskButton.isEnabled = false
        var params: [String: Any] = ["goal": goal]
        if let conv = selectedConversation, !conv.isEmpty {
            params["conversation"] = conv
        }
        Task { @MainActor in
            defer { self.runTaskButton.isEnabled = true }
            do {
                let res = try await HostServiceHealthClient.performRPC(
                    socketURL: socketURL,
                    method: "mika.task.start",
                    params: params,
                    timeout: 20
                )
                if let item = AssistantRemoteTaskItem(dictionary: res) {
                    self.selectedConversation = item.conversation
                }
                self.triggerPoll()
            } catch {
                self.activeTaskDetailLabel.stringValue = "下发任务失败：\(error.localizedDescription)"
            }
        }
    }

    private func submitFollowUp() {
        let text = followUpField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let active = currentTasks.first,
              !active.isFinished,
              let socketURL = plugin.activeSocketURL() else { return }
        followUpField.stringValue = ""
        let method = active.status == "waiting_for_answer" ? "mika.task.answer" : "mika.task.steer"
        Task { @MainActor in
            do {
                _ = try await HostServiceHealthClient.performRPC(
                    socketURL: socketURL,
                    method: method,
                    params: ["taskId": active.taskId, "text": text],
                    timeout: 15
                )
                self.triggerPoll()
            } catch {
                self.activeTaskDetailLabel.stringValue = "发送失败：\(error.localizedDescription)"
            }
        }
    }

    private func cancelActiveTask() {
        guard let active = currentTasks.first,
              !active.isFinished,
              let socketURL = plugin.activeSocketURL() else { return }
        Task { @MainActor in
            _ = try? await HostServiceHealthClient.performRPC(
                socketURL: socketURL,
                method: "mika.task.cancel",
                params: ["taskId": active.taskId],
                timeout: 10
            )
            self.triggerPoll()
        }
    }

    func triggerPoll() {
        guard !isPolling else { return }
        guard let socketURL = plugin.activeSocketURL() else {
            statusBadgeLabel.stringValue = "未连接"
            statusBadgeCard.fillColor = TFTheme.warnSoft
            statusBadgeLabel.textColor = TFTheme.warn
            statusDetailLabel.stringValue = plugin.runtimeStatusSummary
            return
        }
        isPolling = true
        let wantPreview = isPreviewEnabled
        Task { @MainActor in
            defer { self.isPolling = false }
            if let status = try? await HostServiceHealthClient.performRPC(
                socketURL: socketURL,
                method: "mika.status",
                timeout: 5
            ) {
                self.applyServiceStatus(status)
            }
            if let config = try? await HostServiceHealthClient.performRPC(
                socketURL: socketURL,
                method: "mika.config.get",
                timeout: 5
            ) {
                self.applyModelConfig(config)
            }
            if let listObj = try? await HostServiceHealthClient.performRPC(
                socketURL: socketURL,
                method: "mika.task.list",
                params: ["limit": 8],
                timeout: 6
            ), let rawTasks = listObj["tasks"] as? [[String: Any]] {
                let parsed = rawTasks.compactMap(AssistantRemoteTaskItem.init(dictionary:))
                self.applyTasks(parsed)
            }
            if wantPreview,
               let snap = try? await HostServiceHealthClient.performRPC(
                socketURL: socketURL,
                method: "mika.display.snapshot",
                timeout: 6
               ) {
                self.applyDisplaySnapshot(snap)
            }
        }
    }

    private func applyServiceStatus(_ status: [String: Any]) {
        let phase = (status["phase"] as? String) ?? "starting"
        let detail = (status["detail"] as? String) ?? ""
        switch phase {
        case "ready":
            statusBadgeLabel.stringValue = "就绪"
            statusBadgeCard.fillColor = TFTheme.positiveSoft
            statusBadgeLabel.textColor = TFTheme.positive
            let modelNote = (status["modelConfigured"] as? Bool) == true ? "" : " · Magpie 模型未就绪"
            statusDetailLabel.stringValue = "系统通道已就绪 · 后台显示 #\(status["displayId"] as? Int ?? -1)\(modelNote)"
        case "pending-build":
            statusBadgeLabel.stringValue = "待构建"
            statusBadgeCard.fillColor = TFTheme.warnSoft
            statusBadgeLabel.textColor = TFTheme.warn
            statusDetailLabel.stringValue = detail
        case "degraded":
            statusBadgeLabel.stringValue = "需处理"
            statusBadgeCard.fillColor = TFTheme.dangerSoft
            statusBadgeLabel.textColor = TFTheme.danger
            statusDetailLabel.stringValue = detail
        default:
            statusBadgeLabel.stringValue = "初始化中"
            statusBadgeCard.fillColor = TFTheme.accentSoft
            statusBadgeLabel.textColor = TFTheme.accent
            statusDetailLabel.stringValue = detail.isEmpty ? "正在准备系统助手环境…" : detail
        }
    }

    private func applyTasks(_ tasks: [AssistantRemoteTaskItem]) {
        currentTasks = tasks
        if let first = tasks.first {
            activeTaskBadge.stringValue = first.statusLabel
            activeTaskBadge.textColor = first.status == "failed" ? TFTheme.danger : (first.isFinished ? TFTheme.positive : TFTheme.accent)
            activeTaskGoalLabel.stringValue = first.goal
            activeTaskDetailLabel.stringValue = first.statusSummary
            cancelTaskButton.isHidden = first.isFinished
            followUpStack.isHidden = first.isFinished || first.status == "waiting_on_phone"
            runTaskButton.isEnabled = !["starting", "running", "queued"].contains(first.status)
            followUpField.placeholderString = first.status == "waiting_for_answer"
                ? "输入对提问的回答…"
                : "在任务执行中追加说明…"
        } else {
            activeTaskBadge.stringValue = "空闲"
            activeTaskBadge.textColor = TFTheme.ink3
            activeTaskGoalLabel.stringValue = "尚未发起任务"
            activeTaskDetailLabel.stringValue = "输入一句话目标后点击「执行任务」，系统助手将在独立后台显示上完成操作。"
            cancelTaskButton.isHidden = true
            followUpStack.isHidden = true
            runTaskButton.isEnabled = true
        }

        historyStack.arrangedSubviews.forEach {
            historyStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for item in tasks.prefix(5) {
            let row = TFCardView(frame: .zero)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.cornerRadius = 8
            row.fillColor = TFTheme.card2
            row.strokeColor = TFTheme.line

            let goalLbl = NSTextField(labelWithString: item.goal)
            goalLbl.font = .systemFont(ofSize: 12, weight: .medium)
            goalLbl.textColor = TFTheme.ink
            goalLbl.lineBreakMode = .byTruncatingTail
            goalLbl.translatesAutoresizingMaskIntoConstraints = false

            let stateLbl = NSTextField(labelWithString: "\(item.statusLabel) · \(item.statusSummary)")
            stateLbl.font = .systemFont(ofSize: 11)
            stateLbl.textColor = TFTheme.ink3
            stateLbl.lineBreakMode = .byTruncatingTail
            stateLbl.translatesAutoresizingMaskIntoConstraints = false

            row.addSubview(goalLbl)
            row.addSubview(stateLbl)
            NSLayoutConstraint.activate([
                goalLbl.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
                goalLbl.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
                goalLbl.topAnchor.constraint(equalTo: row.topAnchor, constant: 7),
                stateLbl.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
                stateLbl.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
                stateLbl.topAnchor.constraint(equalTo: goalLbl.bottomAnchor, constant: 2),
                stateLbl.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -7)
            ])
            historyStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: historyStack.widthAnchor).isActive = true
        }
    }

    private func applyDisplaySnapshot(_ snap: [String: Any]) {
        let displayId = (snap["display_id"] as? Int) ?? -1
        let active = (snap["active"] as? Bool) ?? false
        if active && displayId >= 0 {
            observerBadgeLabel.stringValue = "Display #\(displayId) 运行中"
            observerBadgeLabel.textColor = TFTheme.positive
        } else {
            observerBadgeLabel.stringValue = "后台屏空闲"
            observerBadgeLabel.textColor = TFTheme.ink3
        }

        if let b64 = snap["jpeg_base64"] as? String,
           !b64.isEmpty,
           let data = Data(base64Encoded: b64),
           let img = NSImage(data: data) {
            previewImageView.image = img
            previewImageView.isHidden = false
            previewEmptyLabel.isHidden = true
        } else if !active {
            previewImageView.image = nil
            previewImageView.isHidden = true
            previewEmptyLabel.isHidden = false
        }
    }
}
