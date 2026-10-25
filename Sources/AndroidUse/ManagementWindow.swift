import AppKit
import Metal
import QuartzCore
import UniformTypeIdentifiers

enum ManagementSection: Int, CaseIterable {
    case apps = 0
    case plugins = 1
    case monitor = 2
    case settings = 3
    case serving = 4
    case about = 5

    var title: String {
        switch self {
        case .apps: return "应用"
        case .plugins: return "插件"
        case .monitor: return "状态"
        case .settings: return "设置"
        case .serving: return "诊断"
        case .about: return "关于"
        }
    }

    var pageHeading: String {
        switch self {
        case .apps: return "应用"
        case .plugins: return "插件"
        case .monitor: return "运行状态"
        case .settings: return "偏好设置"
        case .serving: return "环境诊断"
        case .about: return "关于 Macdora"
        }
    }

    var pageSubheading: String {
        switch self {
        case .apps: return "独立窗口运行，账号与数据持久保存"
        case .plugins: return "按需下载启用系统扩展能力"
        case .monitor: return "实时帧率与系统资源占用"
        case .settings: return "显示比例、输入体验与权限管理"
        case .serving: return "核心组件与运行环境自检"
        case .about: return "版本与软件更新"
        }
    }

    var symbolName: String {
        switch self {
        case .apps: return "square.grid.2x2"
        case .plugins: return "puzzlepiece.extension"
        case .monitor: return "waveform.path.ecg"
        case .settings: return "slider.horizontal.3"
        case .serving: return "checkmark.shield"
        case .about: return "info.circle"
        }
    }
}

private enum AppCategoryFilter: String, CaseIterable {
    case all = "all"
    case installed = "installed"
    case enterprise = "enterprise"
    case lifestyle = "lifestyle"
    case system = "system"

    var label: String {
        switch self {
        case .all: return "全部"
        case .installed: return "已安装"
        case .enterprise: return "办公"
        case .lifestyle: return "生活"
        case .system: return "系统"
        }
    }
}

// MARK: - Macdora Design Tokens

@MainActor
enum TFTheme {
    static var isDark: Bool = false

    static var bg: NSColor { isDark ? hex(0x1C1C1E) : hex(0xF2F3F6) }
    static var frostedSidebarTint: NSColor { isDark ? hex(0x1C1C1E, alpha: 0.78) : hex(0xF2F3F6, alpha: 0.80) }
    static var canvas: NSColor { isDark ? hex(0x141416) : hex(0xFBFBFC) }
    static var card: NSColor { isDark ? hex(0x1C1C1F) : hex(0xFFFFFF) }
    static var card2: NSColor { isDark ? hex(0x242428) : hex(0xF4F5F7) }
    static var surfaceHover: NSColor {
        isDark
            ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.065)
            : NSColor(srgbRed: 15.0 / 255.0, green: 23.0 / 255.0, blue: 42.0 / 255.0, alpha: 0.05)
    }

    static var ink: NSColor { isDark ? hex(0xF3F4F6) : hex(0x0F1419) }
    static var ink2: NSColor { isDark ? hex(0xA1A1AA) : hex(0x4B5563) }
    static var ink3: NSColor { isDark ? hex(0x71717A) : hex(0x8A93A2) }
    static var ink4: NSColor { isDark ? hex(0x52525B) : hex(0xB6BDC9) }

    static var line: NSColor {
        isDark
            ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08)
            : NSColor(srgbRed: 15.0 / 255.0, green: 23.0 / 255.0, blue: 42.0 / 255.0, alpha: 0.08)
    }
    static var seamLine: NSColor {
        isDark
            ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.09)
            : NSColor(srgbRed: 15.0 / 255.0, green: 23.0 / 255.0, blue: 42.0 / 255.0, alpha: 0.11)
    }

    static var accent: NSColor { isDark ? hex(0x33AEFF) : hex(0x0F97FF) }
    static var accentSoft: NSColor {
        isDark
            ? NSColor(srgbRed: 51.0 / 255.0, green: 174.0 / 255.0, blue: 1.0, alpha: 0.15)
            : NSColor(srgbRed: 15.0 / 255.0, green: 151.0 / 255.0, blue: 1.0, alpha: 0.10)
    }
    static var positive: NSColor { isDark ? hex(0x34D399) : hex(0x10B981) }
    static var positiveSoft: NSColor {
        isDark
            ? NSColor(srgbRed: 52.0 / 255.0, green: 211.0 / 255.0, blue: 153.0 / 255.0, alpha: 0.15)
            : NSColor(srgbRed: 16.0 / 255.0, green: 185.0 / 255.0, blue: 129.0 / 255.0, alpha: 0.10)
    }
    static var warn: NSColor { isDark ? hex(0xFBBF24) : hex(0xF59E0B) }
    static var warnSoft: NSColor {
        isDark
            ? NSColor(srgbRed: 251.0 / 255.0, green: 191.0 / 255.0, blue: 36.0 / 255.0, alpha: 0.15)
            : NSColor(srgbRed: 245.0 / 255.0, green: 158.0 / 255.0, blue: 11.0 / 255.0, alpha: 0.10)
    }
    static var danger: NSColor { isDark ? hex(0xF87171) : hex(0xEF4444) }
    static var dangerSoft: NSColor {
        isDark
            ? NSColor(srgbRed: 248.0 / 255.0, green: 113.0 / 255.0, blue: 113.0 / 255.0, alpha: 0.15)
            : NSColor(srgbRed: 239.0 / 255.0, green: 68.0 / 255.0, blue: 68.0 / 255.0, alpha: 0.10)
    }

    static func hex(_ value: UInt32, alpha: CGFloat = 1.0) -> NSColor {
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}

// MARK: - Macdora Reusable Views

final class TFFlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class TFWindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

class TFCardView: NSView {
    var fillColor: NSColor = .clear { didSet { needsDisplay = true } }
    var strokeColor: NSColor? = nil { didSet { needsDisplay = true } }
    var lineWidth: CGFloat = 1.0 { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 12.0 { didSet { needsDisplay = true } }
    var leftCornersOnly: Bool = false { didSet { needsDisplay = true } }
    var dashed: Bool = false { didSet { needsDisplay = true } }
    var hasCardShadow: Bool = false { didSet { needsDisplay = true } }
    var hasLeftSeamShadow: Bool = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func updateLayer() {
        guard let layer else { return }
        layer.backgroundColor = fillColor.cgColor
        layer.cornerRadius = cornerRadius
        if #available(macOS 11.0, *) {
            layer.cornerCurve = .continuous
        }
        if leftCornersOnly {
            layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        } else {
            layer.maskedCorners = [
                .layerMinXMinYCorner, .layerMaxXMinYCorner,
                .layerMinXMaxYCorner, .layerMaxXMaxYCorner
            ]
        }
        if dashed {
            layer.borderWidth = 0
            layer.borderColor = nil
        } else if let strokeColor {
            layer.borderColor = strokeColor.cgColor
            layer.borderWidth = lineWidth
        } else {
            layer.borderColor = nil
            layer.borderWidth = 0
        }

        if hasLeftSeamShadow {
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = TFTheme.isDark ? 0.35 : 0.06
            layer.shadowOffset = CGSize(width: -6, height: 0)
            layer.shadowRadius = 12
        } else if hasCardShadow {
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = TFTheme.isDark ? 0.22 : 0.03
            layer.shadowOffset = CGSize(width: 0, height: -1)
            layer.shadowRadius = 2
        } else {
            layer.shadowOpacity = 0
        }
    }

    override var wantsUpdateLayer: Bool { !dashed }

    override func draw(_ dirtyRect: NSRect) {
        guard dashed else { return }
        let inset = bounds.insetBy(dx: 0.75, dy: 0.75)
        let path = NSBezierPath(roundedRect: inset, xRadius: cornerRadius, yRadius: cornerRadius)
        fillColor.setFill()
        path.fill()
        if let strokeColor {
            strokeColor.setStroke()
            let pattern: [CGFloat] = [5, 4]
            path.setLineDash(pattern, count: pattern.count, phase: 0)
            path.lineWidth = 1.0
            path.stroke()
        }
    }
}

final class TFIconBadgeView: NSView {
    private let bgView = TFCardView(frame: .zero)
    private let imageView = NSImageView()

    init(symbol: String, accentHex: UInt32, size: CGFloat = 40, cornerRadius: CGFloat = 10) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        bgView.translatesAutoresizingMaskIntoConstraints = false
        bgView.cornerRadius = cornerRadius
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        addSubview(bgView)
        addSubview(imageView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            bgView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bgView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bgView.topAnchor.constraint(equalTo: topAnchor),
            bgView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: round(size * 0.50)),
            imageView.heightAnchor.constraint(equalToConstant: round(size * 0.50))
        ])
        configure(symbol: symbol, accentHex: accentHex, pointSize: round(size * 0.44))
    }

    required init?(coder: NSCoder) { nil }

    func configure(symbol: String, accentHex: UInt32, pointSize: CGFloat = 17) {
        let color = TFTheme.hex(accentHex)
        bgView.fillColor = TFTheme.hex(accentHex, alpha: TFTheme.isDark ? 0.18 : 0.11)
        bgView.strokeColor = TFTheme.hex(accentHex, alpha: TFTheme.isDark ? 0.28 : 0.16)
        bgView.lineWidth = 1
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            imageView.image = image.withSymbolConfiguration(cfg)
            imageView.contentTintColor = color
        }
    }
}

@MainActor
final class TFAppIconView: NSView {
    private let clipView = NSView(frame: .zero)
    private let borderView = TFCardView(frame: .zero)
    let imageView = NSImageView()
    private(set) var hasOwnAppIcon = false

    init(app: ContainerApp, size: CGFloat = 40, cornerRadius: CGFloat = 10) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        clipView.translatesAutoresizingMaskIntoConstraints = false
        clipView.wantsLayer = true
        clipView.layer?.cornerRadius = cornerRadius
        if #available(macOS 11.0, *) {
            clipView.layer?.cornerCurve = .continuous
        }
        clipView.layer?.masksToBounds = true
        addSubview(clipView)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleAxesIndependently
        clipView.addSubview(imageView)

        borderView.translatesAutoresizingMaskIntoConstraints = false
        borderView.cornerRadius = cornerRadius
        borderView.fillColor = .clear
        borderView.strokeColor = TFTheme.line
        borderView.lineWidth = 1.0
        addSubview(borderView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            clipView.leadingAnchor.constraint(equalTo: leadingAnchor),
            clipView.trailingAnchor.constraint(equalTo: trailingAnchor),
            clipView.topAnchor.constraint(equalTo: topAnchor),
            clipView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: clipView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
            borderView.leadingAnchor.constraint(equalTo: leadingAnchor),
            borderView.trailingAnchor.constraint(equalTo: trailingAnchor),
            borderView.topAnchor.constraint(equalTo: topAnchor),
            borderView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        configure(with: app)
    }

    required init?(coder: NSCoder) { nil }

    func configure(with app: ContainerApp) {
        borderView.strokeColor = TFTheme.line
        if let image = Self.resolveAppIconImage(for: app) {
            hasOwnAppIcon = true
            imageView.image = image
            imageView.contentTintColor = nil
            clipView.layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            hasOwnAppIcon = false
            imageView.image = NSWorkspace.shared.icon(for: .applicationBundle)
            imageView.contentTintColor = nil
            clipView.layer?.backgroundColor = TFTheme.card2.cgColor
        }
    }

    static func resolveAppIconImage(for app: ContainerApp) -> NSImage? {
        if let explicitPath = app.iconPath,
           !explicitPath.isEmpty,
           FileManager.default.isReadableFile(atPath: explicitPath),
           let image = NSImage(contentsOfFile: explicitPath) {
            return image
        }
        if let fallbackPath = ContainerApp.resolveDefaultIconPath(for: app.package),
           let image = NSImage(contentsOfFile: fallbackPath) {
            return image
        }
        return nil
    }
}

final class TFButton: NSControl {
    enum Variant {
        case primary
        case secondary
        case subtle
        case ghost
        case danger
    }

    enum Size {
        case sm
        case md
    }

    var title: String {
        didSet {
            label.stringValue = title
            setAccessibilityLabel(title)
            invalidateIntrinsicContentSize()
        }
    }
    var symbolName: String? { didSet { updateIcon(); invalidateIntrinsicContentSize() } }
    var variant: Variant { didSet { refreshColors() } }
    let controlSizeMode: Size
    var onClick: (() -> Void)?

    private let card = TFCardView(frame: .zero)
    private let stack = NSStackView()
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var isPressed = false { didSet { refreshColors() } }

    override var isEnabled: Bool {
        didSet {
            alphaValue = isEnabled ? 1.0 : 0.45
            refreshColors()
        }
    }

    init(title: String, symbolName: String? = nil, variant: Variant = .secondary, size: Size = .sm) {
        self.title = title
        self.symbolName = symbolName
        self.variant = variant
        self.controlSizeMode = size
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        focusRingType = .exterior

        card.translatesAutoresizingMaskIntoConstraints = false
        card.cornerRadius = size == .sm ? 8 : 10
        addSubview(card)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(stack)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        stack.addArrangedSubview(iconView)

        label.stringValue = title
        label.font = .systemFont(ofSize: size == .sm ? 12 : 13, weight: .medium)
        label.lineBreakMode = .byClipping
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.addArrangedSubview(label)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        let padX: CGFloat = title.isEmpty ? (size == .sm ? 7 : 9) : (size == .sm ? 11 : 14)
        let height: CGFloat = size == .sm ? 28 : 34

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padX),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padX),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        label.isHidden = title.isEmpty
        updateIcon()
        refreshColors()
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { isEnabled }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onClick?()
        return true
    }

    override func keyDown(with event: NSEvent) {
        let hasShortcutModifier = !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if !hasShortcutModifier && (event.charactersIgnoringModifiers == " " || event.charactersIgnoringModifiers == "\r") {
            _ = accessibilityPerformPress()
        } else {
            super.keyDown(with: event)
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    private func updateIcon() {
        if let symbolName, let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let pt: CGFloat = controlSizeMode == .sm ? 11.5 : 13
            iconView.image = img.withSymbolConfiguration(.init(pointSize: pt, weight: .medium))
            iconView.isHidden = false
        } else {
            iconView.image = nil
            iconView.isHidden = true
        }
        label.isHidden = title.isEmpty
    }

    func refreshColors() {
        let fg: NSColor
        switch variant {
        case .primary:
            card.fillColor = isPressed ? TFTheme.hex(0x0080E6) : TFTheme.accent
            card.strokeColor = nil
            card.hasCardShadow = true
            fg = .white
        case .secondary:
            card.fillColor = isPressed ? TFTheme.card2 : TFTheme.card
            card.strokeColor = TFTheme.line
            card.hasCardShadow = true
            fg = TFTheme.ink
        case .subtle:
            card.fillColor = isPressed ? TFTheme.surfaceHover : TFTheme.card2
            card.strokeColor = nil
            card.hasCardShadow = false
            fg = TFTheme.ink
        case .ghost:
            card.fillColor = isPressed ? TFTheme.surfaceHover : .clear
            card.strokeColor = nil
            card.hasCardShadow = false
            fg = TFTheme.ink2
        case .danger:
            card.fillColor = isPressed ? TFTheme.dangerSoft : TFTheme.card
            card.strokeColor = TFTheme.danger.withAlphaComponent(0.32)
            card.hasCardShadow = false
            fg = TFTheme.danger
        }
        label.textColor = fg
        iconView.contentTintColor = fg
        card.needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if inside {
            if let action, let target {
                NSApp.sendAction(action, to: target, from: self)
            }
            onClick?()
        }
    }
}

/// Dedicated Android VM Start / Progress / Stop button for the main runtime bar:
/// - `.start`: Green button (#10B981) with a white play arrow and "启动".
/// - `.progress`: In-button horizontal progress bar + live stage expectation text & percentage.
/// - `.stop`: Red button (#EF4444) with a crisp white close icon (`xmark`) to shut down the Android VM.
@MainActor
final class TFRuntimeControlButton: NSControl {
    enum Mode: Equatable {
        case start
        case download
        case progress(fraction: CGFloat, statusText: String, isStopping: Bool)
        case stop
    }

