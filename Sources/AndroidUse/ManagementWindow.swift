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
        case .apps: return "在独立窗口中使用安卓应用"
        case .plugins: return "按需添加扩展功能"
        case .monitor: return "查看画面表现与资源使用"
        case .settings: return "调整显示、输入与应用权限"
        case .serving: return "检查运行环境，处理使用问题"
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
    static var isDark: Bool = true

    static var bg: NSColor { isDark ? hex(0x10182B) : hex(0xF1F5FB) }
    static var canvas: NSColor { isDark ? hex(0x101A2B) : hex(0xF2F6FC) }
    static var card: NSColor { isDark ? hex(0x18263B) : hex(0xFFFFFF) }
    static var card2: NSColor { isDark ? hex(0x22324B) : hex(0xEDF2F8) }
    static var sidebarInk: NSColor { hex(0xF0F5FC) }
    static var sidebarInk2: NSColor { hex(0xAABAD1) }
    static var sidebarAccent: NSColor { hex(0x8CD4FF) }
    static var sidebarSelection: NSColor { NSColor.white.withAlphaComponent(0.09) }
    static var sidebarSelectionLine: NSColor { NSColor.white.withAlphaComponent(0.13) }
    static var surfaceHover: NSColor {
        isDark
            ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.065)
            : NSColor(srgbRed: 15.0 / 255.0, green: 23.0 / 255.0, blue: 42.0 / 255.0, alpha: 0.05)
    }

    static var ink: NSColor { isDark ? hex(0xF3F4F6) : hex(0x0F1419) }
    static var ink2: NSColor { isDark ? hex(0xB5C2D7) : hex(0x4B5563) }
    static var ink3: NSColor { isDark ? hex(0x98ABC5) : hex(0x5D6B80) }

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

    static var accent: NSColor { isDark ? hex(0x33AEFF) : hex(0x076DC4) }
    // Filled controls keep white labels legible in both appearances.
    static var accentFill: NSColor { hex(0x076DC4) }
    static var accentPressed: NSColor { hex(0x055CAA) }
    static var accentInk: NSColor { isDark ? hex(0x33AEFF) : hex(0x055CAA) }
    static var positiveFill: NSColor { hex(0x147D55) }
    static var positivePressed: NSColor { hex(0x106A48) }
    static var dangerFill: NSColor { hex(0xC12E38) }
    static var dangerPressed: NSColor { hex(0xA32530) }
    static var accentSoft: NSColor {
        isDark
            ? NSColor(srgbRed: 51.0 / 255.0, green: 174.0 / 255.0, blue: 1.0, alpha: 0.15)
            : NSColor(srgbRed: 15.0 / 255.0, green: 151.0 / 255.0, blue: 1.0, alpha: 0.10)
    }
    static var positive: NSColor { isDark ? hex(0x34D399) : hex(0x147D55) }
    static var positiveSoft: NSColor {
        isDark
            ? NSColor(srgbRed: 52.0 / 255.0, green: 211.0 / 255.0, blue: 153.0 / 255.0, alpha: 0.15)
            : NSColor(srgbRed: 16.0 / 255.0, green: 185.0 / 255.0, blue: 129.0 / 255.0, alpha: 0.10)
    }
    static var warn: NSColor { isDark ? hex(0xFBBF24) : hex(0x8D5E00) }
    static var warnSoft: NSColor {
        isDark
            ? NSColor(srgbRed: 251.0 / 255.0, green: 191.0 / 255.0, blue: 36.0 / 255.0, alpha: 0.15)
            : NSColor(srgbRed: 245.0 / 255.0, green: 158.0 / 255.0, blue: 11.0 / 255.0, alpha: 0.10)
    }
    static var danger: NSColor { isDark ? hex(0xF87171) : hex(0xC12E38) }
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
        case tinted
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
    var foregroundOverride: NSColor? { didSet { refreshColors() } }
    let controlSizeMode: Size
    var onClick: (() -> Void)?

    private let card = TFCardView(frame: .zero)
    private let stack = NSStackView()
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var isPressed = false { didSet { refreshColors() } }
    private var isHovered = false { didSet { refreshColors() } }
    private var hoverTrackingArea: NSTrackingArea?

    override var isEnabled: Bool {
        didSet {
            if !isEnabled { isPressed = false }
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

        setAccessibilityElement(true)
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
        if let action { NSApp.sendAction(action, to: target, from: self) }
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

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
        let highlighted = isEnabled && (isPressed || isHovered)
        switch variant {
        case .primary:
            card.fillColor = highlighted ? TFTheme.accentPressed : TFTheme.accentFill
            card.strokeColor = nil
            card.hasCardShadow = false
            fg = .white
        case .tinted:
            card.fillColor = highlighted ? TFTheme.accent.withAlphaComponent(0.18) : TFTheme.accentSoft
            card.strokeColor = nil
            card.hasCardShadow = false
            fg = TFTheme.accentInk
        case .secondary:
            card.fillColor = highlighted ? TFTheme.card2 : TFTheme.card
            card.strokeColor = TFTheme.line
            card.hasCardShadow = true
            fg = TFTheme.ink
        case .subtle:
            card.fillColor = highlighted ? TFTheme.surfaceHover : TFTheme.card2
            card.strokeColor = nil
            card.hasCardShadow = false
            fg = TFTheme.ink
        case .ghost:
            card.fillColor = highlighted ? TFTheme.surfaceHover : .clear
            card.strokeColor = nil
            card.hasCardShadow = false
            fg = TFTheme.ink2
        case .danger:
            card.fillColor = highlighted ? TFTheme.dangerSoft : .clear
            card.strokeColor = nil
            card.hasCardShadow = false
            fg = highlighted ? TFTheme.danger : TFTheme.ink2
        }
        label.textColor = foregroundOverride ?? fg
        iconView.contentTintColor = foregroundOverride ?? fg
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
            _ = accessibilityPerformPress()
        }
    }
}

