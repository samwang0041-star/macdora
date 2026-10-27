import AppKit
import AVFoundation
import Metal
import UniformTypeIdentifiers

@MainActor
final class AppWindowSession {
    let package: String
    let window: ApplicationWindow
    var stream: VideoStream?
    var openTask: Task<Void, Never>?
    var presenceTimer: Timer?
    var presenceQueryInProgress = false
    var absentCount = 0
    var hasObservedTarget = false
    var hasPresentedFrame = false
    var hasDecodedFrame = false
    var generation = UUID()
    var presentationTimes: [Double] = []
    var usingHardwareDecoder = true
    var isOpening = false
    var resolutionPreset: String
    var tabletMode: Bool

    init(
        package: String,
        window: ApplicationWindow,
        resolutionPreset: String,
        tabletMode: Bool
    ) {
        self.package = package
        self.window = window
        self.resolutionPreset = resolutionPreset
        self.tabletMode = tabletMode
    }

    func stopStreamAndTimers() {
        presenceTimer?.invalidate()
        presenceTimer = nil
        presenceQueryInProgress = false
        stream?.stop()
        stream = nil
        presentationTimes.removeAll()
    }
}

@MainActor
final class ProductAppDelegate: NSObject, NSApplicationDelegate {
    private let runtime = RuntimeController()
    private var manager: ManagementWindow!
    private var injectedApplicationWindow: ApplicationWindow?
    private var appSessions: [String: AppWindowSession] = [:]
    private var operation: Task<Void, Never>?
    private var telemetryTimer: Timer?
    private var terminating = false
    private var isRestartingForUpdate = false
    private var keyboardMenu: HostKeyboardMenu?
    private var uninstallConfirmationActive = false
    private var activePackage: String = DefaultApp.package
    private let dockPresentation = AppDockPresentation(mode: AppDockIconMode.parse(arguments: ProcessInfo.processInfo.arguments))

    init(manager: ManagementWindow? = nil, applicationWindow: ApplicationWindow? = nil) {
        self.manager = manager
        self.injectedApplicationWindow = applicationWindow
        super.init()
    }

    private var applicationWindow: ApplicationWindow? {
        if let keyWin = NSApp.keyWindow,
           let matched = appSessions.values.first(where: { $0.window.window === keyWin }) {
            return matched.window
        }
        if let activeSession = appSessions[activePackage] {
            return activeSession.window
        }
        return appSessions.values.first?.window ?? injectedApplicationWindow
    }

    private var activeSession: AppWindowSession? {
        if let keyWin = NSApp.keyWindow,
           let matched = appSessions.values.first(where: { $0.window.window === keyWin }) {
            return matched
        }
        return appSessions[activePackage] ?? appSessions.values.first
    }

    private func resolvedAppMetadata(for package: String) -> ContainerApp {
        runtime.cachedContainerApps().first(where: { $0.package == package })
            ?? ContainerApp.metadata(for: package)
    }

    private func syncManagerApps(_ catalog: [ContainerApp]? = nil) {
        let apps = catalog ?? runtime.cachedContainerApps()
        let activeSet = Set(appSessions.keys).union(runtime.activeDisplayPackages)
        let primaryPkg = runtime.activeDisplayPackage ?? appSessions[activePackage]?.package ?? appSessions.keys.first
        manager.updateApps(apps, activePackage: primaryPkg, activePackages: activeSet)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        dockPresentation.update(app: nil)
        installMenus()
        manager = ManagementWindow()
        manager.onOpen = { [weak self] in self?.openApp(package: self?.activePackage ?? DefaultApp.package) }
        manager.onOpenApp = { [weak self] pkg in self?.openApp(package: pkg) }
        manager.onForceStopApp = { [weak self] pkg in self?.forceStopApp(package: pkg) }
        manager.onUninstallApp = { [weak self] pkg in self?.uninstallApp(package: pkg) }
        manager.onCloseApp = { [weak self] pkg in
            self?.appSessions[pkg]?.window.performExplicitClose()
        }
        manager.onInstall = { [weak self] in self?.chooseAPK() }
        manager.onDropAPK = { [weak self] url in self?.installAPKFile(url) }
        manager.onStartRuntime = { [weak self] in self?.startContainerOnly() }
        manager.onStop = { [weak self] in self?.stopRuntime() }
        manager.onRefreshApps = { [weak self] in self?.refreshAppsCatalog() }
        manager.onCloseActiveApp = { [weak self] in self?.applicationWindow?.performExplicitClose() }
        manager.onSettings = { [weak self] in self?.showSettings() }
        manager.onToggleCamera = { [weak self] enabled in self?.setCameraEnabled(enabled) }
        manager.onUpdatePreferences = { [weak self] prefs in self?.updateContainerPreferences(prefs) }
        manager.onToggleOfficeKeepAwake = { [weak self] enabled in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let applied = await self.runtime.setOfficeKeepAwakeEnabled(enabled)
                self.syncPreferencesToManager()
                if !applied { self.manager.show(detail: "未能确认办公环境唤醒设置生效，请稍后重试。") }
            }
        }
        manager.onClearCache = { [weak self] in self?.clearContainerCache() }
        manager.onRevealData = { [weak self] in self?.revealData() }
        manager.onAppearanceChanged = { [weak self] in
            guard let self else { return }
            for session in self.appSessions.values {
                session.window.refreshTheme()
            }
        }
        manager.onImportDeveloperPlugin = { [weak self] in self?.chooseDeveloperPluginPackage() }
        manager.onExportDeveloperPluginTemplate = { [weak self] in self?.exportDeveloperPluginTemplate() }
        manager.onRevealPluginsDirectory = { [weak self] in self?.revealPluginsDirectory() }
        manager.bindPluginManager(runtime.pluginManager)
        runtime.onEnvironmentDownloadProgress = { [weak self] progress in
            self?.manager.updateEnvironmentDownloadProgress(progress)
        }

        runtime.onPluginBanner = { [weak self] msg in
            self?.manager.show(detail: msg)
        }
        runtime.onPluginStateChanged = { [weak self] in
            guard let self else { return }
            self.syncPreferencesToManager()
        }

        manager.onCheckForUpdates = {
            Task { @MainActor in
                await MacdoraUpdateController.shared.checkForUpdates(manual: true)
            }
        }
        manager.onStartUpdateDownload = {
            MacdoraUpdateController.shared.startDownload()
        }
        manager.onCancelUpdateDownload = {
            MacdoraUpdateController.shared.cancelDownload()
        }
        manager.onRestartToInstallUpdate = {
            MacdoraUpdateController.shared.restartAndInstall()
        }

