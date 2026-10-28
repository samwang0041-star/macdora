import Foundation
import CoreGraphics

enum Wire {
    static let version = "5.0.1"
    static let displayConfigurationType: UInt8 = 129
    static let displayConfigurationAckType: UInt8 = 4

    static func integer<T: FixedWidthInteger>(_ value: T) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    static func read<T: FixedWidthInteger>(_ data: Data, at offset: Int = 0, as: T.Type = T.self) -> T {
        data.subdata(in: offset..<(offset + MemoryLayout<T>.size)).reduce(T.zero) { ($0 << 8) | T($1) }
    }

    static func key(_ code: UInt32, down: Bool, meta: UInt32 = 0) -> Data {
        Data([0, down ? 0 : 1]) + integer(code) + integer(UInt32(0)) + integer(meta)
    }

    static func text(_ text: String) -> Data {
        let bytes = Data(text.utf8)
        return Data([1]) + integer(UInt32(bytes.count)) + bytes
    }

    static func paste(_ text: String, sequence: UInt64) -> Data {
        let bytes = Data(text.utf8)
        return Data([9]) + integer(sequence) + Data([1]) + integer(UInt32(bytes.count)) + bytes
    }

    static func touch(action: UInt8, x: UInt32, y: UInt32, width: UInt16, height: UInt16) -> Data {
        // A generic finger avoids the mouse-hover semantics of POINTER_ID_MOUSE.
        Data([2, action]) + integer(UInt64.max - 1) + integer(x) + integer(y)
            + integer(width) + integer(height) + integer(action == 1 ? UInt16(0) : UInt16.max)
            + integer(UInt32(0)) + integer(UInt32(0))
    }

    static func touchFinished(_ sequence: UInt64) -> Data { Data([128]) + integer(sequence) }

    static func displayConfiguration(_ configuration: DisplayStreamConfiguration, sequence: UInt32) -> Data {
        precondition(configuration.isValid, "Invalid display configuration")
        return Data([displayConfigurationType])
            + integer(sequence)
            + integer(UInt32(configuration.nativeWidth))
            + integer(UInt32(configuration.nativeHeight))
            + integer(UInt32(configuration.density))
            + integer(UInt32(configuration.maxSize))
            + integer(UInt32(configuration.maxFPS))
    }

    static func scroll(x: UInt32, y: UInt32, width: UInt16, height: UInt16, dx: Double, dy: Double) -> Data {
        func fixed(_ v: Double) -> UInt16 {
            UInt16(bitPattern: Int16(max(-32768, min(32767, Int((v / 16 * 32768).rounded())))))
        }
        return Data([3]) + integer(x) + integer(y) + integer(width) + integer(height)
            + integer(fixed(dx)) + integer(fixed(dy)) + integer(UInt32(0))
    }

    static func startApp(_ package: String) -> Data {
        let bytes = Data(package.utf8.prefix(255))
        return Data([16, UInt8(bytes.count)]) + bytes
    }
}

struct DisplayStreamConfiguration: Equatable, Sendable {
    let nativeWidth: Int
    let nativeHeight: Int
    let density: Int
    let maxSize: Int
    let maxFPS: Int

    var videoSize: CGSize {
        let scale = min(1, Double(maxSize) / Double(max(nativeWidth, nativeHeight)))
        let width = max(2, Int(Double(nativeWidth) * scale) & ~1)
        let height = max(2, Int(Double(nativeHeight) * scale) & ~1)
        return CGSize(width: width, height: height)
    }

    var isValid: Bool {
        (320...4096).contains(nativeWidth)
            && (320...4096).contains(nativeHeight)
            && (density == 320 || density == 400)
            && [1280, 1920, 2560].contains(maxSize)
            && [30, 45, 60].contains(maxFPS)
    }
}

struct TouchFinishedAcknowledgement: Equatable {
    let sequence: UInt64
    let displayId: Int32
    let success: Bool
    init(payload: Data) throws {
        guard payload.count == 13, payload[12] <= 1 else { throw StreamFailure.invalid("touch acknowledgement") }
        sequence = Wire.read(payload)
        displayId = Int32(bitPattern: Wire.read(payload, at: 8, as: UInt32.self))
        success = payload[12] == 1
        guard !success || displayId > 0 else { throw StreamFailure.invalid("touch display") }
    }
}

struct DisplayConfigurationAcknowledgement: Equatable {
    let sequence: UInt32
    let success: Bool

    init(sequence: UInt32, success: Bool) {
        self.sequence = sequence
        self.success = success
    }

    init(payload: Data) throws {
        guard payload.count == 6,
              payload[0] == Wire.displayConfigurationAckType,
              payload[5] <= 1 else {
            throw StreamFailure.invalid("display configuration acknowledgement")
        }
        sequence = Wire.read(payload, at: 1)
        success = payload[5] == 0
    }
}

struct SurfaceGeometry {
    let bounds: CGRect
    let pixels: CGSize

    var contentRect: CGRect {
        guard pixels.width > 0, pixels.height > 0 else { return .zero }
        let scale = min(bounds.width / pixels.width, bounds.height / pixels.height)
        let size = CGSize(width: pixels.width * scale, height: pixels.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// NSView is flipped: both host points and Android pixels have a top-left origin.
    func guestPoint(_ point: CGPoint, clamp: Bool = false) -> CGPoint? {
        let rect = contentRect
        guard rect.width > 0, rect.height > 0, clamp || rect.contains(point) else { return nil }
        return CGPoint(
            x: max(0, min(pixels.width - 1, (point.x - rect.minX) * pixels.width / rect.width)),
            y: max(0, min(pixels.height - 1, (point.y - rect.minY) * pixels.height / rect.height))
        )
    }
}

enum AnnexB {
    static func units(_ data: Data) -> [Data] {
        let b = [UInt8](data)
        var starts: [(Int, Int)] = []
        var i = 0
        while i + 2 < b.count {
            if b[i] == 0 && b[i + 1] == 0 {
                if b[i + 2] == 1 { starts.append((i, 3)); i += 3; continue }
                if i + 3 < b.count && b[i + 2] == 0 && b[i + 3] == 1 { starts.append((i, 4)); i += 4; continue }
            }
            i += 1
        }
        return starts.enumerated().compactMap { index, pair in
            let end = index + 1 < starts.count ? starts[index + 1].0 : b.count
            let begin = pair.0 + pair.1
            return begin < end ? Data(b[begin..<end]) : nil
        }
    }
}
