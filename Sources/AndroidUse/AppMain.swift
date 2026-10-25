import AppKit
import Metal

@main
@MainActor
enum AndroidUseMain {
    static func main() {
        let app = NSApplication.shared
        let delegate: NSObject & NSApplicationDelegate = ProcessInfo.processInfo.arguments.contains("--probe") ? ProbeAppDelegate() : ProductAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class ProbeAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var stream: VideoStream?
    private var measurement: ProbeMeasurement?
    private var surface: AndroidSurfaceView?
    private var keyboardMenu: HostKeyboardMenu?
    private var measurementTimer: Timer?
    private let args = ProcessInfo.processInfo.arguments

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.applicationIconImage = MacdoraBrand.appIconImage(size: 512)
        guard let device = MTLCreateSystemDefaultDevice() else { NSApplication.shared.terminate(nil); return }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 432, height: 768), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(MacdoraBrand.appName) · 显示输入技术实验"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 280, height: 400)
        window.center()
        let surface = AndroidSurfaceView(frame: NSRect(x: 0, y: 0, width: 432, height: 768), device: device)
        self.surface = surface
        window.contentView = surface
        let bar = NSMenu()
        let appItem = NSMenuItem(); bar.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "退出 \(MacdoraBrand.appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); bar.addItem(editItem)
        let edit = NSMenu(title: "编辑"); editItem.submenu = edit
        for (title, action, key) in [("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let keyboard = HostKeyboardMenu(available: { [weak self] in self?.surface?.canSelectHostInputSource == true }) { [weak self] in self?.surface?.selectHostInputSource($0) }
        keyboardMenu = keyboard
        let inputSources = edit.addItem(withTitle: "输入法", action: nil, keyEquivalent: ""); inputSources.submenu = keyboard.menu
        NSApplication.shared.mainMenu = bar
        let stream = VideoStream(probeMarkers: args.contains("--benchmark"))
        self.stream = stream
        surface.onPointerBegan = { [weak stream] in stream?.beginPointer($0) }
        stream.onConfirmedFocus = { [weak surface] focus, pointer in
            DispatchQueue.main.async { [weak surface] in surface?.confirmInputFocus(focus, pointerSequence: pointer) }
        }
        if let index = args.firstIndex(of: "--ime-port"), index + 1 < args.count, let port = UInt16(args[index + 1]) {
            stream.enableDirectInput(port: port) { [weak surface] focus in
                DispatchQueue.main.async { [weak surface] in surface?.setInputFocus(focus) }
            }
            surface.sendDirectText = { [weak stream, weak self] text, lease in
                stream?.sendText(text, lease: lease) { [weak self] issue in
                    DispatchQueue.main.async { [weak self] in
                        self?.window.title = issue ?? "\(MacdoraBrand.appName) · 显示输入技术实验"
                    }
                }
            }
        }
        surface.onInputIssue = { [weak self] message in self?.window.title = message }
        stream.onClipboard = { text in DispatchQueue.main.async { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) } }
        surface.sendInput = { [weak stream] in stream?.send($0) }
        stream.decoder.onFrame = { [weak surface] in surface?.accept($0) }
        stream.onError = { [weak self] error in DispatchQueue.main.async { [weak self] in
            self?.window.title = "显示实验结束：\(error.localizedDescription)"
            self?.measurement?.fail(at: CACurrentMediaTime(), reason: "stream_error: \(error.localizedDescription)")
        } }
        stream.onSize = { [weak surface] w, h in DispatchQueue.main.async { [weak surface] in surface?.pixelSize = CGSize(width: w, height: h) } }
        if args.contains("--benchmark") {
            let measurement = ProbeMeasurement(); self.measurement = measurement
            measurement.metadata = ["decoderPixelFormat": H264Decoder.outputPixelFormat,
                                    "windowLevel": "normal", "targetFPS": 60,
                                    "maximumDrawables": ProcessInfo.processInfo.environment["ANDROID_USE_MAX_DRAWABLES"] == "3" ? 3 : 2]
            measurement.metadata["presentationQueue"] = "coalesced-latest-frame"
            measurement.metadata["renderQueue"] = ProcessInfo.processInfo.environment["ANDROID_USE_RENDER_QUEUE"] == "main" ? "main" : "background"
            surface.onRenderPath = { [weak measurement] path in
                measurement?.metadata["renderPath"] = path
                measurement?.rendered(using: path)
            }
            surface.onRenderTiming = { [weak measurement] name, seconds in measurement?.renderTiming(name, seconds: seconds) }
            surface.onRenderDiagnostic = { [weak measurement] diagnostic in
                if measurement?.metadata["renderDiagnostic"] == nil { measurement?.metadata["renderDiagnostic"] = diagnostic }
            }
            measurement.onScheduleTap = { [weak measurement] deadline in
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - CACurrentMediaTime())) {
                    measurement?.fireInput(at: CACurrentMediaTime())
                }
            }
            stream.decoder.onHardware = { [weak measurement] hardware in DispatchQueue.main.async { measurement?.hardwareDecoder = hardware } }
            surface.onInput = { [weak measurement] in measurement?.sent(at: $0) }
            surface.onPresented = { [weak measurement] in measurement?.presented($0, at: $1) }
            surface.onInvalidPresentation = { [weak measurement] time in measurement?.invalidPresentation(at: time) }
            measurement.onTap = { [weak surface] in surface?.probeTap() }
            measurement.onComplete = { [weak self] report in
                guard let index = self?.args.firstIndex(of: "--report"), let self, index + 1 < self.args.count else { return }
                do {
                    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: URL(fileURLWithPath: self.args[index + 1]), options: .atomic)
                    self.window.title = "\(MacdoraBrand.appName) · 性能采样完成"
                    self.measurementTimer?.invalidate()
                    if self.args.contains("--exit-after-report") { NSApplication.shared.terminate(nil) }
                } catch { self.window.title = "性能报告写入失败" }
            }
        }
        let portIndex = args.firstIndex(of: "--port")
        let port = portIndex.flatMap { $0 + 1 < args.count ? UInt16(args[$0 + 1]) : nil } ?? 27184
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(surface)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let packageIndex = args.firstIndex(of: "--app")
        let package = packageIndex.flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        measurement?.start(at: CACurrentMediaTime())
        captureWindowState()
        if let measurement {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self, weak measurement] _ in
                self?.captureWindowState()
                measurement?.tick(at: CACurrentMediaTime())
            }
            measurementTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        stream.connect(port: port, startApp: package)
    }

    private func captureWindowState() {
        guard let window else { return }
        measurement?.observedWindow(.init(visible: window.isVisible, minimized: window.isMiniaturized,
                                          occluded: !window.occlusionState.contains(.visible),
                                          applicationActive: NSApp.isActive), at: CACurrentMediaTime())
    }

    func windowDidChangeOcclusionState(_ notification: Notification) { captureWindowState() }
    func windowDidMiniaturize(_ notification: Notification) { captureWindowState() }
    func windowDidDeminiaturize(_ notification: Notification) { captureWindowState() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { measurementTimer?.invalidate(); stream?.stop() }
}
