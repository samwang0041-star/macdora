import AppKit
import QuartzCore

private enum ManagementVisualPalette {
    static let sidebarTop = NSColor(srgbRed: 16.0 / 255.0, green: 24.0 / 255.0, blue: 43.0 / 255.0, alpha: 0.98)
    static let sidebarBottom = NSColor(srgbRed: 22.0 / 255.0, green: 33.0 / 255.0, blue: 58.0 / 255.0, alpha: 0.96)
    static let sidebarGlow = NSColor(srgbRed: 55.0 / 255.0, green: 116.0 / 255.0, blue: 232.0 / 255.0, alpha: 0.22)

    static let deviceEdge = NSColor(srgbRed: 5.0 / 255.0, green: 17.0 / 255.0, blue: 36.0 / 255.0, alpha: 1)
    static let deviceTop = NSColor(srgbRed: 77.0 / 255.0, green: 128.0 / 255.0, blue: 224.0 / 255.0, alpha: 1)
    static let deviceBottom = NSColor(srgbRed: 18.0 / 255.0, green: 48.0 / 255.0, blue: 103.0 / 255.0, alpha: 1)
    static let deviceRim = NSColor(srgbRed: 135.0 / 255.0, green: 178.0 / 255.0, blue: 255.0 / 255.0, alpha: 0.72)

    static let screenTop = NSColor(srgbRed: 13.0 / 255.0, green: 42.0 / 255.0, blue: 79.0 / 255.0, alpha: 1)
    static let screenBottom = NSColor(srgbRed: 4.0 / 255.0, green: 17.0 / 255.0, blue: 38.0 / 255.0, alpha: 1)
    static let screenTopMuted = NSColor(srgbRed: 23.0 / 255.0, green: 42.0 / 255.0, blue: 67.0 / 255.0, alpha: 1)
    static let screenBottomMuted = NSColor(srgbRed: 9.0 / 255.0, green: 22.0 / 255.0, blue: 39.0 / 255.0, alpha: 1)
    static let screenGlow = NSColor(srgbRed: 45.0 / 255.0, green: 151.0 / 255.0, blue: 255.0 / 255.0, alpha: 0.42)
    static let screenGlowMuted = NSColor(srgbRed: 74.0 / 255.0, green: 108.0 / 255.0, blue: 148.0 / 255.0, alpha: 0.12)

    static let appTop = NSColor(srgbRed: 96.0 / 255.0, green: 199.0 / 255.0, blue: 255.0 / 255.0, alpha: 1)
    static let appBottom = NSColor(srgbRed: 27.0 / 255.0, green: 105.0 / 255.0, blue: 210.0 / 255.0, alpha: 1)
    static let appMuted = NSColor(srgbRed: 74.0 / 255.0, green: 111.0 / 255.0, blue: 151.0 / 255.0, alpha: 1)
}

@MainActor
final class TFSidebarBackdropView: TFCardView {
    private let backdropContainer = CALayer()
    private let gradientLayer = CAGradientLayer()
    private let glowLayer = CAGradientLayer()
    private let clippingMask = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        fillColor = .clear
        strokeColor = nil
        cornerRadius = 0
        hasCardShadow = false
        hasLeftSeamShadow = false
        setAccessibilityElement(false)

        wantsLayer = true
        layer?.insertSublayer(backdropContainer, at: 0)

        gradientLayer.colors = [
            ManagementVisualPalette.sidebarTop.cgColor,
            ManagementVisualPalette.sidebarBottom.cgColor
        ]
        gradientLayer.locations = [0, 1]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 1)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)

        glowLayer.type = .radial
        glowLayer.colors = [
            ManagementVisualPalette.sidebarGlow.cgColor,
            NSColor.clear.cgColor
        ]
        glowLayer.locations = [0, 1]
        glowLayer.startPoint = CGPoint(x: 0.78, y: 0.82)
        glowLayer.endPoint = CGPoint(x: 0.1, y: 0.08)

        backdropContainer.masksToBounds = true
        backdropContainer.addSublayer(gradientLayer)
        backdropContainer.addSublayer(glowLayer)
        backdropContainer.mask = clippingMask
        layOutBackdropLayers()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        layOutBackdropLayers()
    }

    override func updateLayer() {
        super.updateLayer()
        layOutBackdropLayers()
    }

    private func layOutBackdropLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let localBounds = bounds
        backdropContainer.frame = localBounds
        gradientLayer.frame = backdropContainer.bounds
        glowLayer.frame = backdropContainer.bounds

        let radius = min(cornerRadius, min(localBounds.width, localBounds.height) / 2)
        let maskPath = NSBezierPath(
            roundedRect: backdropContainer.bounds,
            xRadius: radius,
            yRadius: radius
        )
        clippingMask.frame = backdropContainer.bounds
        clippingMask.path = maskPath.cgPath
    }
}

