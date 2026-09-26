import CoreVideo
import Foundation
import Metal
import Syphon

/// Publishes a 16:9 perspective view of the 360° stream as a Syphon server.
/// OBS picks it up with a "Syphon Client" source and forwards it through "OBS Virtual Camera" —
/// no window has to stay visible and no screen-recording permission is needed.
final class SyphonOutput {
    static let serverName = "360 Webcam"

    var enabled = true { didSet { enabled ? start() : stop() } }
    var mode: ViewMode = .perspective
    var mount: MountOrientation = .sideways
    var height = 1080 { didSet { if height != oldValue { target = nil } } }
    let angles = ViewAngles()

    private let store: FrameStore
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private var cache: CVMetalTextureCache?
    private var server: SyphonMetalServer?
    private var target: MTLTexture?
    private var timer: Timer?

    init(store: FrameStore) {
        self.store = store
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        pipeline = device.flatMap { makePanoramaPipeline($0, format: .bgra8Unorm) }
        if let device { CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) }
        start()
    }

    deinit { stop() }

    private func start() {
        guard server == nil, let device else { return }
        server = SyphonMetalServer(name: Self.serverName, device: device, options: nil)
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.publish() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        server?.stop()
        server = nil
    }

    private func publish() {
        guard let server, server.hasClients, let device, let queue, let pipeline, let cache,
              let pb = store.get() else { return }
        let w = height * 16 / 9
        if target == nil {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            target = device.makeTexture(descriptor: d)
        }
        var cvTex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm,
                                                  CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &cvTex)
        guard let target, let cvTex, let src = CVMetalTextureGetTexture(cvTex),
              let cmd = queue.makeCommandBuffer() else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        var u = PanoramaMTKView.Uniforms(yaw: angles.yaw, pitch: angles.pitch, fov: angles.fov,
                                         aspect: Float(w) / Float(height), mode: mode.rawValue, mount: mount.matrix)
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(src, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<PanoramaMTKView.Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        server.publishFrameTexture(target, on: cmd, imageRegion: NSRect(x: 0, y: 0, width: w, height: height), flipped: false)
        cmd.addCompletedHandler { _ in _ = cvTex }
        cmd.commit()
    }
}
