import Foundation

enum DemoApp {
    static let package = "local.macdora.demo"
    static let activity = ".MainActivity"
    static let version = "1.0"
}

enum DefaultApp {
    static let package = "com.android.settings"
}

struct ContainerApp: Codable, Equatable, Identifiable, Sendable {
    var id: String { package }
    let package: String
    var name: String
    var subtitle: String
    var version: String
    var category: String
    var iconSymbol: String
    var accentHex: UInt32
    var isSystem: Bool
    var isInstalled: Bool
    var iconPath: String?

    var title: String { name }
    var summary: String { subtitle }
    var symbolName: String { iconSymbol }
    var isSystemApp: Bool { isSystem }

    init(
        package: String,
        name: String,
        subtitle: String,
        version: String,
        category: String,
        iconSymbol: String,
        accentHex: UInt32,
        isSystem: Bool,
        isInstalled: Bool,
        iconPath: String? = nil
    ) {
        self.package = package
        self.name = name
        self.subtitle = subtitle
        self.version = version
        self.category = category
        self.iconSymbol = iconSymbol
        self.accentHex = accentHex
        self.isSystem = isSystem
        self.isInstalled = isInstalled
        self.iconPath = iconPath
    }

    static let internalPackages: Set<String> = [
        "local.androiduse.ime",
        "local.androiduse.probe",
        "local.androiduse.camtest",
        "local.androiduse.plugin.gnss"
    ]

    static func isInternalPackage(_ package: String) -> Bool {
        internalPackages.contains(package) || package.hasPrefix("local.androiduse.")
    }

    static func hasCuratedDisplayName(for package: String) -> Bool {
        switch package {
        case "com.sankuai.meituan.takeoutnew",
             DemoApp.package,
             "com.sankuai.meituan",
             "com.tencent.mm",
             "com.coolapk.market",
             "com.android.settings":
            return true
        default:
            return false
        }
    }

    static func resolveDefaultIconPath(
        for package: String,
        iconsDirectoryURL: URL? = nil,
        includeBundledResources: Bool = true,
        fileManager: FileManager = .default
    ) -> String? {
        guard isValidPackageIdentifier(package) else { return nil }
        let fileName = "\(package).png"
        var candidates: [URL] = []
        if let iconsDirectoryURL {
            candidates.append(iconsDirectoryURL.appendingPathComponent(fileName))
        }
        if let defaultRoot = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).appendingPathComponent("AndroidUse", isDirectory: true) {
            candidates.append(
                defaultRoot
                    .appendingPathComponent("private", isDirectory: true)
                    .appendingPathComponent("icons", isDirectory: true)
                    .appendingPathComponent(fileName)
            )
        }
        if includeBundledResources {
            if let bundled = Bundle.main.url(forResource: package, withExtension: "png", subdirectory: "AppIcons") {
                candidates.append(bundled)
            }
            if let resourceURL = Bundle.main.resourceURL {
                candidates.append(resourceURL.appendingPathComponent("AppIcons/\(fileName)"))
                candidates.append(resourceURL.appendingPathComponent("RuntimeSeed/icons/\(fileName)"))
            }
            #if DEBUG
            let repoRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            candidates.append(repoRoot.appendingPathComponent("Resources/AppIcons/\(fileName)"))
            #endif
        }