        MacdoraUpdateController.shared.prepareForRestart = { [weak self] in
            await self?.prepareForUpdateRestart()
        }
        MacdoraUpdateController.shared.onStateChange = { [weak self] updateState in
            self?.manager.updateAppUpdateState(updateState)
        }

        runtime.onState = { [weak self] state in
            guard let self else { return }
            self.manager.update(state)
            self.syncPreferencesToManager()
            self.refreshTelemetry()
        }
        runtime.onOfficeKeepAwakeChanged = { [weak self] in self?.syncPreferencesToManager() }
        runtime.onPackageDisplayTerminated = { [weak self] pkg in
            guard let self, !self.terminating, let session = self.appSessions[pkg], session.stream != nil else { return }
            let appTitle = self.resolvedAppMetadata(for: pkg).title
            self.displayFailed(for: pkg, message: "\(appTitle) 会话已结束，可在管理台重新打开。")
        }
        runtime.onDisplayTerminated = { [weak self] in
            guard let self, !self.terminating else { return }
            if self.runtime.activeDisplayPackages.isEmpty {
                for pkg in Array(self.appSessions.keys) where self.appSessions[pkg]?.stream != nil {
                    let appTitle = self.resolvedAppMetadata(for: pkg).title
                    self.displayFailed(for: pkg, message: "\(appTitle) 会话已结束，可在管理台重新打开。")
                }
            }
        }

        syncManagerApps(runtime.cachedContainerApps())
        syncPreferencesToManager()
        manager.update(runtime.state)
        manager.updateAppUpdateState(MacdoraUpdateController.shared.state)
        MacdoraUpdateController.shared.checkOnLaunch()
        refreshTelemetry()
        startTelemetryTimer()

        if let sectionEnv = ProcessInfo.processInfo.environment["ANDROID_USE_INITIAL_SECTION"] {
            switch sectionEnv.lowercased() {
            case "plugins", "plugin": manager.selectSection(.plugins)
            case "monitor", "command": manager.selectSection(.monitor)
            case "settings": manager.selectSection(.settings)
            case "serving", "readiness": manager.selectSection(.serving)
            case "about", "version", "update": manager.selectSection(.about)
            default: manager.selectSection(.apps)
            }
        }

        manager.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        if let autoPkg = ProcessInfo.processInfo.environment["ANDROID_USE_AUTO_OPEN_PACKAGE"],
           ContainerApp.isValidPackageIdentifier(autoPkg) {
            openApp(package: autoPkg)
        }

