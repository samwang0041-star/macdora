import Foundation
import Darwin
import VideoToolbox
import CoreVideo
import QuartzCore

enum StreamFailure: LocalizedError {
    case socket(String), closed, invalid(String), decoder(OSStatus)
    var errorDescription: String? {
        switch self {
        case .socket(let s): return "本地显示连接失败：\(s)"
        case .closed: return "Android 显示连接已结束。"
        case .invalid(let s): return "Android 显示数据不符合固定协议：\(s)"
        case .decoder(let s): return "视频解码失败（\(s)）。"
        }
    }
}

final class LocalSocket {
    private let sendLock = NSLock()
    private let stateLock = NSLock()
    private let descriptor: Int32
    private var closed = false

    init(port: UInt16) throws {
        descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw StreamFailure.socket("socket") }
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var noDelay: Int32 = 1
        setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            let errorCode = errno
            // A throwing initializer runs deinit after all stored properties were set.
            // That single owner performs the final close; never close the fd here.
            throw StreamFailure.socket(String(cString: strerror(errorCode)))
        }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    func receive(_ size: Int) throws -> Data {
        guard size >= 0, size <= 32 * 1024 * 1024 else { throw StreamFailure.invalid("packet length") }
        var bytes = [UInt8](repeating: 0, count: size)
        var done = 0
        while done < size {
            let count = bytes.withUnsafeMutableBytes { Darwin.recv(descriptor, $0.baseAddress!.advanced(by: done), size - done, 0) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw StreamFailure.closed }
            done += count
        }
        return Data(bytes)
    }

    func send(_ data: Data) throws {
        sendLock.lock(); defer { sendLock.unlock() }
        var done = 0
        while done < data.count {
            let count = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress!.advanced(by: done), data.count - done, 0) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw StreamFailure.closed }
            done += count
        }
    }

    func close() {
        stateLock.lock(); defer { stateLock.unlock() }
        if !closed { closed = true; Darwin.shutdown(descriptor, SHUT_RDWR) }
    }
    // Keep the descriptor allocated until all in-flight reads/writes release this object.
    // shutdown wakes readers; close in deinit prevents descriptor reuse races.
    deinit { close(); Darwin.close(descriptor) }
}

struct DecodedFrame {
    let buffer: CVPixelBuffer
    let pts: Int64
    let marker: ProbeMarker?
    var timing: FrameTiming? = nil
    var submittedAt: Double? = nil
}

struct FrameTiming {
    let received: Double
    let decoded: Double
}

struct ProbeMarker {
    let frame: UInt32
    let input: UInt16
    static func read(_ buffer: CVPixelBuffer) -> ProbeMarker? {
        let pixelFormat = CVPixelBufferGetPixelFormatType(buffer)
        guard CVPixelBufferGetWidth(buffer) >= 800, CVPixelBufferGetHeight(buffer) > 80 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            func lumaBits(y: Int, count: Int) -> UInt32 {
                var value: UInt32 = 0
                for i in 0..<count {
                    let luma = Int(base[y * stride + (16 + 24 * i + 12)])
                    if luma > 128 { value |= 1 << i }
                }
                return value
            }
            return ProbeMarker(frame: lumaBits(y: 28, count: 32), input: UInt16(lumaBits(y: 60, count: 16)))
        }
        guard pixelFormat == kCVPixelFormatType_32BGRA else { return nil }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        func bits(y: Int, count: Int) -> UInt32 {
            var value: UInt32 = 0
            for i in 0..<count {
                let pixel = base.advanced(by: y * stride + (16 + 24 * i + 12) * 4)
                if Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2]) > 384 { value |= 1 << i }
            }
            return value
        }
        return ProbeMarker(frame: bits(y: 28, count: 32), input: UInt16(bits(y: 60, count: 16)))
    }
}

final class H264Decoder {
    var onFrame: ((DecodedFrame) -> Void)?
    var onFirstDecodedFrame: (() -> Void)?
    var onHardware: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?
    let probeMarkers: Bool
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private let timingLock = NSLock()
    private var receiveTimes: [Int64: Double] = [:]
    private var decodedFirstFrame = false
    static var outputPixelFormat: OSType {
        ProcessInfo.processInfo.environment["ANDROID_USE_DECODE_FORMAT"] == "bgra"
            ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    init(probeMarkers: Bool) { self.probeMarkers = probeMarkers }
    func finish() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
    }
    deinit { finish() }

    func receiveOutput(status: OSStatus, image: CVImageBuffer?, pts: CMTime) {
        let decodedAt = CACurrentMediaTime()
        timingLock.lock()
        let received = receiveTimes.removeValue(forKey: pts.value)
        timingLock.unlock()
        guard status == noErr else { onError?(StreamFailure.decoder(status)); return }
        guard let image else { return } // A decoder may legitimately drop a frame.
        timingLock.lock()
        let isFirst = !decodedFirstFrame
        decodedFirstFrame = true
        timingLock.unlock()
        if isFirst { onFirstDecodedFrame?() }
        let marker = probeMarkers ? ProbeMarker.read(image) : nil
        let timing = received.map { FrameTiming(received: $0, decoded: decodedAt) }
        onFrame?(DecodedFrame(buffer: image, pts: pts.value, marker: marker, timing: timing))
    }