        for url in candidates where fileManager.isReadableFile(atPath: url.path) {
            return url.path
        }
        return nil
    }

    static func metadata(
        for package: String,
        version: String? = nil,
        isInstalled: Bool = true,
        iconPath: String? = nil,
        includeBundledResources: Bool = true
    ) -> ContainerApp {
        let resolvedVersion = (version?.isEmpty == false) ? version! : defaultVersion(for: package)
        let resolvedIconPath = iconPath ?? resolveDefaultIconPath(
            for: package,
            includeBundledResources: includeBundledResources
        )
        switch package {
        case "com.sankuai.meituan.takeoutnew":
            return ContainerApp(
                package: package,
                name: "美团外卖",
                subtitle: "美食外卖与即时配送",
                version: resolvedVersion,
                category: "生活服务",
                iconSymbol: "takeoutbag.and.cup.and.straw.fill",
                accentHex: 0xF59E0B,
                isSystem: false,
                isInstalled: isInstalled,
                iconPath: resolvedIconPath
            )
        case DemoApp.package:
            return ContainerApp(
                package: package,
                name: "演示应用",
                subtitle: "用于验证应用导入与容器的示例",
                version: resolvedVersion,
                category: "示例应用",
                iconSymbol: "app.badge.fill",
                accentHex: 0x0F97FF,
                isSystem: false,
                isInstalled: isInstalled,
                iconPath: resolvedIconPath
            )
        case "com.sankuai.meituan":
            return ContainerApp(
                package: package,
                name: "美团",
                subtitle: "本地生活服务",
                version: resolvedVersion,
                category: "生活服务",
                iconSymbol: "bag.fill",
                accentHex: 0x10B981,
                isSystem: false,
                isInstalled: isInstalled,
                iconPath: resolvedIconPath
            )
        case "com.tencent.mm":
            return ContainerApp(
                package: package,
                name: "微信",
                subtitle: "即时通讯 · 支持平板与手机同时登录",
                version: resolvedVersion,
                category: "社交通讯",
                iconSymbol: "message.fill",
                accentHex: 0x07C160,
                isSystem: false,
                isInstalled: isInstalled,
                iconPath: resolvedIconPath
            )
        case "com.coolapk.market":
            return ContainerApp(
                package: package,
                name: "酷安",
                subtitle: "数码与应用社区",
                version: resolvedVersion,
                category: "应用市场",
                iconSymbol: "square.stack.3d.up.fill",
                accentHex: 0x10B981,
                isSystem: false,
                isInstalled: isInstalled,
                iconPath: resolvedIconPath
            )
        case "com.android.settings":
            return ContainerApp(
                package: package,
                name: "系统设置",
                subtitle: "网络、显示与系统偏好",
                version: resolvedVersion,
                category: "系统组件",
                iconSymbol: "gearshape.2.fill",
                accentHex: 0x0F97FF,
                isSystem: true,
                isInstalled: true,
                iconPath: resolvedIconPath
            )
        default:
            let shortName = package.split(separator: ".").last.map(String.init) ?? package
            let displayName = shortName.prefix(1).uppercased() + shortName.dropFirst()
            return ContainerApp(
                package: package,
                name: displayName,
                subtitle: "独立应用",
                version: resolvedVersion,
                category: "用户应用",
                iconSymbol: "app.badge.fill",
                accentHex: 0x10B981,
                isSystem: false,
                isInstalled: isInstalled,
                iconPath: resolvedIconPath
            )
        }
    }

    private static func defaultVersion(for package: String) -> String {
        switch package {
        case DemoApp.package: return DemoApp.version
        case "com.sankuai.meituan.takeoutnew": return "8.84.2"
        case "com.tencent.mm": return "8.0.79"
        case "com.android.settings": return "17.0"
        default: return "已安装"
        }
    }

    static func isValidPackageIdentifier(_ package: String) -> Bool {
        package.range(of: #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$"#, options: .regularExpression) != nil
    }
}

struct DisplayResolutionOption: Equatable, Sendable {
    let preset: String
    let title: String
    let shortTitle: String
    let subtitle: String
    let landscapeSize: CGSize
    let portraitSize: CGSize

    func pixelSize(tabletMode: Bool) -> CGSize {
        tabletMode ? landscapeSize : portraitSize
    }

    func dimensionLabel(tabletMode: Bool, interfaceScale: DisplayInterfaceScale = .standard) -> String {
        let size = ContainerPreferences.pixelSize(for: preset, tabletMode: tabletMode, interfaceScale: interfaceScale)
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    func menuTitle(tabletMode: Bool, interfaceScale: DisplayInterfaceScale = .standard) -> String {
        "\(title) · \(dimensionLabel(tabletMode: tabletMode, interfaceScale: interfaceScale))"
    }
}

enum DisplayInterfaceScale: String, Codable, CaseIterable, Sendable {
    case small
    case standard
    case large

    var title: String {
        switch self {
        case .small: return "较小"
        case .standard: return "标准"
        case .large: return "较大"
        }
    }

    var percentage: Int {
        switch self {
        case .small: return 80
        case .standard: return 100
        case .large: return 125
        }
    }

    /// Every scale keeps one density. Android relaunches Activities that do
    /// not handle `density`, so the size changes only the display pixels.
    var nativeDPI: Int { 320 }

