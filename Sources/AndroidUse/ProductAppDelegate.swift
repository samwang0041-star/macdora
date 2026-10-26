import AppKit
import AVFoundation
import Metal
import UniformTypeIdentifiers

@MainActor
final class ProductAppDelegate: NSObject, NSApplicationDelegate {
    private let runtime = RuntimeController()
    private var manager: ManagementWindow!
    private var applicationWindow: ApplicationWindow?
    private var stream: VideoStream?
    private var operation: Task<Void, Never>?
    private var displayGeneration = UUID()
    private var presenceTimer: Timer?
    private var telemetryTimer: Timer?
    private var presenceQueryInProgress = false
    private var absentCount = 0
    private var hasObservedTarget = false
    private var hasPresentedFrame = false
    private var hasDecodedFrame = false
    private var terminating = false
    private var isRestartingForUpdate = false
    private var openingPackage: String?
    private var keyboardMenu: HostKeyboardMenu?
    private var uninstallConfirmationActive = false
    private var activePackage: String = DefaultApp.package
    private var presentationTimes: [Double] = []
    private var usingHardwareDecoder = true
    private let dockPresentation = AppDockPresentation(mode: AppDockIconMode.parse(arguments: ProcessInfo.processInfo.arguments))

    init(manager: ManagementWindow? = nil, applicationWindow: ApplicationWindow? = nil) {
        self.manager = manager
        self.applicationWindow = applicationWindow
        super.init()
    }

    private func resolvedAppMetadata(for package: String) -> ContainerApp {
        runtime.cachedContainerApps().first(where: { $0.package == package })
            ?? ContainerApp.metadata(for: package)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        dockPresentation.update(app: nil)
        installMenus()
        manager = ManagementWindow()
        manager.onOpen = { [weak self] in self?.openApp(package: self?.activePackage ?? DefaultApp.package) }
        manager.onOpenApp = { [weak self] pkg in self?.openApp(package: pkg) }
        manager.onForceStopApp = { [weak self] pkg in self?.forceStopApp(package: pkg) }
        manager.onUninstallApp = { [weak self] pkg in self?.uninstallApp(package: pkg) }
        manager.onInstall = { [weak self] in self?.chooseAPK() }
        manager.onDropAPK = { [weak self] url in self?.installAPKFile(url) }
        manager.onStartRuntime = { [weak self] in self?.startContainerOnly() }
        manager.onStop = { [weak self] in self?.stopRuntime() }
        manager.onRefreshApps = { [weak self] in self?.refreshAppsCatalog() }
        manager.onCloseActiveApp = { [weak self] in self?.applicationWindow?.performExplicitClose() }
        manager.onSettings = { [weak self] in self?.showSettings() }
        manager.onToggleCamera = { [weak self] enabled in self?.setCameraEnabled(enabled) }
        manager.onUpdatePreferences = { [weak self] prefs in self?.updateContainerPreferences(prefs) }
        manager.onClearCache = { [weak self] in self?.clearContainerCache() }
        manager.onRevealData = { [weak self] in self?.revealData() }
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
        runtime.onDisplayTerminated = { [weak self] in
            guard let self, self.stream != nil, !self.terminating else { return }
            let appTitle = self.resolvedAppMetadata(for: self.activePackage).title
            self.displayFailed("\(appTitle) 会话已结束，可在管理台重新打开。")
        }

        manager.updateApps(runtime.cachedContainerApps(), activePackage: runtime.activeDisplayPackage)
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
        if window === applicationWindow?.window,
           let surface = applicationWindow?.surface,
           let cgImage = surface.currentSnapshotCGImage() {
            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = ctx
                let surfaceRect = view.convert(surface.bounds, from: surface)
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
        var prefs = runtime.containerPreferences
        prefs.tabletMode.toggle()
        updateContainerPreferences(prefs)
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
        openingPackage = nil
        displayGeneration = UUID()
        presenceTimer?.invalidate()
        presenceTimer = nil
        telemetryTimer?.invalidate()
        telemetryTimer = nil
        stream?.stop()
        stream = nil
        applicationWindow?.window?.orderOut(nil)
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
        presentationTimes.removeAll { now - $0 > 2.5 }
        var fps = 0.0
        var p95Ms = 0.0
        if presentationTimes.count >= 2, let first = presentationTimes.first, let last = presentationTimes.last, last > first {
            fps = min(60.0, Double(presentationTimes.count - 1) / max(0.25, now - first))
            var intervals: [Double] = []
            for i in 1..<presentationTimes.count {
                intervals.append((presentationTimes[i] - presentationTimes[i - 1]) * 1000.0)
            }
            intervals.sort()
            let p95Index = min(intervals.count - 1, Int(Double(intervals.count - 1) * 0.95))
            p95Ms = intervals[p95Index]
        }
        let activePkg = runtime.activeDisplayPackage
        let activeName = activePkg.map { resolvedAppMetadata(for: $0).title }
        let sample = runtime.sampleTelemetry(
            presentedFPS: fps,
            frameIntervalP95Ms: p95Ms,
            hardwareDecoder: usingHardwareDecoder,
            activeAppName: activeName,
            activePackage: activePkg
        )
        manager.updateTelemetry(sample)
        applicationWindow?.updateFPSBadge(fps)
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
                self.manager.updateApps(apps, activePackage: self.runtime.activeDisplayPackage)
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
            self.manager.updateApps(apps, activePackage: self.runtime.activeDisplayPackage)
        }
    }