        if let snapDir = ProcessInfo.processInfo.environment["ANDROID_USE_SNAPSHOT_DIR"] {
            scheduleQASnapshots(to: URL(fileURLWithPath: snapDir, isDirectory: true))
        }
    }

    private func scheduleQASnapshots(to directory: URL) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? await Task.sleep(for: .milliseconds(600))
            self.refreshTelemetry()
            for (section, filename) in [
                (ManagementSection.apps, "macdora-apps.png"),
                (ManagementSection.plugins, "macdora-plugins.png"),
                (ManagementSection.monitor, "macdora-monitor.png"),
                (ManagementSection.settings, "macdora-settings.png"),
                (ManagementSection.serving, "macdora-readiness.png"),
                (ManagementSection.about, "macdora-about.png")
            ] {
                self.manager.selectSection(section)
                self.manager.window?.displayIfNeeded()
                try? await Task.sleep(for: .milliseconds(150))
                self.writeWindowSnapshot(self.manager.window, to: directory.appendingPathComponent(filename))
            }
            self.manager.selectSection(.apps)
            self.manager.window?.displayIfNeeded()
        }
    }

    private func writeWindowSnapshot(_ window: NSWindow?, to url: URL) {
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 10, bounds.height > 10,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        if window === manager.window {
            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext {
                let dots: [(CGFloat, UInt32, UInt32)] = [
                    (13, 0xFF5F57, 0xE0443E),
                    (33, 0xFEBC2E, 0xD89E24),
                    (53, 0x28C840, 0x1AAB29)
                ]
                for (x, fillHex, strokeHex) in dots {
                    let rect = CGRect(x: x, y: bounds.height - 22, width: 12, height: 12)
                    ctx.setFillColor(MacdoraBrand.rgba(fillHex))
                    ctx.fillEllipse(in: rect)
                    ctx.setStrokeColor(MacdoraBrand.rgba(strokeHex, 0.55))
                    ctx.setLineWidth(0.5)
                    ctx.strokeEllipse(in: rect)
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        if let appWin = appSessions.values.first(where: { $0.window.window === window })?.window ?? applicationWindow,
           window === appWin.window,
           let cgImage = appWin.surface.currentSnapshotCGImage() {
            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = ctx
                let surfaceRect = view.convert(appWin.surface.bounds, from: appWin.surface)
                ctx.cgContext.draw(cgImage, in: surfaceRect)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url, options: .atomic)
        }
    }

    private func installMenus() {
        let bar = NSMenu()
        let appItem = NSMenuItem(); bar.addItem(appItem)
        let appMenu = NSMenu(title: MacdoraBrand.appName); appItem.submenu = appMenu
        let aboutItem = appMenu.addItem(withTitle: "关于 \(MacdoraBrand.appName)", action: #selector(aboutCommand), keyEquivalent: "")
        aboutItem.target = self
        let checkUpdateItem = appMenu.addItem(withTitle: "检查更新…", action: #selector(checkForUpdatesCommand), keyEquivalent: "")
        checkUpdateItem.target = self
        let settings = appMenu.addItem(withTitle: "设置…", action: #selector(settingsCommand), keyEquivalent: ","); settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 \(MacdoraBrand.appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 \(MacdoraBrand.appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileItem = NSMenuItem(); bar.addItem(fileItem)
        let file = NSMenu(title: "文件"); fileItem.submenu = file
        let openSystemSettings = file.addItem(withTitle: "打开系统设置", action: #selector(openSystemSettingsCommand), keyEquivalent: "o"); openSystemSettings.target = self
        let install = file.addItem(withTitle: "安装应用…", action: #selector(installCommand), keyEquivalent: "i"); install.target = self
        file.addItem(.separator())
        file.addItem(withTitle: "最小化窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let explicitCloseItem = file.addItem(withTitle: "关闭当前应用会话", action: #selector(explicitCloseAppCommand), keyEquivalent: "W")
        explicitCloseItem.keyEquivalentModifierMask = [.command, .shift]
        explicitCloseItem.target = self
        let editItem = NSMenuItem(); bar.addItem(editItem)
        let edit = NSMenu(title: "编辑"); editItem.submenu = edit
        for (title, action, key) in [("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        edit.addItem(.separator())
        let keyboard = HostKeyboardMenu(available: { [weak self] in self?.applicationWindow?.surface.canSelectHostInputSource == true }) { [weak self] in self?.applicationWindow?.surface.selectHostInputSource($0) }
        keyboardMenu = keyboard
        let inputSources = edit.addItem(withTitle: "输入法", action: nil, keyEquivalent: ""); inputSources.submenu = keyboard.menu
        let windowItem = NSMenuItem(); bar.addItem(windowItem)
        let windows = NSMenu(title: "窗口"); windowItem.submenu = windows
        let management = windows.addItem(withTitle: "应用", action: #selector(managementCommand), keyEquivalent: "1"); management.target = self
        let pluginsItem = windows.addItem(withTitle: "插件", action: #selector(pluginsCommand), keyEquivalent: "2"); pluginsItem.target = self
        let monitorItem = windows.addItem(withTitle: "状态", action: #selector(monitorCommand), keyEquivalent: "3"); monitorItem.target = self
        let settingsItem = windows.addItem(withTitle: "设置", action: #selector(settingsTabCommand), keyEquivalent: "4"); settingsItem.target = self
        let servingItem = windows.addItem(withTitle: "诊断", action: #selector(servingCommand), keyEquivalent: "5"); servingItem.target = self
        let aboutWindowItem = windows.addItem(withTitle: "关于 \(MacdoraBrand.appName)", action: #selector(aboutCommand), keyEquivalent: "6"); aboutWindowItem.target = self
        windows.addItem(.separator())
        windows.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let fullScreen = windows.addItem(withTitle: "进入 / 退出全屏", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.control, .command]
        windows.addItem(.separator())
        let tabletToggleItem = windows.addItem(withTitle: "切换横屏 / 竖屏布局", action: #selector(toggleTabletModeCommand), keyEquivalent: "T")
        tabletToggleItem.keyEquivalentModifierMask = [.command, .shift]
        tabletToggleItem.target = self
        NSApplication.shared.windowsMenu = windows
        NSApplication.shared.mainMenu = bar
    }

    @objc private func openSystemSettingsCommand() { openApp(package: DefaultApp.package) }
    @objc private func installCommand() { chooseAPK() }
    @objc private func explicitCloseAppCommand() { applicationWindow?.performExplicitClose() }
    @objc private func toggleTabletModeCommand() {
        if let session = activeSession {
            toggleWindowOrientation(for: session.package)
        } else {
            var prefs = runtime.containerPreferences
            prefs.tabletMode.toggle()
            updateContainerPreferences(prefs)
        }
    }
    @objc private func settingsCommand() { showSettings() }
    @objc private func managementCommand() { manager.selectSection(.apps); manager.presentWindow() }
    @objc private func pluginsCommand() { manager.selectSection(.plugins); manager.presentWindow() }
    @objc private func monitorCommand() { manager.selectSection(.monitor); manager.presentWindow() }
    @objc private func settingsTabCommand() { manager.selectSection(.settings); manager.presentWindow() }
    @objc private func servingCommand() { manager.selectSection(.serving); manager.presentWindow() }
    @objc private func aboutCommand() { manager.selectSection(.about); manager.presentWindow() }
    @objc private func checkForUpdatesCommand() {
        manager.selectSection(.about)
        manager.presentWindow()
        Task { @MainActor in
            await MacdoraUpdateController.shared.checkForUpdates(manual: true)
        }
    }

    private func prepareForUpdateRestart() async {
        isRestartingForUpdate = true
        terminating = true
        operation?.cancel()
        telemetryTimer?.invalidate()
        telemetryTimer = nil
        for session in appSessions.values {
            session.openTask?.cancel()
            session.stopStreamAndTimers()
            session.window.window?.orderOut(nil)
        }
        appSessions.removeAll()
        _ = await runtime.stop()
        manager.window?.orderOut(nil)
    }

    private func startTelemetryTimer() {
        telemetryTimer?.invalidate()
        telemetryTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshTelemetry()
            }
        }
    }

    private func refreshTelemetry() {
        let now = CACurrentMediaTime()
        var primaryFPS = 0.0
        var primaryP95Ms = 0.0
        var primaryHW = true

        for session in appSessions.values {
            session.presentationTimes.removeAll { now - $0 > 2.5 }
            var fps = 0.0
            var p95Ms = 0.0
            if session.presentationTimes.count >= 2,
               let first = session.presentationTimes.first,
               let last = session.presentationTimes.last,
               last > first {
                fps = min(60.0, Double(session.presentationTimes.count - 1) / max(0.25, now - first))
                var intervals: [Double] = []
                for i in 1..<session.presentationTimes.count {
                    intervals.append((session.presentationTimes[i] - session.presentationTimes[i - 1]) * 1000.0)
                }
                intervals.sort()
                let p95Index = min(intervals.count - 1, Int(Double(intervals.count - 1) * 0.95))
                p95Ms = intervals[p95Index]
            }
            session.window.updateFPSBadge(fps)
            if session.package == activePackage || primaryFPS == 0 {
                primaryFPS = fps
                primaryP95Ms = p95Ms
                primaryHW = session.usingHardwareDecoder
            }
        }

        let activePkg = runtime.activeDisplayPackage ?? activeSession?.package
        let activeName = activePkg.map { resolvedAppMetadata(for: $0).title }
        let sample = runtime.sampleTelemetry(
            presentedFPS: primaryFPS,
            frameIntervalP95Ms: primaryP95Ms,
            hardwareDecoder: primaryHW,
            activeAppName: activeName,
            activePackage: activePkg
        )
        manager.updateTelemetry(sample)
    }

    private func startContainerOnly() {
        guard !runtime.state.isBusy, !terminating else { return }
        let previousOperation = operation
        previousOperation?.cancel()
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                await previousOperation?.value
                try Task.checkCancellation()
                try await self.runtime.prepare()
                try Task.checkCancellation()
                try await self.runtime.start()
                try Task.checkCancellation()
                let apps = await self.runtime.refreshContainerApps()
                self.syncManagerApps(apps)
                self.manager.show(detail: "运行环境已就绪，可使用 \(apps.filter(\.isInstalled).count) 个应用。")
            } catch is CancellationError {
                return
            } catch {
                self.manager.update(.failed(error.localizedDescription))
            }
        }
    }

    private func refreshAppsCatalog() {
        Task { [weak self] in
            guard let self else { return }
            let apps = await self.runtime.refreshContainerApps()
            self.syncManagerApps(apps)
        }
    }

    private func forceStopApp(package: String) {
        guard !runtime.state.isBusy, !terminating else { return }
        let appMeta = resolvedAppMetadata(for: package)
        Task { [weak self] in
            guard let self else { return }
            do {
                if let session = self.appSessions.removeValue(forKey: package) {
                    session.openTask?.cancel()
                    session.stopStreamAndTimers()
                    await self.runtime.closeDisplay(package: package)
                    session.window.performRuntimeOperationClose()
                    if self.appSessions.isEmpty {
                        self.dockPresentation.update(app: nil)
                    }
                }
                try await self.runtime.forceStopApp(package: package)
                self.syncManagerApps(await self.runtime.refreshContainerApps())
                self.manager.show(detail: "已停止 \(appMeta.title)。")
            } catch {
                self.manager.show(detail: error.localizedDescription)
            }
        }
    }

    private func uninstallApp(package: String) {
        guard !runtime.state.isBusy, !terminating, !uninstallConfirmationActive else { return }
        let appTitle = resolvedAppMetadata(for: package).title
        let confirmation = NSAlert()
        confirmation.alertStyle = .warning
        confirmation.messageText = "卸载 \(appTitle)？"
        confirmation.informativeText = "将删除容器内的应用及其数据，包括登录状态和设置。此操作无法撤销。"
        confirmation.addButton(withTitle: "卸载")
        confirmation.addButton(withTitle: "取消")
        guard let window = manager.window else { return }
        uninstallConfirmationActive = true
        confirmation.beginSheetModal(for: window) { [weak self] response in
            self?.uninstallConfirmationActive = false
            guard let self, response == .alertFirstButtonReturn else {
                self?.syncManagerApps()
                return
            }
            self.performUninstallApp(package: package, appTitle: appTitle)
        }
    }

    private func performUninstallApp(package: String, appTitle: String) {
        guard !runtime.state.isBusy, !terminating else { return }
        let previousOperation = operation
        previousOperation?.cancel()
        if let session = appSessions.removeValue(forKey: package) {
            session.openTask?.cancel()
            session.stopStreamAndTimers()
            session.window.performRuntimeOperationClose()
            if appSessions.isEmpty {
                dockPresentation.update(app: nil)
            }
        }
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                await previousOperation?.value
                try Task.checkCancellation()
                if self.runtime.displayEndpoint(for: package) != nil {
                    await self.runtime.closeDisplay(package: package)
                }
                if self.runtime.state != .ready && self.runtime.state != .running {
                    self.manager.show(detail: "正在启动环境以卸载 \(appTitle)…")
                    try await self.runtime.prepare()
                    try Task.checkCancellation()
                    try await self.runtime.start()
                    try Task.checkCancellation()
                } else {
                    self.manager.show(detail: "正在卸载 \(appTitle)…")
                }
                try await self.runtime.uninstallApp(package: package)
                self.syncManagerApps(self.runtime.cachedContainerApps())
                self.syncPreferencesToManager()
                self.refreshTelemetry()
                self.manager.show(detail: "已卸载 \(appTitle)。")
            } catch is CancellationError {
                self.syncManagerApps(self.runtime.cachedContainerApps())
                return
            } catch {
                self.manager.show(detail: error.localizedDescription)
            }
        }
    }

    private func openApp(package: String, forceReconfigureDisplay: Bool = false) {
        guard runtime.state != .stopping, !terminating else { return }
        manager.show(detail: nil)
        let appMeta = resolvedAppMetadata(for: package)

        if !forceReconfigureDisplay,
           let existing = appSessions[package] {
            if existing.stream != nil,
               self.runtime.displayEndpoint(for: package) != nil,
               (existing.window.window?.isVisible == true || existing.window.window?.isMiniaturized == true) {
                activePackage = package
                dockPresentation.update(app: appMeta)
                existing.window.presentWindow()
                return
            }
            if existing.isOpening {
                activePackage = package
                existing.window.presentWindow()
                return
            }
        }

        if appSessions[package] == nil && appSessions.count >= RuntimeController.maxConcurrentDisplays {
            let limit = RuntimeController.maxConcurrentDisplays
            manager.show(detail: "最多可同时开启 \(limit) 个独立应用窗口，请先关闭一个窗口后再打开 \(appMeta.title)。")
            manager.presentWindow()
            return
        }

        activePackage = package
        let generation = UUID()
        guard let session = ensureAppWindowSession(for: appMeta, generation: generation) else {
            return
        }
        session.openTask?.cancel()
        session.stopStreamAndTimers()
        session.generation = generation
        session.isOpening = true
        session.hasObservedTarget = false
        session.hasPresentedFrame = false
        session.hasDecodedFrame = false

        syncManagerApps()
        session.window.loading("正在准备 \(appMeta.title)…")

        let previousOperation = operation
        let task = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            defer {
                if session.generation == generation {
                    session.isOpening = false
                }
            }
            do {
                await previousOperation?.value
                try Task.checkCancellation()
                guard session.generation == generation else { return }

                if forceReconfigureDisplay {
                    session.stopStreamAndTimers()
                    await self.runtime.closeDisplay(package: package)
                }
                try Task.checkCancellation()
                try await self.runtime.prepare()
                try Task.checkCancellation()
                if self.runtime.cameraEnabled,
                   AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                    let allowed = await AVCaptureDevice.requestAccess(for: .video)
                    self.runtime.cameraEnabled = allowed
                    self.syncPreferencesToManager()
                }
                try Task.checkCancellation()
                if self.runtime.state != .ready && self.runtime.state != .running {
                    session.window.loading("正在启动运行环境…")
                }
                try await self.runtime.start()
                try Task.checkCancellation()
                if package != DefaultApp.package {
                    let installed = try await self.runtime.isPackageInstalled(package)
                    guard installed else {
                        throw NSError(
                            domain: "AndroidUse",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "尚未安装 \(appMeta.title)，请先在管理台导入 APK。"]
                        )
                    }
                }
                try Task.checkCancellation()
                let currentCached = self.runtime.cachedContainerApps()
                let apps: [ContainerApp]
                if currentCached.contains(where: { $0.package == package && $0.isInstalled }) {
                    apps = currentCached
                } else {
                    apps = await self.runtime.refreshContainerApps()
                }
                let refreshedMeta = self.resolvedAppMetadata(for: package)
                session.window.configureForApp(refreshedMeta)
                self.dockPresentation.update(app: refreshedMeta)
                self.syncManagerApps(apps)
                session.window.loading("正在打开 \(refreshedMeta.title)…")
                let endpoint = try await self.runtime.openDisplay(
                    package: package,
                    resolutionPreset: session.resolutionPreset,
                    tabletMode: session.tabletMode,
                    replaceExisting: false
                )
                guard session.generation == generation, !Task.isCancelled else {
                    await self.runtime.closeDisplay(package: package)
                    return
                }
                self.syncManagerApps(apps)
                self.connect(endpoint, session: session, generation: generation)
            } catch is CancellationError {
                if session.generation == generation {
                    await self.runtime.closeDisplay(package: package)
                }
            } catch {
                if session.generation == generation {
                    self.displayFailed(for: package, message: error.localizedDescription)
                }
            }
        }
        session.openTask = task
        operation = task
    }

    private func ensureAppWindowSession(for app: ContainerApp, generation: UUID) -> AppWindowSession? {
        let appPref = runtime.containerPreferences.displayPreference(for: app.package)
        let session: AppWindowSession
        let isNewWindow: Bool
        if let existing = appSessions[app.package] {
            existing.resolutionPreset = appPref.resolutionPreset
            existing.tabletMode = appPref.tabletMode
            session = existing
            isNewWindow = false
        } else {
            let window: ApplicationWindow
            if let injected = injectedApplicationWindow {
                injectedApplicationWindow = nil
                window = injected
            } else {
                guard let device = MTLCreateSystemDefaultDevice() else {
                    manager.update(.failed("当前设备不支持硬件图形加速。"))
                    return nil
                }
                window = ApplicationWindow(device: device)
            }
            let pkg = app.package
            window.onClose = { [weak self] in self?.closedApplicationWindow(for: pkg) }
            window.onRetry = { [weak self] in self?.openApp(package: pkg, forceReconfigureDisplay: true) }
            window.onManagement = { [weak self] in self?.manager.presentWindow() }
            window.onBack = { [weak window] in window?.surface.key(4) }
            window.onToggleTabletMode = { [weak self] in self?.toggleWindowOrientation(for: pkg) }
            window.onSelectResolutionPreset = { [weak self] preset in
                self?.selectWindowResolutionPreset(preset, for: pkg)
            }
            let created = AppWindowSession(
                package: pkg,
                window: window,
                resolutionPreset: appPref.resolutionPreset,
                tabletMode: appPref.tabletMode
            )
            appSessions[pkg] = created
            session = created
            isNewWindow = true
        }

        let targetPixels = ContainerPreferences.pixelSize(
            for: session.resolutionPreset,
            tabletMode: session.tabletMode
        )
        session.window.applyDisplayMode(
            tabletMode: session.tabletMode,
            preferredPixelSize: targetPixels,
            resolutionPreset: session.resolutionPreset
        )
        session.window.configureForApp(app)
        if isNewWindow && appSessions.count > 1 {
            cascadeWindowPlacement(session.window, index: appSessions.count - 1)
        }
        dockPresentation.update(app: app)
        session.window.presentWindow()
        return session
    }

    private func cascadeWindowPlacement(_ appWindow: ApplicationWindow, index: Int) {
        guard index > 0, let win = appWindow.window else { return }
        let screen = (win.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let offset = CGFloat(index % 4) * 34.0
        var frame = win.frame
        frame.origin.x = min(max(screen.minX + 16, frame.origin.x + offset), screen.maxX - frame.width - 16)
        frame.origin.y = max(screen.minY + 16, min(screen.maxY - frame.height - 16, frame.origin.y - offset))
        win.setFrameOrigin(frame.origin)
    }

    private func toggleWindowOrientation(for package: String) {
        var prefs = runtime.containerPreferences
        let currentPref = prefs.displayPreference(for: package)
        let nextTabletMode = !currentPref.tabletMode
        prefs.appDisplayOverrides[package] = AppDisplayPreference(
            resolutionPreset: currentPref.resolutionPreset,
            tabletMode: nextTabletMode
        )
        runtime.containerPreferences = prefs
        if let session = appSessions[package] {
            session.tabletMode = nextTabletMode
            let pixels = ContainerPreferences.pixelSize(for: session.resolutionPreset, tabletMode: nextTabletMode)
            session.window.applyDisplayMode(
                tabletMode: nextTabletMode,
                preferredPixelSize: pixels,
                resolutionPreset: session.resolutionPreset
            )
        }
        syncPreferencesToManager()
        let label = ContainerPreferences.displayLabel(for: currentPref.resolutionPreset, tabletMode: nextTabletMode)
        manager.show(detail: "已切换 \(resolvedAppMetadata(for: package).title) 至 \(label)。")
        if runtime.state == .running {
            openApp(package: package, forceReconfigureDisplay: true)
        }
    }

    private func selectWindowResolutionPreset(_ preset: String, for package: String) {
        let option = ContainerPreferences.resolutionOption(for: preset)
        var prefs = runtime.containerPreferences
        let currentPref = prefs.displayPreference(for: package)
        prefs.appDisplayOverrides[package] = AppDisplayPreference(
            resolutionPreset: option.preset,
            tabletMode: currentPref.tabletMode
        )
        runtime.containerPreferences = prefs
        if let session = appSessions[package] {
            session.resolutionPreset = option.preset
            let pixels = option.pixelSize(tabletMode: session.tabletMode)
            session.window.applyDisplayMode(
                tabletMode: session.tabletMode,
                preferredPixelSize: pixels,
                resolutionPreset: option.preset
            )
        }
        syncPreferencesToManager()
        let label = ContainerPreferences.displayLabel(for: option.preset, tabletMode: currentPref.tabletMode)
        manager.show(detail: "已切换 \(resolvedAppMetadata(for: package).title) 分辨率至 \(label)。")
        if runtime.state == .running {
            openApp(package: package, forceReconfigureDisplay: true)
        }
    }

    private func connect(_ endpoint: DisplayEndpoint, session: AppWindowSession, generation: UUID) {
        let window = session.window
        let stream = VideoStream()
        session.stream = stream
        session.hasObservedTarget = false
        session.hasPresentedFrame = false
        session.hasDecodedFrame = false
        session.presentationTimes.removeAll()
        window.surface.beginSession(generation)
        window.surface.clipboardSyncEnabled = runtime.containerPreferences.clipboardSyncEnabled
        window.surface.onPixelSizeChanged = { [weak window] size in
            window?.syncToPixelSize(size)
        }
        stream.decoder.onHardware = { [weak session] hw in
            DispatchQueue.main.async { [weak session] in
                guard let session, session.generation == generation else { return }
                session.usingHardwareDecoder = hw
            }
        }
        window.surface.onPresented = { [weak session] _, hostTime in
            guard let session, session.generation == generation else { return }
            session.presentationTimes.append(hostTime)
            if session.presentationTimes.count > 180 {
                session.presentationTimes.removeFirst(session.presentationTimes.count - 180)
            }
        }
        let inputIssue: (String) -> Void = { [weak session, weak window] message in
            DispatchQueue.main.async { [weak session, weak window] in
                guard session?.generation == generation else { return }
                window?.showInputIssue(message)
            }
        }
        window.surface.onInputIssue = inputIssue
        window.surface.onPointerBegan = { [weak stream] in stream?.beginPointer($0) }
        stream.onConfirmedFocus = { [weak session, weak window] focus, pointer in
            DispatchQueue.main.async { [weak session, weak window] in
                guard session?.generation == generation else { return }
                window?.surface.confirmInputFocus(focus, pointerSequence: pointer)
            }
        }
        if runtime.containerPreferences.directIMEEnabled, let imePort = endpoint.imePort {
            stream.enableDirectInput(port: imePort) { [weak session, weak window] focus in
                DispatchQueue.main.async { [weak session, weak window] in
                    guard session?.generation == generation else { return }
                    window?.surface.setInputFocus(focus)
                }
            }
            window.surface.sendDirectText = { [weak stream] text, lease in
                stream?.sendText(text, lease: lease) { inputIssue($0 ?? "") }
            }
        }
        stream.onClipboard = { [weak self, weak session] text in
            DispatchQueue.main.async { [weak self, weak session] in
                guard let self, session?.generation == generation,
                      self.runtime.containerPreferences.clipboardSyncEnabled else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
        window.surface.sendInput = { [weak stream] in stream?.send($0) }
        stream.decoder.onFrame = { [weak window] frame in window?.surface.accept(frame, session: generation) }
        stream.decoder.onFirstDecodedFrame = { [weak session] in
            DispatchQueue.main.async { [weak session] in
                guard let session, session.generation == generation else { return }
                session.hasDecodedFrame = true
            }
        }
        stream.onSize = { [weak session, weak window] width, height in
            DispatchQueue.main.async { [weak session, weak window] in
                guard session?.generation == generation else { return }
                let newSize = CGSize(width: width, height: height)
                window?.surface.pixelSize = newSize
                window?.syncToPixelSize(newSize)
            }
        }
        stream.onError = { [weak self, weak session] error in
            DispatchQueue.main.async { [weak self, weak session] in
                guard let self, let session, session.generation == generation else { return }
                self.displayFailed(for: session.package, message: error.localizedDescription)
            }
        }
        window.surface.onFirstFrame = { [weak self, weak session] in
            guard let self, let session, session.generation == generation else { return }
            session.hasPresentedFrame = true
            if session.hasObservedTarget { session.window.ready() }
            let isHorizontal = session.tabletMode
            Task { @MainActor [weak self] in
                await self?.runtime.configureVirtualDisplayOrientation(tabletMode: isHorizontal)
            }
        }
        stream.connect(port: endpoint.port, startApp: endpoint.package)
        startPresenceMonitor(for: session, generation: generation)
        let appTitle = resolvedAppMetadata(for: endpoint.package).title
        Task { [weak self, weak session] in
            var deadline = DisplayStartupDeadline(at: CACurrentMediaTime())
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let session, session.generation == generation, session.stream != nil,
                      !(session.hasObservedTarget && session.hasPresentedFrame) else { return }
                let win = session.window.window
                let presentable = win?.isVisible == true && win?.isMiniaturized == false
                    && win?.occlusionState.contains(.visible) == true
                if deadline.expired(
                    at: CACurrentMediaTime(),
                    decoded: session.hasDecodedFrame,
                    targetVisible: session.hasObservedTarget,
                    presentable: presentable,
                    applicationActive: NSApp.isActive && win?.isKeyWindow == true
                ) {
                    self.displayFailed(
                        for: session.package,
                        message: "\(appTitle) 暂时没有产生可显示的画面。请重新打开；若仍失败，请停止容器后重试。"
                    )
                    return
                }
            }
        }
    }

    private func startPresenceMonitor(for session: AppWindowSession, generation: UUID) {
        session.presenceTimer?.invalidate()
        session.absentCount = 0
        let monitoredPackage = session.package
        let appTitle = resolvedAppMetadata(for: monitoredPackage).title
        var tickCount = 0
        session.presenceTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self, weak session] _ in
            Task { @MainActor [weak self, weak session] in
                guard let self, let session,
                      !session.presenceQueryInProgress,
                      session.generation == generation,
                      session.stream != nil else { return }
                tickCount &+= 1
                if session.hasObservedTarget && session.absentCount == 0 && (tickCount % 5) != 0 {
                    return
                }
                session.presenceQueryInProgress = true
                let presence = await self.runtime.targetPresence(package: monitoredPackage)
                session.presenceQueryInProgress = false
                guard session.generation == generation else { return }
                switch presence {
                case .notRunning:
                    if session.hasObservedTarget {
                        session.absentCount += 1
                        if session.absentCount >= 2 {
                            self.displayFailed(for: monitoredPackage, message: "\(appTitle) 已退出。可以在容器管理台重新打开。")
                        }
                    }
                case .visible, .systemInteraction:
                    session.absentCount = 0
                    if !session.hasObservedTarget {
                        session.hasObservedTarget = true
                        session.window.awaitFirstPresentation()
                        if session.hasPresentedFrame { session.window.ready() }
                        self.refreshTelemetry()
                        if let snapDir = ProcessInfo.processInfo.environment["ANDROID_USE_SNAPSHOT_DIR"] {
                            let dirURL = URL(fileURLWithPath: snapDir, isDirectory: true)
                            Task { @MainActor [weak self, weak session] in
                                try? await Task.sleep(for: .seconds(3))
                                guard let self, let session else { return }
                                self.refreshTelemetry()
                                self.writeWindowSnapshot(session.window.window, to: dirURL.appendingPathComponent("macdora-app-window.png"))
                                for (section, filename) in [
                                    (ManagementSection.apps, "macdora-apps-running.png"),
                                    (ManagementSection.monitor, "macdora-monitor-running.png"),
                                    (ManagementSection.settings, "macdora-settings-running.png"),
                                    (ManagementSection.serving, "macdora-readiness-running.png")
                                ] {
                                    self.manager.selectSection(section)
                                    self.manager.window?.displayIfNeeded()
                                    try? await Task.sleep(for: .milliseconds(150))
                                    self.writeWindowSnapshot(self.manager.window, to: dirURL.appendingPathComponent(filename))
                                }
                                self.manager.selectSection(.apps)
                            }
                        }
                    }
                case .unavailable:
                    break
                }
            }
        }
    }

    private func displayFailed(for package: String, message: String) {
        guard let session = appSessions[package] else {
            manager.show(detail: message)
            return
        }
        let generation = UUID()
        session.generation = generation
        session.isOpening = false
        session.stopStreamAndTimers()
        session.window.failure(message)
        if runtime.state == .ready || runtime.state == .running {
            manager.show(detail: message)
            manager.update(runtime.state)
        } else {
            manager.update(.failed(message))
        }
        Task { [weak self, weak session] in
            guard let self, let session, session.generation == generation else { return }
            await self.runtime.closeDisplay(package: package)
            self.syncManagerApps()
            self.manager.update(self.runtime.state)
        }
    }

    private func closedApplicationWindow(for package: String) {
        guard let session = appSessions.removeValue(forKey: package) else { return }
        session.generation = UUID()
        session.isOpening = false
        session.openTask?.cancel()
        session.stopStreamAndTimers()
        session.window.surface.sendInput = nil

        if let nextSession = appSessions.values.first {
            activePackage = nextSession.package
            dockPresentation.update(app: resolvedAppMetadata(for: nextSession.package))
        } else {
            dockPresentation.update(app: nil)
        }

        let noRemainingWindows = appSessions.isEmpty
        Task { [weak self] in
            guard let self else { return }
            await self.runtime.closeDisplay(package: package)
            if noRemainingWindows && !self.runtime.shouldKeepRuntimeInBackground {
                _ = await self.runtime.stop()
            }
            if !self.terminating {
                self.syncManagerApps()
                self.manager.update(self.runtime.state)
                if noRemainingWindows {
                    self.manager.presentWindow()
                }
            }
        }
    }

    private func chooseAPK() {
        guard !runtime.state.isBusy, !terminating else { return }
        let panel = NSOpenPanel()
        panel.title = "安装本地应用"
        panel.message = "选择 APK 安装包，已有应用数据与登录状态将自动保留。"
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.beginSheetModal(for: manager.window!) { [weak self] result in
            guard result == .OK, let url = panel.url, let self else { return }
            self.installAPKFile(url)
        }
    }

    private func installAPKFile(_ url: URL) {
        guard !runtime.state.isBusy, !terminating else { return }
        let fileName = url.lastPathComponent
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runtime.prepare()
                try await self.runtime.start()
                self.manager.show(detail: "正在安装 \(fileName)…")
                try await self.runtime.installAPK(url)
                let apps = await self.runtime.refreshContainerApps()
                self.syncManagerApps(apps)
                self.manager.show(detail: "\(fileName) 安装完成。")
            } catch {
                self.manager.update(.failed(error.localizedDescription))
            }
        }
    }

    private func stopRuntime() {
        guard !runtime.state.isBusy, !terminating else { return }
        operation?.cancel()
        let sessions = Array(appSessions.values)
        appSessions.removeAll()
        for session in sessions {
            session.generation = UUID()
            session.openTask?.cancel()
            session.stopStreamAndTimers()
            session.window.performRuntimeOperationClose()
        }
        dockPresentation.update(app: nil)
        operation = Task { [weak self] in
            guard let self else { return }
            _ = await self.runtime.stop()
            self.syncManagerApps()
            self.refreshTelemetry()
        }
    }

    private func showSettings() {
        syncPreferencesToManager()
        manager.selectSection(.settings)
        manager.presentWindow()
    }

    @objc private func revealData() { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: runtime.rootURL.path) }

    private func chooseDeveloperPluginPackage() {
        let panel = NSOpenPanel()
        panel.title = "导入系统级热插拔插件"
        panel.message = "选择包含 manifest.json 的插件文件夹，或 .auplugin / .zip 插件归档包。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: manager.window!) { [weak self] result in
            guard result == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                do {
                    _ = try await self.runtime.pluginManager.importDeveloperPlugin(from: url)
                    self.manager.refreshPluginsSection()
                } catch {
                    self.manager.show(detail: error.localizedDescription)
                }
            }
        }
    }

    private func exportDeveloperPluginTemplate() {
        let sdkRoot = runtime.rootURL
            .appendingPathComponent("plugin-sdk-templates", isDirectory: true)
            .appendingPathComponent("dev.custom.sample-capability", isDirectory: true)
        do {
            let createdURL = try SystemPluginPackageFactory.createDeveloperTemplateDirectory(
                at: sdkRoot,
                overwriteExisting: false
            )
            manager.show(detail: "已生成开发者插件脚手架：\(createdURL.path)")
            NSWorkspace.shared.selectFile(
                createdURL.appendingPathComponent("manifest.json").path,
                inFileViewerRootedAtPath: createdURL.path
            )
        } catch {
            manager.show(detail: error.localizedDescription)
        }
    }

    private func revealPluginsDirectory() {
        let dir = runtime.pluginManager.pluginsRootURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path)
    }

    private var canChangeCamera: Bool {
        !runtime.state.isBusy
    }

    private func syncPreferencesToManager() {
        let metalAvailable = MTLCreateSystemDefaultDevice() != nil
        manager.updateEnvironmentDownloadNeeded(runtime.needsEnvironmentDownload)
        manager.updatePreferences(
            cameraEnabled: runtime.cameraEnabled,
            canChangeCamera: canChangeCamera,
            rootPath: runtime.rootURL.path,
            preferences: runtime.containerPreferences,
            readiness: runtime.evaluateReadinessChecks(metalAvailable: metalAvailable),
            officeKeepAwake: runtime.officeKeepAwakeStatus
        )
    }

    private func updateContainerPreferences(_ prefs: ContainerPreferences) {
        let previous = runtime.containerPreferences
        var updatedPrefs = prefs
        if previous.resolutionPreset != prefs.resolutionPreset || previous.tabletMode != prefs.tabletMode {
            for pkg in appSessions.keys {
                var override = updatedPrefs.displayPreference(for: pkg)
                if previous.resolutionPreset != prefs.resolutionPreset {
                    override.resolutionPreset = prefs.resolutionPreset
                }
                if previous.tabletMode != prefs.tabletMode {
                    override.tabletMode = prefs.tabletMode
                }
                updatedPrefs.appDisplayOverrides[pkg] = override
            }
        }
        runtime.containerPreferences = updatedPrefs

        for session in appSessions.values {
            session.window.surface.clipboardSyncEnabled = updatedPrefs.clipboardSyncEnabled
            if !updatedPrefs.directIMEEnabled {
                session.window.surface.sendDirectText = nil
            }
            if previous.resolutionPreset != updatedPrefs.resolutionPreset {
                session.resolutionPreset = updatedPrefs.resolutionPreset
            }
            if previous.tabletMode != updatedPrefs.tabletMode {
                session.tabletMode = updatedPrefs.tabletMode
            }
            let targetPixels = ContainerPreferences.pixelSize(
                for: session.resolutionPreset,
                tabletMode: session.tabletMode
            )
            session.window.applyDisplayMode(
                tabletMode: session.tabletMode,
                preferredPixelSize: targetPixels,
                resolutionPreset: session.resolutionPreset
            )
        }

        syncPreferencesToManager()
        if (previous.tabletMode != updatedPrefs.tabletMode || previous.resolutionPreset != updatedPrefs.resolutionPreset),
           runtime.state == .running,
           !appSessions.isEmpty {
            manager.show(detail: "已切换至\(updatedPrefs.resolutionDisplayLabel) · \(updatedPrefs.targetFPS)Hz。")
            let packagesToReconfigure = Array(appSessions.keys)
            for pkg in packagesToReconfigure {
                openApp(package: pkg, forceReconfigureDisplay: true)
            }
        } else if (previous.tabletMode != updatedPrefs.tabletMode || previous.resolutionPreset != updatedPrefs.resolutionPreset),
                  runtime.state == .ready {
            let expectedTabletMode = updatedPrefs.tabletMode
            let summary = "\(updatedPrefs.resolutionDisplayLabel) · \(updatedPrefs.targetFPS)Hz"
            manager.show(detail: "正在切换至\(updatedPrefs.resolutionDisplayLabel) · \(updatedPrefs.targetFPS)Hz…")
            Task { @MainActor [weak self] in
                guard let self else { return }
                let applied = await self.runtime.applyGuestDeviceFormFactor(tabletMode: expectedTabletMode)
                guard self.runtime.containerPreferences.tabletMode == expectedTabletMode else { return }
                if applied {
                    self.manager.show(detail: "已切换至\(summary)。")
                } else {
                    self.manager.show(detail: "切换至\(summary)未完成，请重试。")
                }
            }
        } else {
            manager.show(detail: "已切换至\(updatedPrefs.resolutionDisplayLabel) · \(updatedPrefs.targetFPS)Hz。")
        }
    }

    private func clearContainerCache() {
        let freedBytes = runtime.clearTemporaryLogsAndStaging()
        refreshTelemetry()
        syncPreferencesToManager()
        let freedMB = Double(freedBytes) / (1024.0 * 1024.0)
        let msg = freedBytes > 0
            ? String(format: "已释放 %.1f MB 缓存空间，应用数据与登录状态已保留。", freedMB)
            : "缓存已清理，应用数据与登录状态已保留。"
        manager.show(detail: msg)
    }

    private func setCameraEnabled(_ enabled: Bool) {
        guard canChangeCamera else {
            syncPreferencesToManager()
            return
        }
        let applyCameraChange: (Bool) -> Void = { [weak self] allowed in
            guard let self else { return }
            let changed = self.runtime.cameraEnabled != allowed
            self.runtime.cameraEnabled = allowed
            var prefs = self.runtime.containerPreferences
            prefs.cameraEnabled = allowed
            self.runtime.containerPreferences = prefs
            self.syncPreferencesToManager()
            if !allowed && enabled {
                self.manager.show(detail: "摄像头尚未获得 macOS 授权。可在系统设置的“隐私与安全性 → 摄像头”中允许 \(MacdoraBrand.appName)。")
                return
            }
            guard changed else { return }
            if self.runtime.state == .running, !self.appSessions.isEmpty {
                let openPackages = Array(self.appSessions.keys)
                self.manager.show(detail: allowed ? "已启用摄像头权限，正在应用更改…" : "已关闭摄像头权限，正在应用更改…")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    for session in self.appSessions.values {
                        session.stopStreamAndTimers()
                    }
                    await self.runtime.closeDisplay()
                    _ = await self.runtime.stop()
                    for pkg in openPackages {
                        self.openApp(package: pkg, forceReconfigureDisplay: true)
                    }
                }
            } else if self.runtime.state == .ready {
                self.manager.show(detail: allowed ? "已启用摄像头权限，正在刷新运行环境…" : "已关闭摄像头权限，正在刷新运行环境…")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    _ = await self.runtime.stop()
                    try? await self.runtime.prepare()
                    try? await self.runtime.start()
                    self.refreshTelemetry()
                    self.manager.show(detail: allowed ? "摄像头权限已就绪。" : "摄像头权限已关闭。")
                }
            } else {
                self.manager.show(detail: allowed ? "摄像头权限已启用。" : "摄像头权限已关闭。")
            }
        }
        if enabled {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async { [weak self] in
                    _ = self
                    applyCameraChange(allowed)
                }
            }
        } else {
            applyCameraChange(false)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let session = activeSession,
           let win = session.window.window,
           win.isVisible || win.isMiniaturized || session.isOpening {
            session.window.presentWindow()
        } else if let injected = injectedApplicationWindow,
                  let win = injected.window,
                  win.isVisible || win.isMiniaturized {
            injected.presentWindow()
        } else {
            manager.presentWindow()
        }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let sessions = appSessions.values.sorted(by: { $0.package < $1.package })
        var addedRestoreItems = false
        for session in sessions {
            guard let win = session.window.window,
                  win.isVisible || win.isMiniaturized || session.isOpening else { continue }
            let restore = menu.addItem(withTitle: "返回 \(win.title)", action: #selector(restoreSpecificApplicationCommand(_:)), keyEquivalent: "")
            restore.target = self
            restore.representedObject = session.package
            restore.image = win.miniwindowImage
            addedRestoreItems = true
        }
        if !addedRestoreItems,
           let injected = injectedApplicationWindow,
           let win = injected.window,
           win.isVisible || win.isMiniaturized {
            let restore = menu.addItem(withTitle: "返回 \(win.title)", action: #selector(restoreSpecificApplicationCommand(_:)), keyEquivalent: "")
            restore.target = self
            restore.image = win.miniwindowImage
            addedRestoreItems = true
        }
        if addedRestoreItems {
            menu.addItem(.separator())
        }
        let management = menu.addItem(withTitle: "打开 \(MacdoraBrand.appName)", action: #selector(managementCommand), keyEquivalent: "")
        management.target = self
        return menu
    }

    @objc private func restoreSpecificApplicationCommand(_ sender: NSMenuItem) {
        if let pkg = sender.representedObject as? String, let session = appSessions[pkg] {
            activePackage = pkg
            session.window.presentWindow()
        } else {
            applicationWindow?.presentWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isRestartingForUpdate || runtime.state == .stopped {
            terminating = true
            operation?.cancel()
            telemetryTimer?.invalidate(); telemetryTimer = nil
            for session in appSessions.values {
                session.openTask?.cancel()
                session.stopStreamAndTimers()
            }
            return .terminateNow
        }
        if terminating { return .terminateLater }
        terminating = true; operation?.cancel()
        telemetryTimer?.invalidate(); telemetryTimer = nil
        for session in appSessions.values {
            session.generation = UUID()
            session.openTask?.cancel()
            session.stopStreamAndTimers()
            session.window.failure("正在正常退出 \(MacdoraBrand.appName)…")
        }
        Task {
            let completed = await runtime.stop()
            if completed { sender.reply(toApplicationShouldTerminate: true) }
            else {
                terminating = false
                for session in appSessions.values {
                    session.window.failure(RuntimeError.stopUnconfirmed.localizedDescription)
                }
                manager.update(runtime.state); manager.showWindow(nil)
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}