    func configure(_ bytes: Data) throws {
        let nals = AnnexB.units(bytes)
        guard let sps = nals.first(where: { ($0.first ?? 0) & 31 == 7 }),
              let pps = nals.first(where: { ($0.first ?? 0) & 31 == 8 }) else { throw StreamFailure.invalid("H.264 SPS/PPS") }
        let result = sps.withUnsafeBytes { sp in
            pps.withUnsafeBytes { pp in
                var pointers = [sp.baseAddress!.assumingMemoryBound(to: UInt8.self), pp.baseAddress!.assumingMemoryBound(to: UInt8.self)]
                var sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: &pointers, parameterSetSizes: &sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        guard result == noErr, let format else { throw StreamFailure.decoder(result) }
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session); VTDecompressionSessionInvalidate(session) }
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { ref, _, status, _, image, pts, _ in
            guard let ref else { return }
            let decoder = Unmanaged<H264Decoder>.fromOpaque(ref).takeUnretainedValue()
            decoder.receiveOutput(status: status, image: image, pts: pts)
        }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        let spec: [CFString: Any] = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true]
        let targetFormat = Self.outputPixelFormat
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: targetFormat,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let code = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: spec as CFDictionary, imageBufferAttributes: attrs as CFDictionary, outputCallback: &callback, decompressionSessionOut: &session)
        guard code == noErr, let session else { throw StreamFailure.decoder(code) }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        var hardware: CFTypeRef?
        withUnsafeMutablePointer(to: &hardware) { pointer in
            _ = VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: kCFAllocatorDefault, valueOut: pointer)
        }
        onHardware?((hardware as? Bool) == true)
    }

    func decode(_ packet: Data, pts: Int64) throws {
        if probeMarkers {
            timingLock.lock()
            if receiveTimes.count >= 256 { receiveTimes.removeAll(keepingCapacity: true) }
            receiveTimes[pts] = CACurrentMediaTime()
            timingLock.unlock()
        }
        guard let session, let format else { throw StreamFailure.invalid("frame before configuration") }
        let units = AnnexB.units(packet)
        var avcc = Data()
        for unit in units { avcc.append(Wire.integer(UInt32(unit.count))); avcc.append(unit) }
        guard !avcc.isEmpty else { return }
        var block: CMBlockBuffer?
        var code = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block)
        guard code == noErr, let block else { throw StreamFailure.decoder(code) }
        code = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }
        guard code == noErr else { throw StreamFailure.decoder(code) }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: pts, timescale: 1_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        var size = avcc.count
        code = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard code == noErr, let sample else { throw StreamFailure.decoder(code) }
        code = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback], frameRefcon: nil, infoFlagsOut: nil)
        guard code == noErr else { throw StreamFailure.decoder(code) }
    }
}

final class VideoStream {
    private var video: LocalSocket?
    private var control: LocalSocket?
    private let queue = DispatchQueue(label: "local.androiduse.video", qos: .userInteractive)
    private let controlQueue = DispatchQueue(label: "local.androiduse.input", qos: .userInteractive)
    private let imeQueue = DispatchQueue(label: "local.androiduse.ime", qos: .userInteractive)
    private let deviceQueue = DispatchQueue(label: "local.androiduse.device-messages", qos: .userInitiated)
    private let stateLock = NSLock()
    let decoder: H264Decoder
    private var directInput: DirectInputClient?
    private var pointerSequence: UInt64 = 0
    private var completedPointer: UInt64?
    private var completedDisplay: Int32 = -1
    var onConfirmedFocus: ((InputFocus?, UInt64) -> Void)?
    var onSize: ((Int, Int) -> Void)?
    var onError: ((Error) -> Void)?
    var onClipboard: ((String) -> Void)?
    private var isStopped = false
    private var stopped: Bool { stateLock.lock(); defer { stateLock.unlock() }; return isStopped }

    init(probeMarkers: Bool = false) {
        decoder = H264Decoder(probeMarkers: probeMarkers)
        decoder.onError = { [weak self] error in self?.fail(error) }
    }

    private func fail(_ error: Error) {
        stateLock.lock()
        guard !isStopped else { stateLock.unlock(); return }
        isStopped = true
        let video = self.video; let control = self.control
        stateLock.unlock()
        video?.close(); control?.close()
        directInput?.stop()
        onError?(error)
    }

    func enableDirectInput(port: UInt16, onFocus: @escaping (InputFocus?) -> Void) {
        let client = DirectInputClient(port: port)
        directInput = client
        client.onFocus = { [weak self] focus in
            onFocus(focus)
            self?.imeQueue.async { [weak self] in self?.confirmCurrentFocus() }
        }
        client.start()
    }