    func nativePixelSize(tabletMode: Bool) -> CGSize {
        let landscape: CGSize
        switch self {
        case .small: landscape = CGSize(width: 3200, height: 2000)
        case .standard: landscape = CGSize(width: 2560, height: 1600)
        case .large: landscape = CGSize(width: 2048, height: 1280)
        }
        return tabletMode ? landscape : CGSize(width: landscape.height, height: landscape.width)
    }
}

struct AppDisplayPreference: Codable, Equatable, Sendable {
    var resolutionPreset: String
    var tabletMode: Bool
    var interfaceScale: DisplayInterfaceScale

    init(resolutionPreset: String, tabletMode: Bool, interfaceScale: DisplayInterfaceScale = .standard) {
        self.resolutionPreset = ContainerPreferences.canonicalResolutionPreset(resolutionPreset)
        self.tabletMode = tabletMode
        self.interfaceScale = interfaceScale
    }

    private enum CodingKeys: String, CodingKey {
        case resolutionPreset, tabletMode, interfaceScale
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let preset = try values.decodeIfPresent(String.self, forKey: .resolutionPreset) ?? "1080p"
        resolutionPreset = ContainerPreferences.canonicalResolutionPreset(preset)
        tabletMode = try values.decodeIfPresent(Bool.self, forKey: .tabletMode) ?? true
        interfaceScale = try values.decodeIfPresent(DisplayInterfaceScale.self, forKey: .interfaceScale)
            ?? ContainerPreferences.legacyInterfaceScale(for: preset)
    }
}

struct ContainerPreferences: Codable, Equatable, Sendable {
    var resolutionPreset: String
    var interfaceScale: DisplayInterfaceScale
    var targetFPS: Int
    var keepWarmInBackground: Bool
    var clipboardSyncEnabled: Bool
    var directIMEEnabled: Bool
    var cameraEnabled: Bool
    /// Legacy persistence name retained for compatibility. This now controls
    /// only the display layout; the guest hardware identity is always tablet.
    var tabletMode: Bool
    var appDisplayOverrides: [String: AppDisplayPreference]

    init(
        resolutionPreset: String = "1080p",
        targetFPS: Int = 60,
        keepWarmInBackground: Bool = true,
        clipboardSyncEnabled: Bool = true,
        directIMEEnabled: Bool = true,
        cameraEnabled: Bool = true,
        tabletMode: Bool = true,
        appDisplayOverrides: [String: AppDisplayPreference] = [:],
        interfaceScale: DisplayInterfaceScale = .standard
    ) {
        self.resolutionPreset = Self.canonicalResolutionPreset(resolutionPreset)
        self.interfaceScale = interfaceScale
        self.targetFPS = targetFPS
        self.keepWarmInBackground = keepWarmInBackground
        self.clipboardSyncEnabled = clipboardSyncEnabled
        self.directIMEEnabled = directIMEEnabled
        self.cameraEnabled = cameraEnabled
        self.tabletMode = tabletMode
        self.appDisplayOverrides = appDisplayOverrides
    }

    private enum CodingKeys: String, CodingKey {
        case resolutionPreset
        case interfaceScale
        case targetFPS
        case keepWarmInBackground
        case clipboardSyncEnabled
        case directIMEEnabled
        case cameraEnabled
        case tabletMode
        case appDisplayOverrides
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let preset = try container.decodeIfPresent(String.self, forKey: .resolutionPreset) ?? "1080p"
        resolutionPreset = Self.canonicalResolutionPreset(preset)
        interfaceScale = try container.decodeIfPresent(DisplayInterfaceScale.self, forKey: .interfaceScale)
            ?? Self.legacyInterfaceScale(for: preset)
        targetFPS = try container.decodeIfPresent(Int.self, forKey: .targetFPS) ?? 60
        keepWarmInBackground = try container.decodeIfPresent(Bool.self, forKey: .keepWarmInBackground) ?? true
        clipboardSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .clipboardSyncEnabled) ?? true
        directIMEEnabled = try container.decodeIfPresent(Bool.self, forKey: .directIMEEnabled) ?? true
        cameraEnabled = try container.decodeIfPresent(Bool.self, forKey: .cameraEnabled) ?? true
        tabletMode = try container.decodeIfPresent(Bool.self, forKey: .tabletMode) ?? true
        appDisplayOverrides = try container.decodeIfPresent([String: AppDisplayPreference].self, forKey: .appDisplayOverrides) ?? [:]
    }

