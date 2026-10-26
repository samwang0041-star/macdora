import AppKit
import CoreImage
import CoreVideo
import Metal
import QuartzCore
import Carbon

final class AndroidSurfaceView: NSView, NSTextInputClient {
    static let metalShaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };
    vertex VertexOut surfaceVertex(uint vid [[vertex_id]]) {
        constexpr float2 positions[4] = {
            float2(-1.0,  1.0),
            float2( 1.0,  1.0),
            float2(-1.0, -1.0),
            float2( 1.0, -1.0)
        };
        constexpr float2 texCoords[4] = {
            float2(0.0, 0.0),
            float2(1.0, 0.0),
            float2(0.0, 1.0),
            float2(1.0, 1.0)
        };
        VertexOut out;
        out.position = float4(positions[vid], 0.0, 1.0);
        out.texCoord = texCoords[vid];
        return out;
    }
    fragment half4 surfaceFragmentBGRA(VertexOut in [[stage_in]], texture2d<half, access::sample> tex [[texture(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        return tex.sample(s, in.texCoord);
    }
    fragment half4 surfaceFragmentNV12(
        VertexOut in [[stage_in]],
        texture2d<float, access::sample> yTex [[texture(0)]],
        texture2d<float, access::sample> uvTex [[texture(1)]],
        constant uint &colorMode [[buffer(0)]]
    ) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float ySample = yTex.sample(s, in.texCoord).r;
        float2 uvSample = uvTex.sample(s, in.texCoord).rg;
        bool fullRange = (colorMode & 1u) != 0u;
        bool bt601 = (colorMode & 2u) != 0u;
        float y = fullRange ? ySample : clamp((ySample - (16.0 / 255.0)) * (255.0 / 219.0), 0.0, 1.0);
        float chromaScale = fullRange ? 1.0 : (255.0 / 224.0);
        float cb = (uvSample.r - (128.0 / 255.0)) * chromaScale;
        float cr = (uvSample.g - (128.0 / 255.0)) * chromaScale;
        float3 rgb;
        if (bt601) {
            rgb.r = y + 1.4020 * cr;
            rgb.g = y - 0.344136 * cb - 0.714136 * cr;
            rgb.b = y + 1.7720 * cb;
        } else {
            rgb.r = y + 1.5748 * cr;
            rgb.g = y - 0.187324 * cb - 0.468124 * cr;
            rgb.b = y + 1.8556 * cb;
        }
        rgb = clamp(rgb, 0.0, 1.0);
        if ((colorMode & 4u) != 0u) {
            float3 linear = select(pow((rgb + 0.099) / 1.099, float3(1.0 / 0.45)), rgb / 4.5, rgb < 0.081);
            rgb = select(1.055 * pow(linear, float3(1.0 / 2.4)) - 0.055, 12.92 * linear, linear <= 0.0031308);
        }
        return half4(half3(rgb), 1.0h);
    }
    """

    private let metal: CAMetalLayer
    private let gpu: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let context: CIContext
    private var textureCache: CVMetalTextureCache?
    private let bgraPipelineState: MTLRenderPipelineState?
    private let nv12PipelineState: MTLRenderPipelineState?
    private let frameLock = NSLock()
    private var pendingFrame: DecodedFrame?
    private var renderingScheduled = false
    private var sessionID = UUID()
    private var currentSessionID: UUID {
        frameLock.lock()
        defer { frameLock.unlock() }
        return sessionID
    }
    private var lastFrame: DecodedFrame?
    private var lastFrameSequence: UInt64 = 0
    private var isTouching = false
    private var marked = NSAttributedString(string: "")
    private var markedSelection = NSRange(location: 0, length: 0)
    private var requestedHostInputSource: String?
    private var clipboardSequence: UInt64 = 0
    private var inputFocus: InputFocus?
    private var trustedInputLease: InputLease?
    private var compositionLease: InputLease?
    private var compositionPointer: UInt64?
    private var invalidatedComposition = false
    private var discardingComposition = false
    private var awaitingPointerFocus = false
    private var pointerSequence: UInt64 = 0
    private var secureInputEnabled = false
    private var focusObservers: [NSObjectProtocol] = []
    private let composition = NSTextField(labelWithString: "")
    var pixelSize = CGSize(width: 1080, height: 1920) {
        didSet {
            if pixelSize != oldValue {
                updateDrawableSize()
            }
        }
    }
    var fillBoundsEdgeToEdge = true { didSet { updateDrawableSize() } }
    var onPixelSizeChanged: ((CGSize) -> Void)?
    var sendInput: ((Data) -> Void)?
    var sendDirectText: ((String, InputLease) -> Void)?
    var onPointerBegan: ((UInt64) -> Void)?
    var onInputIssue: ((String) -> Void)?
    var onPresented: ((DecodedFrame, Double) -> Void)?
    var onInvalidPresentation: ((Double) -> Void)?
    var onRenderPath: ((String) -> Void)?
    var onRenderTiming: ((String, Double) -> Void)?
    var onRenderDiagnostic: ((String) -> Void)?
    var onFirstFrame: (() -> Void)?
    var onInput: ((Double) -> Void)?
    var displaySyncEnabled: Bool { metal.displaySyncEnabled }
    private let configuredPresentationInterval = ProcessInfo.processInfo.environment["ANDROID_USE_PACED_PRESENTATION"] == "0" ? 0.0 : 1.0 / 120.0
    var minimumPresentationInterval: Double { metal.displaySyncEnabled ? 0 : configuredPresentationInterval }
    private var firstFrame = true
    private var backgroundRenderQueue: FrameRenderQueue<BackgroundRenderPayload>?
    var inputEnabled = true { didSet { updateSecureInput() } }
    var clipboardSyncEnabled = true
    var videoVisible = true {
        didSet {
            metal.isHidden = !videoVisible
            updateSecureInput()
            if videoVisible && !oldValue, let lastFrame {
                submitCachedRedraw(lastFrame, session: currentSessionID)
            }
        }
    }
    var canSelectHostInputSource: Bool { videoVisible && inputEnabled && window?.isVisible == true }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(frame: NSRect, device: MTLDevice) {
        gpu = device
        commandQueue = device.makeCommandQueue()!
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        textureCache = cache
        if let library = try? device.makeLibrary(source: Self.metalShaderSource, options: nil),
           let vertexFn = library.makeFunction(name: "surfaceVertex") {
            if let bgraFn = library.makeFunction(name: "surfaceFragmentBGRA") {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertexFn
                descriptor.fragmentFunction = bgraFn
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                bgraPipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)
            } else {
                bgraPipelineState = nil
            }
            if let nv12Fn = library.makeFunction(name: "surfaceFragmentNV12") {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertexFn
                descriptor.fragmentFunction = nv12Fn
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                nv12PipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)
            } else {
                nv12PipelineState = nil
            }
        } else {
            bgraPipelineState = nil
            nv12PipelineState = nil
        }
        metal = CAMetalLayer()
        metal.device = device
        metal.pixelFormat = .bgra8Unorm
        metal.framebufferOnly = (bgraPipelineState != nil || nv12PipelineState != nil)
        metal.maximumDrawableCount = ProcessInfo.processInfo.environment["ANDROID_USE_MAX_DRAWABLES"] == "2" ? 2 : 3
        // The guest already paces frames. Avoid a second host display-sync wait.
        metal.displaySyncEnabled = ProcessInfo.processInfo.environment["ANDROID_USE_DISPLAY_SYNC"] == "1"
        metal.isOpaque = true
        metal.backgroundColor = NSColor.black.cgColor
        metal.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metal.contentsGravity = .resize
        let usesBackgroundRenderQueue = ProcessInfo.processInfo.environment["ANDROID_USE_RENDER_QUEUE"] != "main"
        // Core Image writes through CAMetalLayer drawable textures. Keep the
        // experimental background path writable so color-managed fallback can
        // never fail after the renderer has moved off main.
        if usesBackgroundRenderQueue {
            metal.framebufferOnly = false
        }
        super.init(frame: frame)
        if usesBackgroundRenderQueue {
            backgroundRenderQueue = FrameRenderQueue(
                label: "local.androiduse.metal-render",
                session: sessionID,
                qos: .userInteractive
            ) { [weak self] job in
                try self?.renderOffMain(job)
            }
        } else {
            backgroundRenderQueue = nil
        }
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(metal)
        layerContentsRedrawPolicy = .never
        setAccessibilityRole(.image)
        setAccessibilityLabel("Android 应用画面，支持点击、滚动和键盘输入")
        composition.font = .systemFont(ofSize: 15)
        composition.drawsBackground = true
        composition.backgroundColor = .controlBackgroundColor
        composition.textColor = .labelColor
        composition.isHidden = true
        addSubview(composition)
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        focusObservers.forEach { NotificationCenter.default.removeObserver($0) }
        focusObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                          NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification,
                          NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let self else { return }
                if name == NSWindow.didResignKeyNotification || name == NSApplication.didResignActiveNotification { self.discardComposition() }
                self.updateSecureInput()
                let ownWindow = (notification.object as? NSWindow) === self.window
                let redraw = name == NSApplication.didBecomeActiveNotification
                    || (ownWindow && (name == NSWindow.didBecomeKeyNotification
                        || name == NSWindow.didDeminiaturizeNotification
                        || (name == NSWindow.didChangeOcclusionStateNotification && self.window?.occlusionState.contains(.visible) == true)))
                if redraw, let frame = self.lastFrame {
                    self.submitCachedRedraw(frame, session: self.currentSessionID)
                }
            }
        }
        updateDrawableSize()
        updateSecureInput()
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder(); updateSecureInput(); return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { endSecureInput(); discardComposition() }
        return result
    }

    func currentSnapshotCGImage() -> CGImage? {
        frameLock.lock()
        let frame = lastFrame
        frameLock.unlock()
        guard let buffer = frame?.buffer else { return nil }
        let ciImage = CIImage(cvPixelBuffer: buffer)
        return context.createCGImage(ciImage, from: ciImage.extent)
    }

    func setInputFocus(_ focus: InputFocus?) {
        let sameEditor = focus.map { next in inputFocus?.lease.hasSameEditor(as: next.lease) == true } ?? false
        if !sameEditor || focus?.active != true {
            trustedInputLease = nil
            if !awaitingPointerFocus || focus == nil
                || (inputFocus != nil && inputFocus?.lease.connection != focus?.lease.connection) { discardComposition() }
        }
        inputFocus = focus
        if focus?.sensitive == true { requestedHostInputSource = nil; discardComposition() }
        composition.stringValue = focus?.sensitive == true ? "" : marked.string
        composition.isHidden = marked.length == 0 || focus?.sensitive == true
        inputContext?.allowedInputSourceLocales = focus?.sensitive == true ? [NSAllRomanInputSourcesLocaleIdentifier] : nil
        updateSecureInput()
    }

    /// Only VideoStream's ordered touch ACK plus Guest connection confirmation
    /// may grant a lease. An unsolicited active-focus event cannot grant one.
    func confirmInputFocus(_ focus: InputFocus?, pointerSequence: UInt64) {
        guard pointerSequence == self.pointerSequence else { return }
        guard let focus, focus.active,
              focus.lease.pointerSequence == pointerSequence, focus.lease.displayId > 0,
              inputFocus?.active == true, inputFocus?.lease.hasSameEditor(as: focus.lease) == true else {
            trustedInputLease = nil
            if !awaitingPointerFocus { discardComposition() }
            return
        }
        trustedInputLease = focus.lease
        awaitingPointerFocus = false
        if hasMarkedText(), compositionLease == nil, compositionPointer == pointerSequence { compositionLease = focus.lease }
    }

    @discardableResult
    func beginPointerInteraction() -> UInt64 {
        discardComposition(); trustedInputLease = nil; awaitingPointerFocus = true
        pointerSequence &+= 1
        onPointerBegan?(pointerSequence)
        return pointerSequence
    }

    private func updateSecureInput() {
        applyRequestedInputSource()
        let needed = videoVisible && inputEnabled && inputFocus?.active == true && inputFocus?.sensitive == true
            && NSApplication.shared.isActive && window?.isKeyWindow == true && window?.firstResponder === self
        if needed && !secureInputEnabled { secureInputEnabled = EnableSecureEventInput() == noErr }
        if !needed { endSecureInput() }
    }
    private func endSecureInput() {
        if secureInputEnabled { _ = DisableSecureEventInput(); secureInputEnabled = false }
    }
    private func discardComposition() {
        let hadComposition = hasMarkedText()
        compositionLease = nil; compositionPointer = nil
        if hadComposition { invalidatedComposition = true }
        discardingComposition = true
        if hadComposition { inputContext?.discardMarkedText() }
        unmarkText()
        discardingComposition = false
    }
    deinit {
        focusObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if secureInputEnabled {
            if Thread.isMainThread { _ = DisableSecureEventInput() }
            else { DispatchQueue.main.async { _ = DisableSecureEventInput() } }
        }
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
        composition.frame = CGRect(x: 14, y: max(0, bounds.height - 48), width: max(1, bounds.width - 28), height: 30)
        inputContext?.invalidateCharacterCoordinates()
        if !inLiveResize, let lastFrame {
            submitCachedRedraw(lastFrame, session: currentSessionID)
        }
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        // Keep one drawable at source resolution during live resize. Only its
        // viewport moves; disabling implicit animations prevents resize trails.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metal.contentsScale = scale
        metal.frame = fillBoundsEdgeToEdge
            ? SurfaceGeometry(bounds: bounds, pixels: pixelSize).contentRect
            : bounds
        let desiredSize: CGSize
        if fillBoundsEdgeToEdge, pixelSize.width > 0, pixelSize.height > 0 {
            desiredSize = pixelSize
        } else {
            desiredSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        }
        if metal.drawableSize != desiredSize {
            metal.drawableSize = desiredSize
        }
        CATransaction.commit()
    }

    /// At most one background render is executing. Decoder frames are coalesced
    /// to the newest one; cached redraws cannot displace a newer decoded frame.
    func beginSession(_ identifier: UUID) {
        frameLock.lock(); sessionID = identifier; pendingFrame = nil; frameLock.unlock()
        backgroundRenderQueue?.beginSession(identifier)
        firstFrame = true; lastFrame = nil; lastFrameSequence = 0; isTouching = false
        awaitingPointerFocus = false; pointerSequence = 0; trustedInputLease = nil; requestedHostInputSource = nil; setInputFocus(nil)
    }

    func accept(_ frame: DecodedFrame, session: UUID? = nil) {
        frameLock.lock()
        if let session, session != sessionID { frameLock.unlock(); return }
        pendingFrame = frame
        if renderingScheduled { frameLock.unlock(); return }
        renderingScheduled = true
        frameLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.renderLatest() }
    }

    private func renderLatest() {
        frameLock.lock()
        let frame = pendingFrame
        let activeSession = sessionID
        pendingFrame = nil
        renderingScheduled = false
        frameLock.unlock()
        guard let frame else { return }
        lastFrameSequence &+= 1
        installAsLatestFrame(frame)
        if let backgroundRenderQueue {
            guard let snapshot = mainThreadSnapshot() else { return }
            backgroundRenderQueue.submitDecoded(BackgroundRenderPayload(frame: frame, snapshot: snapshot), session: activeSession, frameSequence: lastFrameSequence)
        } else {
            render(frame, countPresentation: true, session: activeSession)
        }
    }

    private enum ZeroCopySource {
        case bgra(MTLRenderPipelineState, CVMetalTexture, MTLTexture)
        case nv12(MTLRenderPipelineState, CVMetalTexture, MTLTexture, CVMetalTexture, MTLTexture, UInt32)

        var path: String {
            switch self {
            case .bgra: return "metal-bgra"
            case .nv12: return "metal-nv12"
            }
        }
    }

    private func prepareZeroCopySource(for buffer: CVPixelBuffer) -> ZeroCopySource? {
        guard let textureCache else { return nil }
        let pixelFormat = CVPixelBufferGetPixelFormatType(buffer)
        if (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
           let nv12PipelineState, let colorMode = Self.nv12ColorMode(buffer) {
            var yCVTex: CVMetalTexture?
            var uvCVTex: CVMetalTexture?
            let yWidth = CVPixelBufferGetWidthOfPlane(buffer, 0)
            let yHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
            let uvWidth = CVPixelBufferGetWidthOfPlane(buffer, 1)
            let uvHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
            let yStatus = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, buffer, nil, .r8Unorm, yWidth, yHeight, 0, &yCVTex
            )
            let uvStatus = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, buffer, nil, .rg8Unorm, uvWidth, uvHeight, 1, &uvCVTex
            )
            if yStatus == kCVReturnSuccess, uvStatus == kCVReturnSuccess,
               let retainedY = yCVTex, let yTex = CVMetalTextureGetTexture(retainedY),
               let retainedUV = uvCVTex, let uvTex = CVMetalTextureGetTexture(retainedUV) {
                return .nv12(nv12PipelineState, retainedY, yTex, retainedUV, uvTex, colorMode)
            }
            return nil
        }
        if pixelFormat == kCVPixelFormatType_32BGRA, let bgraPipelineState {
            var cvTex: CVMetalTexture?
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, buffer, nil, .bgra8Unorm, width, height, 0, &cvTex
            )
            if status == kCVReturnSuccess, let retained = cvTex, let tex = CVMetalTextureGetTexture(retained) {
                return .bgra(bgraPipelineState, retained, tex)
            }
        }
        return nil
    }

    static func nv12ColorMode(_ buffer: CVPixelBuffer) -> UInt32? {
        // Unknown/wide-gamut metadata is handled by Core Image's color management.
        func matches(_ key: CFString, _ value: CFString) -> Bool {
            guard let attachment = CVBufferCopyAttachment(buffer, key, nil) else { return false }
            return CFEqual(attachment, value)
        }
        guard matches(kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2) else { return nil }
        guard matches(kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center),
              CVBufferCopyAttachment(buffer, kCVImageBufferChromaLocationBottomFieldKey, nil) == nil else { return nil }
        let bt601 = matches(kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        guard bt601 || matches(kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2) else { return nil }
        let bt709Transfer = matches(kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2)
        guard bt709Transfer || matches(kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB) else { return nil }
        let fullRange = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        return (fullRange ? 1 : 0) | (bt601 ? 2 : 0) | (bt709Transfer ? 4 : 0)
    }

    func didPresent(_ frame: DecodedFrame, at time: Double, session: UUID) {
        guard currentSessionID == session else { return }
        guard time.isFinite, time > 0 else { onInvalidPresentation?(time); return }
        if firstFrame {
            firstFrame = false
            onFirstFrame?()
        }
        onPresented?(frame, time)
    }

    private struct RenderSnapshot {
        let geometry: SurfaceGeometrySnapshot
        let videoVisible: Bool
        let windowVisible: Bool
        let windowMiniaturized: Bool
        let firstFrame: Bool
        let renderPathCallback: ((String) -> Void)?
        let diagnosticCallback: ((String) -> Void)?
        let timingCallback: ((String, Double) -> Void)?
    }

    private struct SurfaceGeometrySnapshot {
        let drawableSize: CGSize
        let fillBoundsEdgeToEdge: Bool
        let pixelSize: CGSize
    }

    private struct BackgroundRenderPayload {
        let frame: DecodedFrame
        let snapshot: RenderSnapshot?
    }

    private struct RenderDiagnostic {
        var path: String
        var fallbackReason: String?
        let renderPathCallback: ((String) -> Void)?
        let diagnosticCallback: ((String) -> Void)?
        let timingCallback: ((String, Double) -> Void)?
    }

    private func mainThreadSnapshot() -> RenderSnapshot? {
        guard Thread.isMainThread,
              videoVisible, window?.isVisible == true, window?.isMiniaturized == false else { return nil }
        return RenderSnapshot(
            geometry: geometrySnapshot(drawableSize: metal.drawableSize),
            videoVisible: videoVisible,
            windowVisible: window?.isVisible == true,
            windowMiniaturized: window?.isMiniaturized == true,
            firstFrame: firstFrame,
            renderPathCallback: onRenderPath,
            diagnosticCallback: onRenderDiagnostic,
            timingCallback: onRenderTiming
        )
    }

    private func geometrySnapshot(drawableSize: CGSize) -> SurfaceGeometrySnapshot {
        SurfaceGeometrySnapshot(
            drawableSize: drawableSize,
            fillBoundsEdgeToEdge: fillBoundsEdgeToEdge,
            pixelSize: pixelSize
        )
    }

    private var acceptsPresentableFrame: Bool {
        videoVisible && window?.isVisible == true && window?.isMiniaturized == false
    }

    private func isPresentable(snapshot: RenderSnapshot) -> Bool {
        snapshot.videoVisible && snapshot.windowVisible && !snapshot.windowMiniaturized
    }

    private func installAsLatestFrame(_ frame: DecodedFrame) {
        lastFrame = frame
        let newSize = CGSize(width: CVPixelBufferGetWidth(frame.buffer), height: CVPixelBufferGetHeight(frame.buffer))
        if newSize != pixelSize {
            pixelSize = newSize
            onPixelSizeChanged?(newSize)
        }
    }

    private func publishTiming(_ name: String, seconds: Double, callback: ((String, Double) -> Void)?, session: UUID) {
        guard let callback, seconds.isFinite, seconds >= 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard self?.currentSessionID == session else { return }
            callback(name, seconds)
        }
    }

    private func recordRenderDiagnostic(
        _ diagnostic: RenderDiagnostic,
        main: Bool,
        nextDrawableSeconds: Double,
        session: UUID
    ) {
        let deliver = { (body: @escaping () -> Void) in
            if main {
                body()
            } else {
                DispatchQueue.main.async(execute: body)
            }
        }
        deliver { [weak self] in
            guard self?.currentSessionID == session else { return }
            diagnostic.renderPathCallback?(diagnostic.path)
            diagnostic.timingCallback?("nextDrawableSeconds", nextDrawableSeconds)
            if let reason = diagnostic.fallbackReason {
                diagnostic.diagnosticCallback?("fallback=\(diagnostic.path) reason=\(reason)")
            }
        }
    }

    private func submitCachedRedraw(_ frame: DecodedFrame, session: UUID) {
        if let backgroundRenderQueue {
            guard acceptsPresentableFrame,
                  let snapshot = mainThreadSnapshot() else { return }
            backgroundRenderQueue.submitCached(
                BackgroundRenderPayload(frame: frame, snapshot: snapshot),
                session: session,
                frameSequence: lastFrameSequence
            )
        } else {
            render(frame, countPresentation: false, session: session)
        }
    }

    private func fallbackReason(for buffer: CVPixelBuffer) -> String {
        let reason: String
        let pixelFormat = CVPixelBufferGetPixelFormatType(buffer)
        if textureCache == nil {
            reason = "texture-cache-unavailable"
        } else if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            if nv12PipelineState == nil {
                reason = "nv12-pipeline-unavailable"
            } else if Self.nv12ColorMode(buffer) == nil {
                reason = "nv12-metadata-unsupported"
            } else {
                reason = "nv12-texture-creation-failed"
            }
        } else if pixelFormat == kCVPixelFormatType_32BGRA {
            reason = bgraPipelineState == nil ? "bgra-pipeline-unavailable" : "bgra-texture-creation-failed"
        } else {
            reason = "unsupported-pixel-format-\(pixelFormat)"
        }
        return reason
    }

    private func renderDiagnostic(for zeroCopySource: ZeroCopySource?, buffer: CVPixelBuffer) -> RenderDiagnostic {
        let reason = zeroCopySource == nil ? fallbackReason(for: buffer) : nil
        return RenderDiagnostic(
            path: zeroCopySource?.path ?? "core-image-color-managed",
            fallbackReason: reason,
            renderPathCallback: onRenderPath,
            diagnosticCallback: onRenderDiagnostic,
            timingCallback: onRenderTiming
        )
    }

    private func render(_ frame: DecodedFrame, countPresentation: Bool, session: UUID) {
        guard videoVisible, window?.isVisible == true, window?.isMiniaturized == false,
              let command = commandQueue.makeCommandBuffer() else { return }
        let target = CGRect(origin: .zero, size: metal.drawableSize)
        let rect = fillBoundsEdgeToEdge ? target : SurfaceGeometry(bounds: target, pixels: pixelSize).contentRect
        let zeroCopySource = prepareZeroCopySource(for: frame.buffer)
        var diagnostic = renderDiagnostic(for: zeroCopySource, buffer: frame.buffer)
        let targetFramebufferOnly = (zeroCopySource != nil)
        if metal.framebufferOnly != targetFramebufferOnly {
            metal.framebufferOnly = targetFramebufferOnly
        }
        let drawableWaitStarted = CACurrentMediaTime()
        guard var drawable = metal.nextDrawable() else { return }
        let drawableWait = CACurrentMediaTime() - drawableWaitStarted
        var encodedZeroCopy = false
        if let zeroCopySource {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = fillBoundsEdgeToEdge ? .dontCare : .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            if let encoder = command.makeRenderCommandEncoder(descriptor: pass) {
                encoder.setViewport(MTLViewport(
                    originX: Double(rect.minX),
                    originY: Double(rect.minY),
                    width: Double(rect.width),
                    height: Double(rect.height),
                    znear: 0.0,
                    zfar: 1.0
                ))
                switch zeroCopySource {
                case let .bgra(pipeline, retained, tex):
                    encoder.setRenderPipelineState(pipeline)
                    encoder.setFragmentTexture(tex, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    encoder.endEncoding()
                    command.addCompletedHandler { _ in _ = retained }
                case let .nv12(pipeline, retainedY, yTex, retainedUV, uvTex, colorMode):
                    var mode = colorMode
                    encoder.setRenderPipelineState(pipeline)
                    encoder.setFragmentTexture(yTex, index: 0)
                    encoder.setFragmentTexture(uvTex, index: 1)
                    encoder.setFragmentBytes(&mode, length: MemoryLayout<UInt32>.size, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    encoder.endEncoding()
                    command.addCompletedHandler { _ in
                        _ = retainedY
                        _ = retainedUV
                    }
                }
                encodedZeroCopy = true
            }
        }
        if !encodedZeroCopy {
            if zeroCopySource != nil {
                diagnostic.path = "core-image-color-managed"
                diagnostic.fallbackReason = "render-encoder-unavailable"
            }
            if metal.framebufferOnly {
                metal.framebufferOnly = false
                guard let writableDrawable = metal.nextDrawable() else { return }
                drawable = writableDrawable
            }
            let baseImage = CIImage(cvPixelBuffer: frame.buffer)
            let image: CIImage
            if rect == target && rect.size == pixelSize {
                image = baseImage
            } else {
                image = baseImage
                    .transformed(by: CGAffineTransform(scaleX: rect.width / pixelSize.width, y: rect.height / pixelSize.height))
                    .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
                    .composited(over: CIImage(color: .black).cropped(to: target))
            }
            context.render(image, to: drawable.texture, commandBuffer: command, bounds: target, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        command.addCompletedHandler { _ in _ = frame.buffer }
        if let timingCallback = onRenderTiming {
            command.addCompletedHandler { [weak self] completed in
                let gpuStart = completed.gpuStartTime
                let gpuEnd = completed.gpuEndTime
                guard gpuStart > 0, gpuEnd >= gpuStart else { return }
                self?.publishTiming("gpuExecutionSeconds", seconds: gpuEnd - gpuStart, callback: timingCallback, session: session)
            }
        }
        if countPresentation || firstFrame {
            var measuredFrame = frame
            measuredFrame.submittedAt = CACurrentMediaTime()
            drawable.addPresentedHandler { [weak self] shown in
                let time = shown.presentedTime
                DispatchQueue.main.async { [weak self] in
                    if countPresentation || self?.firstFrame == true {
                        self?.didPresent(measuredFrame, at: time, session: session)
                    }
                }
            }
        }
        present(drawable, using: command)
        command.commit()
        recordRenderDiagnostic(diagnostic, main: true, nextDrawableSeconds: drawableWait, session: session)
    }

    private func renderOffMain(_ job: FrameRenderQueue<BackgroundRenderPayload>.Job) throws {
        let frame = job.payload.frame
        if job.demand == .decoded {
            guard backgroundRenderQueue?.isCurrent(session: job.session) == true,
                  let currentSnapshot = job.payload.snapshot,
                  backgroundRenderQueue?.shouldAbandon(job) == false else { return }
            try autoreleasepool {
                try render(
                    frame,
                    snapshot: currentSnapshot,
                    countPresentation: true,
                    session: job.session,
                    job: job
                )
            }
        } else {
            guard backgroundRenderQueue?.isCurrent(session: job.session) == true,
                  let snapshot = job.payload.snapshot,
                  isPresentable(snapshot: snapshot) else { return }
            try autoreleasepool {
                try render(
                    frame,
                    snapshot: snapshot,
                    countPresentation: false,
                    session: job.session,
                    job: job
                )
            }
        }
    }

    private func render(
        _ frame: DecodedFrame,
        snapshot: RenderSnapshot,
        countPresentation: Bool,
        session: UUID,
        job: FrameRenderQueue<BackgroundRenderPayload>.Job
    ) throws {
        guard isPresentable(snapshot: snapshot) else { return }
        guard let command = commandQueue.makeCommandBuffer() else { return }
        let drawableWaitStarted = CACurrentMediaTime()
        guard let drawable = metal.nextDrawable() else { return }
        let drawableWait = CACurrentMediaTime() - drawableWaitStarted
        if backgroundRenderQueue?.shouldAbandon(job) == true
            || drawable.texture.width != Int(snapshot.geometry.drawableSize.width)
            || drawable.texture.height != Int(snapshot.geometry.drawableSize.height) {
            return
        }
        let zeroCopySource = prepareZeroCopySource(for: frame.buffer)
        let path = zeroCopySource?.path ?? "core-image-color-managed"
        var diagnostic = RenderDiagnostic(
            path: path,
            fallbackReason: zeroCopySource == nil ? fallbackReason(for: frame.buffer) : nil,
            renderPathCallback: snapshot.renderPathCallback,
            diagnosticCallback: snapshot.diagnosticCallback,
            timingCallback: snapshot.timingCallback
        )
        let target = CGRect(origin: .zero, size: snapshot.geometry.drawableSize)
        let rect = snapshot.geometry.fillBoundsEdgeToEdge
            ? target
            : SurfaceGeometry(bounds: target, pixels: snapshot.geometry.pixelSize).contentRect
        var encodedZeroCopy = false
        if let zeroCopySource {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = snapshot.geometry.fillBoundsEdgeToEdge ? .dontCare : .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            if let encoder = command.makeRenderCommandEncoder(descriptor: pass) {
                encoder.setViewport(MTLViewport(
                    originX: Double(rect.minX),
                    originY: Double(rect.minY),
                    width: Double(rect.width),
                    height: Double(rect.height),
                    znear: 0.0,
                    zfar: 1.0
                ))
                switch zeroCopySource {
                case let .bgra(pipeline, retained, tex):
                    encoder.setRenderPipelineState(pipeline)
                    encoder.setFragmentTexture(tex, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    encoder.endEncoding()
                    command.addCompletedHandler { _ in _ = retained }
                case let .nv12(pipeline, retainedY, yTex, retainedUV, uvTex, colorMode):
                    var mode = colorMode
                    encoder.setRenderPipelineState(pipeline)
                    encoder.setFragmentTexture(yTex, index: 0)
                    encoder.setFragmentTexture(uvTex, index: 1)
                    encoder.setFragmentBytes(&mode, length: MemoryLayout<UInt32>.size, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    encoder.endEncoding()
                    command.addCompletedHandler { _ in
                        _ = retainedY
                        _ = retainedUV
                    }
                }
                encodedZeroCopy = true
            }
        }
        if !encodedZeroCopy {
            if zeroCopySource != nil {
                diagnostic.path = "core-image-color-managed"
                diagnostic.fallbackReason = "render-encoder-unavailable"
            }
            let baseImage = CIImage(cvPixelBuffer: frame.buffer)
            let image: CIImage
            if rect == target && rect.size == snapshot.geometry.pixelSize {
                image = baseImage
            } else {
                image = baseImage
                    .transformed(by: CGAffineTransform(
                        scaleX: rect.width / snapshot.geometry.pixelSize.width,
                        y: rect.height / snapshot.geometry.pixelSize.height
                    ))
                    .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
                    .composited(over: CIImage(color: .black).cropped(to: target))
            }
            context.render(
                image,
                to: drawable.texture,
                commandBuffer: command,
                bounds: target,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
            )
        }

        command.addCompletedHandler { _ in _ = frame.buffer }
        if let timingCallback = snapshot.timingCallback {
            command.addCompletedHandler { [weak self] completed in
                let gpuStart = completed.gpuStartTime
                let gpuEnd = completed.gpuEndTime
                guard gpuStart > 0, gpuEnd >= gpuStart else { return }
                self?.publishTiming("gpuExecutionSeconds", seconds: gpuEnd - gpuStart, callback: timingCallback, session: session)
            }
        }
        if countPresentation || snapshot.firstFrame {
            var measuredFrame = frame
            measuredFrame.submittedAt = CACurrentMediaTime()
            drawable.addPresentedHandler { [weak self] shown in
                let time = shown.presentedTime
                DispatchQueue.main.async { [weak self] in
                    if countPresentation || self?.firstFrame == true {
                        self?.didPresent(measuredFrame, at: time, session: session)
                    }
                }
            }
        }
        guard backgroundRenderQueue?.commitIfCurrent(session: session, {
            present(drawable, using: command)
            command.commit()
        }) == true else { return }
        recordRenderDiagnostic(diagnostic, main: false, nextDrawableSeconds: drawableWait, session: session)
    }

    private func present(_ drawable: CAMetalDrawable, using command: MTLCommandBuffer) {
        // Bound arrival bursts without adding another full 60 Hz frame of buffering.
        if minimumPresentationInterval > 0 {
            command.present(drawable, afterMinimumDuration: minimumPresentationInterval)
        } else {
            command.present(drawable)
        }
    }

    private func resolveGuestPoint(_ point: CGPoint, clamp: Bool = false) -> CGPoint? {
        return SurfaceGeometry(bounds: bounds, pixels: pixelSize).guestPoint(point, clamp: clamp)
    }

    private func touch(_ point: CGPoint, action: UInt8, clamp: Bool = false) {
        guard videoVisible, let guest = resolveGuestPoint(point, clamp: clamp) else { return }
        if action == 0 { onInput?(CACurrentMediaTime()) }
        sendInput?(Wire.touch(action: action, x: UInt32(guest.x), y: UInt32(guest.y), width: UInt16(pixelSize.width), height: UInt16(pixelSize.height)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        isTouching = videoVisible && inputEnabled && resolveGuestPoint(point) != nil
        if isTouching { beginPointerInteraction(); touch(point, action: 0) }
    }
    override func mouseDragged(with event: NSEvent) { if isTouching { touch(convert(event.locationInWindow, from: nil), action: 2, clamp: true) } }
    override func mouseUp(with event: NSEvent) {
        if isTouching {
            touch(convert(event.locationInWindow, from: nil), action: 1, clamp: true)
            sendInput?(Wire.touchFinished(pointerSequence)); isTouching = false
        }
    }
    override func rightMouseDown(with event: NSEvent) { key(4) }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard videoVisible, let guest = resolveGuestPoint(point) else { return }
        let divisor = event.hasPreciseScrollingDeltas ? 32.0 : 1.0
        sendInput?(Wire.scroll(x: UInt32(guest.x), y: UInt32(guest.y), width: UInt16(pixelSize.width), height: UInt16(pixelSize.height), dx: Double(event.scrollingDeltaX) / divisor, dy: Double(event.scrollingDeltaY) / divisor))
    }

    /// Performance mode calls the same coordinate mapper and touch serializer as mouseDown.
    func probeTap() {
        let rect = SurfaceGeometry(bounds: bounds, pixels: pixelSize).contentRect
        let point = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.08)
        beginPointerInteraction()
        touch(point, action: 0)
        touch(point, action: 1)
        sendInput?(Wire.touchFinished(pointerSequence))
    }

    func key(_ code: UInt32, meta: UInt32 = 0) {
        guard videoVisible, inputEnabled else { return }
        sendInput?(Wire.key(code, down: true, meta: meta))
        sendInput?(Wire.key(code, down: false, meta: meta))
    }

    override func keyDown(with event: NSEvent) {
        guard videoVisible, inputEnabled else { return }
        applyRequestedInputSource()
        invalidatedComposition = false
        if event.modifierFlags.contains(.command), let char = event.charactersIgnoringModifiers?.lowercased() {
            if char == "v" {
                if let text = NSPasteboard.general.string(forType: .string) { commit(text, useClipboard: true) }
                return
            }
            if char == "c" { copy(nil); return }
            if char == "x" { cut(nil); return }
            if char == "a" { selectAll(nil); return }
        }
        interpretKeyEvents([event])
    }

    private func commit(_ text: String, useClipboard: Bool = false, lease: InputLease? = nil, fromComposition: Bool = false) {
        guard !text.isEmpty, videoVisible, inputEnabled else { return }
        if useClipboard {
            guard text.utf8.count <= 256 * 1024 - 14 else { onInputIssue?(DirectInputFailure.tooLong.localizedDescription); return }
            clipboardSequence &+= 1
            sendInput?(Wire.paste(text, sequence: clipboardSequence))
        } else if !fromComposition && text.unicodeScalars.allSatisfy({ $0.value < 128 }) {
            guard text.utf8.count <= 250 else { onInputIssue?(DirectInputFailure.tooLong.localizedDescription); return }
            sendInput?(Wire.text(text))
        } else if let sendDirectText, let lease = lease ?? (!awaitingPointerFocus ? trustedInputLease : nil) {
            sendDirectText(text, lease)
        } else {
            onInputIssue?(DirectInputFailure.noFocus.localizedDescription)
        }
    }

    func selectHostInputSource(_ identifier: String) {
        guard canSelectHostInputSource,
              let source = HostKeyboardSource.enabled().first(where: { $0.identifier == identifier }) else { return }
        guard inputFocus?.sensitive != true || source.asciiCapable else {
            onInputIssue?("当前密码输入框使用英文安全输入。请使用应用既有输入方式。")
            return
        }
        discardComposition(); requestedHostInputSource = identifier
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        NSApplication.shared.activate(ignoringOtherApps: true)
        applyRequestedInputSource()
    }

    private func applyRequestedInputSource() {
        guard let identifier = requestedHostInputSource, NSApplication.shared.isActive,
              window?.isKeyWindow == true, window?.firstResponder === self else { return }
        requestedHostInputSource = nil
        guard let source = HostKeyboardSource.enabled().first(where: { $0.identifier == identifier }),
              inputFocus?.sensitive != true || source.asciiCapable, let context = inputContext else { return }
        context.activate(); context.selectedKeyboardInputSource = identifier
    }

    @objc func paste(_ sender: Any?) {
        guard videoVisible, inputEnabled, clipboardSyncEnabled else { return }
        if let text = NSPasteboard.general.string(forType: .string) { commit(text, useClipboard: true) }
    }
    @objc func copy(_ sender: Any?) { guard videoVisible, inputEnabled, clipboardSyncEnabled else { return }; sendInput?(Data([8, 1])) }
    @objc func cut(_ sender: Any?) { guard videoVisible, inputEnabled, clipboardSyncEnabled else { return }; sendInput?(Data([8, 2])) }
    @objc override func selectAll(_ sender: Any?) { key(29, meta: 4096) }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard !discardingComposition, !invalidatedComposition else { unmarkText(); return }
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let lease = compositionLease; let fromComposition = hasMarkedText()
        unmarkText(); commit(text, lease: lease, fromComposition: fromComposition)
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard !discardingComposition else { return }
        if marked.length == 0 {
            invalidatedComposition = false
            compositionLease = !awaitingPointerFocus ? trustedInputLease : nil
            compositionPointer = pointerSequence
        }
        marked = (string as? NSAttributedString) ?? NSAttributedString(string: (string as? String) ?? "")
        let location = selectedRange.location == NSNotFound || selectedRange.location < 0 ? marked.length : min(selectedRange.location, marked.length)
        markedSelection = NSRange(location: location, length: min(max(0, selectedRange.length), marked.length - location))
        composition.stringValue = inputFocus?.sensitive == true ? "" : marked.string
        composition.isHidden = marked.length == 0 || inputFocus?.sensitive == true
    }
    func unmarkText() { marked = NSAttributedString(string: ""); markedSelection = NSRange(location: 0, length: 0); compositionLease = nil; compositionPointer = nil; composition.stringValue = ""; composition.isHidden = true }
    func selectedRange() -> NSRange { markedSelection }
    func markedRange() -> NSRange { NSRange(location: marked.length == 0 ? NSNotFound : 0, length: marked.length) }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        // This virtual document contains only the current host composition.
        // It never retrieves preceding text or a selection from Android.
        guard range.location >= 0, range.length >= 0, range.location != NSNotFound, range.location <= marked.length else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0); return nil
        }
        let bounded = NSRange(location: range.location, length: min(range.length, marked.length - range.location))
        let adjusted = (marked.string as NSString).rangeOfComposedCharacterSequences(for: bounded)
        actualRange?.pointee = adjusted
        return marked.attributedSubstring(from: adjusted)
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = NSRange(location: 0, length: marked.length)
        guard let window else { return .zero }
        return window.convertToScreen(convert(composition.frame, to: nil))
    }
    override func doCommand(by selector: Selector) {
        let codes: [String: UInt32] = ["deleteBackward:": 67, "deleteForward:": 112, "insertNewline:": 66, "insertTab:": 61, "cancelOperation:": 4, "moveLeft:": 21, "moveRight:": 22, "moveUp:": 19, "moveDown:": 20, "moveToBeginningOfLine:": 122, "moveToEndOfLine:": 123]
        if let code = codes[NSStringFromSelector(selector)] { key(code) }
    }
}