    var mode: Mode = .start {
        didSet {
            guard mode != oldValue else { return }
            updateLayoutForMode()
            needsDisplay = true
        }
    }

    var onClick: (() -> Void)?
    private var isPressed = false { didSet { needsDisplay = true } }
    private var widthConstraint: NSLayoutConstraint!

    init(mode: Mode = .start) {
        self.mode = mode
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)

        widthConstraint = widthAnchor.constraint(equalToConstant: 74)
        NSLayoutConstraint.activate([
            widthConstraint,
            heightAnchor.constraint(equalToConstant: 28)
        ])
        updateLayoutForMode()
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { isEnabled }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onClick?()
        return true
    }

    override func keyDown(with event: NSEvent) {
        if [36, 49, 76].contains(event.keyCode), accessibilityPerformPress() { return }
        super.keyDown(with: event)
    }

    private func updateLayoutForMode() {
        switch mode {
        case .start:
            widthConstraint.constant = 74
            isEnabled = true
            toolTip = "启动安卓虚拟机"
            setAccessibilityLabel("启动")
        case .download:
            widthConstraint.constant = 104
            isEnabled = true
            toolTip = "下载并准备 Android 环境"
            setAccessibilityLabel("下载环境")
        case .progress(_, let statusText, _):
            widthConstraint.constant = 136
            isEnabled = false
            toolTip = statusText
            setAccessibilityLabel(statusText)
        case .stop:
            widthConstraint.constant = 36
            isEnabled = true
            toolTip = "关闭安卓虚拟机"
            setAccessibilityLabel("关闭安卓虚拟机")
        }
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: widthConstraint.constant, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        let rect = bounds
        let radius: CGFloat = 8.0
        let clipPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        switch mode {
        case .start, .download:
            ctx.saveGState()
            ctx.addPath(clipPath)
            ctx.setFillColor(MacdoraBrand.rgba(isPressed ? 0x059669 : 0x10B981))
            ctx.fillPath()
            ctx.restoreGState()

            // Crisp white Play triangle arrow on the left
            let playCenterX: CGFloat = 19.5
            let playCenterY = rect.midY
            let playPath = CGMutablePath()
            playPath.move(to: CGPoint(x: playCenterX - 3.6, y: playCenterY + 4.5))
            playPath.addLine(to: CGPoint(x: playCenterX - 3.6, y: playCenterY - 4.5))
            playPath.addLine(to: CGPoint(x: playCenterX + 4.4, y: playCenterY))
            playPath.closeSubpath()
            ctx.saveGState()
            ctx.setFillColor(MacdoraBrand.rgba(0xFFFFFF))
            ctx.addPath(playPath)
            ctx.fillPath()
            ctx.restoreGState()

            // "启动" label
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph
            ]
            let str = NSAttributedString(string: mode == .download ? "下载环境" : "启动", attributes: attrs)
            let textSize = str.size()
            let textRect = CGRect(
                x: 29.0,
                y: (rect.height - textSize.height) * 0.5,
                width: textSize.width + 4,
                height: textSize.height
            )
            str.draw(in: textRect)

        case .progress(let rawFraction, let statusText, let isStopping):
            let fraction = max(0, min(1, rawFraction))
            let accentHex: UInt32 = isStopping ? 0xEF4444 : 0x10B981

            ctx.saveGState()
            ctx.addPath(clipPath)
            ctx.clip()

            // Track background
            ctx.setFillColor(MacdoraBrand.rgba(accentHex, TFTheme.isDark ? 0.16 : 0.10))
            ctx.fill(rect)

            // Horizontal progress fill bar
            let fillW = round(rect.width * fraction)
            ctx.setFillColor(MacdoraBrand.rgba(accentHex, TFTheme.isDark ? 0.34 : 0.22))
            ctx.fill(CGRect(x: 0, y: 0, width: fillW, height: rect.height))

            // Crisp bottom progress indicator stripe
            ctx.setFillColor(MacdoraBrand.rgba(accentHex, 0.92))
            ctx.fill(CGRect(x: 0, y: 0, width: fillW, height: 2.5))
            ctx.restoreGState()

            // Subtle border
            ctx.saveGState()
            let insetRect = rect.insetBy(dx: 0.5, dy: 0.5)
            ctx.addPath(CGPath(roundedRect: insetRect, cornerWidth: radius - 0.5, cornerHeight: radius - 0.5, transform: nil))
            ctx.setStrokeColor(MacdoraBrand.rgba(accentHex, 0.40))
            ctx.setLineWidth(1.0)
            ctx.strokePath()
            ctx.restoreGState()

            // Stage status & percentage text
            let fgColor: NSColor
            if isStopping {
                fgColor = TFTheme.isDark ? TFTheme.hex(0xFCA5A5) : TFTheme.hex(0xB91C1C)
            } else {
                fgColor = TFTheme.isDark ? TFTheme.hex(0x6EE7B7) : TFTheme.hex(0x047857)
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: fgColor,
                .paragraphStyle: paragraph
            ]
            let str = NSAttributedString(string: statusText, attributes: attrs)
            let textSize = str.size()
            let textRect = CGRect(
                x: 4,
                y: (rect.height - textSize.height) * 0.5 + 0.5,
                width: rect.width - 8,
                height: textSize.height
            )
            str.draw(in: textRect)

        case .stop:
            ctx.saveGState()
            ctx.addPath(clipPath)
            ctx.setFillColor(MacdoraBrand.rgba(isPressed ? 0xDC2626 : 0xEF4444))
            ctx.fillPath()
            ctx.restoreGState()

            // Crisp white Close icon (X) centered on the red button
            let cx = rect.midX
            let cy = rect.midY
            let d: CGFloat = 4.6
            ctx.saveGState()
            ctx.setStrokeColor(MacdoraBrand.rgba(0xFFFFFF))
            ctx.setLineWidth(2.0)
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: cx - d, y: cy - d))
            ctx.addLine(to: CGPoint(x: cx + d, y: cy + d))
            ctx.move(to: CGPoint(x: cx - d, y: cy + d))
            ctx.addLine(to: CGPoint(x: cx + d, y: cy - d))
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if inside {
            onClick?()
        }
    }
}

// Macdora Segmented Control
final class TFSegmentedControl: NSView {
    struct Option {
        let value: String
        let label: String
    }

    let options: [Option]
    var selectedValue: String { didSet { refreshSegments() } }
    var onSelect: ((String) -> Void)?

    private let track = TFCardView(frame: .zero)
    private let stack = NSStackView()
    private var segmentCards: [String: TFCardView] = [:]
    private var segmentLabels: [String: NSTextField] = [:]

    init(options: [Option], selectedValue: String) {
        self.options = options
        self.selectedValue = selectedValue
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        track.translatesAutoresizingMaskIntoConstraints = false
        track.cornerRadius = 8
        track.fillColor = TFTheme.card2
        track.strokeColor = TFTheme.line
        addSubview(track)

        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for (idx, opt) in options.enumerated() {
            let pill = TFCardView(frame: .zero)
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.cornerRadius = 6.5

            let lbl = NSTextField(labelWithString: opt.label)
            lbl.font = .systemFont(ofSize: 12, weight: .medium)
            lbl.alignment = .center
            lbl.translatesAutoresizingMaskIntoConstraints = false
            pill.addSubview(lbl)

            let btn = NSButton(title: "", target: self, action: #selector(segmentTapped(_:)))
            btn.tag = idx
            btn.isBordered = false
            btn.isTransparent = true
            btn.translatesAutoresizingMaskIntoConstraints = false
            pill.addSubview(btn)

            NSLayoutConstraint.activate([
                pill.heightAnchor.constraint(equalToConstant: 24),
                lbl.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 10),
                lbl.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -10),
                lbl.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
                btn.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
                btn.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
                btn.topAnchor.constraint(equalTo: pill.topAnchor),
                btn.bottomAnchor.constraint(equalTo: pill.bottomAnchor)
            ])

            segmentCards[opt.value] = pill
            segmentLabels[opt.value] = lbl
            stack.addArrangedSubview(pill)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            track.leadingAnchor.constraint(equalTo: leadingAnchor),
            track.trailingAnchor.constraint(equalTo: trailingAnchor),
            track.topAnchor.constraint(equalTo: topAnchor),
            track.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        refreshSegments()
    }

    required init?(coder: NSCoder) { nil }

    @objc private func segmentTapped(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < options.count else { return }
        let next = options[sender.tag].value
        guard next != selectedValue else { return }
        selectedValue = next
        onSelect?(next)
    }

    func refreshSegments() {
        track.fillColor = TFTheme.card2
        track.strokeColor = TFTheme.line
        for opt in options {
            let active = opt.value == selectedValue
            if let pill = segmentCards[opt.value] {
                pill.fillColor = active ? TFTheme.card : .clear
                pill.hasCardShadow = active
                pill.needsDisplay = true
            }
            if let lbl = segmentLabels[opt.value] {
                lbl.textColor = active ? TFTheme.ink : TFTheme.ink2
                lbl.font = .systemFont(ofSize: 12, weight: active ? .medium : .regular)
            }
        }
    }
}

// Macdora 38x22 Toggle
final class TFToggleSwitch: NSControl {
    var isOn: Bool { didSet { refreshState() } }
    var onToggle: ((Bool) -> Void)?

    private let track = TFCardView(frame: .zero)
    private let thumb = TFCardView(frame: .zero)
    private var thumbLeading: NSLayoutConstraint!

    override var isEnabled: Bool {
        didSet {
            alphaValue = isEnabled ? 1.0 : 0.45
            refreshState()
        }
    }

    init(isOn: Bool) {
        self.isOn = isOn
        super.init(frame: NSRect(x: 0, y: 0, width: 38, height: 22))
        translatesAutoresizingMaskIntoConstraints = false

        track.translatesAutoresizingMaskIntoConstraints = false
        track.cornerRadius = 11
        addSubview(track)

        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.cornerRadius = 9
        thumb.fillColor = .white
        thumb.hasCardShadow = true
        addSubview(thumb)

        thumbLeading = thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: isOn ? 18 : 2)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 38),
            heightAnchor.constraint(equalToConstant: 22),
            track.leadingAnchor.constraint(equalTo: leadingAnchor),
            track.trailingAnchor.constraint(equalTo: trailingAnchor),
            track.topAnchor.constraint(equalTo: topAnchor),
            track.bottomAnchor.constraint(equalTo: bottomAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 18),
            thumb.heightAnchor.constraint(equalToConstant: 18),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbLeading
        ])

        refreshState()
    }

    required init?(coder: NSCoder) { nil }

    func refreshState() {
        track.fillColor = isOn ? TFTheme.accent : TFTheme.card2
        track.strokeColor = isOn ? nil : TFTheme.line
        thumbLeading.constant = isOn ? 18 : 2
        track.needsDisplay = true
        thumb.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        guard inside else { return }
        isOn.toggle()
        onToggle?(isOn)
    }
}

private final class APKDropCardView: TFCardView {
    var onDropAPK: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              urls.contains(where: { $0.pathExtension.lowercased() == "apk" }) else {
            return []
        }
        fillColor = TFTheme.accentSoft
        strokeColor = TFTheme.accent
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        fillColor = .clear
        strokeColor = TFTheme.line
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        fillColor = .clear
        strokeColor = TFTheme.line
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              let apkURL = urls.first(where: { $0.pathExtension.lowercased() == "apk" }) else {
            return false
        }
        onDropAPK?(apkURL)
        return true
    }
}

// MARK: - ManagementWindow (Macdora Shell + Pages)

@MainActor
final class TFProgressBarView: NSView {
    var percent: Int = 0 {
        didSet {
            let clamped = min(100, max(0, percent))
            if clamped != percent {
                percent = clamped
                return
            }
            needsDisplay = true
        }
    }

    var isCompleted: Bool = false {
        didSet { needsDisplay = true }
    }

    var fillRatio: CGFloat {
        CGFloat(min(100, max(0, percent))) / 100.0
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        identifier = NSUserInterfaceItemIdentifier("macdora-update-progress-bar")
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 8)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        let trackRect = bounds
        let radius = min(4.0, trackRect.height * 0.5)
        let trackPath = CGPath(roundedRect: trackRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(trackPath)
        ctx.setFillColor(TFTheme.card2.cgColor)
        ctx.fillPath()

        let ratio = fillRatio
        if ratio > 0.0 {
            let fillWidth = max(radius * 2.0, trackRect.width * ratio)
            let fillRect = CGRect(x: trackRect.minX, y: trackRect.minY, width: min(trackRect.width, fillWidth), height: trackRect.height)
            let fillPath = CGPath(roundedRect: fillRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.addPath(fillPath)
            let fillColor = isCompleted ? TFTheme.positive : TFTheme.accent
            ctx.setFillColor(fillColor.cgColor)
            ctx.fillPath()
        }
        ctx.restoreGState()
    }
}

@MainActor
final class ManagementWindow: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate {
    var onOpen: (() -> Void)?
    var onOpenApp: ((String) -> Void)?
    var onForceStopApp: ((String) -> Void)?
    var onUninstallApp: ((String) -> Void)?
    var onCloseActiveApp: (() -> Void)?
    var onInstall: (() -> Void)?
    var onDropAPK: ((URL) -> Void)?
    var onStartRuntime: (() -> Void)?
    var onStop: (() -> Void)?
    var onRefreshApps: (() -> Void)?
    var onSettings: (() -> Void)?
    var onToggleCamera: ((Bool) -> Void)?
    var onUpdatePreferences: ((ContainerPreferences) -> Void)?
    var onClearCache: (() -> Void)?
    var onRevealData: (() -> Void)?
    var onImportDeveloperPlugin: (() -> Void)?
    var onExportDeveloperPluginTemplate: (() -> Void)?
    var onRevealPluginsDirectory: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onStartUpdateDownload: (() -> Void)?
    var onCancelUpdateDownload: (() -> Void)?
    var onRestartToInstallUpdate: (() -> Void)?

    private var selectedSection: ManagementSection = .apps
    private var selectedCategory: AppCategoryFilter = .all
    private var searchQuery: String = ""
    private var currentState: RuntimeState = .stopped
    private var apps: [ContainerApp] = []
    private var activePackage: String?
    private var currentTelemetry: ContainerTelemetry = .idle
    private var currentPreferences: ContainerPreferences = .default
    private var currentReadiness: [ReadinessCheckItem] = []
    private var cameraEnabled = true
    private var canChangeCamera = true
    private var rootPath = ""
    private var bannerMessage: String?
    private weak var pluginManager: SystemPluginManager?
    private(set) var activePluginDetailID: String?
    private var locationWorkspaceViews: [String: DeveloperLocationWorkspaceView] = [:]
    private weak var livePluginStatusLabel: NSTextField?
    private weak var livePluginToggleButton: TFButton?
    private(set) var currentUpdateState: MacdoraUpdateState = .idle(lastCheckedAt: nil)

    private let rootView = TFFlippedView(frame: NSRect(x: 0, y: 0, width: 1060, height: 700))
    private let sidebarBackdrop = NSVisualEffectView()
    private let sidebarTintView = TFCardView(frame: .zero)
    private let contentCard = TFCardView(frame: .zero)
    private let titleBarLine = NSTextField(labelWithString: "应用")
    private var headerInstallButton: TFButton!
    private var themeToggleButton: TFButton!
    private let brandLockupView = MacdoraBrandLockupView(frame: .zero)

    private var navRowCards: [ManagementSection: TFCardView] = [:]
    private var navRowIcons: [ManagementSection: NSImageView] = [:]
    private var navRowLabels: [ManagementSection: NSTextField] = [:]
    private var quickAppIcons: [String: TFAppIconView] = [:]
    private let quickHeaderLabel = NSTextField(labelWithString: "常用")
    private weak var activeRuntimeButton: TFRuntimeControlButton?
    private weak var activeRuntimeFPSLabel: NSTextField?
    private var runtimeProgressTimer: Timer?
    private var runtimeBusyStartDate: Date?
    private var needsRuntimeDownload = false
    private var runtimeEnvironmentProgress: RuntimeEnvironmentDownloadProgress?