    static let `default` = ContainerPreferences(
        resolutionPreset: "1080p",
        targetFPS: 60,
        keepWarmInBackground: true,
        clipboardSyncEnabled: true,
        directIMEEnabled: true,
        cameraEnabled: true,
        tabletMode: true,
        appDisplayOverrides: [:]
    )

    static let resolutionOptions: [DisplayResolutionOption] = [
        DisplayResolutionOption(
            preset: "720p",
            title: "流畅",
            shortTitle: "流畅",
            subtitle: "减少视频传输与解码开销；不改变界面大小",
            landscapeSize: CGSize(width: 1280, height: 800),
            portraitSize: CGSize(width: 800, height: 1280)
        ),
        DisplayResolutionOption(
            preset: "1080p",
            title: "清晰（推荐）",
            shortTitle: "清晰",
            subtitle: "适合日常办公；不改变界面大小",
            landscapeSize: CGSize(width: 1920, height: 1200),
            portraitSize: CGSize(width: 1200, height: 1920)
        ),
        DisplayResolutionOption(
            preset: "1440p",
            title: "精细",
            shortTitle: "精细",
            subtitle: "文字边缘更细腻，资源占用更高；不改变界面大小",
            landscapeSize: CGSize(width: 2560, height: 1600),
            portraitSize: CGSize(width: 1600, height: 2560)
        )
    ]

    static func canonicalResolutionPreset(_ preset: String) -> String {
        switch preset {
        case "960x600", "1280x800_comfortable", "720p": return "720p"
        case "1440p": return "1440p"
        default: return "1080p"
        }
    }

    static func legacyInterfaceScale(for preset: String) -> DisplayInterfaceScale {
        switch preset {
        case "960x600", "1280x800_comfortable", "1440x900", "1920x1200_hidpi": return .large
        default: return .standard
        }
    }

    static func resolutionOption(for preset: String) -> DisplayResolutionOption {
        resolutionOptions.first { $0.preset == canonicalResolutionPreset(preset) }!
    }

    static func pixelSize(for preset: String, tabletMode: Bool) -> CGSize {
        resolutionOption(for: preset).pixelSize(tabletMode: tabletMode)
    }

    /// The video never exceeds the native display; scrcpy only scales down.
    static func pixelSize(for preset: String, tabletMode: Bool, interfaceScale: DisplayInterfaceScale) -> CGSize {
        let output = pixelSize(for: preset, tabletMode: tabletMode)
        let native = interfaceScale.nativePixelSize(tabletMode: tabletMode)
        return max(native.width, native.height) < max(output.width, output.height) ? native : output
    }

    static func scrcpyNewDisplaySpec(tabletMode: Bool, interfaceScale: DisplayInterfaceScale = .standard) -> String {
        let size = interfaceScale.nativePixelSize(tabletMode: tabletMode)
        return "\(Int(size.width))x\(Int(size.height))/\(interfaceScale.nativeDPI)"
    }

    static func displayLabel(for preset: String, tabletMode: Bool) -> String {
        let option = resolutionOption(for: preset)
        let sizeText = option.dimensionLabel(tabletMode: tabletMode)
        if tabletMode {
            switch option.preset {
            case "720p": return "1280 × 800 · 横屏布局"
            case "1080p": return "1920 × 1200 · 横屏布局"
            case "1440p": return "2560 × 1600 · 横屏超清"
            default: return "\(sizeText) · 横屏\(option.shortTitle)"
            }
        }
        switch option.preset {
        case "720p": return "800 × 1280 · 竖屏布局"
        case "1080p": return "1200 × 1920 · 竖屏布局"
        case "1440p": return "1600 × 2560 · 竖屏超清"
        default: return "\(sizeText) · 竖屏\(option.shortTitle)"
        }
    }

    func displayPreference(for package: String?) -> AppDisplayPreference {
        if let package, let override = appDisplayOverrides[package] {
            return override
        }
        return AppDisplayPreference(resolutionPreset: resolutionPreset, tabletMode: tabletMode, interfaceScale: interfaceScale)
    }

    var resolutionDisplayLabel: String {
        Self.displayLabel(for: resolutionPreset, tabletMode: tabletMode)
    }

    var displaySummary: String {
        "\(Self.resolutionOption(for: resolutionPreset).shortTitle) · \(interfaceScale.title) \(interfaceScale.percentage)% · \(tabletMode ? "横屏" : "竖屏")"
    }

