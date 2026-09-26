import AVFoundation
import CoreGraphics
import ImageIO
import MetalKit
import UniformTypeIdentifiers
import CoreVideo
import Metal
import simd

/// How the camera sits physically. The camera's own "up" is along the USB plug,
/// so plugged into a Mac's side port the panorama arrives rotated 90°.
enum MountOrientation: String, CaseIterable, Identifiable {
    case sideways, sidewaysFlipped, upright, upsideDown
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sideways: return "Sideways (Mac port)"
        case .sidewaysFlipped: return "Sideways, flipped"
        case .upright: return "Upright"
        case .upsideDown: return "Upside down"
        }
    }

    var matrix: simd_float3x3 {
        let angle: Float
        switch self {
        case .upright: return matrix_identity_float3x3
        case .sideways: angle = .pi / 2
        case .sidewaysFlipped: angle = -.pi / 2
        case .upsideDown: angle = .pi
        }
        return simd_float3x3(simd_quatf(angle: angle, axis: [1, 0, 0]))
    }
}

extension MountOrientation {
    /// CDB[8] of the shutter command. The Android app maps phone rotation to 0...3, but on
    /// firmware v1.3B00 the value changes neither pixels nor EXIF, so the Mac levels photos itself.
    var photoOrientationCode: UInt8 { 0 }
}

/// Levels a camera JPEG for the current mount and tags it as a 360° photo (GPano XMP),
/// keeping the camera's EXIF (make/model/date).
enum PhotoFixer {
    private static let gpanoNS = "http://ns.google.com/photos/1.0/panorama/" as CFString

    static func process(_ jpeg: [UInt8], mount: MountOrientation, corrector: EquirectCorrector?) -> [UInt8] {
        let data = Data(jpeg) as CFData
        guard let src = CGImageSourceCreateWithData(data, nil),
              let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil).flatMap({ CGImageMetadataCreateMutableCopy($0) }),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return jpeg }

        CGImageMetadataRegisterNamespaceForPrefix(meta, gpanoNS, "GPano" as CFString, nil)
        let tags: [(String, Any)] = [
            ("ProjectionType", "equirectangular"), ("UsePanoramaViewer", "True"),
            ("FullPanoWidthPixels", w), ("FullPanoHeightPixels", h),
            ("CroppedAreaImageWidthPixels", w), ("CroppedAreaImageHeightPixels", h),
            ("CroppedAreaLeftPixels", 0), ("CroppedAreaTopPixels", 0),
        ]
        for (k, v) in tags {
            CGImageMetadataSetValueWithPath(meta, nil, "GPano:\(k)" as CFString, "\(v)" as CFString)
        }

        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return jpeg }
        if mount == .upright {
            // Lossless: only the metadata changes.
            let opts: [CFString: Any] = [kCGImageDestinationMetadata: meta, kCGImageDestinationMergeMetadata: true]
            guard CGImageDestinationCopyImageSource(dst, src, opts as CFDictionary, nil) else { return jpeg }
            return [UInt8](out as Data)
        }
        guard let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let level = corrector?.correct(img, mount: mount) else { return jpeg }
        CGImageMetadataSetValueWithPath(meta, nil, "tiff:Orientation" as CFString, "1" as CFString)
        CGImageDestinationAddImageAndMetadata(dst, level, meta, [kCGImageDestinationLossyCompressionQuality: 0.97] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return jpeg }
        return [UInt8](out as Data)
    }
}

func makePanoramaPipeline(_ dev: MTLDevice, format: MTLPixelFormat) -> MTLRenderPipelineState? {
    do {
        let lib = try dev.makeLibrary(source: shaderSource, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "vmain")
        d.fragmentFunction = lib.makeFunction(name: "fmain")
        d.colorAttachments[0].pixelFormat = format
        return try dev.makeRenderPipelineState(descriptor: d)
    } catch {
        NSLog("Metal pipeline error: \(error)")
        return nil
    }
}

/// Re-projects a raw camera frame into a level equirectangular frame (same size) on the GPU.
final class EquirectCorrector {
    fileprivate let device: MTLDevice
    fileprivate let queue: MTLCommandQueue
    fileprivate let pipeline: MTLRenderPipelineState
    private var cache: CVMetalTextureCache?
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    fileprivate let lock = NSLock() // used from the USB thread (recording) and main thread (snapshot)

    init?() {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(),
              let p = makePanoramaPipeline(dev, format: .bgra8Unorm) else { return nil }
        device = dev; queue = q; pipeline = p
        CVMetalTextureCacheCreate(nil, nil, dev, nil, &cache)
    }

    private func texture(_ pb: CVPixelBuffer) -> (CVMetalTexture, MTLTexture)? {
        guard let cache else { return nil }
        var t: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm,
                                                  CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &t)
        guard let t, let tex = CVMetalTextureGetTexture(t) else { return nil }
        return (t, tex)
    }

    func correct(_ src: CVPixelBuffer, mount: MountOrientation) -> CVPixelBuffer? {
        if mount == .upright { return src }
        lock.lock(); defer { lock.unlock() }
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        if pool == nil || poolSize != (w, h) {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            poolSize = (w, h)
        }
        var dst: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst) == kCVReturnSuccess, let dst,
              let (srcCV, srcTex) = texture(src), let (dstCV, dstTex) = texture(dst),
              let cmd = queue.makeCommandBuffer() else { return nil }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = dstTex
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return nil }
        var u = PanoramaMTKView.Uniforms(yaw: 0, pitch: 0, fov: 1, aspect: 2, mode: ViewMode.flat.rawValue, mount: mount.matrix)
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(srcTex, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<PanoramaMTKView.Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        _ = (srcCV, dstCV)
        return dst
    }
}

extension EquirectCorrector {
    /// Same re-projection for a still image (e.g. the camera's 5376x2688 JPEG).
    func correct(_ image: CGImage, mount: MountOrientation) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        let w = image.width, h = image.height
        guard let srcTex = try? MTKTextureLoader(device: device).newTexture(cgImage: image, options: [.SRGB: false]) else { return nil }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget]
        td.storageMode = .shared
        guard let dstTex = device.makeTexture(descriptor: td), let cmd = queue.makeCommandBuffer() else { return nil }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = dstTex
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return nil }
        var u = PanoramaMTKView.Uniforms(yaw: 0, pitch: 0, fov: 1, aspect: 2, mode: ViewMode.flat.rawValue, mount: mount.matrix)
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(srcTex, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<PanoramaMTKView.Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: w * h * 4)
        dstTex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?.makeImage()
        }
    }
}

/// Encodes level (corrected) frames to an H.264 MP4.
final class CorrectedRecorder {
    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var started = false

    init(url: URL, width: Int, height: Int) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 16_000_000],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
    }

    func append(_ pb: CVPixelBuffer, pts: CMTime) {
        if !started {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: pts)
            started = true
        }
        if input.isReadyForMoreMediaData { adaptor.append(pb, withPresentationTime: pts) }
    }

    func finish(_ done: @escaping () -> Void) {
        guard started else { done(); return }
        input.markAsFinished()
        writer.finishWriting(completionHandler: done)
    }
}
