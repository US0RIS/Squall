import AppKit
import Metal
import MetalKit
import QuartzCore

/// One drawn quad. Matches `Inst` in the shader (three float4s, 48 bytes).
///
/// Particle (b.w == 0): a = (center x, center y, width, height), b = (angle, kind, softness, 0).
///   kind 0 snowflake, 1 rain streak, 2 droplet.
/// Column (b.w == 1): a = (left x, base y, width, kind), b = (left height, right height, 0, 1).
///   kind 0 snow, 1 water. A run of columns draws a pile with a smooth top.
struct Instance {
    var a: SIMD4<Float>
    var b: SIMD4<Float>
    var color: SIMD4<Float>
}

struct Uniforms {
    var view: SIMD2<Float>
    var time: Float
    var pad: Float = 0
}

/// Shared Metal state. Shaders are compiled from source at launch, so the package needs no
/// Metal build step.
@MainActor
final class Renderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    static let sampleCount = 4

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: Shaders.source, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "Squall"
            desc.vertexFunction = library.makeFunction(name: "squall_vertex")
            desc.fragmentFunction = library.makeFunction(name: "squall_fragment")
            desc.rasterSampleCount = Renderer.sampleCount
            let ca: MTLRenderPipelineColorAttachmentDescriptor = desc.colorAttachments[0]
            ca.pixelFormat = .bgra8Unorm
            ca.isBlendingEnabled = true
            ca.rgbBlendOperation = .add
            ca.alphaBlendOperation = .add
            ca.sourceRGBBlendFactor = .one
            ca.sourceAlphaBlendFactor = .one
            ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            NSLog("Squall: Metal setup failed: \(error)")
            return nil
        }
        self.device = device
        self.queue = queue
    }
}

/// A transparent, click-through window covering one screen, drawn with Metal.
@MainActor
final class Overlay: NSObject, MTKViewDelegate {
    let displayID: Int
    private(set) var rectQ: CGRect
    var instances: [Instance] = []
    var time: Float = 0

    private let window: NSWindow
    private let view: MTKView
    private let renderer: Renderer
    private var buffers: [MTLBuffer?] = [nil, nil, nil]
    private var bufferIndex = 0
    private let inFlight = DispatchSemaphore(value: 3)
    private var drewEmpty = false

    init(screen: NSScreen, displayID: Int, rectQ: CGRect, renderer: Renderer) {
        self.displayID = displayID
        self.rectQ = rectQ
        self.renderer = renderer

        let frame = screen.frame
        let view = MTKView(frame: NSRect(origin: .zero, size: frame.size), device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.sampleCount = Renderer.sampleCount
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.framebufferOnly = true
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = .clear
        if let metal = view.layer as? CAMetalLayer {
            metal.isOpaque = false
            metal.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }
        self.view = view

        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = view
        window.setFrame(frame, display: false)
        self.window = window

        super.init()
        view.delegate = self
        window.orderFrontRegardless()
    }

    func reposition(screen: NSScreen, rectQ: CGRect) {
        self.rectQ = rectQ
        window.setFrame(screen.frame, display: false)
        window.orderFrontRegardless()
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }

    func render() {
        // Once the screen is clear, stop redrawing it.
        if instances.isEmpty && drewEmpty { return }
        view.draw()
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        // Only ever triggered by `render()` on the main thread.
        MainActor.assumeIsolated { encode() }
    }

    private func encode() {
        guard inFlight.wait(timeout: .now()) == .success else { return }   // GPU behind: skip a frame
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = renderer.queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            inFlight.signal()
            return
        }
        let n = instances.count
        if n > 0 {
            let bytes = n * MemoryLayout<Instance>.stride
            let buffer = instanceBuffer(bytes: bytes)
            instances.withUnsafeBytes { src in
                if let base = src.baseAddress { buffer.contents().copyMemory(from: base, byteCount: bytes) }
            }
            var uniforms = Uniforms(view: SIMD2(Float(view.bounds.width), Float(view.bounds.height)), time: time)
            encoder.setRenderPipelineState(renderer.pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: n)
        }
        encoder.endEncoding()
        commands.present(drawable)
        let semaphore = inFlight
        commands.addCompletedHandler { _ in semaphore.signal() }
        commands.commit()
        drewEmpty = n == 0
    }