@MainActor
final class TFDeviceSceneView: NSView {
    private final class ObserverRegistration {
        let isWindow: Bool
        let center: NotificationCenter
        let token: NSObjectProtocol

        init(isWindow: Bool, center: NotificationCenter, token: NSObjectProtocol) {
            self.isWindow = isWindow
            self.center = center
            self.token = token
        }

        func remove() {
            center.removeObserver(token)
        }
    }

    private enum AnimationKey {
        static let entrance = "macdora.device-entrance"
        static let busyPulse = "macdora.device-busy-pulse"
    }

    private let deviceRoot = CALayer()
    private let floorShadowLayer = CAShapeLayer()
    private let edgeLayer = CAGradientLayer()
    private let chassisLayer = CAGradientLayer()
    private let chassisSheenLayer = CAGradientLayer()
    private let rimLayer = CAShapeLayer()
    private let screenLayer = CAGradientLayer()
    private let screenGlowLayer = CAGradientLayer()
    private let screenSheenLayer = CAGradientLayer()
    private let glassHighlightLayer = CAShapeLayer()
    private let topHighlightLayer = CAShapeLayer()
    private let appTileLayer = CAGradientLayer()
    private var appGlyphLayers: [CAShapeLayer] = []

    private var observerRegistrations: [ObserverRegistration] = []
    private weak var observedWindow: NSWindow?
    private var isActive = false
    private var isBusy = false
    private var busyPulsePending = false
    private var busyPulseRemainingTime: CFTimeInterval?