    private func forceStopApp(package: String) {
        guard !runtime.state.isBusy, !terminating else { return }
        let appMeta = resolvedAppMetadata(for: package)
        Task { [weak self] in
            guard let self else { return }
            do {
                if self.runtime.activeDisplayPackage == package {
                    self.dockPresentation.update(app: nil)
                    self.stream?.stop()
                    self.stream = nil
                    await self.runtime.closeDisplay()
                    self.applicationWindow?.performRuntimeOperationClose()
                }
                try await self.runtime.forceStopApp(package: package)
                self.manager.updateApps(await self.runtime.refreshContainerApps(), activePackage: self.runtime.activeDisplayPackage)
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
                self?.manager.updateApps(self?.runtime.cachedContainerApps() ?? [], activePackage: self?.runtime.activeDisplayPackage)
                return
            }
            self.performUninstallApp(package: package, appTitle: appTitle)
        }
    }

    private func performUninstallApp(package: String, appTitle: String) {
        guard !runtime.state.isBusy, !terminating else { return }
        let previousOperation = operation
        previousOperation?.cancel()
        if activePackage == package || runtime.activeDisplayPackage == package {
            dockPresentation.update(app: nil)
            openingPackage = nil
            displayGeneration = UUID()
            presenceTimer?.invalidate()
            presenceTimer = nil
            stream?.stop()
            stream = nil
            presentationTimes.removeAll()
            applicationWindow?.performRuntimeOperationClose()
        }
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                await previousOperation?.value
                try Task.checkCancellation()
                if self.runtime.activeDisplayPackage == package {
                    self.stream?.stop()
                    self.stream = nil
                    await self.runtime.closeDisplay()
                    self.applicationWindow?.performRuntimeOperationClose()
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
                self.manager.updateApps(self.runtime.cachedContainerApps(), activePackage: self.runtime.activeDisplayPackage)
                self.syncPreferencesToManager()
                self.refreshTelemetry()
                self.manager.show(detail: "已卸载 \(appTitle)。")
            } catch is CancellationError {
                self.manager.updateApps(self.runtime.cachedContainerApps(), activePackage: self.runtime.activeDisplayPackage)
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
           let applicationWindow,
           stream != nil,
           runtime.activeDisplayPackage == package,
           (applicationWindow.window?.isVisible == true || applicationWindow.window?.isMiniaturized == true) {
            applicationWindow.presentWindow()
            return
        }
        if !forceReconfigureDisplay,
           openingPackage == package,
           operation != nil {
            applicationWindow?.presentWindow()
            return
        }
        activePackage = package
        openingPackage = package
        presentationTimes.removeAll()
        presenceTimer?.invalidate()
        presenceTimer = nil
        stream?.stop()
        stream = nil
        let previousOperation = operation
        previousOperation?.cancel()
        displayGeneration = UUID()
        let generation = displayGeneration
        let cachedApps = runtime.cachedContainerApps()
        manager.updateApps(cachedApps, activePackage: package)
        showApplicationWindow(for: appMeta)
        applicationWindow?.loading("正在准备 \(appMeta.title)…")
        operation = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.displayGeneration == generation {
                    self.openingPackage = nil
                }
            }
            do {
                await previousOperation?.value
                try Task.checkCancellation()
                self.stream?.stop(); self.stream = nil
                await self.runtime.closeDisplay()
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
                self.applicationWindow?.loading("正在启动运行环境…")
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
                self.applicationWindow?.configureForApp(refreshedMeta)
                self.dockPresentation.update(app: refreshedMeta)
                self.manager.updateApps(apps, activePackage: package)
                self.applicationWindow?.loading("正在打开 \(refreshedMeta.title)…")
                let endpoint = try await self.runtime.openDisplay(package: package)
                guard self.displayGeneration == generation, !Task.isCancelled else { await self.runtime.closeDisplay(); return }
                self.manager.updateApps(apps, activePackage: package)
                self.connect(endpoint, generation: generation)
            } catch is CancellationError {
                await self.runtime.closeDisplay()
            } catch {
                if self.displayGeneration == generation { self.displayFailed(error.localizedDescription) }
            }
        }
    }

    private func showApplicationWindow(for app: ContainerApp) {
        if applicationWindow == nil {
            guard let device = MTLCreateSystemDefaultDevice() else {
                manager.update(.failed("当前设备不支持硬件图形加速。")); return
            }
            let window = ApplicationWindow(device: device)
            window.onClose = { [weak self] in self?.closedApplicationWindow() }
            window.onRetry = { [weak self] in
                guard let self else { return }
                self.openApp(package: self.activePackage)
            }
            window.onManagement = { [weak self] in self?.manager.presentWindow() }
            window.onBack = { [weak window] in window?.surface.key(4) }
            window.onToggleTabletMode = { [weak self] in
                guard let self else { return }
                var prefs = self.runtime.containerPreferences
                prefs.tabletMode.toggle()
                self.updateContainerPreferences(prefs)
            }
            applicationWindow = window
        }
        let prefs = runtime.containerPreferences
        applicationWindow?.applyDisplayMode(
            tabletMode: prefs.tabletMode,
            preferredPixelSize: prefs.preferredPixelSize
        )
        applicationWindow?.configureForApp(app)
        dockPresentation.update(app: app)
        applicationWindow?.presentWindow()
    }

    private func connect(_ endpoint: DisplayEndpoint, generation: UUID) {
        guard let window = applicationWindow else { return }
        let stream = VideoStream()
        self.stream = stream
        hasObservedTarget = false
        hasPresentedFrame = false
        hasDecodedFrame = false
        presentationTimes.removeAll()
        window.surface.beginSession(generation)
        window.surface.clipboardSyncEnabled = runtime.containerPreferences.clipboardSyncEnabled
        window.surface.onPixelSizeChanged = { [weak window] size in
            window?.syncToPixelSize(size)
        }
        stream.decoder.onHardware = { [weak self] hw in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.displayGeneration == generation else { return }
                self.usingHardwareDecoder = hw
            }
        }
        window.surface.onPresented = { [weak self] _, hostTime in
            guard let self, self.displayGeneration == generation else { return }
            self.presentationTimes.append(hostTime)
            if self.presentationTimes.count > 180 {
                self.presentationTimes.removeFirst(self.presentationTimes.count - 180)
            }
        }
        let inputIssue: (String) -> Void = { [weak self, weak window] message in
            DispatchQueue.main.async { [weak self, weak window] in
                guard self?.displayGeneration == generation else { return }
                window?.showInputIssue(message)
            }
        }
        window.surface.onInputIssue = inputIssue
        window.surface.onPointerBegan = { [weak stream] in stream?.beginPointer($0) }
        stream.onConfirmedFocus = { [weak self, weak window] focus, pointer in
            DispatchQueue.main.async { [weak self, weak window] in
                guard self?.displayGeneration == generation else { return }
                window?.surface.confirmInputFocus(focus, pointerSequence: pointer)
            }
        }
        if runtime.containerPreferences.directIMEEnabled, let imePort = endpoint.imePort {
            stream.enableDirectInput(port: imePort) { [weak self, weak window] focus in
                DispatchQueue.main.async { [weak self, weak window] in
                    guard self?.displayGeneration == generation else { return }
                    window?.surface.setInputFocus(focus)
                }
            }
            window.surface.sendDirectText = { [weak stream] text, lease in
                stream?.sendText(text, lease: lease) { inputIssue($0 ?? "") }
            }
        }
        stream.onClipboard = { [weak self] text in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.displayGeneration == generation,
                      self.runtime.containerPreferences.clipboardSyncEnabled else { return }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            }
        }
        window.surface.sendInput = { [weak stream] in stream?.send($0) }
        stream.decoder.onFrame = { [weak window] frame in window?.surface.accept(frame, session: generation) }
        stream.decoder.onFirstDecodedFrame = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.displayGeneration == generation else { return }
                self.hasDecodedFrame = true
            }
        }
        stream.onSize = { [weak self, weak window] width, height in
            DispatchQueue.main.async { [weak self, weak window] in
                guard self?.displayGeneration == generation else { return }
                let newSize = CGSize(width: width, height: height)
                window?.surface.pixelSize = newSize
                window?.syncToPixelSize(newSize)
            }
        }
        stream.onError = { [weak self] error in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.displayGeneration == generation else { return }
                self.displayFailed(error.localizedDescription)
            }
        }
        window.surface.onFirstFrame = { [weak self] in
            guard let self, self.displayGeneration == generation else { return }
            self.hasPresentedFrame = true
            if self.hasObservedTarget { self.applicationWindow?.ready() }
            let isHorizontal = self.runtime.containerPreferences.tabletMode
            Task { @MainActor [weak self] in
                await self?.runtime.configureVirtualDisplayOrientation(tabletMode: isHorizontal)
            }
        }
        stream.connect(port: endpoint.port, startApp: endpoint.package)
        startPresenceMonitor(generation: generation)
        let appTitle = resolvedAppMetadata(for: endpoint.package).title
        Task { [weak self] in
            var deadline = DisplayStartupDeadline(at: CACurrentMediaTime())
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.displayGeneration == generation, self.stream != nil,
                      !(self.hasObservedTarget && self.hasPresentedFrame) else { return }
                let window = self.applicationWindow?.window
                let presentable = window?.isVisible == true && window?.isMiniaturized == false
                    && window?.occlusionState.contains(.visible) == true
                if deadline.expired(at: CACurrentMediaTime(), decoded: self.hasDecodedFrame,
                                    targetVisible: self.hasObservedTarget, presentable: presentable,
                                    applicationActive: NSApp.isActive && window?.isKeyWindow == true) {
                    self.displayFailed("\(appTitle) 暂时没有产生可显示的画面。请重新打开；若仍失败，请停止容器后重试。")
                    return
                }
            }
        }
    }

    private func startPresenceMonitor(generation: UUID) {
        presenceTimer?.invalidate()
        absentCount = 0
        let monitoredPackage = activePackage
        let appTitle = resolvedAppMetadata(for: monitoredPackage).title
        var tickCount = 0
        presenceTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.presenceQueryInProgress, self.displayGeneration == generation, self.stream != nil else { return }
                tickCount &+= 1
                if self.hasObservedTarget && self.absentCount == 0 && (tickCount % 5) != 0 {
                    return
                }
                self.presenceQueryInProgress = true
                let presence = await self.runtime.targetPresence(package: monitoredPackage)
                self.presenceQueryInProgress = false
                guard self.displayGeneration == generation else { return }
                switch presence {
                case .notRunning:
                    if self.hasObservedTarget {
                        self.absentCount += 1
                        if self.absentCount >= 2 { self.displayFailed("\(appTitle) 已退出。可以在容器管理台重新打开。") }
                    }
                case .visible, .systemInteraction:
                    self.absentCount = 0
                    if !self.hasObservedTarget {
                        self.hasObservedTarget = true
                        // Allow rendering under the loading state; readiness waits for an actual presentation.
                        self.applicationWindow?.awaitFirstPresentation()
                        if self.hasPresentedFrame { self.applicationWindow?.ready() }
                        self.refreshTelemetry()
                        if let snapDir = ProcessInfo.processInfo.environment["ANDROID_USE_SNAPSHOT_DIR"] {
                            let dirURL = URL(fileURLWithPath: snapDir, isDirectory: true)
                            Task { @MainActor [weak self] in
                                try? await Task.sleep(for: .seconds(3))
                                guard let self else { return }
                                self.refreshTelemetry()
                                self.writeWindowSnapshot(self.applicationWindow?.window, to: dirURL.appendingPathComponent("macdora-app-window.png"))
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
                case .unavailable: break
                }
            }
        }
    }

    private func displayFailed(_ message: String) {
        displayGeneration = UUID()
        let generation = displayGeneration
        openingPackage = nil
        presenceTimer?.invalidate(); presenceTimer = nil
        stream?.stop(); stream = nil
        presentationTimes.removeAll()
        applicationWindow?.failure(message)
        if runtime.state == .ready || runtime.state == .running {
            manager.show(detail: message)
            manager.update(runtime.state)
        } else {
            manager.update(.failed(message))
        }
        Task { [weak self] in
            guard let self, self.displayGeneration == generation else { return }
            await self.runtime.closeDisplay()
            self.manager.updateApps(self.runtime.cachedContainerApps(), activePackage: nil)
            self.manager.update(self.runtime.state)
        }
    }

    private func closedApplicationWindow() {
        dockPresentation.update(app: nil)
        displayGeneration = UUID()
        openingPackage = nil
        let previousOperation = operation
        previousOperation?.cancel()
        let generation = displayGeneration
        presenceTimer?.invalidate(); presenceTimer = nil
        stream?.stop(); stream = nil
        presentationTimes.removeAll()
        applicationWindow?.surface.sendInput = nil
        operation = Task { [weak self] in
            guard let self else { return }
            await previousOperation?.value
            guard self.displayGeneration == generation else { return }
            await self.runtime.closeDisplay()
            if !self.runtime.containerPreferences.keepWarmInBackground {
                _ = await self.runtime.stop()
            }
            if !self.terminating, self.displayGeneration == generation {
                self.manager.updateApps(self.runtime.cachedContainerApps(), activePackage: nil)
                self.manager.update(self.runtime.state)
                self.manager.presentWindow()
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
                self.manager.updateApps(apps, activePackage: self.runtime.activeDisplayPackage)
                self.manager.show(detail: "\(fileName) 安装完成。")
            } catch {
                self.manager.update(.failed(error.localizedDescription))
            }
        }
    }

    private func stopRuntime() {
        guard !runtime.state.isBusy, !terminating else { return }
        operation?.cancel(); displayGeneration = UUID()
        presenceTimer?.invalidate(); presenceTimer = nil
        stream?.stop(); stream = nil
        presentationTimes.removeAll()
        applicationWindow?.performExplicitClose()
        operation = Task { [weak self] in
            guard let self else { return }
            _ = await self.runtime.stop()
            self.manager.updateApps(self.runtime.cachedContainerApps(), activePackage: nil)
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
            readiness: runtime.evaluateReadinessChecks(metalAvailable: metalAvailable)
        )
    }

    private func updateContainerPreferences(_ prefs: ContainerPreferences) {
        let previous = runtime.containerPreferences
        runtime.containerPreferences = prefs
        applicationWindow?.surface.clipboardSyncEnabled = prefs.clipboardSyncEnabled
        if !prefs.directIMEEnabled {
            applicationWindow?.surface.sendDirectText = nil
        }
        applicationWindow?.applyDisplayMode(
            tabletMode: prefs.tabletMode,
            preferredPixelSize: prefs.preferredPixelSize
        )
        syncPreferencesToManager()
        if (previous.tabletMode != prefs.tabletMode || previous.resolutionPreset != prefs.resolutionPreset),
           runtime.state == .running,
           let activePkg = runtime.activeDisplayPackage {
            manager.show(detail: "已切换至\(prefs.resolutionDisplayLabel) · \(prefs.targetFPS)Hz。")
            openApp(package: activePkg, forceReconfigureDisplay: true)
        } else if previous.tabletMode != prefs.tabletMode, runtime.state == .ready {
            let expectedTabletMode = prefs.tabletMode
            let summary = "\(prefs.resolutionDisplayLabel) · \(prefs.targetFPS)Hz"
            manager.show(detail: "正在切换至\(prefs.resolutionDisplayLabel) · \(prefs.targetFPS)Hz…")
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
            manager.show(detail: "已切换至\(prefs.resolutionDisplayLabel) · \(prefs.targetFPS)Hz。")
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
            if self.runtime.state == .running, let pkg = self.runtime.activeDisplayPackage {
                self.manager.show(detail: allowed ? "已启用摄像头权限，正在应用更改…" : "已关闭摄像头权限，正在应用更改…")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.stream?.stop()
                    self.stream = nil
                    await self.runtime.closeDisplay()
                    _ = await self.runtime.stop()
                    self.openApp(package: pkg, forceReconfigureDisplay: true)
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
        if let window = applicationWindow?.window,
           window.isVisible || window.isMiniaturized || openingPackage != nil {
            applicationWindow?.presentWindow()
        } else {
            manager.presentWindow()
        }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        if let window = applicationWindow?.window, window.isVisible || window.isMiniaturized || openingPackage != nil {
            let restore = menu.addItem(withTitle: "返回 \(window.title)", action: #selector(restoreApplicationCommand), keyEquivalent: "")
            restore.target = self
            restore.image = window.miniwindowImage
            menu.addItem(.separator())
        }
        let management = menu.addItem(withTitle: "打开 \(MacdoraBrand.appName)", action: #selector(managementCommand), keyEquivalent: "")
        management.target = self
        return menu
    }

    @objc private func restoreApplicationCommand() { applicationWindow?.presentWindow() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isRestartingForUpdate || runtime.state == .stopped {
            terminating = true
            operation?.cancel()
            openingPackage = nil
            displayGeneration = UUID()
            presenceTimer?.invalidate(); presenceTimer = nil
            telemetryTimer?.invalidate(); telemetryTimer = nil
            stream?.stop(); stream = nil
            return .terminateNow
        }
        if terminating { return .terminateLater }
        terminating = true; operation?.cancel(); displayGeneration = UUID()
        openingPackage = nil
        presenceTimer?.invalidate(); presenceTimer = nil
        telemetryTimer?.invalidate(); telemetryTimer = nil
        stream?.stop(); stream = nil
        applicationWindow?.failure("正在正常退出 \(MacdoraBrand.appName)…")
        Task {
            let completed = await runtime.stop()
            if completed { sender.reply(toApplicationShouldTerminate: true) }
            else {
                terminating = false
                applicationWindow?.failure(RuntimeError.stopUnconfirmed.localizedDescription)
                manager.update(runtime.state); manager.showWindow(nil)
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}
