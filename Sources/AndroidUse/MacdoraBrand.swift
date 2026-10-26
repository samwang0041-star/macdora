import AppKit
import CoreGraphics

enum MacdoraBrand {
    static let appName = "Macdora"
    static let initialVersionString = "0.01"
    static let initialBuildString = "1"
    /// Public source, release assets and anonymous update feed share one repository.
    static let defaultGitHubRepository = "samwang0041-star/macdora"

    static func rgba(_ hex: UInt32, _ alpha: CGFloat = 1.0) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }

    static func continuousSquirclePath(_ rect: CGRect, cornerRadius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let r = min(cornerRadius, min(rect.width, rect.height) * 0.5)
        let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        let inset = min(r * 1.05, min(rect.width, rect.height) * 0.48)
        let k: CGFloat = 0.60
        path.move(to: CGPoint(x: minX + inset, y: maxY))
        path.addLine(to: CGPoint(x: maxX - inset, y: maxY))
        path.addCurve(
            to: CGPoint(x: maxX, y: maxY - inset),
            control1: CGPoint(x: maxX - inset * (1 - k), y: maxY),
            control2: CGPoint(x: maxX, y: maxY - inset * (1 - k))
        )
        path.addLine(to: CGPoint(x: maxX, y: minY + inset))
        path.addCurve(
            to: CGPoint(x: maxX - inset, y: minY),
            control1: CGPoint(x: maxX, y: minY + inset * (1 - k)),
            control2: CGPoint(x: maxX - inset * (1 - k), y: minY)
        )
        path.addLine(to: CGPoint(x: minX + inset, y: minY))
        path.addCurve(
            to: CGPoint(x: minX, y: minY + inset),
            control1: CGPoint(x: minX + inset * (1 - k), y: minY),
            control2: CGPoint(x: minX, y: minY + inset * (1 - k))
        )
        path.addLine(to: CGPoint(x: minX, y: maxY - inset))
        path.addCurve(
            to: CGPoint(x: minX + inset, y: maxY),
            control1: CGPoint(x: minX, y: maxY - inset * (1 - k)),
            control2: CGPoint(x: minX + inset * (1 - k), y: maxY)
        )
        path.closeSubpath()
        return path
    }

    static func capsulePath(from a: CGPoint, to b: CGPoint, radius: CGFloat) -> CGPath {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let path = CGMutablePath()
        path.addArc(
            center: a,
            radius: radius,
            startAngle: angle + .pi / 2,
            endAngle: angle + 3 * .pi / 2,
            clockwise: false
        )
        path.addArc(
            center: b,
            radius: radius,
            startAngle: angle - .pi / 2,
            endAngle: angle + .pi / 2,
            clockwise: false
        )
        path.closeSubpath()
        return path
    }

    /// Draws the flat minimalist Macdora Emblem / App Icon in unflipped coordinates:
    /// - Deep architectural Obsidian-Navy squircle (#0F172A)
    /// - Bespoke geometric 'M' monogram (#FFFFFF) whose two upper peaks are morphed into Flat Doraemon-Blue (#28A8FF) ears
    ///   separated by a negative-space arch seam, matching the first letter of the Macdora wordmark.
    static func drawEmblem(in ctx: CGContext, rect: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        let scale = rect.width / 1024.0
        ctx.scaleBy(x: scale, y: scale)

        let bodyRect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let squircle = continuousSquirclePath(bodyRect, cornerRadius: 232)

        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.clip()

        ctx.setFillColor(rgba(0x0F172A))
        ctx.fill(bodyRect)

        let mScale: CGFloat = 5.75
        let mW: CGFloat = 104.0
        let mH: CGFloat = 98.0
        let originX = (1024.0 - mW * mScale) * 0.5
        let originY = (1024.0 - mH * mScale) * 0.5 - 4.0

        ctx.saveGState()
        ctx.translateBy(x: originX, y: originY)
        ctx.scaleBy(x: mScale, y: mScale)

        let W: CGFloat = 17.6
        let r: CGFloat = W * 0.5
        let rTip: CGFloat = 6.2
        let mLeftX = r
        let mMidX = mW * 0.5
        let mRightX = mW - r
        let peakY: CGFloat = 98.0 - rTip
        let valleyY: CGFloat = 15.0

        let leftPeakPt = CGPoint(x: mLeftX - r + rTip, y: peakY)
        let rightPeakPt = CGPoint(x: mRightX + r - rTip, y: peakY)
        let midBottomPt = CGPoint(x: mMidX, y: valleyY)

        let mMasterPath = CGMutablePath()
        mMasterPath.addPath(taperedCapsulePath(from: CGPoint(x: mLeftX, y: r), radiusA: r, to: leftPeakPt, radiusB: rTip))
        mMasterPath.addPath(taperedCapsulePath(from: leftPeakPt, radiusA: rTip, to: midBottomPt, radiusB: r))
        mMasterPath.addPath(taperedCapsulePath(from: midBottomPt, radiusA: r, to: rightPeakPt, radiusB: rTip))
        mMasterPath.addPath(taperedCapsulePath(from: CGPoint(x: mRightX, y: r), radiusA: r, to: rightPeakPt, radiusB: rTip))

        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(rgba(0xFFFFFF))
        ctx.addPath(mMasterPath)
        ctx.fillPath()

        ctx.saveGState()
        ctx.addPath(mMasterPath)
        ctx.clip()

        let earCutRadius: CGFloat = 42.0
        let earCutCenterY: CGFloat = 31.5
        let leftCutCenter = CGPoint(x: mLeftX + 5.0, y: earCutCenterY)
        let rightCutCenter = CGPoint(x: mRightX - 5.0, y: earCutCenterY)

        // 1. Two upper peaks -> Flat Doraemon-Blue Ear-Peaks (#28A8FF)
        for c in [leftCutCenter, rightCutCenter] {
            let capPath = CGMutablePath()
            capPath.addArc(center: c, radius: earCutRadius, startAngle: 15.0 * .pi / 180.0, endAngle: 165.0 * .pi / 180.0, clockwise: false)
            capPath.addLine(to: CGPoint(x: c.x - 45.0, y: 110.0))
            capPath.addLine(to: CGPoint(x: c.x + 45.0, y: 110.0))
            capPath.closeSubpath()

            ctx.setBlendMode(.sourceIn)
            ctx.setFillColor(rgba(0x28A8FF))
            ctx.addPath(capPath)
            ctx.fillPath()

            ctx.setBlendMode(.clear)
            ctx.setLineWidth(3.5)
            let seamArc = CGMutablePath()
            seamArc.addArc(center: c, radius: earCutRadius, startAngle: 15.0 * .pi / 180.0, endAngle: 165.0 * .pi / 180.0, clockwise: false)
            ctx.addPath(seamArc)
            ctx.strokePath()
        }

        ctx.restoreGState()
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        ctx.addPath(squircle)
        ctx.setStrokeColor(rgba(0xFFFFFF, 0.14))
        ctx.setLineWidth(20)
        ctx.strokePath()

        ctx.restoreGState()
        ctx.restoreGState()
    }

    /// Returns the Macdora application icon image (loads bundled AppIcon.icns when available, otherwise renders dynamically).
    static func appIconImage(size: CGFloat = 512) -> NSImage {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let bundled = NSImage(contentsOf: url) {
            return bundled
        }
        let pixels = Int(size * 2)
        let image = NSImage(size: NSSize(width: size, height: size))
        if let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) {
            rep.size = NSSize(width: size, height: size)
            NSGraphicsContext.saveGraphicsState()
            if let gctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = gctx
                drawEmblem(in: gctx.cgContext, rect: CGRect(x: 48, y: 48, width: CGFloat(pixels) - 96, height: CGFloat(pixels) - 96))
            }
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        return image
    }

    static func dockAppIconImage(_ icon: NSImage, size: CGFloat = 512) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }
        let inset = size * 48 / 1024
        let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
        if let context = NSGraphicsContext.current {
            context.imageInterpolation = .high
            context.cgContext.addPath(continuousSquirclePath(rect, cornerRadius: size * 232 / 1024))
            context.cgContext.clip()
            icon.draw(in: rect)
        }
        return image
    }

    /// Creates a tapered capsule from point `a` (radius `rA`) to point `b` (radius `rB`) with exact tangent flanks.
    static func taperedCapsulePath(from a: CGPoint, radiusA rA: CGFloat, to b: CGPoint, radiusB rB: CGFloat) -> CGPath {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let d = max(0.001, hypot(dx, dy))
        let baseAngle = atan2(dy, dx)
        let sinAlpha = max(-1.0, min(1.0, (rA - rB) / d))
        let alpha = asin(sinAlpha)

        let a1 = baseAngle + .pi * 0.5 - alpha
        let a2 = baseAngle - .pi * 0.5 + alpha

        let p = CGMutablePath()
        p.addArc(center: a, radius: rA, startAngle: a1, endAngle: a2, clockwise: false)
        p.addArc(center: b, radius: rB, startAngle: a2, endAngle: a1, clockwise: false)
        p.closeSubpath()
        return p
    }

    /// Draws the bespoke flat circular-geometric "Macdora" English wordmark:
    /// - The two upper peaks of "M" are morphed into flat minimalist Doraemon-blue ears separated by a negative-space arch.
    /// - The letter "o" in "dora" is morphed into an abstract flat golden-yellow Doraemon bell (no cartoon outlines/loops).
    /// Coordinate system is 100pt ascender height (total width ~545 units at scale = 1.0).
    static func drawWordmark(
        in ctx: CGContext,
        origin: CGPoint,
        scale: CGFloat,
        isDark: Bool
    ) {
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: scale, y: scale)

        let R: CGFloat = 36.0
        let cy: CGFloat = 36.0
        let W: CGFloat = 17.2
        let r: CGFloat = W * 0.5
        let ascH: CGFloat = 100.0
        let innerR = R - W

        let inkColor = isDark ? rgba(0xFFFFFF) : rgba(0x0F172A)
        let doraBlue = isDark ? rgba(0x28A8FF) : rgba(0x0096FA)
        let bellGold = isDark ? rgba(0xFACC15) : rgba(0xF5B700)

        func fillBowlAndStem(ringCenterX: CGFloat, stemTop: CGFloat, stemBottom: CGFloat) {
            let stemX = ringCenterX + R - r
            let stem = capsulePath(
                from: CGPoint(x: stemX, y: stemBottom + r),
                to: CGPoint(x: stemX, y: stemTop - r),
                radius: r
            )

            ctx.saveGState()
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)

            ctx.setFillColor(inkColor)
            ctx.fillEllipse(in: CGRect(x: ringCenterX - R, y: cy - R, width: 2 * R, height: 2 * R))
            ctx.fill(CGRect(x: ringCenterX + innerR * 0.5, y: cy - R * 0.56, width: R - innerR * 0.5, height: R * 1.12))
            ctx.addPath(stem)
            ctx.fillPath()

            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: CGRect(x: ringCenterX - innerR, y: cy - innerR, width: 2 * innerR, height: 2 * innerR))
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }

        var cursorX: CGFloat = 2.0

        // 1. Capital 'M' with its two upper peaks morphed into Flat Doraemon Blue Ear-Peaks
        let mW: CGFloat = 104.0
        let mLeftX = cursorX + r
        let mMidX = cursorX + mW * 0.5
        let mRightX = cursorX + mW - r
        let rTip: CGFloat = 6.2
        let peakY: CGFloat = 98.0 - rTip
        let leftPeakPt = CGPoint(x: mLeftX - r + rTip, y: peakY)
        let rightPeakPt = CGPoint(x: mRightX + r - rTip, y: peakY)
        let midBottomPt = CGPoint(x: mMidX, y: 14.5)

        let mMasterPath = CGMutablePath()
        mMasterPath.addPath(taperedCapsulePath(from: CGPoint(x: mLeftX, y: r), radiusA: r, to: leftPeakPt, radiusB: rTip))
        mMasterPath.addPath(taperedCapsulePath(from: leftPeakPt, radiusA: rTip, to: midBottomPt, radiusB: r))
        mMasterPath.addPath(taperedCapsulePath(from: midBottomPt, radiusA: r, to: rightPeakPt, radiusB: rTip))
        mMasterPath.addPath(taperedCapsulePath(from: CGPoint(x: mRightX, y: r), radiusA: r, to: rightPeakPt, radiusB: rTip))

        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(inkColor)
        ctx.addPath(mMasterPath)
        ctx.fillPath()

        ctx.saveGState()
        ctx.addPath(mMasterPath)
        ctx.clip()

        let earCutRadius: CGFloat = 42.0
        let earCutCenterY: CGFloat = 31.5
        let leftCutCenter = CGPoint(x: mLeftX + 5.0, y: earCutCenterY)
        let rightCutCenter = CGPoint(x: mRightX - 5.0, y: earCutCenterY)

        for c in [leftCutCenter, rightCutCenter] {
            let capPath = CGMutablePath()
            capPath.addArc(center: c, radius: earCutRadius, startAngle: 15.0 * .pi / 180.0, endAngle: 165.0 * .pi / 180.0, clockwise: false)
            capPath.addLine(to: CGPoint(x: c.x - 45.0, y: 110.0))
            capPath.addLine(to: CGPoint(x: c.x + 45.0, y: 110.0))
            capPath.closeSubpath()

            ctx.setBlendMode(.sourceIn)
            ctx.setFillColor(doraBlue)
            ctx.addPath(capPath)
            ctx.fillPath()

            ctx.setBlendMode(.clear)
            ctx.setLineWidth(3.4)
            let seamArc = CGMutablePath()
            seamArc.addArc(center: c, radius: earCutRadius, startAngle: 15.0 * .pi / 180.0, endAngle: 165.0 * .pi / 180.0, clockwise: false)
            ctx.addPath(seamArc)
            ctx.strokePath()
        }
        ctx.restoreGState()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        cursorX += mW + 12.0

        // 2. Single-story 'a'
        let a1CenterX = cursorX + R
        fillBowlAndStem(ringCenterX: a1CenterX, stemTop: cy + R, stemBottom: 0)
        cursorX += 2 * R + 11.5

        // 3. Geometric 'c'
        let cCenterX = cursorX + R
        let midR = R - r
        let startA: CGFloat = 37.5 * .pi / 180.0
        let endA: CGFloat = -37.5 * .pi / 180.0
        let cArc = CGMutablePath()
        cArc.addArc(center: CGPoint(x: cCenterX, y: cy), radius: midR, startAngle: startA, endAngle: endA, clockwise: false)
        let cStroked = cArc.copy(strokingWithWidth: W, lineCap: .round, lineJoin: .round, miterLimit: 4)
        ctx.saveGState()
        ctx.setFillColor(inkColor)
        ctx.addPath(cStroked)
        ctx.fillPath()
        ctx.restoreGState()
        cursorX += 2 * R - 4.5 + 10.5

        // 4. Geometric 'd'
        let dCenterX = cursorX + R
        fillBowlAndStem(ringCenterX: dCenterX, stemTop: ascH, stemBottom: 0)
        cursorX += 2 * R + 13.0

        // 5. 'o' -> Abstract Flat Golden-Yellow Bell morphed from the letter 'o'
        let bellCenterX = cursorX + R
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)

        ctx.setFillColor(bellGold)
        ctx.fillEllipse(in: CGRect(x: bellCenterX - R, y: cy - R, width: 2 * R, height: 2 * R))

        let rimW = 2 * R + 7.6
        let rimH: CGFloat = 8.6
        let rimY = cy + 5.2
        let rimRect = CGRect(x: bellCenterX - rimW * 0.5, y: rimY, width: rimW, height: rimH)

        // Negative-space seam right above the equatorial rim
        ctx.setBlendMode(.clear)
        ctx.fill(CGRect(x: bellCenterX - R - 4.0, y: rimRect.maxY, width: 2 * R + 8.0, height: 3.4))

        // Flat protruding equatorial rim pill
        ctx.setBlendMode(.normal)
        ctx.setFillColor(bellGold)
        ctx.addPath(CGPath(roundedRect: rimRect, cornerWidth: rimH * 0.5, cornerHeight: rimH * 0.5, transform: nil))
        ctx.fillPath()

        // Circular 'o' counter + 6-o'clock vertical keyhole slit
        ctx.setBlendMode(.clear)
        let holeR: CGFloat = 11.6
        let holeY: CGFloat = cy - 7.2
        ctx.fillEllipse(in: CGRect(x: bellCenterX - holeR, y: holeY - holeR, width: 2 * holeR, height: 2 * holeR))
        ctx.addPath(capsulePath(from: CGPoint(x: bellCenterX, y: holeY), to: CGPoint(x: bellCenterX, y: cy - R - 2.0), radius: 3.6))
        ctx.fillPath()

        ctx.endTransparencyLayer()
        ctx.restoreGState()
        cursorX += 2 * R + 14.0

        // 6. Geometric 'r'
        let rStemX = cursorX + r
        let rArcRadius: CGFloat = 24.5
        let rArcCenterX = rStemX + rArcRadius - r * 0.22
        let rArcCenterY = cy + R - r - rArcRadius
        let rArc = CGMutablePath()
        rArc.addArc(
            center: CGPoint(x: rArcCenterX, y: rArcCenterY),
            radius: rArcRadius,
            startAngle: 145.0 * .pi / 180.0,
            endAngle: 38.0 * .pi / 180.0,
            clockwise: true
        )
        let rShoulder = rArc.copy(strokingWithWidth: W, lineCap: .round, lineJoin: .round, miterLimit: 4)
        let rStem = capsulePath(from: CGPoint(x: rStemX, y: r), to: CGPoint(x: rStemX, y: cy + R - r), radius: r)

        ctx.saveGState()
        ctx.setFillColor(inkColor)
        ctx.addPath(rStem)
        ctx.fillPath()
        ctx.addPath(rShoulder)
        ctx.fillPath()
        ctx.restoreGState()
        cursorX += r + rArcRadius + 23.0

        // 7. Final single-story 'a'
        let a2CenterX = cursorX + R
        fillBowlAndStem(ringCenterX: a2CenterX, stemTop: cy + R, stemBottom: 0)

        ctx.restoreGState()
    }
}

@MainActor
final class MacdoraEmblemView: NSView {
    private let emblemSize: CGFloat

    init(size: CGFloat = 26) {
        self.emblemSize = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        MacdoraBrand.drawEmblem(in: ctx, rect: bounds)
    }
}

@MainActor
final class MacdoraBrandLockupView: NSView {
    var isDark: Bool = false {
        didSet { needsDisplay = true }
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(MacdoraBrand.appName)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 144),
            heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        MacdoraBrand.drawWordmark(
            in: ctx,
            origin: CGPoint(x: 1.0, y: 5.5),
            scale: 0.22,
            isDark: isDark
        )
    }
}
