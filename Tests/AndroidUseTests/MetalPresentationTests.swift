import XCTest
import AppKit
import CoreVideo
import Metal
@testable import AndroidUse

final class MetalPresentationTests: XCTestCase {
    @MainActor
    func testFirstFrameRejectsMissingOrInvalidPresentationTimestamps() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = AndroidSurfaceView(frame: NSRect(x: 0, y: 0, width: 32, height: 32), device: device)
        let session = UUID()
        view.beginSession(session)
        view.videoVisible = false
        let frame = DecodedFrame(buffer: try buffer(fullRange: false), pts: 0, marker: nil)
        var first = 0
        var presented = 0
        var invalid = 0
        view.onFirstFrame = { first += 1 }
        view.onPresented = { _, _ in presented += 1 }
        view.onInvalidPresentation = { _ in invalid += 1 }
        view.accept(frame, session: session)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        XCTAssertEqual(first, 0, "Decoding while hidden cannot announce successful display.")
        view.didPresent(frame, at: 100, session: UUID())
        view.didPresent(frame, at: 0, session: session)
        XCTAssertEqual(first, 0)
        XCTAssertEqual(invalid, 1)
        view.videoVisible = true
        view.didPresent(frame, at: 0, session: UUID())
        XCTAssertEqual(first, 0, "A stale session cannot make the new application ready.")
        view.didPresent(frame, at: .nan, session: session)
        view.didPresent(frame, at: -1, session: session)
        XCTAssertEqual(first, 0)
        view.didPresent(frame, at: 0, session: session)
        XCTAssertEqual(first, 0, "A dropped drawable must not enable input before a real presentation.")
        XCTAssertEqual(presented, 0, "A missing timestamp cannot become a performance sample.")
        XCTAssertEqual(invalid, 4)
        view.didPresent(frame, at: 101, session: session)
        view.didPresent(frame, at: 102, session: session)
        XCTAssertEqual(first, 1)
        XCTAssertEqual(presented, 2)
        let nextSession = UUID()
        view.beginSession(nextSession)
        view.didPresent(frame, at: 103, session: session)
        XCTAssertEqual(first, 1)
        view.didPresent(frame, at: 104, session: nextSession)
        XCTAssertEqual(first, 2)
    }

    func testUnknownOrWideGamutMetadataUsesColorManagedFallback() throws {
        let image = try buffer(fullRange: false)
        XCTAssertNil(AndroidSurfaceView.nv12ColorMode(image))
        setMetadata(image, bt601: false, transfer709: false)
        XCTAssertEqual(AndroidSurfaceView.nv12ColorMode(image), 0)
        CVBufferSetAttachment(image, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left, .shouldPropagate)
        XCTAssertNil(AndroidSurfaceView.nv12ColorMode(image))
        CVBufferSetAttachment(image, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_TopLeft, .shouldPropagate)
        XCTAssertNil(AndroidSurfaceView.nv12ColorMode(image))
        CVBufferRemoveAttachment(image, kCVImageBufferChromaLocationTopFieldKey)
        XCTAssertNil(AndroidSurfaceView.nv12ColorMode(image))
        setMetadata(image, bt601: false, transfer709: false)
        CVBufferSetAttachment(image, kCVImageBufferChromaLocationBottomFieldKey, kCVImageBufferChromaLocation_Center, .shouldPropagate)
        XCTAssertNil(AndroidSurfaceView.nv12ColorMode(image))
        CVBufferRemoveAttachment(image, kCVImageBufferChromaLocationBottomFieldKey)
        XCTAssertEqual(AndroidSurfaceView.nv12ColorMode(image), 0)
        CVBufferSetAttachment(image, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_P3_D65, .shouldPropagate)
        XCTAssertNil(AndroidSurfaceView.nv12ColorMode(image))
    }

    func testActualMetalNV12ShaderMatchesColorBarsAndTransferFunction() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: AndroidSurfaceView.metalShaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "surfaceVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "surfaceFragmentNV12")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var cache: CVMetalTextureCache?
        XCTAssertEqual(CVMetalTextureCacheCreate(nil, nil, device, nil, &cache), kCVReturnSuccess)
        let textureCache = try XCTUnwrap(cache)
        let colors: [(Double, Double, Double)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (0, 0, 0), (1, 1, 1), (0.5, 0.5, 0.5)]
        for fullRange in [false, true] {
            for bt601 in [false, true] {
                for transfer709 in [false, true] {
                    for (r, g, b) in colors {
                        let image = try buffer(fullRange: fullRange)
                        setMetadata(image, bt601: bt601, transfer709: transfer709)
                        let kr = bt601 ? 0.299 : 0.2126
                        let kb = bt601 ? 0.114 : 0.0722
                        let y = kr * r + (1 - kr - kb) * g + kb * b
                        let cb = (b - y) / (2 * (1 - kb))
                        let cr = (r - y) / (2 * (1 - kr))
                        let bytes = [UInt8(clamping: Int((y * (fullRange ? 255 : 219) + (fullRange ? 0 : 16)).rounded())),
                                     UInt8(clamping: Int((cb * (fullRange ? 255 : 224) + 128).rounded())),
                                     UInt8(clamping: Int((cr * (fullRange ? 255 : 224) + 128).rounded()))]
                        CVPixelBufferLockBaseAddress(image, [])
                        memset(CVPixelBufferGetBaseAddressOfPlane(image, 0), Int32(bytes[0]), CVPixelBufferGetBytesPerRowOfPlane(image, 0) * 4)
                        let uv = CVPixelBufferGetBaseAddressOfPlane(image, 1)!.assumingMemoryBound(to: UInt8.self)
                        for row in 0..<2 { for col in 0..<2 {
                            let offset = row * CVPixelBufferGetBytesPerRowOfPlane(image, 1) + col * 2
                            uv[offset] = bytes[1]; uv[offset + 1] = bytes[2]
                        } }
                        CVPixelBufferUnlockBaseAddress(image, [])
                        var yTexture: CVMetalTexture?
                        var uvTexture: CVMetalTexture?
                        XCTAssertEqual(CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, image, nil, .r8Unorm, 4, 4, 0, &yTexture), kCVReturnSuccess)
                        XCTAssertEqual(CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, image, nil, .rg8Unorm, 2, 2, 1, &uvTexture), kCVReturnSuccess)
                        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 4, height: 4, mipmapped: false)
                        outputDescriptor.storageMode = .shared
                        outputDescriptor.usage = [.renderTarget]
                        let output = try XCTUnwrap(device.makeTexture(descriptor: outputDescriptor))
                        let pass = MTLRenderPassDescriptor()
                        pass.colorAttachments[0].texture = output
                        pass.colorAttachments[0].loadAction = .clear
                        pass.colorAttachments[0].storeAction = .store
                        let command = try XCTUnwrap(queue.makeCommandBuffer())
                        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
                        encoder.setRenderPipelineState(pipeline)
                        encoder.setFragmentTexture(CVMetalTextureGetTexture(try XCTUnwrap(yTexture)), index: 0)
                        encoder.setFragmentTexture(CVMetalTextureGetTexture(try XCTUnwrap(uvTexture)), index: 1)
                        var mode = try XCTUnwrap(AndroidSurfaceView.nv12ColorMode(image))
                        encoder.setFragmentBytes(&mode, length: 4, index: 0)
                        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                        encoder.endEncoding()
                        command.commit(); command.waitUntilCompleted()
                        XCTAssertNil(command.error)
                        var actual = [UInt8](repeating: 0, count: 64)
                        output.getBytes(&actual, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0)
                        // Primary color bars stay primary; 50% Rec.709 gray maps to about 139.4 in sRGB.
                        let expected = [b, g, r].map { value in transfer709 && value == 0.5 ? 139.4 : value * 255 }
                        for channel in 0..<3 {
                            XCTAssertEqual(Double(actual[channel]), expected[channel], accuracy: 3, "full=\(fullRange), 601=\(bt601), transfer709=\(transfer709), YUV=\(bytes)")
                        }
                        XCTAssertEqual(actual[3], 255)
                    }
                }
            }
        }
    }

    private func buffer(fullRange: Bool) throws -> CVPixelBuffer {
        var image: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
        XCTAssertEqual(CVPixelBufferCreate(nil, 4, 4, fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &image), kCVReturnSuccess)
        return try XCTUnwrap(image)
    }

    private func setMetadata(_ image: CVPixelBuffer, bt601: Bool, transfer709: Bool) {
        CVBufferSetAttachment(image, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center, .shouldPropagate)
        CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey, bt601 ? kCVImageBufferYCbCrMatrix_ITU_R_601_4 : kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(image, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(image, kCVImageBufferTransferFunctionKey, transfer709 ? kCVImageBufferTransferFunction_ITU_R_709_2 : kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
    }
}