    func beginPointer(_ sequence: UInt64) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            stateLock.lock()
            guard !isStopped else { stateLock.unlock(); return }
            pointerSequence = sequence; completedPointer = nil; completedDisplay = -1
            let client = directInput
            stateLock.unlock()
            client?.invalidatePointer(sequence)
        }
    }

    private func confirmCurrentFocus() {
        stateLock.lock()
        let active = !isStopped
        let pointer = pointerSequence
        let completed = completedPointer
        let display = completedDisplay
        let client = directInput
        stateLock.unlock()
        guard active, completed == pointer, let client else { return }
        let focus = try? client.confirm(pointerSequence: pointer, displayId: display)
        stateLock.lock()
        let stillValid = !isStopped && pointerSequence == pointer && completedPointer == pointer
        stateLock.unlock()
        if stillValid { onConfirmedFocus?(focus, pointer) }
    }

    private func acknowledgeTouch(_ acknowledgement: TouchFinishedAcknowledgement) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            stateLock.lock()
            guard !isStopped, acknowledgement.sequence == pointerSequence else { stateLock.unlock(); return }
            let pointer = pointerSequence
            guard acknowledgement.success else {
                completedPointer = nil
                stateLock.unlock()
                onConfirmedFocus?(nil, pointer)
                return
            }
            completedPointer = acknowledgement.sequence; completedDisplay = acknowledgement.displayId
            stateLock.unlock()
            imeQueue.async { [weak self] in self?.confirmCurrentFocus() }
        }
    }

    func sendText(_ text: String, lease: InputLease, onStatus: @escaping (String?) -> Void) {
        imeQueue.async { [weak self] in
            guard let self, !stopped, let directInput else { return }
            do { try directInput.commit(text, lease: lease); if !stopped { onStatus(nil) } }
            catch { if !stopped { onStatus(error.localizedDescription) } }
        }
    }

    func connect(port: UInt16, startApp: String? = nil) {
        queue.async { [self] in
            // Retain the decoder while its callbacks drain, off the main/callback threads.
            defer { decoder.finish() }
            do {
                guard !stopped else { return }
                // The fixed server suppresses device metadata and the dummy byte.
                let video = try LocalSocket(port: port)
                let control = try LocalSocket(port: port)
                stateLock.lock()
                if isStopped {
                    stateLock.unlock(); video.close(); control.close(); return
                }
                self.video = video; self.control = control
                stateLock.unlock()
                readDeviceMessages(control)
                if let startApp { try control.send(Wire.startApp(startApp)) }
                let codec = try video.receive(4)
                guard codec == Data("h264".utf8) else { throw StreamFailure.invalid("codec") }
                while true {
                    let header = try video.receive(12)
                    let flags: UInt64 = Wire.read(header)
                    if flags & (1 << 63) != 0 {
                        let width: UInt32 = Wire.read(header, at: 4)
                        let height: UInt32 = Wire.read(header, at: 8)
                        guard width > 0, width < 16384, height > 0, height < 16384 else { throw StreamFailure.invalid("resolution") }
                        onSize?(Int(width), Int(height)); continue
                    }
                    let size: UInt32 = Wire.read(header, at: 8)
                    let payload = try video.receive(Int(size))
                    if flags & (1 << 62) != 0 { try decoder.configure(payload) }
                    else { try decoder.decode(payload, pts: Int64(flags & ((1 << 61) - 1))) }
                }
            } catch { fail(error) }
        }
    }

    func send(_ data: Data) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            stateLock.lock(); let control = self.control; let active = !isStopped; stateLock.unlock()
            guard active, let control else { return }
            do { try control.send(data) } catch { fail(error) }
        }
    }

    private func readDeviceMessages(_ socket: LocalSocket) {
        deviceQueue.async { [weak self] in
            do {
                while true {
                    let type = try socket.receive(1)[0]
                    switch type {
                    case 0:
                        let size: UInt32 = Wire.read(try socket.receive(4))
                        guard size <= 256 * 1024 else { throw StreamFailure.invalid("clipboard size") }
                        let bytes = try socket.receive(Int(size))
                        if let text = String(data: bytes, encoding: .utf8) { self?.onClipboard?(text) }
                    case 1: _ = try socket.receive(8) // Clipboard acknowledgement.
                    case 3: self?.acknowledgeTouch(try TouchFinishedAcknowledgement(payload: socket.receive(13)))
                    default: throw StreamFailure.invalid("unexpected device message")
                    }
                }
            } catch {
                self?.fail(error)
            }
        }
    }

    func stop() {
        stateLock.lock(); isStopped = true; let video = self.video; let control = self.control; stateLock.unlock()
        video?.close(); control?.close()
        directInput?.stop()
    }
    deinit { stop() }
}