    private let scrollView = NSScrollView()
    private let documentContainer = TFFlippedView(frame: .zero)
    private let pageStack = NSStackView()

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = MacdoraBrand.appName
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = false
        win.minSize = NSSize(width: 900, height: 600)
        win.center()
        super.init(window: win)
        win.delegate = self
        win.contentView = rootView
        buildLayout()
        applyTheme()
        rebuildPageContent()
    }

    required init?(coder: NSCoder) { nil }

    func presentWindow() {
        if window?.isMiniaturized == true {
            window?.deminiaturize(nil)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.miniaturize(nil)
        return false
    }

    // MARK: - Shell Construction

    private func buildLayout() {
        rootView.wantsLayer = true

        // 1. Sidebar Backdrop (236pt width)
        sidebarBackdrop.material = .underWindowBackground
        sidebarBackdrop.blendingMode = .behindWindow
        sidebarBackdrop.state = .active
        sidebarBackdrop.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(sidebarBackdrop)

        sidebarTintView.translatesAutoresizingMaskIntoConstraints = false
        sidebarTintView.cornerRadius = 0
        rootView.addSubview(sidebarTintView)

        let sidebarDragHeader = TFWindowDragView(frame: .zero)
        sidebarDragHeader.translatesAutoresizingMaskIntoConstraints = false
        sidebarTintView.addSubview(sidebarDragHeader)

        sidebarDragHeader.addSubview(brandLockupView)

        themeToggleButton = TFButton(
            title: "",
            symbolName: TFTheme.isDark ? "sun.max" : "moon",
            variant: .ghost,
            size: .sm
        )
        themeToggleButton.onClick = { [weak self] in
            TFTheme.isDark.toggle()
            self?.applyTheme()
            self?.rebuildPageContent()
        }
        sidebarDragHeader.addSubview(themeToggleButton)

        let navStack = NSStackView()
        navStack.orientation = .vertical
        navStack.alignment = .leading
        navStack.spacing = 2
        navStack.translatesAutoresizingMaskIntoConstraints = false
        sidebarTintView.addSubview(navStack)

        for section in ManagementSection.allCases {
            addFullWidth(makeNavRow(for: section), to: navStack)
        }

        let quickSpacer = NSView()
        quickSpacer.translatesAutoresizingMaskIntoConstraints = false
        quickSpacer.heightAnchor.constraint(equalToConstant: 14).isActive = true
        addFullWidth(quickSpacer, to: navStack)

        quickHeaderLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let quickHeaderWrap = NSView()
        quickHeaderWrap.translatesAutoresizingMaskIntoConstraints = false
        quickHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        quickHeaderWrap.addSubview(quickHeaderLabel)
        NSLayoutConstraint.activate([
            quickHeaderWrap.heightAnchor.constraint(equalToConstant: 22),
            quickHeaderLabel.leadingAnchor.constraint(equalTo: quickHeaderWrap.leadingAnchor, constant: 10),
            quickHeaderLabel.centerYAnchor.constraint(equalTo: quickHeaderWrap.centerYAnchor)
        ])
        addFullWidth(quickHeaderWrap, to: navStack)

        addFullWidth(makeQuickRow(title: "系统设置", package: DefaultApp.package, symbol: nil, action: #selector(quickOpenSystemSettings)), to: navStack)
        addFullWidth(makeQuickRow(title: "安装应用…", package: nil, symbol: "plus.circle", action: #selector(quickInstallAPK)), to: navStack)

        // 2. Right Content Card (.content-card with left-only 12pt radius)
        contentCard.translatesAutoresizingMaskIntoConstraints = false
        contentCard.cornerRadius = 12
        contentCard.leftCornersOnly = true
        contentCard.hasLeftSeamShadow = true
        rootView.addSubview(contentCard)

        let titleBar = TFWindowDragView(frame: .zero)
        titleBar.translatesAutoresizingMaskIntoConstraints = false
        contentCard.addSubview(titleBar)

        titleBarLine.font = .systemFont(ofSize: 13, weight: .medium)
        titleBarLine.translatesAutoresizingMaskIntoConstraints = false
        titleBar.addSubview(titleBarLine)

        let titleRightStack = NSStackView()
        titleRightStack.orientation = .horizontal
        titleRightStack.alignment = .centerY
        titleRightStack.spacing = 8
        titleRightStack.translatesAutoresizingMaskIntoConstraints = false
        titleBar.addSubview(titleRightStack)

        headerInstallButton = TFButton(title: "安装应用", symbolName: "plus", variant: .subtle, size: .sm)
        headerInstallButton.onClick = { [weak self] in self?.onInstall?() }
        titleRightStack.addArrangedSubview(headerInstallButton)

        // Scrollable main content area
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentCard.addSubview(scrollView)

        documentContainer.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentContainer

        pageStack.orientation = .vertical
        pageStack.alignment = .leading
        pageStack.spacing = 18
        pageStack.translatesAutoresizingMaskIntoConstraints = false
        documentContainer.addSubview(pageStack)

        let preferredPageWidth = pageStack.widthAnchor.constraint(equalTo: documentContainer.widthAnchor, constant: -72)
        preferredPageWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            sidebarBackdrop.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            sidebarBackdrop.topAnchor.constraint(equalTo: rootView.topAnchor),
            sidebarBackdrop.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            sidebarBackdrop.widthAnchor.constraint(equalToConstant: 236),

            sidebarTintView.leadingAnchor.constraint(equalTo: sidebarBackdrop.leadingAnchor),
            sidebarTintView.trailingAnchor.constraint(equalTo: sidebarBackdrop.trailingAnchor),
            sidebarTintView.topAnchor.constraint(equalTo: sidebarBackdrop.topAnchor),
            sidebarTintView.bottomAnchor.constraint(equalTo: sidebarBackdrop.bottomAnchor),

            sidebarDragHeader.leadingAnchor.constraint(equalTo: sidebarTintView.leadingAnchor),
            sidebarDragHeader.trailingAnchor.constraint(equalTo: sidebarTintView.trailingAnchor),
            sidebarDragHeader.topAnchor.constraint(equalTo: sidebarTintView.topAnchor),
            sidebarDragHeader.heightAnchor.constraint(equalToConstant: 72),

            brandLockupView.leadingAnchor.constraint(equalTo: sidebarDragHeader.leadingAnchor, constant: 15),
            brandLockupView.topAnchor.constraint(equalTo: sidebarDragHeader.topAnchor, constant: 31),

            themeToggleButton.trailingAnchor.constraint(equalTo: sidebarDragHeader.trailingAnchor, constant: -10),
            themeToggleButton.centerYAnchor.constraint(equalTo: brandLockupView.centerYAnchor),

            navStack.leadingAnchor.constraint(equalTo: sidebarTintView.leadingAnchor, constant: 10),
            navStack.trailingAnchor.constraint(equalTo: sidebarTintView.trailingAnchor, constant: -10),
            navStack.topAnchor.constraint(equalTo: sidebarDragHeader.bottomAnchor, constant: 2),

            contentCard.leadingAnchor.constraint(equalTo: sidebarBackdrop.trailingAnchor),
            contentCard.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            contentCard.topAnchor.constraint(equalTo: rootView.topAnchor),
            contentCard.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            titleBar.leadingAnchor.constraint(equalTo: contentCard.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: contentCard.trailingAnchor),
            titleBar.topAnchor.constraint(equalTo: contentCard.topAnchor),
            titleBar.heightAnchor.constraint(equalToConstant: 46),

            titleBarLine.leadingAnchor.constraint(equalTo: titleBar.leadingAnchor, constant: 24),
            titleBarLine.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor, constant: 1),

            titleRightStack.trailingAnchor.constraint(equalTo: titleBar.trailingAnchor, constant: -24),
            titleRightStack.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor, constant: 1),

            scrollView.leadingAnchor.constraint(equalTo: contentCard.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentCard.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentCard.bottomAnchor),

            documentContainer.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentContainer.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentContainer.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentContainer.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            pageStack.topAnchor.constraint(equalTo: documentContainer.topAnchor, constant: 10),
            pageStack.bottomAnchor.constraint(equalTo: documentContainer.bottomAnchor, constant: -36),
            pageStack.centerXAnchor.constraint(equalTo: documentContainer.centerXAnchor),
            preferredPageWidth,
            pageStack.widthAnchor.constraint(lessThanOrEqualToConstant: 740),
            pageStack.leadingAnchor.constraint(greaterThanOrEqualTo: documentContainer.leadingAnchor, constant: 32),
            pageStack.trailingAnchor.constraint(lessThanOrEqualTo: documentContainer.trailingAnchor, constant: -32)
        ])
    }

    private func addFullWidth(_ view: NSView, to stack: NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func makeNavRow(for section: ManagementSection) -> NSView {
        let row = TFCardView(frame: .zero)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.cornerRadius = 9

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        if let img = NSImage(systemSymbolName: section.symbolName, accessibilityDescription: nil) {
            icon.image = img.withSymbolConfiguration(.init(pointSize: 13.5, weight: .medium))
        }
        row.addSubview(icon)

        let lbl = NSTextField(labelWithString: section.title)
        lbl.font = .systemFont(ofSize: 13, weight: .regular)
        lbl.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(lbl)

        let btn = NSButton(title: "", target: self, action: #selector(navRowTapped(_:)))
        btn.tag = section.rawValue
        btn.isBordered = false
        btn.isTransparent = true
        btn.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(btn)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 32),
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            lbl.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            lbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            btn.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            btn.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            btn.topAnchor.constraint(equalTo: row.topAnchor),
            btn.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])

        navRowCards[section] = row
        navRowIcons[section] = icon
        navRowLabels[section] = lbl
        return row
    }