/// Dedicated Android VM Start / Progress / Stop button for the main runtime bar:
/// - `.start`: Green button with a white play arrow and "启动".
/// - `.progress`: In-button horizontal progress bar + live stage expectation text & percentage.
/// - `.stop`: Stop control with a white close icon (`xmark`).
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
        focusRingType = .exterior
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
        let hasModifier = !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if !hasModifier && [36, 49, 76].contains(event.keyCode), accessibilityPerformPress() { return }
        super.keyDown(with: event)
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    private func updateLayoutForMode() {
        switch mode {
        case .start:
            widthConstraint.constant = 74
            isEnabled = true
            toolTip = "启动运行环境；打开应用时也会自动启动"
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
            toolTip = "停止运行环境，保留应用与数据"
            setAccessibilityLabel("停止运行环境")
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
            ctx.setFillColor((isPressed ? TFTheme.positivePressed : TFTheme.positiveFill).cgColor)
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
            ctx.setFillColor((isPressed ? TFTheme.dangerPressed : TFTheme.dangerFill).cgColor)
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
    private var segmentButtons: [String: NSButton] = [:]

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
            btn.setAccessibilityLabel(opt.label)
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
            segmentButtons[opt.value] = btn
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
            segmentButtons[opt.value]?.setAccessibilityValue(NSNumber(value: active))
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
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        focusRingType = .exterior

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
        setAccessibilityValue(NSNumber(value: isOn))
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
        _ = accessibilityPerformPress()
    }

    override var acceptsFirstResponder: Bool { isEnabled }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        isOn.toggle()
        onToggle?(isOn)
        return true
    }

    override func keyDown(with event: NSEvent) {
        let hasShortcutModifier = !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if !hasShortcutModifier && [36, 49, 76].contains(event.keyCode) {
            _ = accessibilityPerformPress()
        } else {
            super.keyDown(with: event)
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 11, yRadius: 11).fill()
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
    var onToggleOfficeKeepAwake: ((Bool) -> Void)?
    var onClearCache: (() -> Void)?
    var onRevealData: (() -> Void)?
    var onImportDeveloperPlugin: (() -> Void)?
    var onExportDeveloperPluginTemplate: (() -> Void)?
    var onRevealPluginsDirectory: (() -> Void)?
    var onAppearanceChanged: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onStartUpdateDownload: (() -> Void)?
    var onCancelUpdateDownload: (() -> Void)?
    var onRestartToInstallUpdate: (() -> Void)?

    private var selectedSection: ManagementSection = .apps
    private var selectedCategory: AppCategoryFilter = .all
    private var searchQuery: String = ""
    private weak var installedAppsCard: NSView?
    private weak var appsSearchRow: NSView?
    private var retainedAppsSearchRow: NSView?
    private var pageInsertionIndex: Int?
    private var categoryLabels: [Int: NSTextField] = [:]
    private var categoryIndicators: [Int: TFCardView] = [:]
    private var categoryButtons: [Int: NSButton] = [:]
    private weak var categoryBottomLine: TFCardView?
    private var currentState: RuntimeState = .stopped
    private var apps: [ContainerApp] = []
    private var activePackage: String?
    private var currentTelemetry: ContainerTelemetry = .idle
    private var currentPreferences: ContainerPreferences = .default
    private var currentOfficeKeepAwake: OfficeKeepAwakeStatus = .off
    private var currentReadiness: [ReadinessCheckItem] = []
    private var cameraEnabled = true
    private var canChangeCamera = true
    private var rootPath = ""
    private var bannerMessage: String?
    private weak var pluginManager: SystemPluginManager?
    private(set) var activePluginDetailID: String?
    private var locationWorkspaceViews: [String: DeveloperLocationWorkspaceView] = [:]
    private var agentWorkspaceViews: [String: HostServiceAgentWorkspaceView] = [:]
    private weak var livePluginStatusLabel: NSTextField?
    private weak var livePluginToggleButton: TFButton?
    private(set) var currentUpdateState: MacdoraUpdateState = .idle(lastCheckedAt: nil)

    private let rootView = TFFlippedView(frame: NSRect(x: 0, y: 0, width: 1060, height: 700))
    private let sidebarBackdrop = NSVisualEffectView()
    private let sidebarTintView = TFSidebarBackdropView(frame: .zero)
    private let contentCard = TFCardView(frame: .zero)
    private let titleBarLine = NSTextField(labelWithString: "应用")
    private let pageSubtitle = NSTextField(labelWithString: "")
    private var headerInstallButton: TFButton!
    private var headerImportButton: TFButton!
    private var headerTemplateButton: TFButton!
    private var themeToggleButton: TFButton!
    private let brandLockupView = MacdoraBrandLockupView(frame: .zero)

    private var navRowCards: [ManagementSection: TFCardView] = [:]
    private var navRowIcons: [ManagementSection: NSImageView] = [:]
    private var navRowLabels: [ManagementSection: NSTextField] = [:]
    private var quickAppIcons: [String: TFAppIconView] = [:]
    private let quickHeaderLabel = NSTextField(labelWithString: "常用")
    private weak var activeRuntimeButton: TFRuntimeControlButton?
    private weak var activeDeviceScene: TFDeviceSceneView?
    private weak var activeRuntimeFPSLabel: NSTextField?
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
            self?.onAppearanceChanged?()
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

        titleBarLine.font = .systemFont(ofSize: 21, weight: .semibold)
        titleBarLine.translatesAutoresizingMaskIntoConstraints = false
        titleBar.addSubview(titleBarLine)

        pageSubtitle.font = .systemFont(ofSize: 12.5)
        pageSubtitle.lineBreakMode = .byTruncatingTail
        pageSubtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pageSubtitle.translatesAutoresizingMaskIntoConstraints = false
        titleBar.addSubview(pageSubtitle)

        let titleRightStack = NSStackView()
        titleRightStack.orientation = .horizontal
        titleRightStack.alignment = .centerY
        titleRightStack.spacing = 8
        titleRightStack.translatesAutoresizingMaskIntoConstraints = false
        titleBar.addSubview(titleRightStack)

        headerInstallButton = TFButton(title: "安装应用…", symbolName: "plus", variant: .primary, size: .sm)
        headerInstallButton.onClick = { [weak self] in self?.onInstall?() }
        titleRightStack.addArrangedSubview(headerInstallButton)

        headerImportButton = TFButton(title: "导入插件…", symbolName: "square.and.arrow.down", variant: .secondary, size: .sm)
        headerImportButton.onClick = { [weak self] in self?.onImportDeveloperPlugin?() }
        titleRightStack.addArrangedSubview(headerImportButton)

        headerTemplateButton = TFButton(title: "开发模板…", symbolName: "doc.badge.plus", variant: .ghost, size: .sm)
        headerTemplateButton.onClick = { [weak self] in self?.onExportDeveloperPluginTemplate?() }
        titleRightStack.addArrangedSubview(headerTemplateButton)

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

        let preferredPageWidth = pageStack.widthAnchor.constraint(equalTo: documentContainer.widthAnchor, constant: -64)
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
            titleBar.heightAnchor.constraint(equalToConstant: 88),

            titleBarLine.leadingAnchor.constraint(equalTo: pageStack.leadingAnchor),
            titleBarLine.topAnchor.constraint(equalTo: titleBar.topAnchor, constant: 24),
            titleBarLine.trailingAnchor.constraint(lessThanOrEqualTo: titleRightStack.leadingAnchor, constant: -16),
            pageSubtitle.leadingAnchor.constraint(equalTo: titleBarLine.leadingAnchor),
            pageSubtitle.topAnchor.constraint(equalTo: titleBarLine.bottomAnchor, constant: 4),
            pageSubtitle.trailingAnchor.constraint(lessThanOrEqualTo: titleRightStack.leadingAnchor, constant: -16),

            titleRightStack.trailingAnchor.constraint(equalTo: pageStack.trailingAnchor),
            titleRightStack.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor, constant: 4),

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
        if stack === pageStack, let index = pageInsertionIndex {
            if !stack.arrangedSubviews.contains(where: { $0 === view }) {
                stack.insertArrangedSubview(view, at: index)
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            pageInsertionIndex = index + 1
        } else {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
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
        btn.setAccessibilityLabel(section.title)
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
            icon.contentTintColor = TFTheme.sidebarInk2
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 18),
                icon.heightAnchor.constraint(equalToConstant: 18)
            ])
            leadingVisual = icon
        }
        row.addSubview(leadingVisual)

        let lbl = NSTextField(labelWithString: title)
        lbl.font = .systemFont(ofSize: 13, weight: .regular)
        lbl.textColor = TFTheme.sidebarInk2
        lbl.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(lbl)

        let btn = NSButton(title: "", target: self, action: action)
        btn.setAccessibilityLabel(title)
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
        sidebarTintView.fillColor = .clear
        sidebarTintView.needsDisplay = true
        contentCard.fillColor = TFTheme.canvas
        contentCard.strokeColor = TFTheme.seamLine
        titleBarLine.textColor = TFTheme.ink
        pageSubtitle.textColor = TFTheme.ink2
        quickHeaderLabel.textColor = TFTheme.sidebarInk2
        brandLockupView.isDark = true
        themeToggleButton.symbolName = TFTheme.isDark ? "sun.max" : "moon"
        themeToggleButton.setAccessibilityLabel(TFTheme.isDark ? "切换到浅色外观" : "切换到深色外观")
        themeToggleButton.foregroundOverride = TFTheme.sidebarInk2
        themeToggleButton.refreshColors()
        headerInstallButton.refreshColors()
        headerImportButton.refreshColors()
        headerTemplateButton.refreshColors()
        for ws in locationWorkspaceViews.values {
            ws.refreshTheme()
        }
        for ws in agentWorkspaceViews.values {
            ws.refreshTheme()
        }
        activeRuntimeButton?.needsDisplay = true
        refreshSidebarState()
    }

    private func refreshSidebarState() {
        titleBarLine.stringValue = selectedSection.pageHeading
        pageSubtitle.stringValue = selectedSection.pageSubheading
        headerInstallButton.isHidden = selectedSection != .apps
        let showsPluginActions = selectedSection == .plugins && activePluginDetailID == nil
        headerImportButton.isHidden = !showsPluginActions
        headerTemplateButton.isHidden = !showsPluginActions
        for sec in ManagementSection.allCases {
            let active = (sec == selectedSection)
            navRowCards[sec]?.fillColor = active ? TFTheme.sidebarSelection : .clear
            navRowCards[sec]?.strokeColor = active ? TFTheme.sidebarSelectionLine : nil
            navRowLabels[sec]?.textColor = active ? TFTheme.sidebarInk : TFTheme.sidebarInk2
            navRowLabels[sec]?.font = .systemFont(ofSize: 13, weight: active ? .medium : .regular)
            navRowIcons[sec]?.contentTintColor = active ? TFTheme.sidebarAccent : TFTheme.sidebarInk2
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
        var reusedAgentDetail = false
        if let pm = pluginManager {
            for existingID in Array(locationWorkspaceViews.keys) where !pm.isPluginInstalled(existingID) {
                locationWorkspaceViews[existingID]?.removeFromSuperview()
                locationWorkspaceViews.removeValue(forKey: existingID)
            }
            for existingID in Array(agentWorkspaceViews.keys)
                where !pm.isPluginInstalled(existingID) || !pm.isPluginEnabled(existingID) {
                agentWorkspaceViews[existingID]?.removeFromSuperview()
                agentWorkspaceViews.removeValue(forKey: existingID)
            }
            if selectedSection == .plugins,
               let detailID = activePluginDetailID,
               pm.isPluginEnabled(detailID),
               let host = pm.hostServicePlugin(for: detailID),
               let ws = agentWorkspaceViews[detailID],
               ws.pluginIdentity == ObjectIdentifier(host),
               ws.superview === pageStack {
                refreshLivePluginControls(for: detailID)
                reusedAgentDetail = true
            } else if selectedSection == .plugins,
                      let detailID = activePluginDetailID,
                      pm.isPluginEnabled(detailID),
                      let host = pm.hostServicePlugin(for: detailID),
                      let stale = agentWorkspaceViews.removeValue(forKey: detailID) {
                let staleIndex = pageStack.arrangedSubviews.firstIndex(of: stale)
                let replacement = HostServiceAgentWorkspaceView(plugin: host)
                agentWorkspaceViews[detailID] = replacement
                stale.removeFromSuperview()
                if let staleIndex {
                    pageStack.insertArrangedSubview(replacement, at: staleIndex)
                    replacement.widthAnchor.constraint(equalTo: pageStack.widthAnchor).isActive = true
                } else {
                    addFullWidth(replacement, to: pageStack)
                }
                refreshLivePluginControls(for: detailID)
                reusedAgentDetail = true
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
        if reusedAgentDetail {
            return
        }
        if selectedSection == .plugins || selectedSection == .settings || selectedSection == .serving {
            rebuildPageContent()
        }
    }

    private func refreshLivePluginControls(for id: String) {
        guard let manager = pluginManager else { return }
        agentWorkspaceViews[id]?.controller.hostStateDidChange()
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
        let changesSection = section != selectedSection
        if section != .plugins {
            activePluginDetailID = nil
        }
        selectedSection = section
        refreshSidebarState()
        rebuildPageContent()
        if changesSection {
            TFMotion.reveal(pageStack)
            activeDeviceScene?.animateEntrance()
        }
    }

    func update(_ state: RuntimeState) {
        currentState = state
        if case .preparing = state {} else { runtimeEnvironmentProgress = nil }
        if case .failed(let msg) = state {
            bannerMessage = msg
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

    private func currentRuntimeButtonMode() -> TFRuntimeControlButton.Mode {
        switch currentState {
        case .stopped, .failed:
            return needsRuntimeDownload ? .download : .start
        case .preparing:
            if let progress = runtimeEnvironmentProgress {
                return .progress(fraction: CGFloat(progress.fraction), statusText: progress.statusText, isStopping: false)
            }
            return .progress(fraction: 0, statusText: "正在准备环境", isStopping: false)
        case .starting:
            return .progress(fraction: 0, statusText: "正在启动…", isStopping: false)
        case .stopping:
            return .progress(fraction: 0, statusText: "正在停止…", isStopping: true)
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
        if selectedSection == .apps {
            refreshInstalledAppsCard()
        } else if selectedSection == .monitor || selectedSection == .serving {
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
        readiness: [ReadinessCheckItem],
        officeKeepAwake: OfficeKeepAwakeStatus = .off
    ) {
        let tabletModeChanged = self.currentPreferences.tabletMode != preferences.tabletMode
        let settingsChanged =
            self.cameraEnabled != cameraEnabled ||
            self.canChangeCamera != canChangeCamera ||
            self.rootPath != rootPath ||
            self.currentPreferences != preferences ||
            self.currentOfficeKeepAwake != officeKeepAwake
        let readinessChanged = self.currentReadiness != readiness
        self.cameraEnabled = cameraEnabled
        self.canChangeCamera = canChangeCamera
        self.rootPath = rootPath
        self.currentPreferences = preferences
        self.currentOfficeKeepAwake = officeKeepAwake
        self.currentReadiness = readiness
        if selectedSection == .settings && settingsChanged {
            rebuildPageContent()
        } else if selectedSection == .serving && (settingsChanged || readinessChanged) {
            rebuildPageContent()
        } else if selectedSection == .apps && tabletModeChanged {
            rebuildPageContent()
        }
    }

    func show(detail: String?) {
        guard bannerMessage != detail else { return }
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
        refreshSidebarState()
        // Keep an active field and its editor attached while asynchronous state
        // changes rebuild the surrounding cards. Recreating marked text would
        // lose the input method's composition session.
        if selectedSection == .apps, let row = appsSearchRow,
           let field = row.subviews.compactMap({ $0 as? NSSearchField }).first,
           let editor = field.currentEditor(), window?.firstResponder === editor {
            retainedAppsSearchRow = row
        }
        pageInsertionIndex = 0
        defer {
            pageInsertionIndex = nil
            retainedAppsSearchRow = nil
        }
        for sub in pageStack.arrangedSubviews {
            if sub === retainedAppsSearchRow { continue }
            pageStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }

        if let bannerMessage, !bannerMessage.isEmpty {
            addFullWidth(makeBannerRow(message: bannerMessage), to: pageStack)
        }

        if selectedSection == .apps {
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
            rowClickBtn.setAccessibilityLabel("打开\(item.name)设置")
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
        } else if item.isAgentHostService,
                  let hostPlugin = pm.hostServicePlugin(for: item.id),
                  hostPlugin.manifest.entrypoints.agentMCP != nil {
            let ws: HostServiceAgentWorkspaceView
            if let existing = agentWorkspaceViews[item.id] {
                if existing.pluginIdentity == ObjectIdentifier(hostPlugin) {
                    existing.removeFromSuperview()
                    ws = existing
                } else {
                    existing.removeFromSuperview()
                    let replacement = HostServiceAgentWorkspaceView(plugin: hostPlugin)
                    agentWorkspaceViews[item.id] = replacement
                    ws = replacement
                }
            } else {
                let created = HostServiceAgentWorkspaceView(plugin: hostPlugin)
                agentWorkspaceViews[item.id] = created
                ws = created
            }
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
        let list = makeInstalledAppsCard()
        installedAppsCard = list
        addFullWidth(list, to: pageStack)
        addFullWidth(makeDropInstallZone(), to: pageStack)
    }

    private func refreshInstalledAppsCard() {
        guard selectedSection == .apps, let previous = installedAppsCard,
              let index = pageStack.arrangedSubviews.firstIndex(where: { $0 === previous }) else { return }
        let list = makeInstalledAppsCard()
        pageStack.removeArrangedSubview(previous)
        previous.removeFromSuperview()
        pageStack.insertArrangedSubview(list, at: index)
        list.widthAnchor.constraint(equalTo: pageStack.widthAnchor).isActive = true
        installedAppsCard = list
    }

    private func makeCompactEngineRuntimeBar() -> NSView {
        let bar = TFCardView(frame: .zero)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.cornerRadius = 12
        bar.fillColor = TFTheme.card
        bar.strokeColor = TFTheme.line
        bar.hasCardShadow = true

        let scene = TFDeviceSceneView()
        scene.translatesAutoresizingMaskIntoConstraints = false
        scene.setActive(currentState == .ready || currentState == .running, busy: currentState.isBusy)
        bar.addSubview(scene)
        activeDeviceScene = scene

        let summary = runtimePresentation
        let title = NSTextField(labelWithString: summary.title)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = TFTheme.ink
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(title)

        let hint = NSTextField(labelWithString: summary.detail)
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = TFTheme.ink3
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.toolTip = summary.detail
        hint.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(hint)

        let rightControls = NSStackView()
        rightControls.orientation = .horizontal
        rightControls.alignment = .centerY
        rightControls.spacing = 10
        rightControls.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(rightControls)
        rightControls.setContentCompressionResistancePriority(.required, for: .horizontal)

        let fpsLbl = NSTextField(labelWithString: currentTelemetry.presentedFPS > 0.5 ? String(format: "%.0f FPS", currentTelemetry.presentedFPS) : "")
        fpsLbl.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        fpsLbl.textColor = TFTheme.ink3
        fpsLbl.isHidden = currentTelemetry.presentedFPS <= 0.5
        activeRuntimeFPSLabel = fpsLbl
        rightControls.addArrangedSubview(fpsLbl)

        let androidModeSwitch = TFSegmentedControl(
            options: [
                .init(value: "phone", label: "竖屏"),
                .init(value: "tablet", label: "横屏")
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
            bar.heightAnchor.constraint(equalToConstant: 104),
            scene.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            scene.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            scene.widthAnchor.constraint(equalToConstant: 126),
            scene.heightAnchor.constraint(equalToConstant: 92),
            title.leadingAnchor.constraint(equalTo: scene.trailingAnchor, constant: 8),
            title.topAnchor.constraint(equalTo: bar.topAnchor, constant: 32),
            title.trailingAnchor.constraint(lessThanOrEqualTo: rightControls.leadingAnchor, constant: -16),
            hint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: rightControls.leadingAnchor, constant: -16),

            rightControls.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            rightControls.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])
        return bar
    }

    private var runtimePresentation: (title: String, detail: String, tone: PillTone) {
        switch currentState {
        case .stopped:
            return needsRuntimeDownload
                ? ("准备开始", "首次使用需下载运行环境", .neutral)
                : ("环境未启动", "打开应用时会自动启动", .neutral)
        case .preparing:
            return ("正在准备环境", "准备完成后会自动继续", .neutral)
        case .starting:
            return ("正在启动", "正在准备应用运行环境", .neutral)
        case .ready:
            return ("环境已就绪", "选择应用，在独立窗口中打开", .positive)
        case .running:
            return ("运行中", currentTelemetry.activeAppName.map { "当前应用：\($0)" } ?? "应用在独立窗口中运行", .positive)
        case .stopping:
            return ("正在停止", "正在安全关闭运行环境", .neutral)
        case .failed:
            return ("需要重新启动", "可重试启动，或前往诊断检查", .danger)
        }
    }

    private func makeCategoryAndSearchRow() -> NSView {
        if let retainedAppsSearchRow {
            refreshCategoryAppearance()
            return retainedAppsSearchRow
        }
        categoryLabels.removeAll()
        categoryIndicators.removeAll()
        categoryButtons.removeAll()
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        appsSearchRow = wrap

        let bottomLine = TFCardView(frame: .zero)
        bottomLine.translatesAutoresizingMaskIntoConstraints = false
        bottomLine.cornerRadius = 0
        bottomLine.fillColor = TFTheme.line
        categoryBottomLine = bottomLine
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
            btn.setAccessibilityLabel(filter.label)
            btn.setAccessibilityValue(NSNumber(value: active))
            btn.tag = idx
            btn.isBordered = false
            btn.isTransparent = true
            btn.translatesAutoresizingMaskIntoConstraints = false
            item.addSubview(btn)
            categoryLabels[idx] = lbl
            categoryIndicators[idx] = indicator
            categoryButtons[idx] = btn

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
        configureAppSearchField(searchField)
        searchField.controlSize = .small
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(appSearchChanged(_:))
        searchField.sendsSearchStringImmediately = true
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
        refreshCategoryAppearance()
        refreshInstalledAppsCard()
    }

    private func refreshCategoryAppearance() {
        categoryBottomLine?.fillColor = TFTheme.line
        for (index, filter) in AppCategoryFilter.allCases.enumerated() {
            let active = filter == selectedCategory
            categoryLabels[index]?.font = .systemFont(ofSize: 13, weight: active ? .medium : .regular)
            categoryLabels[index]?.textColor = active ? TFTheme.ink : TFTheme.ink2
            categoryIndicators[index]?.fillColor = active ? TFTheme.accent : .clear
            categoryButtons[index]?.setAccessibilityValue(NSNumber(value: active))
        }
        if let searchField = appsSearchRow?.subviews.compactMap({ $0 as? NSSearchField }).first {
            configureAppSearchField(searchField)
        }
    }

    private func configureAppSearchField(_ field: NSSearchField) {
        field.textColor = TFTheme.ink
        field.placeholderAttributedString = NSAttributedString(
            string: "搜索应用",
            attributes: [.foregroundColor: TFTheme.ink3, .font: NSFont.systemFont(ofSize: 12.5)]
        )
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        appSearchChanged(field)
    }

    @objc private func appSearchChanged(_ field: NSSearchField) {
        guard searchQuery != field.stringValue else { return }
        searchQuery = field.stringValue
        refreshInstalledAppsCard()
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
                || app.package.lowercased().contains(q)
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
            let hasQuery = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let message = hasQuery ? "没有找到匹配的应用，试试其他名称" : (selectedCategory == .all ? "安装第一个应用，从本地选择 APK 即可" : "这个分类暂时没有应用")
            let lbl = NSTextField(labelWithString: message)
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
        titleLbl.lineBreakMode = .byTruncatingTail
        titleLbl.toolTip = app.title
        titleLbl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
                variant: app.isSystem ? .secondary : .tinted,
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
            pill.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -12),

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

        let lbl = NSTextField(labelWithString: "拖入 APK，安装新应用")
        lbl.font = .systemFont(ofSize: 12.5, weight: .regular)
        lbl.textColor = TFTheme.ink2
        lbl.lineBreakMode = .byTruncatingTail
        lbl.translatesAutoresizingMaskIntoConstraints = false
        drop.addSubview(lbl)

        let chooseBtn = TFButton(title: "选择文件…", variant: .ghost, size: .sm)
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
        let summary = runtimePresentation
        return makeStateSummary(title: summary.title, detail: summary.detail, tone: summary.tone)
    }

    private func makeStateSummary(title: String, detail: String, tone: PillTone) -> NSView {
        let bar = TFCardView(frame: .zero)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.cornerRadius = 10
        bar.fillColor = TFTheme.card
        bar.strokeColor = TFTheme.line
        bar.hasCardShadow = true

        let dot = TFCardView(frame: .zero)
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.cornerRadius = 4
        switch tone {
        case .positive: dot.fillColor = TFTheme.positive
        case .warn: dot.fillColor = TFTheme.warn
        case .danger: dot.fillColor = TFTheme.danger
        case .neutral: dot.fillColor = TFTheme.ink3
        }
        bar.addSubview(dot)

        let statusLbl = NSTextField(labelWithString: title)
        statusLbl.font = .systemFont(ofSize: 13, weight: .medium)
        statusLbl.textColor = TFTheme.ink
        statusLbl.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(statusLbl)

        let detailLbl = NSTextField(labelWithString: detail)
        detailLbl.font = .systemFont(ofSize: 12.5, weight: .regular)
        detailLbl.textColor = TFTheme.ink3
        detailLbl.lineBreakMode = .byTruncatingTail
        detailLbl.toolTip = detail
        detailLbl.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(detailLbl)

        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: 62),
            dot.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            dot.centerYAnchor.constraint(equalTo: statusLbl.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            statusLbl.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            statusLbl.topAnchor.constraint(equalTo: bar.topAnchor, constant: 12),
            statusLbl.trailingAnchor.constraint(lessThanOrEqualTo: bar.trailingAnchor, constant: -16),
            detailLbl.leadingAnchor.constraint(equalTo: statusLbl.leadingAnchor),
            detailLbl.topAnchor.constraint(equalTo: statusLbl.bottomAnchor, constant: 4),
            detailLbl.trailingAnchor.constraint(lessThanOrEqualTo: bar.trailingAnchor, constant: -16)
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

        let hasFrameSample = currentState == .running && currentTelemetry.presentedFPS > 0.5
        let fpsVal = hasFrameSample
            ? String(format: "%.0f FPS", currentTelemetry.presentedFPS)
            : "—"
        let fpsSub = hasFrameSample
            ? (currentTelemetry.hardwareDecoder ? "硬件解码" : "软件解码")
            : (currentState == .running ? "当前没有画面采样" : "打开应用后显示帧率")

        let hasProcessSample = !currentTelemetry.processes.isEmpty
        let cpuVal = hasProcessSample ? String(format: "%.1f%%", currentTelemetry.totalCPUPercent) : "—"
        let cpuSub = "Macdora 与运行环境合计"

        row1.addArrangedSubview(makeMetricCard(label: "画面帧率", value: fpsVal, detail: fpsSub))
        row1.addArrangedSubview(makeMetricCard(label: "处理器占用", value: cpuVal, detail: cpuSub))

        let row2 = NSStackView()
        row2.orientation = .horizontal
        row2.distribution = .fillEqually
        row2.spacing = 12
        row2.translatesAutoresizingMaskIntoConstraints = false

        let memGB = currentTelemetry.totalRSSMiB / 1024.0
        let memVal = hasProcessSample ? String(format: "%.2f GB", memGB) : "—"
        let memSub = "Macdora 与运行环境合计"

        let modeVal = currentPreferences.tabletMode ? "横屏布局" : "竖屏布局"
        let modeSub = "\(currentPreferences.resolutionDisplayLabel) · \(currentPreferences.targetFPS)Hz"

        row2.addArrangedSubview(makeMetricCard(label: "内存使用", value: memVal, detail: memSub))
        row2.addArrangedSubview(makeMetricCard(label: "窗口布局", value: modeVal, detail: modeSub))

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
        sub.lineBreakMode = .byTruncatingTail
        sub.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(sub)

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 86),
            lbl.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            lbl.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            val.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            val.topAnchor.constraint(equalTo: lbl.bottomAnchor, constant: 4),
            sub.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            sub.topAnchor.constraint(equalTo: val.bottomAnchor, constant: 4),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -16)
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
                .init(value: "phone", label: "竖屏布局"),
                .init(value: "tablet", label: "横屏布局")
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
            title: "窗口布局与显示",
            rows: [
                makeSettingRow(
                    title: "窗口布局",
                    detail: "始终使用同一平板，仅调整显示方向",
                    control: modeSeg
                ),
                makeSettingRow(
                    title: "画面清晰度",
                    detail: "当前分辨率：\(currentPreferences.resolutionDisplayLabel)",
                    control: resSeg
                ),
                makeSettingRow(
                    title: "最高刷新率",
                    detail: "设置应用窗口的帧率上限",
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

        let officeKeepAwakeToggle = TFToggleSwitch(isOn: currentOfficeKeepAwake.enabled)
        officeKeepAwakeToggle.identifier = NSUserInterfaceItemIdentifier("office-keep-awake-toggle")
        officeKeepAwakeToggle.setAccessibilityLabel("办公实例保持唤醒")
        officeKeepAwakeToggle.isEnabled = !currentState.isBusy && currentOfficeKeepAwake.phase != .applying
        officeKeepAwakeToggle.onToggle = { [weak self] enabled in
            self?.onToggleOfficeKeepAwake?(enabled)
        }
        let officeKeepAwakeControl: NSView
        if currentOfficeKeepAwake.phase == .failed {
            let retry = TFButton(title: "重试", variant: .secondary, size: .sm)
            retry.identifier = NSUserInterfaceItemIdentifier("office-keep-awake-retry")
            retry.setAccessibilityLabel("重试办公实例保持唤醒设置")
            retry.isEnabled = !currentState.isBusy
            retry.onClick = { [weak self] in
                guard let self else { return }
                self.onToggleOfficeKeepAwake?(self.currentOfficeKeepAwake.enabled)
            }
            let controls = NSStackView(views: [retry, officeKeepAwakeToggle])
            controls.orientation = .horizontal
            controls.alignment = .centerY
            controls.spacing = 8
            controls.translatesAutoresizingMaskIntoConstraints = false
            officeKeepAwakeControl = controls
        } else {
            officeKeepAwakeControl = officeKeepAwakeToggle
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
                    detail: "关闭窗口后保持运行，下次打开更快",
                    control: keepWarmToggle
                ),
                makeSettingRow(
                    title: "办公实例保持唤醒",
                    detail: currentOfficeKeepAwake.detail,
                    control: officeKeepAwakeControl
                ),
                makeSettingRow(
                    title: "原生中文输入",
                    detail: "使用 Mac 输入法输入中文",
                    control: imeToggle
                ),
                makeSettingRow(
                    title: "剪贴板共享",
                    detail: "在 Mac 与安卓应用之间复制粘贴文字",
                    control: clipToggle
                ),
                makeSettingRow(
                    title: "摄像头权限",
                    detail: canChangeCamera ? "使用 Mac 摄像头扫码或拍照" : "停止运行环境后可更改",
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
        clearBtn.toolTip = "仅清理临时安装文件，保留应用与数据"
        clearBtn.onClick = { [weak self] in self?.onClearCache?() }
        storageActions.addArrangedSubview(clearBtn)

        let revealBtn = TFButton(title: "在访达中查看", variant: .ghost, size: .sm)
        revealBtn.onClick = { [weak self] in self?.onRevealData?() }
        storageActions.addArrangedSubview(revealBtn)

        addFullWidth(makeSettingsSection(
            title: "存储管理",
            rows: [
                makeSettingRow(
                    title: "本地数据空间",
                    detail: currentTelemetry.diskUsedGB > 0 ? String(format: "已使用 %.2f GB", currentTelemetry.diskUsedGB) : "等待存储统计",
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
        control.setAccessibilityLabel(title)
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
        dLbl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dLbl.toolTip = detail
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

        let summary: (String, String, PillTone)
        if blockedCount > 0 {
            summary = ("有 \(blockedCount) 项需要处理", "查看下方标记为异常的项目", .danger)
        } else if currentReadiness.isEmpty {
            summary = ("等待检查", "检查结果会显示在这里", .neutral)
        } else if currentReadiness.contains(where: { $0.status == .checking }) {
            summary = ("正在检查", "正在确认运行环境是否就绪", .neutral)
        } else if reviewCount > 0 {
            summary = ("有 \(reviewCount) 项建议调整", "查看下方提示，按需调整设置", .warn)
        } else {
            summary = ("运行条件已就绪", "\(readyCount) 项检查已通过", .positive)
        }
        addFullWidth(makeStateSummary(title: summary.0, detail: summary.1, tone: summary.2), to: pageStack)
        guard !currentReadiness.isEmpty else { return }

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
            detailLbl.toolTip = item.detail
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
        case .idle:
            versionText = "版本 \(MacdoraVersion.current.displayString)"
        case .upToDate:
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
    private var isHorizontalLayout = true
    private var lockedAspectRatio: CGFloat

    private let overlay = TFCardView(frame: .zero)
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var retryButton: TFButton!
    private var manageButton: TFButton!
    private let inputBanner = TFCardView(frame: .zero)
    private let inputBannerLabel = NSTextField(wrappingLabelWithString: "")
    private let toolbarTitleLabel = NSTextField(labelWithString: "应用")
    private let topBar = TFCardView(frame: .zero)
    private let topBarSep = TFCardView(frame: .zero)
    private let fpsBadgeCard = TFCardView(frame: .zero)
    private let fpsBadgeLabel = NSTextField(labelWithString: "60 FPS")
    private var modeSwitchButton: TFButton!
    private var explicitCloseButton: TFButton!
    private var inputBannerTask: Task<Void, Never>?

    init(device: MTLDevice) {
        let initialPixels = ContainerPreferences.default.preferredPixelSize
        let initialRect = NSRect(x: 0, y: 0, width: initialPixels.width / 2, height: initialPixels.height / 2)
        let initialSurface = AndroidSurfaceView(frame: initialRect, device: device)
        initialSurface.pixelSize = initialPixels
        surface = initialSurface
        lockedAspectRatio = initialPixels.width / initialPixels.height
        let window = NSWindow(
            contentRect: initialRect,
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
        refreshTheme()
        syncToPixelSize(surface.pixelSize)
    }

    required init?(coder: NSCoder) { nil }

    func presentWindow() {
        refreshTheme()
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
        let modeChanged = (isHorizontalLayout != tabletMode)
        isHorizontalLayout = tabletMode
        modeSwitchButton?.title = tabletMode ? "切换竖屏" : "切换横屏"
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

        topBar.frame = NSRect(x: 0, y: 0, width: 430, height: Self.toolbarHeight)
        topBar.autoresizingMask = [.width]
        topBar.cornerRadius = 0
        topBar.fillColor = TFTheme.card
        let toolbar = NSTitlebarAccessoryViewController()
        toolbar.view = topBar
        toolbar.layoutAttribute = .bottom
        window?.addTitlebarAccessoryViewController(toolbar)

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

        modeSwitchButton = TFButton(title: "切换竖屏", symbolName: "ipad.landscape", variant: .subtle, size: .sm)
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
        window?.miniwindowTitle = app.title
        window?.miniwindowImage = TFAppIconView.resolveAppIconImage(for: app)
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
        toolbarTitleLabel.stringValue = app.title
    }

    func refreshTheme() {
        window?.appearance = NSAppearance(named: TFTheme.isDark ? .darkAqua : .aqua)
        window?.backgroundColor = TFTheme.card
        topBar.fillColor = TFTheme.card
        topBarSep.fillColor = TFTheme.line
        toolbarTitleLabel.textColor = TFTheme.ink
        statusLabel.textColor = TFTheme.ink2
        fpsBadgeCard.fillColor = TFTheme.positiveSoft
        fpsBadgeLabel.textColor = TFTheme.positive
        // An awaiting first frame must remain transparent during an appearance change.
        if overlay.fillColor.alphaComponent > 0 {
            overlay.fillColor = TFTheme.canvas
        }
        func refreshButtons(in view: NSView) {
            (view as? TFButton)?.refreshColors()
            view.subviews.forEach { refreshButtons(in: $0) }
        }
        refreshButtons(in: topBar)
        refreshButtons(in: overlay)
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
        refreshTheme()
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
        overlay.displayIfNeeded()
        surface.inputEnabled = false
        surface.videoVisible = true
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
        refreshTheme()
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