    mutating func restoreRecommendedDisplay() {
        resolutionPreset = "1080p"
        interfaceScale = .standard
    }

    var preferredPixelSize: CGSize {
        Self.pixelSize(for: resolutionPreset, tabletMode: tabletMode)
    }

    var preferredDPI: Int {
        interfaceScale.nativeDPI
    }
}

enum ReadinessCheckStatus: String, Sendable {
    case ready = "就绪"
    case review = "建议关注"
    case blocked = "阻塞"
    case checking = "检测中"
}

struct ReadinessCheckItem: Equatable, Sendable {
    let id: String
    let area: String
    let title: String
    let detail: String
    let status: ReadinessCheckStatus
    let actionTitle: String?
}

struct ContainerProcessMetric: Equatable, Sendable {
    let name: String
    let role: String
    let pid: Int32?
    let cpuPercent: Double
    let rssMiB: Double
    let status: String
}

struct ContainerTelemetry: Equatable, Sendable {
    let totalCPUPercent: Double
    let emulatorCPUPercent: Double
    let hostClientCPUPercent: Double
    let totalRSSMiB: Double
    let emulatorRSSMiB: Double
    let hostClientRSSMiB: Double
    let guestMemoryBudgetMiB: Double
    let diskUsedGB: Double
    let presentedFPS: Double
    let frameIntervalP95Ms: Double
    let hardwareDecoder: Bool
    let activeAppName: String?
    let activePackage: String?
    let processes: [ContainerProcessMetric]

    static let idle = ContainerTelemetry(
        totalCPUPercent: 0,
        emulatorCPUPercent: 0,
        hostClientCPUPercent: 0,
        totalRSSMiB: 0,
        emulatorRSSMiB: 0,
        hostClientRSSMiB: 0,
        guestMemoryBudgetMiB: 6144,
        diskUsedGB: 0,
        presentedFPS: 0,
        frameIntervalP95Ms: 0,
        hardwareDecoder: true,
        activeAppName: nil,
        activePackage: nil,
        processes: []
    )
}

enum RuntimeState: Equatable {
    case stopped
    case preparing(String)
    case starting
    case ready
    case running
    case stopping
    case failed(String)

    var isBusy: Bool {
        switch self { case .preparing, .starting, .stopping: return true; default: return false }
    }
    var title: String {
        switch self {
        case .stopped: return "环境尚未启动"
        case .preparing(let detail): return detail
        case .starting: return "正在启动 Android 环境"
        case .ready: return "环境已就绪"
        case .running: return "容器应用正在运行"
        case .stopping: return "正在停止 Android 环境"
        case .failed(let error): return error
        }
    }
}

struct DisplayEndpoint {
    let port: UInt16
    let package: String
    let imePort: UInt16?
    init(port: UInt16, package: String, imePort: UInt16? = nil) {
        self.port = port; self.package = package; self.imePort = imePort
    }
}

enum TargetPresence: Equatable {
    case visible
    case systemInteraction
    case notRunning
    case unavailable
}

/// Parses the Android connectivity dump without retaining addresses or names.
/// INTERNET is a network capability, not proof of reachability to any business server.
enum RuntimeNetworkParser {
    static func hasConnectedInternetDefaultNetwork(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        guard let network = capture(#"(?m)^[ \t]*Active default network:[ \t]*(\d+)[ \t]*$"#, in: text) else { return false }
        var searchStart = text.startIndex
        while let opening = text.range(of: "NetworkAgentInfo{", range: searchStart..<text.endIndex) {
            var cursor = text.index(before: opening.upperBound)
            var depth = 0
            var closing: String.Index?
            while cursor < text.endIndex {
                if text[cursor] == "{" { depth += 1 }
                if text[cursor] == "}" {
                    depth -= 1
                    if depth == 0 { closing = text.index(after: cursor); break }
                }
                cursor = text.index(after: cursor)
            }
            guard let closing else { return false }
            let block = String(text[opening.lowerBound..<closing])
            if block.contains("network{\(network)}") {
                guard capture(#"\bni\{\S+[ \t]+([A-Z_]+)\b"#, in: block) == "CONNECTED",
                      let capabilities = capture(#"\bCapabilities:[ \t]*([A-Z_]+(?:&[A-Z_]+)*)"#, in: block) else { return false }
                return capabilities.split(separator: "&").contains("INTERNET")
            }
            searchStart = closing
        }
        return false
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