    private func makeQuickRow(title: String, package: String?, symbol: String?, action: Selector) -> NSView {
        let row = TFCardView(frame: .zero)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.cornerRadius = 9

        let leadingVisual: NSView
        if let package {
            let appIcon = TFAppIconView(app: ContainerApp.metadata(for: package), size: 18, cornerRadius: 4.5)
            quickAppIcons[package] = appIcon
            leadingVisual = appIcon
        } else {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                icon.image = img.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            }
            icon.contentTintColor = TFTheme.ink3
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 18),
                icon.heightAnchor.constraint(equalToConstant: 18)
            ])
            leadingVisual = icon
        }
        row.addSubview(leadingVisual)

        let lbl = NSTextField(labelWithString: title)
        lbl.font = .systemFont(ofSize: 13, weight: .regular)
        lbl.textColor = TFTheme.ink2
        lbl.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(lbl)

        let btn = NSButton(title: "", target: self, action: action)
        btn.isBordered = false
        btn.isTransparent = true
        btn.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(btn)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 31),
            leadingVisual.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            leadingVisual.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            lbl.leadingAnchor.constraint(equalTo: leadingVisual.trailingAnchor, constant: 8),
            lbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            btn.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            btn.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            btn.topAnchor.constraint(equalTo: row.topAnchor),
            btn.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])
        return row
    }

    @objc private func navRowTapped(_ sender: NSButton) {
        guard let sec = ManagementSection(rawValue: sender.tag) else { return }
        if sec == .plugins {
            activePluginDetailID = nil
        }
        selectSection(sec)
    }

    @objc private func quickOpenSystemSettings() { onOpenApp?(DefaultApp.package) }
    @objc private func quickInstallAPK() { onInstall?() }

    private func applyTheme() {
        window?.appearance = NSAppearance(named: TFTheme.isDark ? .darkAqua : .aqua)
        rootView.layer?.backgroundColor = TFTheme.bg.cgColor
        sidebarTintView.fillColor = TFTheme.frostedSidebarTint
        contentCard.fillColor = TFTheme.canvas
        contentCard.strokeColor = TFTheme.seamLine
        titleBarLine.textColor = TFTheme.ink
        quickHeaderLabel.textColor = TFTheme.ink3
        brandLockupView.isDark = TFTheme.isDark
        themeToggleButton.symbolName = TFTheme.isDark ? "sun.max" : "moon"
        themeToggleButton.refreshColors()
        headerInstallButton.refreshColors()
        for ws in locationWorkspaceViews.values {
            ws.refreshTheme()
        }
        activeRuntimeButton?.needsDisplay = true
        refreshSidebarState()
    }

    private func refreshSidebarState() {
        titleBarLine.stringValue = selectedSection.title
        headerInstallButton.isHidden = (selectedSection == .plugins || selectedSection == .about)
        for sec in ManagementSection.allCases {
            let active = (sec == selectedSection)
            navRowCards[sec]?.fillColor = active ? TFTheme.surfaceHover : .clear
            navRowLabels[sec]?.textColor = active ? TFTheme.ink : TFTheme.ink2
            navRowLabels[sec]?.font = .systemFont(ofSize: 13, weight: active ? .medium : .regular)
            navRowIcons[sec]?.contentTintColor = active ? TFTheme.ink : TFTheme.ink3
        }
    }

    // MARK: - Public Updates

    func bindPluginManager(_ manager: SystemPluginManager) {
        self.pluginManager = manager
        manager.onCatalogChanged = { [weak self] _ in
            guard let self else { return }
            self.refreshPluginsSection()
        }
        manager.onLocationTelemetryChanged = { [weak self] pluginID, telemetry in
            guard let self else { return }
            self.locationWorkspaceViews[pluginID]?.syncFromTelemetry(telemetry, recenterMap: false)
            if self.activePluginDetailID == pluginID || self.activePluginDetailID == nil {
                self.refreshLivePluginControls(for: pluginID)
            }
        }
        rebuildPageContent()
        Task { @MainActor in
            _ = await manager.refreshRemoteCatalog()
        }
    }

    func openPluginDetailPage(id: String) {
        guard let pm = pluginManager, pm.isPluginInstalled(id) else {
            show(detail: "请先下载该插件。")
            return
        }
        guard pm.isPluginEnabled(id) else {
            show(detail: "请先启用该插件。")
            return
        }
        guard let item = pm.catalogItems().first(where: { $0.id == id }), item.hasDedicatedWorkspace else {
            return
        }
        bannerMessage = nil
        selectedSection = .plugins
        activePluginDetailID = id
        refreshSidebarState()
        rebuildPageContent()
    }

    func closePluginDetailPage() {
        bannerMessage = nil
        activePluginDetailID = nil
        rebuildPageContent()
    }

    func refreshPluginsSection() {
        if let pm = pluginManager {
            for existingID in Array(locationWorkspaceViews.keys) where !pm.isPluginInstalled(existingID) {
                locationWorkspaceViews[existingID]?.removeFromSuperview()
                locationWorkspaceViews.removeValue(forKey: existingID)
            }
        }
        if let detailID = activePluginDetailID,
           pluginManager?.isPluginEnabled(detailID) != true {
            activePluginDetailID = nil
        }
        if selectedSection == .plugins,
           let detailID = activePluginDetailID,
           pluginManager?.isPluginEnabled(detailID) == true,
           let ws = locationWorkspaceViews[detailID],
           ws.superview === pageStack {
            if let pm = pluginManager, let loc = pm.locationPlugin(for: detailID) {
                ws.bindPlugin(loc)
                refreshLivePluginControls(for: detailID)
            }
            return
        }
        if selectedSection == .plugins || selectedSection == .settings || selectedSection == .serving {
            rebuildPageContent()
        }
    }

    private func refreshLivePluginControls(for id: String) {
        guard let manager = pluginManager else { return }
        if let label = livePluginStatusLabel {
            label.stringValue = manager.pluginStatusText(for: id)
            let hasError = manager.lastError(for: id) != nil || manager.pluginHealthStatus(for: id).isDegraded
            label.textColor = hasError ? TFTheme.danger : (activePluginDetailID == nil ? TFTheme.ink2 : TFTheme.ink3)
        }
        if activePluginDetailID == id, let toggle = livePluginToggleButton {
            let isBusy = manager.isPluginBusy(id)
            toggle.isEnabled = !isBusy
            toggle.title = isBusy ? "处理中…" : "停用"
        }
    }

    func selectSection(_ section: ManagementSection) {
        if section != .plugins {
            activePluginDetailID = nil
        }
        selectedSection = section
        refreshSidebarState()
        rebuildPageContent()
    }

    func update(_ state: RuntimeState) {
        let wasBusy = currentState.isBusy
        currentState = state
        if case .preparing = state {} else { runtimeEnvironmentProgress = nil }
        if case .failed(let msg) = state {
            bannerMessage = msg
        }
        if state.isBusy {
            if !wasBusy || runtimeBusyStartDate == nil {
                runtimeBusyStartDate = Date()
            }
            startRuntimeProgressTimerIfNeeded()
        } else {
            runtimeProgressTimer?.invalidate()
            runtimeProgressTimer = nil
            runtimeBusyStartDate = nil
        }
        refreshSidebarState()
        if selectedSection == .plugins, activePluginDetailID != nil, bannerMessage == nil {
            return
        }
        rebuildPageContent()
    }

    func updateEnvironmentDownloadNeeded(_ needed: Bool) {
        guard needed != needsRuntimeDownload else { return }
        needsRuntimeDownload = needed
        if selectedSection == .apps { rebuildPageContent() }
    }

    func updateEnvironmentDownloadProgress(_ progress: RuntimeEnvironmentDownloadProgress?) {
        runtimeEnvironmentProgress = progress
        activeRuntimeButton?.mode = currentRuntimeButtonMode()
    }

    private func startRuntimeProgressTimerIfNeeded() {
        guard runtimeProgressTimer == nil else { return }
        runtimeProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.currentState.isBusy {
                    self.runtimeProgressTimer?.invalidate()
                    self.runtimeProgressTimer = nil
                    return
                }
                self.activeRuntimeButton?.mode = self.currentRuntimeButtonMode()
            }
        }
    }

    private func currentRuntimeButtonMode() -> TFRuntimeControlButton.Mode {
        let elapsed = Date().timeIntervalSince(runtimeBusyStartDate ?? Date())
        switch currentState {
        case .stopped, .failed:
            return needsRuntimeDownload ? .download : .start
        case .preparing:
            if let progress = runtimeEnvironmentProgress {
                return .progress(fraction: CGFloat(progress.fraction), statusText: progress.statusText, isStopping: false)
            }
            return .progress(fraction: 0, statusText: "正在准备环境", isStopping: false)
        case .starting:
            let p = min(0.95, 0.38 + CGFloat((1.0 - exp(-elapsed / 2.8)) * 0.58))
            let pct = Int(round(p * 100))
            let stage: String
            if p < 0.62 {
                stage = "启动内核"
            } else if p < 0.84 {
                stage = "加载系统"
            } else {
                stage = "连接服务"
            }
            return .progress(fraction: p, statusText: "\(stage) \(pct)%", isStopping: false)
        case .stopping:
            let p = min(0.94, 0.32 + CGFloat((1.0 - exp(-elapsed / 1.4)) * 0.62))
            let pct = Int(round(p * 100))
            return .progress(fraction: p, statusText: "正在关闭 \(pct)%", isStopping: true)
        case .ready, .running:
            return .stop
        }
    }

    func updateApps(_ apps: [ContainerApp], activePackage: String?) {
        self.apps = apps
        self.activePackage = activePackage
        for app in apps {
            quickAppIcons[app.package]?.configure(with: app)
        }
        refreshSidebarState()
        if selectedSection == .apps || selectedSection == .monitor || selectedSection == .serving {
            rebuildPageContent()
        }
    }

    func updateTelemetry(_ telemetry: ContainerTelemetry) {
        currentTelemetry = telemetry
        if let fpsLabel = activeRuntimeFPSLabel {
            if telemetry.presentedFPS > 0.5 {
                fpsLabel.stringValue = String(format: "%.0f FPS", telemetry.presentedFPS)
                fpsLabel.isHidden = false
            } else {
                fpsLabel.stringValue = ""
                fpsLabel.isHidden = true
            }
        }
        if selectedSection == .monitor {
            rebuildPageContent()
        }
    }

    func updatePreferences(
        cameraEnabled: Bool,
        canChangeCamera: Bool,
        rootPath: String,
        preferences: ContainerPreferences,
        readiness: [ReadinessCheckItem]
    ) {
        let tabletModeChanged = self.currentPreferences.tabletMode != preferences.tabletMode
        let settingsChanged =
            self.cameraEnabled != cameraEnabled ||
            self.canChangeCamera != canChangeCamera ||
            self.rootPath != rootPath ||
            self.currentPreferences != preferences
        let readinessChanged = self.currentReadiness != readiness
        self.cameraEnabled = cameraEnabled
        self.canChangeCamera = canChangeCamera
        self.rootPath = rootPath
        self.currentPreferences = preferences
        self.currentReadiness = readiness
        if selectedSection == .settings && settingsChanged {
            rebuildPageContent()
        } else if selectedSection == .serving && (settingsChanged || readinessChanged) {
            rebuildPageContent()
        } else if selectedSection == .apps && tabletModeChanged {
            rebuildPageContent()
        }
    }

    func show(detail: String) {
        bannerMessage = detail
        rebuildPageContent()
    }

    func updateAppUpdateState(_ state: MacdoraUpdateState) {
        currentUpdateState = state
        refreshSidebarState()
        rebuildPageContent()
    }

    // MARK: - Page Rendering

    private func rebuildPageContent() {
        for sub in pageStack.arrangedSubviews {
            pageStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }

        // Page Header
        if !(selectedSection == .plugins && activePluginDetailID != nil) {
            addFullWidth(makePageHeader(), to: pageStack)
        }

        if let bannerMessage, !bannerMessage.isEmpty {
            addFullWidth(makeBannerRow(message: bannerMessage), to: pageStack)
        }

        if selectedSection != .about {
            switch currentUpdateState {
            case .available, .downloading, .readyToInstall, .installing:
                addFullWidth(makeCompactUpdateBannerCard(), to: pageStack)
            default:
                break
            }
        }

        switch selectedSection {
        case .apps:
            buildAppsPage()
        case .plugins:
            buildPluginsPage()
        case .monitor:
            buildMonitorPage()
        case .settings:
            buildSettingsPage()
        case .serving:
            buildReadinessPage()
        case .about:
            buildAboutPage()
        }
    }

    private func makePageHeader() -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false

        let h1 = NSTextField(labelWithString: selectedSection.pageHeading)
        h1.font = .systemFont(ofSize: 21, weight: .semibold)
        h1.textColor = TFTheme.ink
        h1.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(h1)

        let sub = NSTextField(labelWithString: selectedSection.pageSubheading)
        sub.font = .systemFont(ofSize: 13, weight: .regular)
        sub.textColor = TFTheme.ink2
        sub.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(sub)

        if selectedSection == .plugins && activePluginDetailID == nil {
            let actions = NSStackView()
            actions.orientation = .horizontal
            actions.alignment = .centerY
            actions.spacing = 8
            actions.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(actions)

            let importBtn = TFButton(title: "导入插件…", symbolName: "square.and.arrow.down", variant: .secondary, size: .sm)
            importBtn.onClick = { [weak self] in self?.onImportDeveloperPlugin?() }
            actions.addArrangedSubview(importBtn)

            let templateBtn = TFButton(title: "开发模板", symbolName: "doc.badge.plus", variant: .subtle, size: .sm)
            templateBtn.onClick = { [weak self] in self?.onExportDeveloperPluginTemplate?() }
            actions.addArrangedSubview(templateBtn)

            NSLayoutConstraint.activate([
                actions.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
                actions.centerYAnchor.constraint(equalTo: wrap.centerYAnchor)
            ])
        }

        NSLayoutConstraint.activate([
            wrap.heightAnchor.constraint(equalToConstant: 48),
            h1.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            h1.topAnchor.constraint(equalTo: wrap.topAnchor),
            sub.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            sub.topAnchor.constraint(equalTo: h1.bottomAnchor, constant: 3)
        ])
        return wrap
    }

    private func makeBannerRow(message: String) -> NSView {
        let card = TFCardView(frame: .zero)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.cornerRadius = 10
        card.fillColor = TFTheme.card
        card.strokeColor = TFTheme.line

        let dot = TFCardView(frame: .zero)
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.cornerRadius = 3
        dot.fillColor = TFTheme.accent
        card.addSubview(dot)

        let lbl = NSTextField(labelWithString: message)
        lbl.font = .systemFont(ofSize: 12.5, weight: .regular)
        lbl.textColor = TFTheme.ink2
        lbl.lineBreakMode = .byTruncatingTail
        lbl.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(lbl)

        let closeBtn = TFButton(title: "知道了", variant: .ghost, size: .sm)
        closeBtn.onClick = { [weak self] in
            self?.bannerMessage = nil
            self?.rebuildPageContent()
        }
        card.addSubview(closeBtn)

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 38),
            dot.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            dot.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            lbl.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            lbl.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            lbl.trailingAnchor.constraint(lessThanOrEqualTo: closeBtn.leadingAnchor, constant: -8),
            closeBtn.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            closeBtn.centerYAnchor.constraint(equalTo: card.centerYAnchor)
        ])
        return card
    }

    // MARK: 1. Apps Page

    private func buildPluginsPage() {
        if let detailID = activePluginDetailID,
           let item = pluginManager?.catalogItems().first(where: { $0.id == detailID }),
           item.state.isEnabled {
            buildSinglePluginDedicatedManagementPage(for: item)
            return
        }
        activePluginDetailID = nil
        addFullWidth(makePluginsCatalogSection(), to: pageStack)
    }

    private func makePluginsCatalogSection() -> NSView {
        let card = TFCardView(frame: .zero)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.cornerRadius = 12
        card.fillColor = TFTheme.card
        card.strokeColor = TFTheme.line
        card.hasCardShadow = true

        let listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(listStack)

        let items = pluginManager?.catalogItems() ?? SystemPluginCatalogItem.defaultPresetCatalog
        livePluginStatusLabel = nil
        livePluginToggleButton = nil
        for (idx, item) in items.enumerated() {
            addFullWidth(makePluginCatalogRow(item, isLast: idx == items.count - 1), to: listStack)
        }

        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: card.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        return card
    }

    private func makePluginCatalogRow(_ item: SystemPluginCatalogItem, isLast: Bool) -> NSView {
        let isBusy = pluginManager?.isPluginBusy(item.id) == true
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let badge = TFIconBadgeView(symbol: item.iconSymbol, accentHex: item.accentHex, size: 40, cornerRadius: 10)
        row.addSubview(badge)

        let titleLbl = NSTextField(labelWithString: item.name)
        titleLbl.font = .systemFont(ofSize: 14.5, weight: .medium)
        titleLbl.textColor = TFTheme.ink
        titleLbl.lineBreakMode = .byTruncatingTail
        titleLbl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(titleLbl)

        let statePill: NSView
        if isBusy && !item.state.isDownloading {
            statePill = makeStatusPill(text: "处理中…", tone: .neutral)
        } else {
            switch item.state {
            case .notInstalled:
                statePill = makeStatusPill(text: "未下载", tone: .neutral)
            case .downloading(let progress):
                statePill = makeStatusPill(text: String(format: "下载中 %.0f%%", progress * 100.0), tone: .warn)
            case .installed(let isEnabled):
                statePill = makeStatusPill(
                    text: isEnabled ? "已启用" : "未启用",
                    tone: isEnabled ? .positive : .neutral
                )
            case .failed:
                statePill = makeStatusPill(text: "未下载", tone: .neutral)
            }
        }
        row.addSubview(statePill)

        let isFailedState: Bool = {
            if case .failed = item.state { return true }
            return false
        }()
        let hasError = isFailedState || item.lastErrorDetail != nil
        let summaryText = (item.state.isEnabled || hasError) ? item.statusDetail : item.subtitle
        let descLbl = NSTextField(labelWithString: summaryText)
        descLbl.font = .systemFont(ofSize: 12.5, weight: .regular)
        descLbl.textColor = hasError ? TFTheme.danger : (item.state.isEnabled ? TFTheme.ink2 : TFTheme.ink3)
        descLbl.lineBreakMode = .byTruncatingTail
        descLbl.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(descLbl)
        if item.hasDedicatedWorkspace && item.state.isEnabled {
            livePluginStatusLabel = descLbl
        }

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.setContentHuggingPriority(.required, for: .horizontal)
        controls.setContentCompressionResistancePriority(.required, for: .horizontal)
        controls.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(controls)

        switch item.state {
        case .notInstalled, .failed:
            let downloadBtn = TFButton(
                title: "下载",
                symbolName: "arrow.down.circle",
                variant: .primary,
                size: .sm
            )
            downloadBtn.identifier = NSUserInterfaceItemIdentifier("plugin-download-\(item.id)")
            downloadBtn.setAccessibilityLabel("下载\(item.name)")
            downloadBtn.isEnabled = !isBusy
            downloadBtn.onClick = { [weak self] in
                guard let self, let pm = self.pluginManager else { return }
                Task { @MainActor in
                    do {
                        _ = try await pm.downloadAndInstallPlugin(id: item.id)
                    } catch {
                        self.show(detail: error.localizedDescription)
                    }
                }
            }
            controls.addArrangedSubview(downloadBtn)

        case .downloading(let progress):
            let progressBar = TFProgressBarView(frame: .zero)
            progressBar.identifier = NSUserInterfaceItemIdentifier("plugin-download-progress-\(item.id)")
            progressBar.percent = Int(progress * 100)
            progressBar.widthAnchor.constraint(equalToConstant: 80).isActive = true
            controls.addArrangedSubview(progressBar)
            let busyBtn = TFButton(title: "下载中…", variant: .subtle, size: .sm)
            busyBtn.isEnabled = false
            controls.addArrangedSubview(busyBtn)

        case .installed(let isEnabled):
            if let updateVersion = item.availableUpdateVersion {
                let updateBtn = TFButton(
                    title: "更新 v\(updateVersion)",
                    symbolName: "arrow.triangle.2.circlepath",
                    variant: .primary,
                    size: .sm
                )
                updateBtn.isEnabled = !isBusy
                updateBtn.onClick = { [weak self] in
                    guard let self, let pm = self.pluginManager else { return }
                    Task { @MainActor in
                        do {
                            _ = try await pm.downloadAndInstallPlugin(id: item.id, autoEnable: isEnabled)
                        } catch {
                            self.show(detail: error.localizedDescription)
                        }
                    }
                }
                controls.addArrangedSubview(updateBtn)
            }

            if isEnabled && item.hasDedicatedWorkspace {
                let enterBtn = TFButton(
                    title: "设置",
                    variant: .secondary,
                    size: .sm
                )
                enterBtn.isEnabled = !isBusy
                enterBtn.onClick = { [weak self] in
                    self?.openPluginDetailPage(id: item.id)
                }
                controls.addArrangedSubview(enterBtn)
            }

            let toggle = TFButton(title: isEnabled ? "停用" : "启用", variant: isEnabled ? .secondary : .primary, size: .sm)
            toggle.identifier = NSUserInterfaceItemIdentifier("plugin-toggle-\(item.id)")
            toggle.setAccessibilityLabel("\(isEnabled ? "停用" : "启用")\(item.name)")
            toggle.toolTip = isEnabled ? "暂时停用，保留数据" : "启用插件，继续使用已有设置"
            toggle.isEnabled = !isBusy
            toggle.onClick = { [weak self] in
                guard let self, let pm = self.pluginManager else { return }
                Task { @MainActor in
                    await pm.setPluginEnabled(id: item.id, enabled: !isEnabled)
                }
            }
            controls.addArrangedSubview(toggle)

            let deleteBtn = TFButton(title: "删除", variant: .ghost, size: .sm)
            deleteBtn.identifier = NSUserInterfaceItemIdentifier("plugin-delete-\(item.id)")
            deleteBtn.setAccessibilityLabel("删除\(item.name)")
            deleteBtn.isEnabled = !isBusy
            deleteBtn.onClick = { [weak self] in
                self?.confirmDeletePlugin(item)
            }
            controls.addArrangedSubview(deleteBtn)
        }

        if item.state.isInstalled && item.hasDedicatedWorkspace {
            let rowClickBtn = NSButton(title: "", target: self, action: #selector(pluginRowAreaClicked(_:)))
            rowClickBtn.identifier = NSUserInterfaceItemIdentifier(item.id)
            rowClickBtn.isBordered = false
            rowClickBtn.isTransparent = true
            rowClickBtn.setContentHuggingPriority(.init(1), for: .horizontal)
            rowClickBtn.isEnabled = !isBusy
            rowClickBtn.toolTip = item.state.isEnabled ? "打开「\(item.name)」设置" : "请先启用插件"
            rowClickBtn.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(rowClickBtn)
            NSLayoutConstraint.activate([
                rowClickBtn.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                rowClickBtn.topAnchor.constraint(equalTo: row.topAnchor),
                rowClickBtn.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                rowClickBtn.trailingAnchor.constraint(equalTo: controls.leadingAnchor, constant: -8)
            ])
        }

        if !isLast {
            let sep = TFCardView(frame: .zero)
            sep.translatesAutoresizingMaskIntoConstraints = false
            sep.cornerRadius = 0
            sep.fillColor = TFTheme.line
            row.addSubview(sep)
            NSLayoutConstraint.activate([
                sep.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 68),
                sep.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                sep.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                sep.heightAnchor.constraint(equalToConstant: 1)
            ])
        }

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 68),
            badge.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            badge.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            titleLbl.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 12),
            titleLbl.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),

            statePill.leadingAnchor.constraint(equalTo: titleLbl.trailingAnchor, constant: 8),
            statePill.centerYAnchor.constraint(equalTo: titleLbl.centerYAnchor),
            statePill.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor, constant: -12),

            descLbl.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 12),
            descLbl.topAnchor.constraint(equalTo: titleLbl.bottomAnchor, constant: 3),
            descLbl.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor, constant: -12),

            controls.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            controls.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    @objc private func pluginRowAreaClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        openPluginDetailPage(id: id)
    }

    private func buildSinglePluginDedicatedManagementPage(for item: SystemPluginCatalogItem) {
        addFullWidth(makePluginSubpageHeader(for: item), to: pageStack)

        guard let pm = pluginManager else { return }
        if let locPlugin = pm.locationPlugin(for: item.id) {
            let ws: DeveloperLocationWorkspaceView
            if let existing = locationWorkspaceViews[item.id] {
                existing.bindPlugin(locPlugin)
                ws = existing
            } else {
                let created = DeveloperLocationWorkspaceView(plugin: locPlugin)
                locationWorkspaceViews[item.id] = created
                ws = created
            }
            ws.removeFromSuperview()
            addFullWidth(ws, to: pageStack)
            ws.syncFromTelemetry(locPlugin.currentTelemetrySnapshot(), recenterMap: false)
        } else if let extPlugin = pm.externalScriptPlugin(for: item.id) {
            let ws = ExternalScriptPluginWorkspaceView(plugin: extPlugin, hostBridge: pm.hostBridge)
            addFullWidth(ws, to: pageStack)
        }
    }

    private func confirmDeletePlugin(_ item: SystemPluginCatalogItem) {
        guard let window, let pm = pluginManager, !pm.isPluginBusy(item.id), window.attachedSheet == nil else { return }
        let confirmation = NSAlert()
        confirmation.alertStyle = .warning
        confirmation.messageText = "删除「\(item.name)」？"
        confirmation.informativeText = "将删除插件及其数据。若只是暂时不用，请选择停用，数据会保留。"
        confirmation.addButton(withTitle: "取消")
        confirmation.addButton(withTitle: "删除")
        confirmation.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            Task { @MainActor in
                do {
                    try await pm.deletePlugin(id: item.id)
                } catch {
                    self?.show(detail: error.localizedDescription)
                }
            }
        }
    }

    private func makePluginSubpageHeader(for item: SystemPluginCatalogItem) -> NSView {
        let card = TFCardView(frame: .zero)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.cornerRadius = 12
        card.fillColor = TFTheme.card
        card.strokeColor = TFTheme.line
        card.hasCardShadow = true

        let backBtn = TFButton(title: "返回", symbolName: "chevron.left", variant: .secondary, size: .sm)
        backBtn.onClick = { [weak self] in
            self?.closePluginDetailPage()
        }
        card.addSubview(backBtn)

        let badge = TFIconBadgeView(symbol: item.iconSymbol, accentHex: item.accentHex, size: 34, cornerRadius: 9)
        card.addSubview(badge)

        let titleLbl = NSTextField(labelWithString: item.name)
        titleLbl.font = .systemFont(ofSize: 14.5, weight: .semibold)
        titleLbl.textColor = TFTheme.ink
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(titleLbl)

        let subLbl = NSTextField(labelWithString: item.statusDetail)
        subLbl.font = .systemFont(ofSize: 12, weight: .regular)
        subLbl.textColor = TFTheme.ink3
        subLbl.lineBreakMode = .byTruncatingTail
        subLbl.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(subLbl)
        if item.hasDedicatedWorkspace {
            livePluginStatusLabel = subLbl
        }

        let rightControls = NSStackView()
        rightControls.orientation = .horizontal
        rightControls.alignment = .centerY
        rightControls.spacing = 8
        rightControls.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(rightControls)

        let toggle = TFButton(title: "停用", variant: .secondary, size: .sm)
        toggle.toolTip = "暂时停用，保留数据"
        toggle.isEnabled = pluginManager?.isPluginBusy(item.id) != true
        toggle.onClick = { [weak self] in
            guard let self, let pm = self.pluginManager else { return }
            Task { @MainActor in
                await pm.setPluginEnabled(id: item.id, enabled: false)
            }
        }
        rightControls.addArrangedSubview(toggle)
        livePluginToggleButton = toggle
        refreshLivePluginControls(for: item.id)

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 56),
            backBtn.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            backBtn.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            badge.leadingAnchor.constraint(equalTo: backBtn.trailingAnchor, constant: 10),
            badge.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            titleLbl.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            titleLbl.topAnchor.constraint(equalTo: card.topAnchor, constant: 9),

            subLbl.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            subLbl.topAnchor.constraint(equalTo: titleLbl.bottomAnchor, constant: 2),
            subLbl.trailingAnchor.constraint(lessThanOrEqualTo: rightControls.leadingAnchor, constant: -12),

            rightControls.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            rightControls.centerYAnchor.constraint(equalTo: card.centerYAnchor)
        ])
        return card
    }


    private func buildAppsPage() {
        addFullWidth(makeCompactEngineRuntimeBar(), to: pageStack)
        addFullWidth(makeCategoryAndSearchRow(), to: pageStack)
        addFullWidth(makeInstalledAppsCard(), to: pageStack)
        addFullWidth(makeDropInstallZone(), to: pageStack)
    }

    private func makeCompactEngineRuntimeBar() -> NSView {
        let bar = TFCardView(frame: .zero)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.cornerRadius = 12
        bar.fillColor = TFTheme.card
        bar.strokeColor = TFTheme.line
        bar.hasCardShadow = true

        // BrandMark (26x26 Macdora Emblem)
        let brandTile = MacdoraEmblemView(size: 26)
        bar.addSubview(brandTile)

        if needsRuntimeDownload {
            let hint = NSTextField(labelWithString: "首次使用需下载环境，约 1.3 GB")
            hint.font = .systemFont(ofSize: 12)
            hint.textColor = TFTheme.ink3
            hint.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(hint)
            NSLayoutConstraint.activate([
                hint.leadingAnchor.constraint(equalTo: brandTile.trailingAnchor, constant: 12),
                hint.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
            ])
        }

        let rightControls = NSStackView()
        rightControls.orientation = .horizontal
        rightControls.alignment = .centerY
        rightControls.spacing = 10
        rightControls.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(rightControls)

        let fpsLbl = NSTextField(labelWithString: currentTelemetry.presentedFPS > 0.5 ? String(format: "%.0f FPS", currentTelemetry.presentedFPS) : "")
        fpsLbl.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        fpsLbl.textColor = TFTheme.ink3
        fpsLbl.isHidden = currentTelemetry.presentedFPS <= 0.5
        activeRuntimeFPSLabel = fpsLbl
        rightControls.addArrangedSubview(fpsLbl)

        let androidModeSwitch = TFSegmentedControl(
            options: [
                .init(value: "phone", label: "手机模式"),
                .init(value: "tablet", label: "平板模式")
            ],
            selectedValue: currentPreferences.tabletMode ? "tablet" : "phone"
        )
        androidModeSwitch.onSelect = { [weak self] val in
            guard let self else { return }
            var prefs = self.currentPreferences
            prefs.tabletMode = (val == "tablet")
            self.currentPreferences = prefs
            self.onUpdatePreferences?(prefs)
        }
        rightControls.addArrangedSubview(androidModeSwitch)

        let isRunningOrReady = (currentState == .ready || currentState == .running)
        let actionBtn = TFRuntimeControlButton(mode: currentRuntimeButtonMode())
        actionBtn.onClick = { [weak self] in
            guard let self else { return }
            if isRunningOrReady {
                self.onStop?()
            } else if !self.currentState.isBusy {
                self.onStartRuntime?()
            }
        }
        activeRuntimeButton = actionBtn
        rightControls.addArrangedSubview(actionBtn)

        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: 48),
            brandTile.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            brandTile.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            rightControls.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            rightControls.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])
        return bar
    }

    private func makeCategoryAndSearchRow() -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false

        let bottomLine = TFCardView(frame: .zero)
        bottomLine.translatesAutoresizingMaskIntoConstraints = false
        bottomLine.cornerRadius = 0
        bottomLine.fillColor = TFTheme.line
        wrap.addSubview(bottomLine)

        let tabStack = NSStackView()
        tabStack.orientation = .horizontal
        tabStack.spacing = 18
        tabStack.alignment = .centerY
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(tabStack)

        for (idx, filter) in AppCategoryFilter.allCases.enumerated() {
            let active = (filter == selectedCategory)
            let item = NSView()
            item.translatesAutoresizingMaskIntoConstraints = false

            let lbl = NSTextField(labelWithString: filter.label)
            lbl.font = .systemFont(ofSize: 13, weight: active ? .medium : .regular)
            lbl.textColor = active ? TFTheme.ink : TFTheme.ink2
            lbl.translatesAutoresizingMaskIntoConstraints = false
            item.addSubview(lbl)

            let indicator = TFCardView(frame: .zero)
            indicator.translatesAutoresizingMaskIntoConstraints = false
            indicator.cornerRadius = 1
            indicator.fillColor = active ? TFTheme.accent : .clear
            item.addSubview(indicator)

            let btn = NSButton(title: "", target: self, action: #selector(categoryTabClicked(_:)))
            btn.tag = idx
            btn.isBordered = false
            btn.isTransparent = true
            btn.translatesAutoresizingMaskIntoConstraints = false
            item.addSubview(btn)

            NSLayoutConstraint.activate([
                item.heightAnchor.constraint(equalToConstant: 36),
                lbl.leadingAnchor.constraint(equalTo: item.leadingAnchor, constant: 2),
                lbl.trailingAnchor.constraint(equalTo: item.trailingAnchor, constant: -2),
                lbl.centerYAnchor.constraint(equalTo: item.centerYAnchor, constant: -1),
                indicator.leadingAnchor.constraint(equalTo: item.leadingAnchor),
                indicator.trailingAnchor.constraint(equalTo: item.trailingAnchor),
                indicator.bottomAnchor.constraint(equalTo: item.bottomAnchor),
                indicator.heightAnchor.constraint(equalToConstant: 2),
                btn.leadingAnchor.constraint(equalTo: item.leadingAnchor),
                btn.trailingAnchor.constraint(equalTo: item.trailingAnchor),
                btn.topAnchor.constraint(equalTo: item.topAnchor),
                btn.bottomAnchor.constraint(equalTo: item.bottomAnchor)
            ])
            tabStack.addArrangedSubview(item)
        }

        let searchField = NSSearchField(frame: .zero)
        searchField.placeholderString = "搜索应用"
        searchField.stringValue = searchQuery
        searchField.font = .systemFont(ofSize: 12.5)
        searchField.controlSize = .small
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(searchField)

        NSLayoutConstraint.activate([
            wrap.heightAnchor.constraint(equalToConstant: 36),
            bottomLine.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            bottomLine.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            bottomLine.heightAnchor.constraint(equalToConstant: 1),
            tabStack.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            tabStack.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            searchField.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            searchField.centerYAnchor.constraint(equalTo: wrap.centerYAnchor, constant: -2),
            searchField.widthAnchor.constraint(equalToConstant: 170)
        ])
        return wrap
    }

    @objc private func categoryTabClicked(_ sender: NSButton) {
        let all = AppCategoryFilter.allCases
        guard sender.tag >= 0, sender.tag < all.count else { return }
        selectedCategory = all[sender.tag]
        rebuildPageContent()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        searchQuery = field.stringValue
        rebuildPageContent()
    }

    private func filteredApps() -> [ContainerApp] {
        apps.filter { app in
            let matchesCategory: Bool
            switch selectedCategory {
            case .all: matchesCategory = true
            case .installed: matchesCategory = app.isInstalled
            case .enterprise: matchesCategory = app.category.contains("办公") || app.title.contains("办公")
            case .lifestyle: matchesCategory = app.category.contains("生活") || app.category.contains("市场") || app.category.contains("社交")
            case .system: matchesCategory = app.isSystem
            }
            guard matchesCategory else { return false }
            let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !q.isEmpty else { return true }
            return app.title.lowercased().contains(q)
                || app.subtitle.lowercased().contains(q)
                || app.category.lowercased().contains(q)
        }
    }

    private func makeInstalledAppsCard() -> NSView {
        let card = TFCardView(frame: .zero)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.cornerRadius = 12
        card.fillColor = TFTheme.card
        card.strokeColor = TFTheme.line
        card.hasCardShadow = true

        let list = filteredApps()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        if list.isEmpty {
            let emptyWrap = NSView()
            emptyWrap.translatesAutoresizingMaskIntoConstraints = false
            let lbl = NSTextField(labelWithString: "暂无匹配的应用")
            lbl.font = .systemFont(ofSize: 13, weight: .regular)
            lbl.textColor = TFTheme.ink3
            lbl.translatesAutoresizingMaskIntoConstraints = false
            emptyWrap.addSubview(lbl)
            NSLayoutConstraint.activate([
                emptyWrap.heightAnchor.constraint(equalToConstant: 84),
                lbl.centerXAnchor.constraint(equalTo: emptyWrap.centerXAnchor),
                lbl.centerYAnchor.constraint(equalTo: emptyWrap.centerYAnchor)
            ])
            addFullWidth(emptyWrap, to: stack)
        } else {
            for (index, app) in list.enumerated() {
                addFullWidth(makeAppRow(app, isLast: index == list.count - 1), to: stack)
            }
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        return card
    }

    private func makeAppRow(_ app: ContainerApp, isLast: Bool) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.identifier = NSUserInterfaceItemIdentifier("app-row-\(app.package)")

        let badge = TFAppIconView(app: app, size: 40, cornerRadius: 10)
        row.addSubview(badge)

        let titleLbl = NSTextField(labelWithString: app.title)
        titleLbl.font = .systemFont(ofSize: 14.5, weight: .medium)
        titleLbl.textColor = TFTheme.ink
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(titleLbl)

        let isActive = (activePackage == app.package && currentState == .running)
        let pill = makeStatusPill(
            text: isActive ? "运行中" : (app.isInstalled ? app.category : "未安装"),
            tone: isActive ? .positive : .neutral
        )
        row.addSubview(pill)

        let versionSuffix = (!app.isInstalled || app.version.isEmpty || app.version == "已安装" || app.version == "未安装") ? "" : " · v\(app.version)"
        let subLbl = NSTextField(labelWithString: "\(app.subtitle)\(versionSuffix)")
        subLbl.font = .systemFont(ofSize: 12.5, weight: .regular)
        subLbl.textColor = TFTheme.ink3
        subLbl.lineBreakMode = .byTruncatingTail
        subLbl.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(subLbl)

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(actions)

        if isActive {
            if app.isInstalled && !app.isSystem {
                let uninstallBtn = TFButton(title: "卸载", variant: .danger, size: .sm)
                uninstallBtn.identifier = NSUserInterfaceItemIdentifier("uninstall-\(app.package)")
                uninstallBtn.isEnabled = !currentState.isBusy
                uninstallBtn.onClick = { [weak self, weak uninstallBtn] in
                    uninstallBtn?.isEnabled = false
                    self?.onUninstallApp?(app.package)
                }
                actions.addArrangedSubview(uninstallBtn)
            }

            let focusBtn = TFButton(title: "切回窗口", variant: .primary, size: .sm)
            focusBtn.onClick = { [weak self] in self?.onOpenApp?(app.package) }
            actions.addArrangedSubview(focusBtn)
        } else {
            if app.isInstalled && !app.isSystem {
                let uninstallBtn = TFButton(title: "卸载", variant: .danger, size: .sm)
                uninstallBtn.identifier = NSUserInterfaceItemIdentifier("uninstall-\(app.package)")
                uninstallBtn.isEnabled = !currentState.isBusy
                uninstallBtn.onClick = { [weak self, weak uninstallBtn] in
                    uninstallBtn?.isEnabled = false
                    self?.onUninstallApp?(app.package)
                }
                actions.addArrangedSubview(uninstallBtn)
            }

            let openBtn = TFButton(
                title: app.isInstalled ? "打开" : "安装并打开",
                variant: app.isSystem ? .secondary : .primary,
                size: .sm
            )
            openBtn.identifier = NSUserInterfaceItemIdentifier("open-\(app.package)")
            openBtn.isEnabled = !currentState.isBusy
            openBtn.onClick = { [weak self] in self?.onOpenApp?(app.package) }
            actions.addArrangedSubview(openBtn)
        }

        if !isLast {
            let sep = TFCardView(frame: .zero)
            sep.translatesAutoresizingMaskIntoConstraints = false
            sep.cornerRadius = 0
            sep.fillColor = TFTheme.line
            row.addSubview(sep)
            NSLayoutConstraint.activate([
                sep.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 68),
                sep.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                sep.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                sep.heightAnchor.constraint(equalToConstant: 1)
            ])
        }

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 68),
            badge.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            badge.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            titleLbl.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 12),
            titleLbl.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),

            pill.leadingAnchor.constraint(equalTo: titleLbl.trailingAnchor, constant: 8),
            pill.centerYAnchor.constraint(equalTo: titleLbl.centerYAnchor),

            subLbl.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 12),
            subLbl.topAnchor.constraint(equalTo: titleLbl.bottomAnchor, constant: 3),
            subLbl.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -12),

            actions.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            actions.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func makeDropInstallZone() -> NSView {
        let drop = APKDropCardView(frame: .zero)
        drop.translatesAutoresizingMaskIntoConstraints = false
        drop.cornerRadius = 12
        drop.dashed = true
        drop.fillColor = .clear
        drop.strokeColor = TFTheme.line
        drop.onDropAPK = { [weak self] url in self?.onDropAPK?(url) }

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        if let img = NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: nil) {
            icon.image = img.withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        }
        icon.contentTintColor = TFTheme.ink3
        drop.addSubview(icon)

        let lbl = NSTextField(labelWithString: "将 APK 安装包拖入此处，或从本地选择文件安装")
        lbl.font = .systemFont(ofSize: 12.5, weight: .regular)
        lbl.textColor = TFTheme.ink2
        lbl.lineBreakMode = .byTruncatingTail
        lbl.translatesAutoresizingMaskIntoConstraints = false
        drop.addSubview(lbl)

        let chooseBtn = TFButton(title: "选择文件", variant: .secondary, size: .sm)
        chooseBtn.onClick = { [weak self] in self?.onInstall?() }
        drop.addSubview(chooseBtn)

        NSLayoutConstraint.activate([
            drop.heightAnchor.constraint(equalToConstant: 50),
            icon.leadingAnchor.constraint(equalTo: drop.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: drop.centerYAnchor),
            lbl.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            lbl.trailingAnchor.constraint(lessThanOrEqualTo: chooseBtn.leadingAnchor, constant: -12),
            lbl.centerYAnchor.constraint(equalTo: drop.centerYAnchor),
            chooseBtn.trailingAnchor.constraint(equalTo: drop.trailingAnchor, constant: -14),
            chooseBtn.centerYAnchor.constraint(equalTo: drop.centerYAnchor)
        ])
        return drop
    }

    // MARK: 2. Monitor Page

    private func buildMonitorPage() {
        addFullWidth(makeMonitorStatusSummaryBar(), to: pageStack)
        addFullWidth(makeTelemetryMetricGrid(), to: pageStack)
        addFullWidth(makeServiceComponentsCard(), to: pageStack)
    }

    private func makeMonitorStatusSummaryBar() -> NSView {
        let bar = TFCardView(frame: .zero)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.cornerRadius = 10
        bar.fillColor = TFTheme.card
        bar.strokeColor = TFTheme.line
        bar.hasCardShadow = true

        let dot = TFCardView(frame: .zero)
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.cornerRadius = 4
        let isActive = (currentState == .ready || currentState == .running)
        dot.fillColor = isActive ? TFTheme.positive : TFTheme.ink4
        bar.addSubview(dot)

        let statusLbl = NSTextField(labelWithString: isActive ? "运行正常" : "待命")
        statusLbl.font = .systemFont(ofSize: 13, weight: .medium)
        statusLbl.textColor = TFTheme.ink
        statusLbl.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(statusLbl)

        let detailText: String
        if let activeName = currentTelemetry.activeAppName {
            detailText = "当前前台应用：\(activeName) · 硬件图形加速已启用"
        } else if isActive {
            detailText = "运行环境保持热备，打开应用即可立即呈现"
        } else {
            detailText = "未占用后台算力，打开任意应用时自动启动"
        }
        let detailLbl = NSTextField(labelWithString: detailText)
        detailLbl.font = .systemFont(ofSize: 12.5, weight: .regular)
        detailLbl.textColor = TFTheme.ink3
        detailLbl.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(detailLbl)

        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: 42),
            dot.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            dot.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            statusLbl.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            statusLbl.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            detailLbl.leadingAnchor.constraint(equalTo: statusLbl.trailingAnchor, constant: 12),
            detailLbl.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])
        return bar
    }

    private func makeTelemetryMetricGrid() -> NSView {
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false

        let row1 = NSStackView()
        row1.orientation = .horizontal
        row1.distribution = .fillEqually
        row1.spacing = 12
        row1.translatesAutoresizingMaskIntoConstraints = false

        let fpsVal = currentTelemetry.presentedFPS > 0.5
            ? String(format: "%.0f FPS", currentTelemetry.presentedFPS)
            : "按需刷新"
        let fpsSub = currentTelemetry.frameIntervalP95Ms > 0
            ? String(format: "帧间隔 %.1f ms · 硬件解码", currentTelemetry.frameIntervalP95Ms)
            : "画面静止时自动降低功耗"

        let cpuVal = String(format: "%.1f%%", currentTelemetry.totalCPUPercent)
        let cpuSub = "Apple Silicon 硬件虚拟化"

        row1.addArrangedSubview(makeMetricCard(label: "画面帧率", value: fpsVal, detail: fpsSub))
        row1.addArrangedSubview(makeMetricCard(label: "处理器占用", value: cpuVal, detail: cpuSub))

        let row2 = NSStackView()
        row2.orientation = .horizontal
        row2.distribution = .fillEqually
        row2.spacing = 12
        row2.translatesAutoresizingMaskIntoConstraints = false

        let memGB = currentTelemetry.totalRSSMiB / 1024.0
        let memVal = memGB >= 0.05 ? String(format: "%.2f GB", memGB) : "0.08 GB"
        let memSub = "按需动态分配内存"

        let modeVal = currentPreferences.tabletMode ? "Android 平板" : "Android 手机"
        let modeSub = "\(currentPreferences.resolutionDisplayLabel) · \(currentPreferences.targetFPS)Hz"

        row2.addArrangedSubview(makeMetricCard(label: "内存使用", value: memVal, detail: memSub))
        row2.addArrangedSubview(makeMetricCard(label: "设备形态", value: modeVal, detail: modeSub))

        addFullWidth(row1, to: grid)
        addFullWidth(row2, to: grid)
        return grid
    }

    private func makeMetricCard(label: String, value: String, detail: String) -> NSView {
        let card = TFCardView(frame: .zero)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.cornerRadius = 10
        card.fillColor = TFTheme.card
        card.strokeColor = TFTheme.line
        card.hasCardShadow = true

        let lbl = NSTextField(labelWithString: label)
        lbl.font = .systemFont(ofSize: 12, weight: .medium)
        lbl.textColor = TFTheme.ink3
        lbl.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(lbl)

        let val = NSTextField(labelWithString: value)
        val.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        val.textColor = TFTheme.ink
        val.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(val)

        let sub = NSTextField(labelWithString: detail)
        sub.font = .systemFont(ofSize: 12, weight: .regular)
        sub.textColor = TFTheme.ink3
        sub.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(sub)

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 86),
            lbl.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            lbl.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            val.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            val.topAnchor.constraint(equalTo: lbl.bottomAnchor, constant: 4),
            sub.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            sub.topAnchor.constraint(equalTo: val.bottomAnchor, constant: 4)
        ])
        return card
    }

    private func makeServiceComponentsCard() -> NSView {
        let sectionWrap = NSStackView()
        sectionWrap.orientation = .vertical
        sectionWrap.alignment = .leading
        sectionWrap.spacing = 8
        sectionWrap.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: "服务状态")
        header.font = .systemFont(ofSize: 14, weight: .semibold)
        header.textColor = TFTheme.ink
        sectionWrap.addArrangedSubview(header)

        let card = TFCardView(frame: .zero)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.cornerRadius = 12
        card.fillColor = TFTheme.card
        card.strokeColor = TFTheme.line
        card.hasCardShadow = true

        let listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(listStack)

        let items = currentTelemetry.processes
        for (idx, proc) in items.enumerated() {
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false

            let nameLbl = NSTextField(labelWithString: proc.name)
            nameLbl.font = .systemFont(ofSize: 13.5, weight: .medium)
            nameLbl.textColor = TFTheme.ink
            nameLbl.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(nameLbl)

            let roleLbl = NSTextField(labelWithString: proc.role)
            roleLbl.font = .systemFont(ofSize: 12, weight: .regular)
            roleLbl.textColor = TFTheme.ink3
            roleLbl.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(roleLbl)

            let running = (proc.pid != nil)
            let metricText = running ? String(format: "%.1f%% · %.0f MB", proc.cpuPercent, proc.rssMiB) : ""
            let metricLbl = NSTextField(labelWithString: metricText)
            metricLbl.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            metricLbl.textColor = TFTheme.ink3
            metricLbl.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(metricLbl)

            let pill = makeStatusPill(
                text: running ? "运行中" : "待命",
                tone: running ? .positive : .neutral
            )
            row.addSubview(pill)

            if idx < items.count - 1 {
                let sep = TFCardView(frame: .zero)
                sep.translatesAutoresizingMaskIntoConstraints = false
                sep.cornerRadius = 0
                sep.fillColor = TFTheme.line
                row.addSubview(sep)
                NSLayoutConstraint.activate([
                    sep.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
                    sep.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                    sep.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                    sep.heightAnchor.constraint(equalToConstant: 1)
                ])
            }

            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: 54),
                nameLbl.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
                nameLbl.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),
                roleLbl.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
                roleLbl.topAnchor.constraint(equalTo: nameLbl.bottomAnchor, constant: 2),
                metricLbl.trailingAnchor.constraint(equalTo: pill.leadingAnchor, constant: -10),
                metricLbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                pill.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
                pill.centerYAnchor.constraint(equalTo: row.centerYAnchor)
            ])
            addFullWidth(row, to: listStack)
        }

        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: card.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        addFullWidth(card, to: sectionWrap)
        return sectionWrap
    }

    // MARK: 3. Settings Page

    private func buildSettingsPage() {
        // Section 1: Display & Aspect Ratio
        let modeSeg = TFSegmentedControl(
            options: [
                .init(value: "phone", label: "手机模式"),
                .init(value: "tablet", label: "平板模式")
            ],
            selectedValue: currentPreferences.tabletMode ? "tablet" : "phone"
        )
        modeSeg.onSelect = { [weak self] val in
            guard let self else { return }
            var prefs = self.currentPreferences
            prefs.tabletMode = (val == "tablet")
            self.currentPreferences = prefs
            self.onUpdatePreferences?(prefs)
        }

        let resSeg = TFSegmentedControl(
            options: [
                .init(value: "720p", label: "流畅"),
                .init(value: "1080p", label: "标准"),
                .init(value: "1440p", label: "超清")
            ],
            selectedValue: currentPreferences.resolutionPreset
        )
        resSeg.onSelect = { [weak self] val in
            guard let self else { return }
            var prefs = self.currentPreferences
            prefs.resolutionPreset = val
            self.currentPreferences = prefs
            self.onUpdatePreferences?(prefs)
        }

        let fpsSeg = TFSegmentedControl(
            options: [
                .init(value: "30", label: "30Hz"),
                .init(value: "45", label: "45Hz"),
                .init(value: "60", label: "60Hz")
            ],
            selectedValue: String(currentPreferences.targetFPS)
        )
        fpsSeg.onSelect = { [weak self] val in
            guard let self, let fps = Int(val) else { return }
            var prefs = self.currentPreferences
            prefs.targetFPS = fps
            self.currentPreferences = prefs
            self.onUpdatePreferences?(prefs)
        }

        addFullWidth(makeSettingsSection(
            title: "设备形态与显示",
            rows: [
                makeSettingRow(
                    title: "Android 设备形态",
                    detail: "平板模式模拟 Android 平板（支持微信平板与手机同时登录、分栏宽屏显示）",
                    control: modeSeg
                ),
                makeSettingRow(
                    title: "画面清晰度",
                    detail: "当前分辨率：\(currentPreferences.resolutionDisplayLabel)",
                    control: resSeg
                ),
                makeSettingRow(
                    title: "最高刷新率",
                    detail: "调节应用窗口的画面帧率上限",
                    control: fpsSeg,
                    isLast: true
                )
            ]
        ), to: pageStack)

        // Section 2: Interaction & Privacy
        let keepWarmToggle = TFToggleSwitch(isOn: currentPreferences.keepWarmInBackground)
        keepWarmToggle.onToggle = { [weak self] enabled in
            guard let self else { return }
            var prefs = self.currentPreferences
            prefs.keepWarmInBackground = enabled
            self.currentPreferences = prefs
            self.onUpdatePreferences?(prefs)
        }

        let imeToggle = TFToggleSwitch(isOn: currentPreferences.directIMEEnabled)
        imeToggle.onToggle = { [weak self] enabled in
            guard let self else { return }
            var prefs = self.currentPreferences
            prefs.directIMEEnabled = enabled
            self.currentPreferences = prefs
            self.onUpdatePreferences?(prefs)
        }

        let clipToggle = TFToggleSwitch(isOn: currentPreferences.clipboardSyncEnabled)
        clipToggle.onToggle = { [weak self] enabled in
            guard let self else { return }
            var prefs = self.currentPreferences
            prefs.clipboardSyncEnabled = enabled
            self.currentPreferences = prefs
            self.onUpdatePreferences?(prefs)
        }

        let camToggle = TFToggleSwitch(isOn: cameraEnabled)
        camToggle.isEnabled = canChangeCamera
        camToggle.onToggle = { [weak self] enabled in
            self?.onToggleCamera?(enabled)
        }

        addFullWidth(makeSettingsSection(
            title: "交互与权限",
            rows: [
                makeSettingRow(
                    title: "后台常驻",
                    detail: "关闭应用窗口后保持环境热备，再次打开无需等待",
                    control: keepWarmToggle
                ),
                makeSettingRow(
                    title: "原生中文输入",
                    detail: "使用 Mac 输入法直接打字，密码输入自动启用系统级安全保护",
                    control: imeToggle
                ),
                makeSettingRow(
                    title: "剪贴板共享",
                    detail: "在 Mac 与应用之间直接复制和粘贴文字",
                    control: clipToggle
                ),
                makeSettingRow(
                    title: "摄像头权限",
                    detail: "允许应用使用 Mac 摄像头进行扫码、拍照与人脸识别",
                    control: camToggle,
                    isLast: true
                )
            ]
        ), to: pageStack)

        // Section 3: Storage
        let storageActions = NSStackView()
        storageActions.orientation = .horizontal
        storageActions.spacing = 8
        storageActions.translatesAutoresizingMaskIntoConstraints = false

        let clearBtn = TFButton(title: "清理缓存", variant: .secondary, size: .sm)
        clearBtn.onClick = { [weak self] in self?.onClearCache?() }
        storageActions.addArrangedSubview(clearBtn)

        let revealBtn = TFButton(title: "打开数据目录", variant: .subtle, size: .sm)
        revealBtn.onClick = { [weak self] in self?.onRevealData?() }
        storageActions.addArrangedSubview(revealBtn)

        addFullWidth(makeSettingsSection(
            title: "存储管理",
            rows: [
                makeSettingRow(
                    title: "本地数据空间",
                    detail: String(format: "已使用 %.2f GB · 应用数据与登录状态独立保存", currentTelemetry.diskUsedGB),
                    control: storageActions,
                    isLast: true
                )
            ]
        ), to: pageStack)
    }

    private func makeSettingsSection(title: String, rows: [NSView]) -> NSView {
        let wrap = NSStackView()
        wrap.orientation = .vertical
        wrap.alignment = .leading
        wrap.spacing = 8
        wrap.translatesAutoresizingMaskIntoConstraints = false

        let hdr = NSTextField(labelWithString: title)
        hdr.font = .systemFont(ofSize: 14, weight: .semibold)
        hdr.textColor = TFTheme.ink
        wrap.addArrangedSubview(hdr)

        let card = TFCardView(frame: .zero)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.cornerRadius = 12
        card.fillColor = TFTheme.card
        card.strokeColor = TFTheme.line
        card.hasCardShadow = true

        let rowStack = NSStackView()
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 0
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(rowStack)

        for r in rows {
            addFullWidth(r, to: rowStack)
        }

        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: card.topAnchor),
            rowStack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        addFullWidth(card, to: wrap)
        return wrap
    }

    private func makeSettingRow(title: String, detail: String, control: NSView, isLast: Bool = false) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let tLbl = NSTextField(labelWithString: title)
        tLbl.font = .systemFont(ofSize: 13.5, weight: .medium)
        tLbl.textColor = TFTheme.ink
        tLbl.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(tLbl)

        let dLbl = NSTextField(labelWithString: detail)
        dLbl.font = .systemFont(ofSize: 12, weight: .regular)
        dLbl.textColor = TFTheme.ink3
        dLbl.lineBreakMode = .byTruncatingTail
        dLbl.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(dLbl)

        control.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(control)

        if !isLast {
            let sep = TFCardView(frame: .zero)
            sep.translatesAutoresizingMaskIntoConstraints = false
            sep.cornerRadius = 0
            sep.fillColor = TFTheme.line
            row.addSubview(sep)
            NSLayoutConstraint.activate([
                sep.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
                sep.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                sep.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                sep.heightAnchor.constraint(equalToConstant: 1)
            ])
        }

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 58),
            tLbl.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            tLbl.topAnchor.constraint(equalTo: row.topAnchor, constant: 11),
            dLbl.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            dLbl.topAnchor.constraint(equalTo: tLbl.bottomAnchor, constant: 2),
            dLbl.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -12),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    // MARK: 4. Readiness Page

    private func buildReadinessPage() {
        let readyCount = currentReadiness.filter { $0.status == .ready }.count
        let reviewCount = currentReadiness.filter { $0.status == .review }.count
        let blockedCount = currentReadiness.filter { $0.status == .blocked }.count

        let summaryRow = NSStackView()
        summaryRow.orientation = .horizontal
        summaryRow.distribution = .fillEqually
        summaryRow.spacing = 10
        summaryRow.translatesAutoresizingMaskIntoConstraints = false

        summaryRow.addArrangedSubview(makeSummaryCell(label: "已就绪", value: readyCount, tone: .positive))
        summaryRow.addArrangedSubview(makeSummaryCell(label: "可优化", value: reviewCount, tone: .warn))
        summaryRow.addArrangedSubview(makeSummaryCell(label: "需处理", value: blockedCount, tone: .danger))
        summaryRow.addArrangedSubview(makeSummaryCell(label: "检测项", value: currentReadiness.count, tone: .neutral))
        addFullWidth(summaryRow, to: pageStack)

        let card = TFCardView(frame: .zero)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.cornerRadius = 12
        card.fillColor = TFTheme.card
        card.strokeColor = TFTheme.line
        card.hasCardShadow = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        for (idx, item) in currentReadiness.enumerated() {
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false

            let tone: PillTone
            let pillText: String
            switch item.status {
            case .ready:
                tone = .positive
                pillText = "就绪"
            case .review:
                tone = .warn
                pillText = "待关注"
            case .blocked:
                tone = .danger
                pillText = "异常"
            case .checking:
                tone = .neutral
                pillText = "检测中"
            }
            let pill = makeStatusPill(text: pillText, tone: tone)
            row.addSubview(pill)

            let titleLbl = NSTextField(labelWithString: item.title)
            titleLbl.font = .systemFont(ofSize: 13.5, weight: .medium)
            titleLbl.textColor = TFTheme.ink
            titleLbl.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(titleLbl)

            let detailLbl = NSTextField(labelWithString: item.detail)
            detailLbl.font = .systemFont(ofSize: 12, weight: .regular)
            detailLbl.textColor = TFTheme.ink3
            detailLbl.lineBreakMode = .byTruncatingTail
            detailLbl.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(detailLbl)

            if let actionTitle = item.actionTitle {
                let btn = TFButton(title: actionTitle, variant: .subtle, size: .sm)
                btn.onClick = { [weak self] in
                    guard let self else { return }
                    if item.id == "direct-ime" {
                        var prefs = self.currentPreferences
                        prefs.directIMEEnabled = true
                        self.currentPreferences = prefs
                        self.onUpdatePreferences?(prefs)
                    }
                }
                row.addSubview(btn)
                NSLayoutConstraint.activate([
                    btn.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
                    btn.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                    detailLbl.trailingAnchor.constraint(lessThanOrEqualTo: btn.leadingAnchor, constant: -12)
                ])
            } else {
                detailLbl.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -16).isActive = true
            }

            if idx < currentReadiness.count - 1 {
                let sep = TFCardView(frame: .zero)
                sep.translatesAutoresizingMaskIntoConstraints = false
                sep.cornerRadius = 0
                sep.fillColor = TFTheme.line
                row.addSubview(sep)
                NSLayoutConstraint.activate([
                    sep.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
                    sep.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                    sep.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                    sep.heightAnchor.constraint(equalToConstant: 1)
                ])
            }

            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: 58),
                pill.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
                pill.topAnchor.constraint(equalTo: row.topAnchor, constant: 13),
                titleLbl.leadingAnchor.constraint(equalTo: pill.trailingAnchor, constant: 10),
                titleLbl.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
                detailLbl.leadingAnchor.constraint(equalTo: titleLbl.leadingAnchor),
                detailLbl.topAnchor.constraint(equalTo: titleLbl.bottomAnchor, constant: 3)
            ])
            addFullWidth(row, to: stack)
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        addFullWidth(card, to: pageStack)
    }

    // MARK: 5. About Macdora (Minimalist Single-Card View)

    private func buildAboutPage() {
        addFullWidth(makeAboutMinimalCard(), to: pageStack)
    }

    private func makeAboutMinimalCard() -> NSView {
        let card = TFCardView(frame: .zero)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.cornerRadius = 12
        card.fillColor = TFTheme.card
        card.strokeColor = TFTheme.line
        card.hasCardShadow = true
        card.identifier = NSUserInterfaceItemIdentifier("macdora-about-hero-card")

        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 14
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(contentStack)

        let mainRow = NSView()
        mainRow.translatesAutoresizingMaskIntoConstraints = false

        let emblem = MacdoraEmblemView(size: 48)
        mainRow.addSubview(emblem)

        let lockup = MacdoraBrandLockupView(frame: .zero)
        lockup.isDark = TFTheme.isDark
        mainRow.addSubview(lockup)

        let versionText: String
        switch currentUpdateState {
        case .idle, .upToDate:
            versionText = "版本 \(MacdoraVersion.current.displayString) · 已是最新版本"
        case .checking:
            versionText = "版本 \(MacdoraVersion.current.displayString) · 正在检查更新…"
        case .available(let offer):
            versionText = "版本 \(MacdoraVersion.current.displayString) · 发现新版本 \(offer.version.displayString)"
        case .downloading(let offer, let progress):
            versionText = "正在下载 \(offer.version.displayString) · \(progress.formattedBytesText)"
        case .readyToInstall(let staged):
            versionText = "新版本 \(staged.offer.version.displayString) 已下载完成"
        case .installing(let offer):
            versionText = "正在安装 \(offer.version.displayString) 并重启…"
        case .failed(let message, _):
            versionText = "版本 \(MacdoraVersion.current.displayString) · \(message)"
        }

        let statusLbl = NSTextField(labelWithString: versionText)
        statusLbl.font = .systemFont(ofSize: 12.5, weight: .regular)
        statusLbl.textColor = TFTheme.ink2
        statusLbl.lineBreakMode = .byTruncatingTail
        statusLbl.identifier = NSUserInterfaceItemIdentifier("macdora-about-version-pill")
        statusLbl.translatesAutoresizingMaskIntoConstraints = false
        mainRow.addSubview(statusLbl)

        let actionButton = makePrimaryUpdateActionButton()
        mainRow.addSubview(actionButton)

        NSLayoutConstraint.activate([
            mainRow.heightAnchor.constraint(equalToConstant: 54),
            emblem.leadingAnchor.constraint(equalTo: mainRow.leadingAnchor),
            emblem.centerYAnchor.constraint(equalTo: mainRow.centerYAnchor),

            lockup.leadingAnchor.constraint(equalTo: emblem.trailingAnchor, constant: 14),
            lockup.topAnchor.constraint(equalTo: mainRow.topAnchor, constant: 0),

            statusLbl.leadingAnchor.constraint(equalTo: emblem.trailingAnchor, constant: 16),
            statusLbl.topAnchor.constraint(equalTo: lockup.bottomAnchor, constant: 2),
            statusLbl.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -12),

            actionButton.trailingAnchor.constraint(equalTo: mainRow.trailingAnchor),
            actionButton.centerYAnchor.constraint(equalTo: mainRow.centerYAnchor)
        ])
        addFullWidth(mainRow, to: contentStack)

        switch currentUpdateState {
        case .downloading(_, let progress):
            addFullWidth(makeMinimalProgressRow(percent: progress.percent, completed: false), to: contentStack)
        case .readyToInstall:
            addFullWidth(makeMinimalProgressRow(percent: 100, completed: true), to: contentStack)
        case .installing:
            addFullWidth(makeMinimalProgressRow(percent: 100, completed: true), to: contentStack)
        default:
            break
        }

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            contentStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            contentStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18)
        ])
        return card
    }

    private func makeCompactUpdateBannerCard() -> NSView {
        let card = TFCardView(frame: .zero)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.cornerRadius = 10
        card.fillColor = TFTheme.card
        card.strokeColor = TFTheme.line
        card.identifier = NSUserInterfaceItemIdentifier("macdora-update-banner-card")

        let titleText: String
        switch currentUpdateState {
        case .available(let offer):
            titleText = "发现新版本 \(offer.version.displayString)"
        case .downloading(let offer, _):
            titleText = "正在下载 \(offer.version.displayString)"
        case .readyToInstall(let staged):
            titleText = "新版本 \(staged.offer.version.displayString) 已就绪"
        case .installing(let offer):
            titleText = "正在安装 \(offer.version.displayString)…"
        default:
            titleText = ""
        }

        let lbl = NSTextField(labelWithString: titleText)
        lbl.font = .systemFont(ofSize: 12.5, weight: .medium)
        lbl.textColor = TFTheme.ink
        lbl.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(lbl)

        let actionBtn = makePrimaryUpdateActionButton()
        card.addSubview(actionBtn)

        switch currentUpdateState {
        case .downloading(_, let progress):
            let bar = TFProgressBarView(frame: .zero)
            bar.percent = progress.percent
            card.addSubview(bar)

            let pctLbl = NSTextField(labelWithString: "\(progress.percent)%")
            pctLbl.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            pctLbl.textColor = TFTheme.accent
            pctLbl.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(pctLbl)

            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: lbl.trailingAnchor, constant: 14),
                bar.widthAnchor.constraint(equalToConstant: 160),
                bar.centerYAnchor.constraint(equalTo: card.centerYAnchor),
                pctLbl.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 8),
                pctLbl.centerYAnchor.constraint(equalTo: card.centerYAnchor)
            ])
        default:
            break
        }

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 42),
            lbl.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            lbl.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            actionBtn.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            actionBtn.centerYAnchor.constraint(equalTo: card.centerYAnchor)
        ])
        return card
    }

    private func makePrimaryUpdateActionButton() -> TFButton {
        switch currentUpdateState {
        case .available(let offer):
            let btn = TFButton(title: "更新 \(offer.version.displayString)", variant: .primary, size: .sm)
            btn.identifier = NSUserInterfaceItemIdentifier("macdora-start-update-button")
            btn.onClick = { [weak self] in self?.onStartUpdateDownload?() }
            return btn
        case .downloading:
            let btn = TFButton(title: "取消", variant: .secondary, size: .sm)
            btn.identifier = NSUserInterfaceItemIdentifier("macdora-cancel-update-button")
            btn.onClick = { [weak self] in self?.onCancelUpdateDownload?() }
            return btn
        case .readyToInstall:
            let btn = TFButton(title: "重启并安装", variant: .primary, size: .sm)
            btn.identifier = NSUserInterfaceItemIdentifier("macdora-restart-install-button")
            btn.onClick = { [weak self] in self?.onRestartToInstallUpdate?() }
            return btn
        case .installing:
            let btn = TFButton(title: "正在重启…", variant: .secondary, size: .sm)
            btn.isEnabled = false
            return btn
        case .failed(_, let retryOffer):
            if retryOffer != nil {
                let btn = TFButton(title: "重试更新", variant: .primary, size: .sm)
                btn.identifier = NSUserInterfaceItemIdentifier("macdora-start-update-button")
                btn.onClick = { [weak self] in self?.onStartUpdateDownload?() }
                return btn
            }
            let btn = TFButton(title: "检查更新", variant: .secondary, size: .sm)
            btn.identifier = NSUserInterfaceItemIdentifier("macdora-check-update-button")
            btn.onClick = { [weak self] in self?.onCheckForUpdates?() }
            return btn
        case .idle, .checking, .upToDate:
            let btn = TFButton(
                title: currentUpdateState == .checking ? "正在检查…" : "检查更新",
                variant: .secondary,
                size: .sm
            )
            btn.identifier = NSUserInterfaceItemIdentifier("macdora-check-update-button")
            btn.isEnabled = !currentUpdateState.isBusy
            btn.onClick = { [weak self] in self?.onCheckForUpdates?() }
            return btn
        }
    }

    private func makeMinimalProgressRow(percent: Int, completed: Bool) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let bar = TFProgressBarView(frame: .zero)
        bar.percent = percent
        bar.isCompleted = completed
        row.addSubview(bar)

        let pctLbl = NSTextField(labelWithString: "\(percent)%")
        pctLbl.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        pctLbl.textColor = completed ? TFTheme.positive : TFTheme.accent
        pctLbl.identifier = NSUserInterfaceItemIdentifier("macdora-update-percent-label")
        pctLbl.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(pctLbl)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 18),
            bar.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: pctLbl.leadingAnchor, constant: -10),
            bar.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            pctLbl.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            pctLbl.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private enum PillTone {
        case positive
        case warn
        case danger
        case neutral
    }

    private func makeSummaryCell(label: String, value: Int, tone: PillTone) -> NSView {
        let card = TFCardView(frame: .zero)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.cornerRadius = 10
        switch tone {
        case .positive:
            card.fillColor = TFTheme.positiveSoft
            card.strokeColor = TFTheme.positive.withAlphaComponent(0.22)
        case .warn:
            card.fillColor = TFTheme.warnSoft
            card.strokeColor = TFTheme.warn.withAlphaComponent(0.22)
        case .danger:
            card.fillColor = TFTheme.dangerSoft
            card.strokeColor = TFTheme.danger.withAlphaComponent(0.22)
        case .neutral:
            card.fillColor = TFTheme.card
            card.strokeColor = TFTheme.line
        }

        let valLbl = NSTextField(labelWithString: "\(value)")
        valLbl.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        let lbl = NSTextField(labelWithString: label)
        lbl.font = .systemFont(ofSize: 12, weight: .medium)

        switch tone {
        case .positive:
            valLbl.textColor = TFTheme.positive
            lbl.textColor = TFTheme.positive
        case .warn:
            valLbl.textColor = TFTheme.warn
            lbl.textColor = TFTheme.warn
        case .danger:
            valLbl.textColor = TFTheme.danger
            lbl.textColor = TFTheme.danger
        case .neutral:
            valLbl.textColor = TFTheme.ink
            lbl.textColor = TFTheme.ink2
        }

        valLbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(valLbl)
        card.addSubview(lbl)

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 64),
            valLbl.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            valLbl.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            lbl.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            lbl.topAnchor.constraint(equalTo: valLbl.bottomAnchor, constant: 2)
        ])
        return card
    }

    private func makeStatusPill(text: String, tone: PillTone) -> NSView {
        let pill = TFCardView(frame: .zero)
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.cornerRadius = 6

        let lbl = NSTextField(labelWithString: text)
        lbl.font = .systemFont(ofSize: 11, weight: .medium)
        lbl.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(lbl)

        switch tone {
        case .positive:
            pill.fillColor = TFTheme.positiveSoft
            lbl.textColor = TFTheme.positive
        case .warn:
            pill.fillColor = TFTheme.warnSoft
            lbl.textColor = TFTheme.warn
        case .danger:
            pill.fillColor = TFTheme.dangerSoft
            lbl.textColor = TFTheme.danger
        case .neutral:
            pill.fillColor = TFTheme.card2
            lbl.textColor = TFTheme.ink2
        }

        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 20),
            lbl.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 7),
            lbl.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -7),
            lbl.centerYAnchor.constraint(equalTo: pill.centerYAnchor)
        ])
        return pill
    }
}