    convenience init() {
        self.init(frame: .zero)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.masksToBounds = false
        setAccessibilityElement(false)
        buildLayers()
        layoutLayers()
        refreshStateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        observerRegistrations.forEach { $0.remove() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let attachedWindow = window
        if observedWindow !== attachedWindow {
            installWindowObservers()
        }
        updateContentsScale()
        updateMotionAvailability()
    }

    override func layout() {
        super.layout()
        layoutLayers()
    }

    func setActive(_ active: Bool, busy: Bool) {
        let busyBegan = busy && !isBusy
        isActive = active
        isBusy = busy
        if !busy {
            busyPulsePending = false
            busyPulseRemainingTime = nil
            screenGlowLayer.removeAnimation(forKey: AnimationKey.busyPulse)
        } else if busyBegan {
            busyPulsePending = true
            busyPulseRemainingTime = nil
        }

        refreshStateAppearance()
        updateMotionAvailability()
    }

    func animateEntrance() {
        deviceRoot.removeAnimation(forKey: AnimationKey.entrance)
        guard canAnimate, !TFMotion.reducedMotion else { return }
        layoutLayers()

        let finalTransform = deviceTransform()
        var startTransform = finalTransform
        startTransform = CATransform3DTranslate(startTransform, 0, -3, 0)
        startTransform = CATransform3DScale(startTransform, 0.975, 0.975, 1)
        startTransform = CATransform3DRotate(startTransform, -0.025, 0, 0, 1)

        let transformAnimation = CABasicAnimation(keyPath: "transform")
        transformAnimation.fromValue = NSValue(caTransform3D: startTransform)
        transformAnimation.toValue = NSValue(caTransform3D: finalTransform)

        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.fromValue = 0.45
        opacityAnimation.toValue = 1

        let group = CAAnimationGroup()
        group.animations = [transformAnimation, opacityAnimation]
        group.duration = 0.45
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .backwards
        deviceRoot.add(group, forKey: AnimationKey.entrance)
    }

    private var canAnimate: Bool {
        guard let window,
              window.isVisible,
              !window.isMiniaturized,
              window.occlusionState.contains(.visible),
              window.isKeyWindow || window.isMainWindow,
              NSApplication.shared.isActive
        else {
            return false
        }
        return true
    }

    private func updateMotionAvailability() {
        guard canAnimate, !TFMotion.reducedMotion else {
            if isBusy {
                busyPulsePending = true
            }
            pauseAnimations()
            return
        }
        if busyPulsePending {
            startBusyPulseIfNeeded()
        }
    }

    private func motionPreferenceDidChange() {
        stopAnimations()
        updateMotionAvailability()
    }

    private func startBusyPulseIfNeeded() {
        guard canAnimate, !TFMotion.reducedMotion, busyPulsePending else { return }
        busyPulsePending = false

        screenGlowLayer.removeAnimation(forKey: AnimationKey.busyPulse)
        let baseOpacity = screenGlowLayer.opacity
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [
            baseOpacity,
            min(1, baseOpacity + 0.22),
            baseOpacity
        ]
        pulse.keyTimes = [0, 0.5, 1]
        pulse.duration = 0.48
        pulse.repeatCount = 2
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.isRemovedOnCompletion = true
        let localNow = screenGlowLayer.convertTime(CACurrentMediaTime(), from: nil)
        if let remainingTime = busyPulseRemainingTime {
            pulse.beginTime = localNow - max(0, pulse.duration * Double(pulse.repeatCount) - remainingTime)
            busyPulseRemainingTime = nil
        } else {
            pulse.beginTime = localNow
        }
        screenGlowLayer.add(pulse, forKey: AnimationKey.busyPulse)
    }

    private func pauseAnimations() {
        if let pulse = screenGlowLayer.animation(forKey: AnimationKey.busyPulse) {
            let localTime = screenGlowLayer.convertTime(CACurrentMediaTime(), from: nil)
            let elapsed = max(0, localTime - pulse.beginTime)
            let totalDuration = pulse.duration * Double(pulse.repeatCount)
            busyPulseRemainingTime = max(0, totalDuration - min(elapsed, totalDuration))
            busyPulsePending = elapsed < totalDuration && isBusy
        }
        deviceRoot.removeAnimation(forKey: AnimationKey.entrance)
        deviceRoot.removeAllAnimations()
        screenGlowLayer.removeAnimation(forKey: AnimationKey.busyPulse)
    }

    private func stopAnimations() {
        busyPulsePending = false
        busyPulseRemainingTime = nil
        pauseAnimations()
    }

    private func addPermanentObservers() {
        let center = NotificationCenter.default
        let appNotifications: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification
        ]
        observerRegistrations.append(contentsOf: appNotifications.map { name in
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateContentsScale()
                    self?.updateMotionAvailability()
                }
            }
            return ObserverRegistration(isWindow: false, center: center, token: token)
        })
        installWorkspaceObserver()
    }

    private func installWindowObservers() {
        removeWindowObservers()
        let attachedWindow = window
        observedWindow = attachedWindow
        guard let attachedWindow else {
            updateContentsScale()
            return
        }
        let center = NotificationCenter.default
        let windowNotifications: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didChangeBackingPropertiesNotification
        ]
        observerRegistrations.append(contentsOf: windowNotifications.map { name in
            let token = center.addObserver(forName: name, object: attachedWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateContentsScale()
                    self?.updateMotionAvailability()
                }
            }
            return ObserverRegistration(isWindow: true, center: center, token: token)
        })
        if !observerRegistrations.contains(where: { !$0.isWindow }) {
            addPermanentObservers()
        }
    }

    private func installWorkspaceObserver() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        guard !observerRegistrations.contains(where: { $0.center === workspaceCenter }) else { return }
        let token = workspaceCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.motionPreferenceDidChange()
                }
            }
        observerRegistrations.append(ObserverRegistration(isWindow: false, center: workspaceCenter, token: token))
    }

    private func removeWindowObservers() {
        observerRegistrations.removeAll { registration in
            guard registration.isWindow else { return false }
            registration.remove()
            return true
        }
    }

    private func buildLayers() {
        guard let hostLayer = layer else { return }
        deviceRoot.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        deviceRoot.masksToBounds = false
        hostLayer.addSublayer(deviceRoot)

        floorShadowLayer.fillColor = NSColor.black.withAlphaComponent(0.32).cgColor
        floorShadowLayer.shadowColor = NSColor.black.cgColor
        floorShadowLayer.shadowOpacity = 0.32
        floorShadowLayer.shadowRadius = 8
        floorShadowLayer.shadowOffset = CGSize(width: 0, height: -4)

        edgeLayer.colors = [
            NSColor(srgbRed: 25.0 / 255.0, green: 57.0 / 255.0, blue: 112.0 / 255.0, alpha: 1).cgColor,
            ManagementVisualPalette.deviceEdge.cgColor
        ]
        edgeLayer.locations = [0, 1]
        edgeLayer.startPoint = CGPoint(x: 0.5, y: 1)
        edgeLayer.endPoint = CGPoint(x: 0.5, y: 0)
        edgeLayer.masksToBounds = true
        if #available(macOS 11.0, *) {
            edgeLayer.cornerCurve = .continuous
        }

        chassisLayer.colors = [
            ManagementVisualPalette.deviceTop.cgColor,
            ManagementVisualPalette.deviceBottom.cgColor
        ]
        chassisLayer.locations = [0, 1]
        chassisLayer.startPoint = CGPoint(x: 0.2, y: 1)
        chassisLayer.endPoint = CGPoint(x: 0.82, y: 0)
        chassisLayer.borderColor = ManagementVisualPalette.deviceRim.cgColor
        chassisLayer.borderWidth = 0.8
        chassisLayer.masksToBounds = true
        if #available(macOS 11.0, *) {
            chassisLayer.cornerCurve = .continuous
        }

        chassisSheenLayer.colors = [
            NSColor.white.withAlphaComponent(0.24).cgColor,
            NSColor.white.withAlphaComponent(0.03).cgColor,
            NSColor.clear.cgColor
        ]
        chassisSheenLayer.locations = [0, 0.38, 1]
        chassisSheenLayer.startPoint = CGPoint(x: 0.15, y: 1)
        chassisSheenLayer.endPoint = CGPoint(x: 0.75, y: 0.18)
        chassisLayer.addSublayer(chassisSheenLayer)

        rimLayer.fillColor = NSColor.clear.cgColor
        rimLayer.strokeColor = ManagementVisualPalette.deviceRim.cgColor
        rimLayer.lineWidth = 0.9

        screenLayer.startPoint = CGPoint(x: 0.2, y: 1)
        screenLayer.endPoint = CGPoint(x: 0.74, y: 0)
        screenLayer.masksToBounds = true
        if #available(macOS 11.0, *) {
            screenLayer.cornerCurve = .continuous
        }

        screenGlowLayer.type = .radial
        screenGlowLayer.colors = [
            ManagementVisualPalette.screenGlow.cgColor,
            NSColor.clear.cgColor
        ]
        screenGlowLayer.locations = [0, 1]
        screenGlowLayer.startPoint = CGPoint(x: 0.62, y: 0.46)
        screenGlowLayer.endPoint = CGPoint(x: 0.04, y: 0.08)
        screenLayer.addSublayer(screenGlowLayer)

        screenSheenLayer.colors = [
            NSColor.white.withAlphaComponent(0.16).cgColor,
            NSColor.white.withAlphaComponent(0.02).cgColor,
            NSColor.clear.cgColor
        ]
        screenSheenLayer.locations = [0, 0.28, 1]
        screenSheenLayer.startPoint = CGPoint(x: 0.05, y: 1)
        screenSheenLayer.endPoint = CGPoint(x: 0.82, y: 0.03)
        screenLayer.addSublayer(screenSheenLayer)

        glassHighlightLayer.fillColor = NSColor.white.withAlphaComponent(0.10).cgColor
        screenLayer.addSublayer(glassHighlightLayer)

        appTileLayer.startPoint = CGPoint(x: 0.18, y: 1)
        appTileLayer.endPoint = CGPoint(x: 0.82, y: 0)
        appTileLayer.masksToBounds = true
        appTileLayer.shadowColor = ManagementVisualPalette.screenGlow.cgColor
        appTileLayer.shadowOpacity = 0.38
        appTileLayer.shadowRadius = 5
        appTileLayer.shadowOffset = .zero
        if #available(macOS 11.0, *) {
            appTileLayer.cornerCurve = .continuous
        }
        screenLayer.addSublayer(appTileLayer)

        for _ in 0..<4 {
            let glyph = CAShapeLayer()
            glyph.fillColor = NSColor.white.withAlphaComponent(0.94).cgColor
            appTileLayer.addSublayer(glyph)
            appGlyphLayers.append(glyph)
        }

        topHighlightLayer.fillColor = NSColor.clear.cgColor
        topHighlightLayer.strokeColor = NSColor.white.withAlphaComponent(0.54).cgColor
        topHighlightLayer.lineWidth = 0.8
        topHighlightLayer.lineCap = .round

        deviceRoot.addSublayer(floorShadowLayer)
        deviceRoot.addSublayer(edgeLayer)
        deviceRoot.addSublayer(chassisLayer)
        deviceRoot.addSublayer(screenLayer)
        deviceRoot.addSublayer(rimLayer)
        deviceRoot.addSublayer(topHighlightLayer)
    }

    private func layoutLayers() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let availableWidth = max(1, bounds.width - 4)
        let availableHeight = max(1, bounds.height - 4)
        let rootWidth = min(availableWidth, availableHeight * 1.5)
        let rootHeight = rootWidth / 1.5
        deviceRoot.bounds = CGRect(x: 0, y: 0, width: rootWidth, height: rootHeight)
        deviceRoot.position = CGPoint(x: bounds.midX, y: bounds.midY)
        deviceRoot.transform = deviceTransform()

        let root = deviceRoot.bounds
        let body = CGRect(
            x: root.width * 0.045,
            y: root.height * 0.105,
            width: root.width * 0.91,
            height: root.height * 0.77
        )
        let cornerRadius = max(3.5, body.height * 0.085)

        edgeLayer.frame = body.offsetBy(dx: root.width * 0.004, dy: -root.height * 0.045)
        edgeLayer.cornerRadius = cornerRadius

        chassisLayer.frame = body
        chassisLayer.cornerRadius = cornerRadius
        chassisSheenLayer.frame = chassisLayer.bounds

        floorShadowLayer.frame = CGRect(
            x: body.minX + body.width * 0.06,
            y: body.minY - root.height * 0.055,
            width: body.width * 0.88,
            height: root.height * 0.075
        )
        let shadowPath = NSBezierPath(
            ovalIn: floorShadowLayer.bounds
        )
        floorShadowLayer.path = shadowPath.cgPath

        let screenInsetX = body.width * 0.035
        let screenInsetY = body.height * 0.09
        let screenFrame = body.insetBy(dx: screenInsetX, dy: screenInsetY)
        screenLayer.frame = screenFrame
        screenLayer.cornerRadius = max(2.3, cornerRadius - 2.1)
        screenGlowLayer.frame = screenLayer.bounds
        screenSheenLayer.frame = screenLayer.bounds

        let glowInset = screenLayer.bounds.insetBy(
            dx: screenLayer.bounds.width * 0.03,
            dy: screenLayer.bounds.height * 0.035
        )
        let highlightPath = NSBezierPath()
        highlightPath.move(to: CGPoint(x: glowInset.minX, y: glowInset.maxY))
        highlightPath.line(to: CGPoint(x: glowInset.maxX, y: glowInset.maxY))
        highlightPath.line(to: CGPoint(x: glowInset.maxX, y: glowInset.maxY - glowInset.height * 0.36))
        highlightPath.curve(
            to: CGPoint(x: glowInset.minX, y: glowInset.maxY),
            controlPoint1: CGPoint(x: glowInset.midX, y: glowInset.maxY - glowInset.height * 0.72),
            controlPoint2: CGPoint(x: glowInset.minX, y: glowInset.maxY - glowInset.height * 0.48)
        )
        highlightPath.close()
        glassHighlightLayer.frame = screenLayer.bounds
        glassHighlightLayer.path = highlightPath.cgPath

        let tileSide = max(12, min(screenLayer.bounds.width * 0.24, screenLayer.bounds.height * 0.42))
        appTileLayer.bounds = CGRect(x: 0, y: 0, width: tileSide, height: tileSide)
        appTileLayer.position = CGPoint(x: screenLayer.bounds.midX, y: screenLayer.bounds.midY)
        appTileLayer.cornerRadius = tileSide * 0.22

        let glyphInset = tileSide * 0.26
        let glyphGap = tileSide * 0.08
        let glyphSide = (tileSide - glyphInset * 2 - glyphGap) / 2
        for (index, glyph) in appGlyphLayers.enumerated() {
            let column = CGFloat(index % 2)
            let row = CGFloat(index / 2)
            glyph.frame = CGRect(
                x: glyphInset + column * (glyphSide + glyphGap),
                y: glyphInset + row * (glyphSide + glyphGap),
                width: glyphSide,
                height: glyphSide
            )
            let glyphPath = NSBezierPath(
                roundedRect: glyph.bounds,
                xRadius: glyphSide * 0.24,
                yRadius: glyphSide * 0.24
            )
            glyph.path = glyphPath.cgPath
        }

        let chassisPath = NSBezierPath(
            roundedRect: chassisLayer.bounds.insetBy(dx: 0.45, dy: 0.45),
            xRadius: max(0, cornerRadius - 0.45),
            yRadius: max(0, cornerRadius - 0.45)
        )
        rimLayer.frame = chassisLayer.frame
        rimLayer.path = chassisPath.cgPath

        let topPath = NSBezierPath()
        let topY = body.maxY - body.height * 0.045
        topPath.move(to: CGPoint(x: body.minX + body.width * 0.13, y: topY))
        topPath.line(to: CGPoint(x: body.maxX - body.width * 0.13, y: topY))
        topHighlightLayer.frame = root
        topHighlightLayer.path = topPath.cgPath

        updateContentsScale()
    }

    private func deviceTransform() -> CATransform3D {
        let perspective = max(360, deviceRoot.bounds.width * 2.8)
        var transform = CATransform3DIdentity
        transform.m34 = -1 / perspective
        transform = CATransform3DRotate(transform, 0.055, -0.18, 0.98, 0)
        transform = CATransform3DRotate(transform, -0.014, 0, 0, 1)
        return transform
    }

    private func refreshStateAppearance() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let topColor = isActive ? ManagementVisualPalette.screenTop : ManagementVisualPalette.screenTopMuted
        let bottomColor = isActive ? ManagementVisualPalette.screenBottom : ManagementVisualPalette.screenBottomMuted
        screenLayer.colors = [topColor.cgColor, bottomColor.cgColor]

        screenGlowLayer.colors = [
            (isActive ? ManagementVisualPalette.screenGlow : ManagementVisualPalette.screenGlowMuted).cgColor,
            NSColor.clear.cgColor
        ]
        screenGlowLayer.opacity = isActive ? (isBusy ? 0.92 : 0.68) : 0.24

        appTileLayer.colors = isActive
            ? [ManagementVisualPalette.appTop.cgColor, ManagementVisualPalette.appBottom.cgColor]
            : [ManagementVisualPalette.appMuted.cgColor, ManagementVisualPalette.deviceEdge.cgColor]
        appTileLayer.shadowOpacity = isActive ? 0.42 : 0.12

        chassisLayer.borderColor = (
            isActive
                ? ManagementVisualPalette.deviceRim
                : ManagementVisualPalette.deviceRim.withAlphaComponent(0.38)
        ).cgColor
        rimLayer.strokeColor = chassisLayer.borderColor
        for (index, glyph) in appGlyphLayers.enumerated() {
            let alpha: CGFloat = isActive ? (index == 0 ? 1 : 0.78) : 0.50
            glyph.fillColor = NSColor.white.withAlphaComponent(alpha).cgColor
        }
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard abs(deviceRoot.contentsScale - scale) > 0.01 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        deviceRoot.contentsScale = scale
        for sublayer in allDeviceLayers() {
            sublayer.contentsScale = scale
        }
        CATransaction.commit()
    }

    private func allDeviceLayers() -> [CALayer] {
        var result: [CALayer] = []
        var pending: [CALayer] = deviceRoot.sublayers ?? []
        while let layer = pending.popLast() {
            result.append(layer)
            pending.append(contentsOf: layer.sublayers ?? [])
        }
        return result
    }
}

@MainActor
enum TFMotion {
    private static let revealKey = "macdora.page-reveal"

    static var reducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static func reveal(_ view: NSView) {
        if view.layer == nil {
            view.wantsLayer = true
        }
        guard let layer = view.layer else { return }
        layer.removeAnimation(forKey: revealKey)
        layer.opacity = 1

        guard !reducedMotion, canAnimate(view) else { return }

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1

        let lift = CABasicAnimation(keyPath: "transform.translation.y")
        lift.fromValue = 3
        lift.toValue = 0
        lift.isAdditive = true

        let group = CAAnimationGroup()
        group.animations = [fade, lift]
        group.duration = 0.2
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .backwards
        group.isRemovedOnCompletion = true
        layer.add(group, forKey: revealKey)
    }

    private static func canAnimate(_ view: NSView) -> Bool {
        guard let window = view.window,
              NSApplication.shared.isActive,
              window.isKeyWindow || window.isMainWindow,
              !view.isHiddenOrHasHiddenAncestor,
              window.isVisible,
              !window.isMiniaturized,
              window.occlusionState.contains(.visible)
        else {
            return false
        }
        return true
    }
}
