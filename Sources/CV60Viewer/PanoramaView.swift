import AppKit
import CoreVideo
import Metal
import MetalKit
import SwiftUI

enum ViewMode: Int32, CaseIterable, Identifiable {
    case flat = 0, perspective = 1, littlePlanet = 2
    var id: Int32 { rawValue }
    var title: String {
        switch self {
        case .flat: return "Flat"
        case .perspective: return "360°"
        case .littlePlanet: return "Little planet"
        }
    }
}

/// Latest decoded frame, shared between the USB thread and the renderer.
final class FrameStore {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    func set(_ b: CVPixelBuffer) { lock.lock(); buffer = b; lock.unlock() }
    func get() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return buffer }
    func clear() { lock.lock(); buffer = nil; lock.unlock() }
}

let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; float2 uv; };
struct Uniforms { float yaw; float pitch; float fov; float aspect; int mode; float3x3 mount; };

vertex VOut vmain(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

// World direction (x right, y up, -z forward) from longitude / latitude.
static float3 dirFrom(float lon, float lat) {
    return float3(cos(lat) * sin(lon), sin(lat), -cos(lat) * cos(lon));
}

fragment float4 fmain(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], constant Uniforms& u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, s_address::repeat, t_address::clamp_to_edge);
    const float PI = 3.14159265;
    float2 ndc = float2(in.uv.x * 2.0 - 1.0, 1.0 - in.uv.y * 2.0);
    float3 d;

    if (u.mode == 0) {
        // Flat equirectangular, letterboxed to 2:1.
        float2 uv = in.uv;
        if (u.aspect > 2.0) { uv.x = (uv.x - 0.5) * u.aspect / 2.0 + 0.5; }
        else { uv.y = (uv.y - 0.5) * 2.0 / u.aspect + 0.5; }
        if (any(uv < 0.0) || any(uv > 1.0)) return float4(0, 0, 0, 1);
        d = dirFrom((uv.x - 0.5) * 2.0 * PI + u.yaw, (0.5 - uv.y) * PI);
    } else if (u.mode == 1) {
        float t = tan(u.fov * 0.5);
        d = normalize(float3(ndc.x * t * u.aspect, ndc.y * t, -1.0));
        float cp = cos(u.pitch), sp = sin(u.pitch);
        d = float3(d.x, d.y * cp - d.z * sp, d.y * sp + d.z * cp);
        float cy = cos(u.yaw), sy = sin(u.yaw);
        d = float3(d.x * cy - d.z * sy, d.y, d.x * sy + d.z * cy);
    } else {
        // Stereographic "little planet" looking at the nadir.
        float2 p = float2(ndc.x * u.aspect, ndc.y) * (u.fov / 1.2);
        d = dirFrom(atan2(p.x, -p.y) + u.yaw, -PI * 0.5 + 2.0 * atan(length(p)));
    }
    // Undo how the camera is physically mounted (e.g. plugged sideways into a Mac).
    d = u.mount * d;
    float lon = atan2(d.x, -d.z);
    float lat = asin(clamp(d.y, -1.0, 1.0));
    return tex.sample(s, float2(lon / (2.0 * PI) + 0.5, 0.5 - lat / PI));
}
"""

final class PanoramaMTKView: MTKView, MTKViewDelegate {
    struct Uniforms {
        var yaw: Float; var pitch: Float; var fov: Float; var aspect: Float; var mode: Int32
        var mount = matrix_identity_float3x3
    }

    var store: FrameStore?
    var mode: ViewMode = .perspective
    var mount: MountOrientation = .sideways
    private var yaw: Float = 0
    private var pitch: Float = 0
    private var fov: Float = 100 * .pi / 180
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var cache: CVMetalTextureCache?
    private var timer: Timer?

    /// Draw from our own 30 Hz timer instead of the display link, so the view keeps
    /// updating while its window is covered (OBS window capture still gets frames).
    var drivesItself = false {
        didSet {
            guard drivesItself != oldValue else { return }
            timer?.invalidate()
            timer = nil
            isPaused = drivesItself
            enableSetNeedsDisplay = false
            if drivesItself {
                let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.draw() }
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
        }
    }

    deinit { timer?.invalidate() }

    init() {
        let dev = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: dev)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        preferredFramesPerSecond = 60
        delegate = self
        guard let dev else { return }
        queue = dev.makeCommandQueue()
        CVMetalTextureCacheCreate(nil, nil, dev, nil, &cache)
        pipeline = makePanoramaPipeline(dev, format: colorPixelFormat)
    }

    required init(coder: NSCoder) { fatalError("unused") }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDragged(with e: NSEvent) {
        if e.modifierFlags.contains(.option) { return } // ⌥-drag moves the window (see mouseDown)
        let scale = fov / Float(max(bounds.height, 1))
        yaw -= Float(e.deltaX) * scale
        pitch = min(max(pitch + Float(e.deltaY) * scale, -.pi / 2), .pi / 2)
    }

    override func scrollWheel(with e: NSEvent) {
        fov = min(max(fov * (1 + Float(e.scrollingDeltaY) * 0.01), 30 * .pi / 180), 150 * .pi / 180)
    }

    override func mouseDown(with e: NSEvent) {
        if e.modifierFlags.contains(.option) { window?.performDrag(with: e); return }
        if e.clickCount == 2 { yaw = 0; pitch = 0; fov = 100 * .pi / 180 }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let queue, let pipeline, let cache,
              let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let pb = store?.get() {
            var cvTex: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm,
                                                      CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &cvTex)
            if let cvTex, let tex = CVMetalTextureGetTexture(cvTex) {
                var u = Uniforms(yaw: yaw, pitch: pitch, fov: fov,
                                 aspect: Float(drawableSize.width / max(drawableSize.height, 1)), mode: mode.rawValue,
                                 mount: mount.matrix)
                enc.setRenderPipelineState(pipeline)
                enc.setFragmentTexture(tex, index: 0)
                enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                cmd.addCompletedHandler { _ in _ = cvTex } // keep the CV texture alive until the GPU is done
            }
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

struct PanoramaView: NSViewRepresentable {
    let store: FrameStore
    let mode: ViewMode
    let mount: MountOrientation
    var drivesItself = false

    func makeNSView(context: Context) -> PanoramaMTKView {
        let v = PanoramaMTKView()
        v.store = store
        updateNSView(v, context: context)
        return v
    }

    func updateNSView(_ v: PanoramaMTKView, context: Context) {
        v.mode = mode
        v.mount = mount
        v.drivesItself = drivesItself
    }
}