    private func instanceBuffer(bytes: Int) -> MTLBuffer {
        let i = bufferIndex
        bufferIndex = (bufferIndex + 1) % buffers.count
        if let b = buffers[i], b.length >= bytes { return b }
        let length = max(bytes + bytes / 2, 64 * 1024)
        let b = renderer.device.makeBuffer(length: length, options: .storageModeShared)!
        buffers[i] = b
        return b
    }
}

enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Inst { float4 a; float4 b; float4 color; };
    struct Uni { float2 view; float time; float pad; };

    struct VOut {
        float4 pos [[position]];
        float2 uv;
        float4 color;
        float kind;
        float type;
        float h;
        float soft;
    };

    vertex VOut squall_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              const device Inst* inst [[buffer(0)]], constant Uni& u [[buffer(1)]]) {
        Inst I = inst[iid];
        float2 c = float2(float(vid & 1u), float(vid >> 1u));
        VOut o;
        float2 p;
        o.type = I.b.w;
        o.color = I.color;
        o.h = 0.0;
        o.soft = 0.5;
        if (I.b.w < 0.5) {
            float2 hs = I.a.zw * 0.5;
            float2 lp = (c * 2.0 - 1.0) * hs;
            float cs = cos(I.b.x);
            float sn = sin(I.b.x);
            p = I.a.xy + float2(lp.x * cs - lp.y * sn, lp.x * sn + lp.y * cs);
            o.uv = c * 2.0 - 1.0;
            o.kind = I.b.y;
            o.soft = I.b.z;
        } else {
            float h = mix(I.b.x, I.b.y, c.x);
            p = float2(I.a.x + c.x * I.a.z, I.a.y - c.y * h);
            o.uv = c;
            o.h = h;
            o.kind = I.a.w;
        }
        o.pos = float4(p.x / u.view.x * 2.0 - 1.0, 1.0 - p.y / u.view.y * 2.0, 0.0, 1.0);
        return o;
    }

    fragment float4 squall_fragment(VOut in [[stage_in]], constant Uni& u [[buffer(1)]]) {
        float a = in.color.a;
        float3 rgb = in.color.rgb;
        if (in.type < 0.5) {
            float r = length(in.uv);
            if (in.kind < 0.5) {
                // Snowflake: a soft disc, softer when close (bigger).
                a *= 1.0 - smoothstep(1.0 - in.soft, 1.0, r);
            } else if (in.kind < 1.5) {
                // Rain streak: thin across, bright at the leading end, fading to the tail.
                float across = 1.0 - smoothstep(0.15, 1.0, abs(in.uv.x));
                float along = smoothstep(-1.0, 0.55, in.uv.y) * (1.0 - smoothstep(0.85, 1.0, in.uv.y));
                a *= across * along;
            } else {
                // Droplet with a tiny highlight.
                a *= 1.0 - smoothstep(0.55, 1.0, r);
                rgb += (1.0 - smoothstep(0.0, 0.55, length(in.uv - float2(-0.3, -0.35)))) * 0.35;
            }
        } else {
            float fromTop = (1.0 - in.uv.y) * in.h;
            if (in.kind < 0.5) {
                // Snow: bright crust, cooler and bluer deeper down, the odd sparkle.
                float depth = clamp(fromTop / 16.0, 0.0, 1.0);
                rgb = mix(float3(1.0, 1.0, 1.0), float3(0.80, 0.86, 0.96), depth * 0.85);
                float crust = 1.0 - smoothstep(0.0, 1.5, fromTop);
                rgb = mix(rgb, float3(1.0), crust * 0.6);
                float2 cell = floor(in.pos.xy * 0.5);
                float n = fract(sin(dot(cell, float2(12.9898, 78.233)) + floor(u.time * 3.0) * 0.7) * 43758.5453);
                rgb += step(0.996, n) * 0.3 * (1.0 - depth);
            } else {
                // Water: translucent, with a bright meniscus line.
                float line = 1.0 - smoothstep(0.0, 1.3, fromTop);
                rgb = mix(rgb, float3(0.93, 0.97, 1.0), line * 0.9);
                a = mix(a, 0.85, line);
            }
        }
        a = clamp(a, 0.0, 1.0);
        return float4(rgb * a, a);
    }
    """
}