// MARK: - ApplicationWindow (Proportional Edge Resize + Miniaturize on Close + Tablet Mode)

@MainActor
final class ApplicationWindow: NSWindowController, NSWindowDelegate {
    let surface: AndroidSurfaceView
    var onClose: (() -> Void)?
    var onRetry: (() -> Void)?
    var onManagement: (() -> Void)?
    var onBack: (() -> Void)?
    var onToggleTabletMode: (() -> Void)?

    private static let toolbarHeight: CGFloat = 38
    private var allowExplicitClose = false
    private var isTabletMode = false
    private var lockedAspectRatio: CGFloat = 1080.0 / 1920.0

    private let overlay = TFCardView(frame: .zero)
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var retryButton: TFButton!
    private var manageButton: TFButton!
    private let inputBanner = TFCardView(frame: .zero)
    private let inputBannerLabel = NSTextField(wrappingLabelWithString: "")
    private let toolbarTitleLabel = NSTextField(labelWithString: "应用")
    private let fpsBadgeCard = TFCardView(frame: .zero)
    private let fpsBadgeLabel = NSTextField(labelWithString: "60 FPS")
    private var modeSwitchButton: TFButton!
    private var explicitCloseButton: TFButton!
    private var inputBannerTask: Task<Void, Never>?

    init(device: MTLDevice) {
        surface = AndroidSurfaceView(frame: NSRect(x: 0, y: 0, width: 430, height: 764), device: device)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 764),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = MacdoraBrand.appName
        window.backgroundColor = TFTheme.card
        window.tabbingMode = .disallowed
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        syncToPixelSize(surface.pixelSize)
    }

    required init?(coder: NSCoder) { nil }

    func presentWindow() {
        if window?.isMiniaturized == true {
            window?.deminiaturize(nil)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func performExplicitClose() {
        allowExplicitClose = true
        defer { allowExplicitClose = false }
        window?.close()
    }

    func performRuntimeOperationClose() {
        // Runtime operations own their cleanup; do not also run the user's close policy.
        let closeHandler = onClose
        onClose = nil
        performExplicitClose()
        onClose = closeHandler
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowExplicitClose {
            allowExplicitClose = false
            return true
        }
        sender.miniaturize(nil)
        onManagement?()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        inputBannerTask?.cancel()
        onClose?()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        window?.orderFrontRegardless()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let win = window else { return }
        updateResizeLimits(for: win)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
    }

    private func updateResizeLimits(for win: NSWindow) {
        let screen = (win.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let content = win.contentRect(forFrameRect: win.frame)
        let chrome = NSSize(width: win.frame.width - content.width, height: win.frame.height - content.height)
        let maxHeight = max(1, min(screen.height - chrome.height, (screen.width - chrome.width) / lockedAspectRatio))
        // AppKit also enforces the titlebar controls' width. Include that floor
        // in the aspect constraint, or it can widen a 300pt minimum viewport to
        // 359pt while leaving its height at 533pt (visible side bars).
        let toolbarWidth = win.titlebarAccessoryViewControllers.first?.view.fittingSize.width ?? 0
        let minimumWidth = max(320, ceil(toolbarWidth - toolbarTitleLabel.intrinsicContentSize.width + 8))
        let minHeight = min(maxHeight, max(lockedAspectRatio >= 1 ? 280 : 420, minimumWidth / lockedAspectRatio))
        // Both limits must lie on the same ratio. Independent width/height
        // clamps can otherwise deform the viewport at the Dock or a screen edge.
        win.contentMinSize = NSSize(width: minHeight * lockedAspectRatio, height: minHeight)
        win.contentMaxSize = NSSize(width: maxHeight * lockedAspectRatio, height: maxHeight)
    }

    func applyDisplayMode(tabletMode: Bool, preferredPixelSize: CGSize) {
        let modeChanged = (isTabletMode != tabletMode)
        isTabletMode = tabletMode
        modeSwitchButton?.title = tabletMode ? "平板模式" : "手机模式"
        modeSwitchButton?.symbolName = tabletMode ? "ipad.landscape" : "iphone"
        if preferredPixelSize.width > 0, preferredPixelSize.height > 0 {
            surface.pixelSize = preferredPixelSize
            syncToPixelSize(preferredPixelSize, resetDefaultHeight: modeChanged)
        }
    }

    func syncToPixelSize(_ size: CGSize, resetDefaultHeight: Bool = false) {
        guard size.width > 0, size.height > 0, let win = window else { return }
        let newAspect = size.width / size.height
        let prevAspect = lockedAspectRatio
        lockedAspectRatio = newAspect
        // The toolbar lives in the titlebar accessory, so native content sizing
        // describes only the Android surface, including single-edge live resize.
        win.contentAspectRatio = size
        updateResizeLimits(for: win)

        let contentRect = win.contentRect(forFrameRect: win.frame)
        let chromeWidth = win.frame.width - contentRect.width
        let chromeHeight = win.frame.height - contentRect.height
        let currentSurfaceHeight = max(260, contentRect.height)

        let screenFrame = (win.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxSurfaceHeight = max(1, screenFrame.height - chromeHeight - 24)
        let maxSurfaceWidth = max(1, screenFrame.width - chromeWidth - 24)

        var targetSurfaceHeight: CGFloat
        if resetDefaultHeight || (prevAspect < 1.0 && newAspect > 1.0) || (prevAspect > 1.0 && newAspect < 1.0) {
            targetSurfaceHeight = newAspect >= 1.0 ? min(600, maxSurfaceHeight) : min(764, maxSurfaceHeight)
        } else {
            targetSurfaceHeight = min(currentSurfaceHeight, maxSurfaceHeight)
        }
        var targetSurfaceWidth = targetSurfaceHeight * newAspect
        if targetSurfaceWidth > maxSurfaceWidth {
            targetSurfaceWidth = maxSurfaceWidth
            targetSurfaceHeight = targetSurfaceWidth / newAspect
        }

        let targetFrameSize = NSSize(
            width: targetSurfaceWidth + chromeWidth,
            height: targetSurfaceHeight + chromeHeight
        )
        if abs(win.frame.width - targetFrameSize.width) <= 1,
           abs(win.frame.height - targetFrameSize.height) <= 1 {
            return
        }

        var nextFrame = win.frame
        let centerX = nextFrame.midX
        let topY = nextFrame.maxY
        nextFrame.size = targetFrameSize
        nextFrame.origin.x = round(centerX - targetFrameSize.width / 2.0)
        nextFrame.origin.y = round(topY - targetFrameSize.height)

        if nextFrame.minX < screenFrame.minX { nextFrame.origin.x = screenFrame.minX }
        if nextFrame.maxX > screenFrame.maxX { nextFrame.origin.x = screenFrame.maxX - nextFrame.width }
        if nextFrame.minY < screenFrame.minY { nextFrame.origin.y = screenFrame.minY }
        if nextFrame.maxY > screenFrame.maxY { nextFrame.origin.y = screenFrame.maxY - nextFrame.height }

        win.setFrame(nextFrame, display: true, animate: false)
    }

    private func buildUI() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 764))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor

        let topBar = TFCardView(frame: NSRect(x: 0, y: 0, width: 430, height: Self.toolbarHeight))
        topBar.autoresizingMask = [.width]
        topBar.cornerRadius = 0
        topBar.fillColor = TFTheme.card
        let toolbar = NSTitlebarAccessoryViewController()
        toolbar.view = topBar
        toolbar.layoutAttribute = .bottom
        window?.addTitlebarAccessoryViewController(toolbar)

        let topBarSep = TFCardView(frame: .zero)
        topBarSep.translatesAutoresizingMaskIntoConstraints = false
        topBarSep.cornerRadius = 0
        topBarSep.fillColor = TFTheme.line
        topBar.addSubview(topBarSep)

        let backBtn = TFButton(title: "返回", symbolName: "chevron.left", variant: .subtle, size: .sm)
        backBtn.onClick = { [weak self] in self?.onBack?() }
        topBar.addSubview(backBtn)

        toolbarTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        toolbarTitleLabel.textColor = TFTheme.ink
        toolbarTitleLabel.lineBreakMode = .byTruncatingTail
        toolbarTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolbarTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(toolbarTitleLabel)

        fpsBadgeCard.translatesAutoresizingMaskIntoConstraints = false
        fpsBadgeCard.cornerRadius = 6
        fpsBadgeCard.fillColor = TFTheme.positiveSoft
        topBar.addSubview(fpsBadgeCard)

        fpsBadgeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        fpsBadgeLabel.textColor = TFTheme.positive
        fpsBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        fpsBadgeCard.addSubview(fpsBadgeLabel)

        let rightStack = NSStackView()
        rightStack.orientation = .horizontal
        rightStack.alignment = .centerY
        rightStack.spacing = 6
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(rightStack)

        modeSwitchButton = TFButton(title: "手机模式", symbolName: "iphone", variant: .subtle, size: .sm)
        modeSwitchButton.onClick = { [weak self] in self?.onToggleTabletMode?() }
        rightStack.addArrangedSubview(modeSwitchButton)

        let mgrBtn = TFButton(title: "管理台", variant: .subtle, size: .sm)
        mgrBtn.onClick = { [weak self] in self?.onManagement?() }
        rightStack.addArrangedSubview(mgrBtn)

        explicitCloseButton = TFButton(title: "关闭", variant: .ghost, size: .sm)
        explicitCloseButton.onClick = { [weak self] in self?.performExplicitClose() }
        rightStack.addArrangedSubview(explicitCloseButton)

        surface.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(surface)

        inputBanner.translatesAutoresizingMaskIntoConstraints = false
        inputBanner.cornerRadius = 8
        inputBanner.fillColor = TFTheme.hex(0x0F1419, alpha: 0.86)
        inputBanner.isHidden = true
        root.addSubview(inputBanner)

        inputBannerLabel.font = .systemFont(ofSize: 12, weight: .medium)
        inputBannerLabel.textColor = .white
        inputBannerLabel.alignment = .center
        inputBannerLabel.translatesAutoresizingMaskIntoConstraints = false
        inputBanner.addSubview(inputBannerLabel)

        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.cornerRadius = 0
        overlay.fillColor = TFTheme.canvas
        root.addSubview(overlay)

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(spinner)

        statusLabel.font = .systemFont(ofSize: 13.5, weight: .medium)
        statusLabel.textColor = TFTheme.ink2
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(statusLabel)

        let overlayButtons = NSStackView()
        overlayButtons.orientation = .horizontal
        overlayButtons.spacing = 10
        overlayButtons.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(overlayButtons)

        retryButton = TFButton(title: "重试", variant: .primary, size: .md)
        retryButton.onClick = { [weak self] in self?.onRetry?() }
        overlayButtons.addArrangedSubview(retryButton)

        manageButton = TFButton(title: "打开管理台", variant: .secondary, size: .md)
        manageButton.onClick = { [weak self] in self?.onManagement?() }
        overlayButtons.addArrangedSubview(manageButton)

        NSLayoutConstraint.activate([
            topBarSep.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            topBarSep.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            topBarSep.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            topBarSep.heightAnchor.constraint(equalToConstant: 1),

            backBtn.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 10),
            backBtn.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            toolbarTitleLabel.leadingAnchor.constraint(equalTo: backBtn.trailingAnchor, constant: 10),
            toolbarTitleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            fpsBadgeCard.leadingAnchor.constraint(equalTo: toolbarTitleLabel.trailingAnchor, constant: 8),
            fpsBadgeCard.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            fpsBadgeCard.heightAnchor.constraint(equalToConstant: 20),
            fpsBadgeLabel.leadingAnchor.constraint(equalTo: fpsBadgeCard.leadingAnchor, constant: 6),
            fpsBadgeLabel.trailingAnchor.constraint(equalTo: fpsBadgeCard.trailingAnchor, constant: -6),
            fpsBadgeLabel.centerYAnchor.constraint(equalTo: fpsBadgeCard.centerYAnchor),

            rightStack.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -10),
            rightStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            rightStack.leadingAnchor.constraint(greaterThanOrEqualTo: fpsBadgeCard.trailingAnchor, constant: 8),

            surface.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            surface.topAnchor.constraint(equalTo: root.topAnchor),
            surface.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            inputBanner.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            inputBanner.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            inputBanner.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            inputBannerLabel.leadingAnchor.constraint(equalTo: inputBanner.leadingAnchor, constant: 12),
            inputBannerLabel.trailingAnchor.constraint(equalTo: inputBanner.trailingAnchor, constant: -12),
            inputBannerLabel.topAnchor.constraint(equalTo: inputBanner.topAnchor, constant: 7),
            inputBannerLabel.bottomAnchor.constraint(equalTo: inputBanner.bottomAnchor, constant: -7),

            overlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: root.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: -32),

            statusLabel.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 14),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320),

            overlayButtons.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            overlayButtons.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16)
        ])

        window?.contentView = root
    }

    func configureForApp(_ app: ContainerApp) {
        window?.title = app.title
        toolbarTitleLabel.stringValue = app.title
    }

    func updateFPSBadge(_ fps: Double) {
        if fps >= 1.0 {
            fpsBadgeLabel.stringValue = String(format: "%.0f FPS", fps)
            fpsBadgeCard.isHidden = false
        } else {
            fpsBadgeCard.isHidden = true
        }
    }

    func loading(_ message: String) {
        inputBannerTask?.cancel()
        inputBanner.isHidden = true
        surface.inputEnabled = false
        surface.videoVisible = false
        overlay.isHidden = false
        overlay.fillColor = TFTheme.canvas
        spinner.isHidden = false
        spinner.startAnimation(nil)
        retryButton.isHidden = true
        manageButton.isHidden = true
        statusLabel.stringValue = message
    }

    func awaitFirstPresentation() {
        overlay.fillColor = .clear
        surface.videoVisible = true
        surface.inputEnabled = false
    }

    func ready() {
        spinner.stopAnimation(nil)
        overlay.isHidden = true
        surface.videoVisible = true
        surface.inputEnabled = true
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(surface)
    }

    func failure(_ message: String) {
        inputBannerTask?.cancel()
        inputBanner.isHidden = true
        surface.inputEnabled = false
        surface.videoVisible = false
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        overlay.isHidden = false
        overlay.fillColor = TFTheme.canvas
        retryButton.isHidden = false
        manageButton.isHidden = false
        statusLabel.stringValue = message
    }

    func showInputIssue(_ message: String) {
        inputBannerTask?.cancel()
        guard !message.isEmpty else {
            inputBanner.isHidden = true
            return
        }
        inputBannerLabel.stringValue = message
        inputBanner.isHidden = false
        inputBannerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.inputBanner.isHidden = true
        }
    }
}
