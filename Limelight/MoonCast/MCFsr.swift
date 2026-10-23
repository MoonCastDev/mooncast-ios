//
//  MCFsr.swift
//  MoonCast: super resolution with AMD FidelityFX Super Resolution 1.0 (FSR 1, MIT licence), as on Android
//  (FsrRenderer.kt): the decoded frame (NV12 from VideoToolbox) becomes RGB, EASU (edge-adaptive Lanczos) scales
//  it to the screen, RCAS sharpens it. The shaders are the Android app's ports of ffx_fsr1.h's 32-bit FsrEasuF and
//  FsrRcasF, here in Metal. Used by the PC, PS5 and Xbox players when Settings → Picture → Super resolution is on
//  and the stream is clearly smaller than the screen.
//

import UIKit
import Metal
import QuartzCore
import CoreVideo
import VideoToolbox
import CoreMedia

@objc(MCFsr)
final class MCFsr: NSObject {
    /// Settings → Picture → Super resolution is FSR 1.0.
    @objc static var enabled: Bool { UserDefaults.standard.string(forKey: "mc_super_resolution") == "fsr1" }
    /// Settings → Picture → Sharpening, 0...1.
    @objc static var sharpness: Float { Float(UserDefaults.standard.object(forKey: "mc_fsr_sharpness") as? Int ?? 60) / 100 }
    /// Worth it only when the stream is clearly smaller than the screen.
    @objc static func worthIt(videoHeight: Int, screenHeight: Int) -> Bool { Double(screenHeight) > Double(videoHeight) * 1.1 }
    /// Pixels of the screen's shorter side.
    @objc static var screenPixelHeight: Int {
        let b = UIScreen.main.nativeBounds.size
        return Int(min(b.width, b.height))
    }
    @objc static func wanted(videoHeight: Int) -> Bool { enabled && worthIt(videoHeight: videoHeight, screenHeight: screenPixelHeight) }
}

/// Settings → Picture → Ultra low latency (the handheld's switch, iPad style): PC frames shown the moment they're
/// decoded instead of at the next screen refresh, less sound queued on PS5 and Xbox. A rough Wi-Fi can stutter more.
@objc(MCUltraLowLatency)
final class MCUltraLowLatency: NSObject {
    @objc static var enabled: Bool { UserDefaults.standard.bool(forKey: "mc_ultra_low_latency") }
}

/// The picture, drawn through FSR. Feed it decoded frames with display(_:); any thread.
@objc(MCFsrView)
final class MCFsrView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metal: CAMetalLayer { layer as! CAMetalLayer }
    private let device = MTLCreateSystemDefaultDevice()
    private var queue: MTLCommandQueue?
    private var yuvPipe: MTLRenderPipelineState?, easuPipe: MTLRenderPipelineState?, rcasPipe: MTLRenderPipelineState?
    private var cache: CVMetalTextureCache?
    private var rgbTex: MTLTexture?, easuTex: MTLTexture?
    private let inFlight = DispatchSemaphore(value: 2)
    private let sharp: Float
    private var drawableSize = CGSize.zero
    /// The stream's aspect ratio (width / height): the picture is fitted into the view with it.
    @objc var aspect: CGFloat = 16.0 / 9.0
    @objc private(set) var frames = 0

    @objc init(frame: CGRect, sharpness: Float) {
        // stops: 100% = 0, 0% = 2, as FsrRcasCon
        sharp = pow(2, -((1 - max(0, min(1, sharpness))) * 2))
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .black
        metal.device = device
        metal.pixelFormat = .bgra8Unorm
        metal.framebufferOnly = true
        metal.contentsScale = UIScreen.main.nativeScale
        guard let d = device else { return }
        queue = d.makeCommandQueue()
        CVMetalTextureCacheCreate(nil, nil, d, nil, &cache)
        do {
            let lib = try d.makeLibrary(source: MCFsrView.shaders, options: nil)
            func pipe(_ f: String) throws -> MTLRenderPipelineState {
                let p = MTLRenderPipelineDescriptor()
                p.vertexFunction = lib.makeFunction(name: "mcVertex")
                p.fragmentFunction = lib.makeFunction(name: f)
                p.colorAttachments[0].pixelFormat = .bgra8Unorm
                return try d.makeRenderPipelineState(descriptor: p)
            }
            yuvPipe = try pipe("mcYuv"); easuPipe = try pipe("mcEasu"); rcasPipe = try pipe("mcRcas")
        } catch {
            NSLog("MoonCast FSR: shaders failed: \(error)")
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// True when the GPU took the shaders (otherwise the player shows the stream directly).
    @objc var ready: Bool { yuvPipe != nil && easuPipe != nil && rcasPipe != nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = CGSize(width: bounds.width * metal.contentsScale, height: bounds.height * metal.contentsScale)
        metal.drawableSize = s
        drawableSize = s
    }

    private func texture(_ w: Int, _ h: Int) -> MTLTexture? {
        let t = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        t.usage = [.renderTarget, .shaderRead]
        t.storageMode = .private
        return device?.makeTexture(descriptor: t)
    }

    private func plane(_ pb: CVPixelBuffer, _ i: Int, _ f: MTLPixelFormat) -> MTLTexture? {
        guard let cache = cache else { return nil }
        var t: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, f, CVPixelBufferGetWidthOfPlane(pb, i), CVPixelBufferGetHeightOfPlane(pb, i), i, &t)
        return t.flatMap(CVMetalTextureGetTexture)
    }

    /// One frame (NV12, video or full range). Drops the frame when the GPU is two frames behind.
    @objc func display(_ pb: CVPixelBuffer) {
        guard ready, let queue = queue, drawableSize.width > 0, inFlight.wait(timeout: .now()) == .success else { return }
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        guard fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
              let y = plane(pb, 0, .r8Unorm), let uv = plane(pb, 1, .rg8Unorm), let drawable = metal.nextDrawable(),
              let cb = queue.makeCommandBuffer() else { inFlight.signal(); return }
        let inW = CVPixelBufferGetWidth(pb), inH = CVPixelBufferGetHeight(pb)
        // fit the stream into the screen
        let dw = drawableSize.width, dh = drawableSize.height
        var outW = dw, outH = dw / aspect
        if outH > dh { outH = dh; outW = dh * aspect }
        let ow = max(1, Int(outW.rounded())), oh = max(1, Int(outH.rounded()))
        let ox = (Int(dw) - ow) / 2, oy = (Int(dh) - oh) / 2
        if rgbTex?.width != inW || rgbTex?.height != inH { rgbTex = texture(inW, inH) }
        if easuTex?.width != ow || easuTex?.height != oh { easuTex = texture(ow, oh) }
        guard let rgb = rgbTex, let easu = easuTex else { inFlight.signal(); return }

        func pass(_ target: MTLTexture, clear: Bool, _ body: (MTLRenderCommandEncoder) -> Void) {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = target
            rp.colorAttachments[0].loadAction = clear ? .clear : .dontCare
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            rp.colorAttachments[0].storeAction = .store
            guard let e = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
            body(e)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
        // 1. NV12 -> RGB at the frame's own size (BT.709)
        var full: Float = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 1 : 0
        pass(rgb, clear: false) { e in
            e.setRenderPipelineState(yuvPipe!)
            e.setFragmentTexture(y, index: 0); e.setFragmentTexture(uv, index: 1)
            e.setFragmentBytes(&full, length: 4, index: 0)
        }
        // 2. EASU up to the output size (constants as FsrEasuCon)
        let iw = Float(inW), ih = Float(inH), fw = Float(ow), fh = Float(oh)
        var con: [Float] = [iw / fw, ih / fh, 0.5 * iw / fw - 0.5, 0.5 * ih / fh - 0.5,
                            1 / iw, 1 / ih, 1 / iw, -1 / ih,
                            -1 / iw, 2 / ih, 1 / iw, 2 / ih,
                            0, 4 / ih, 0, 0,
                            iw, ih, 0, 0]
        pass(easu, clear: false) { e in
            e.setRenderPipelineState(easuPipe!)
            e.setFragmentTexture(rgb, index: 0)
            e.setFragmentBytes(&con, length: con.count * 4, index: 0)
        }
        // 3. RCAS sharpening into the screen
        var r: [Float] = [sharp, Float(ow), Float(oh), Float(ox), Float(oy), 0, 0, 0]
        pass(drawable.texture, clear: true) { e in
            e.setViewport(MTLViewport(originX: Double(ox), originY: Double(oy), width: Double(ow), height: Double(oh), znear: 0, zfar: 1))
            e.setRenderPipelineState(rcasPipe!)
            e.setFragmentTexture(easu, index: 0)
            e.setFragmentBytes(&r, length: r.count * 4, index: 0)
        }
        cb.present(drawable)
        cb.addCompletedHandler { [weak self] _ in self?.inFlight.signal() }
        cb.commit()
        frames += 1
    }

    private static let shaders = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 pos [[position]]; float2 uv; };

    // a full-screen triangle; no vertex buffers
    vertex VOut mcVertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        VOut o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    fragment float4 mcYuv(VOut in [[stage_in]], texture2d<float> yT [[texture(0)]], texture2d<float> uvT [[texture(1)]],
                          constant float &full [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float y = yT.sample(s, in.uv).r;
        float2 uv = uvT.sample(s, in.uv).rg - 0.5;
        if (full < 0.5) { y = (y - 16.0 / 255.0) * (255.0 / 219.0); uv *= 255.0 / 224.0; }
        float3 rgb = float3(y + 1.5748 * uv.y, y - 0.1873 * uv.x - 0.4681 * uv.y, y + 1.8556 * uv.x);
        return float4(saturate(rgb), 1.0);
    }

    struct Easu { float4 con0; float4 con1; float4 con2; float4 con3; float4 size; };

    float3 texel(texture2d<float> t, int2 p, int2 size) { return t.read(uint2(clamp(p, int2(0), size - 1))).rgb; }
    // textureGather at a texel corner p: x = (left, upper+1), y = (left+1, upper+1), z = (left+1, upper), w = (left, upper)
    void gather(texture2d<float> t, float2 p, int2 size, thread float3 &x, thread float3 &y, thread float3 &z, thread float3 &w) {
        int2 tl = int2(floor(p * float2(size) + 0.5)) - 1;
        x = texel(t, tl + int2(0, 1), size); y = texel(t, tl + int2(1, 1), size); z = texel(t, tl + int2(1, 0), size); w = texel(t, tl, size);
    }
    float luma(float3 c) { return c.b * 0.5 + (c.r * 0.5 + c.g); }
    float rcpf(float x) { return 1.0 / max(x, 1.0e-8); }

    void tap(thread float3 &aC, thread float &aW, float2 off, float2 dir, float2 len, float lob, float clp, float3 c) {
        float2 v;
        v.x = (off.x * ( dir.x)) + (off.y * dir.y);
        v.y = (off.x * (-dir.y)) + (off.y * dir.x);
        v *= len;
        float d2 = min(v.x * v.x + v.y * v.y, clp);
        float wB = 2.0 / 5.0 * d2 - 1.0;
        float wA = lob * d2 - 1.0;
        wB *= wB;
        wA *= wA;
        wB = 25.0 / 16.0 * wB - (25.0 / 16.0 - 1.0);
        float w = wB * wA;
        aC += c * w; aW += w;
    }

    void setF(thread float2 &dir, thread float &len, float2 pp, int corner, float lA, float lB, float lC, float lD, float lE) {
        float w = 0.0;
        if (corner == 0) w = (1.0 - pp.x) * (1.0 - pp.y);
        if (corner == 1) w = pp.x * (1.0 - pp.y);
        if (corner == 2) w = (1.0 - pp.x) * pp.y;
        if (corner == 3) w = pp.x * pp.y;
        float dc = lD - lC;
        float cb = lC - lB;
        float lenX = rcpf(max(abs(dc), abs(cb)));
        float dirX = lD - lB;
        dir.x += dirX * w;
        lenX = clamp(abs(dirX) * lenX, 0.0, 1.0);
        lenX *= lenX;
        len += lenX * w;
        float ec = lE - lC;
        float ca = lC - lA;
        float lenY = rcpf(max(abs(ec), abs(ca)));
        float dirY = lE - lA;
        dir.y += dirY * w;
        lenY = clamp(abs(dirY) * lenY, 0.0, 1.0);
        lenY *= lenY;
        len += lenY * w;
    }

    fragment float4 mcEasu(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant Easu &u [[buffer(0)]]) {
        int2 size = int2(u.size.xy);
        float2 pp = floor(in.pos.xy) * u.con0.xy + u.con0.zw;
        float2 fp = floor(pp);
        pp -= fp;
        float2 p0 = fp * u.con1.xy + u.con1.zw;
        float2 p1 = p0 + u.con2.xy;
        float2 p2 = p0 + u.con2.zw;
        float2 p3 = p0 + u.con3.xy;
        float3 b, c, z0, w0, i, j, f, e, k, l, h, g, x3, y3, oo, n;
        gather(t, p0, size, b, c, z0, w0);
        gather(t, p1, size, i, j, f, e);
        gather(t, p2, size, k, l, h, g);
        gather(t, p3, size, x3, y3, oo, n);
        float bL = luma(b), cL = luma(c), iL = luma(i), jL = luma(j), fL = luma(f), eL = luma(e);
        float kL = luma(k), lL = luma(l), hL = luma(h), gL = luma(g), oL = luma(oo), nL = luma(n);
        float2 dir = float2(0.0);
        float len = 0.0;
        setF(dir, len, pp, 0, bL, eL, fL, gL, jL);
        setF(dir, len, pp, 1, cL, fL, gL, hL, kL);
        setF(dir, len, pp, 2, fL, iL, jL, kL, nL);
        setF(dir, len, pp, 3, gL, jL, kL, lL, oL);
        float2 dir2 = dir * dir;
        float dirR = dir2.x + dir2.y;
        bool zro = dirR < 1.0 / 32768.0;
        dirR = rsqrt(max(dirR, 1.0e-12));
        dirR = zro ? 1.0 : dirR;
        dir.x = zro ? 1.0 : dir.x;
        dir *= float2(dirR);
        len = len * 0.5;
        len *= len;
        float stretch = (dir.x * dir.x + dir.y * dir.y) * rcpf(max(abs(dir.x), abs(dir.y)));
        float2 len2 = float2(1.0 + (stretch - 1.0) * len, 1.0 - 0.5 * len);
        float lob = 0.5 + ((1.0 / 4.0 - 0.04) - 0.5) * len;
        float clp = rcpf(lob);
        float3 min4 = min(min(min(f, g), j), k);
        float3 max4 = max(max(max(f, g), j), k);
        float3 aC = float3(0.0);
        float aW = 0.0;
        tap(aC, aW, float2( 0.0, -1.0) - pp, dir, len2, lob, clp, b);
        tap(aC, aW, float2( 1.0, -1.0) - pp, dir, len2, lob, clp, c);
        tap(aC, aW, float2(-1.0,  1.0) - pp, dir, len2, lob, clp, i);
        tap(aC, aW, float2( 0.0,  1.0) - pp, dir, len2, lob, clp, j);
        tap(aC, aW, float2( 0.0,  0.0) - pp, dir, len2, lob, clp, f);
        tap(aC, aW, float2(-1.0,  0.0) - pp, dir, len2, lob, clp, e);
        tap(aC, aW, float2( 1.0,  1.0) - pp, dir, len2, lob, clp, k);
        tap(aC, aW, float2( 2.0,  1.0) - pp, dir, len2, lob, clp, l);
        tap(aC, aW, float2( 2.0,  0.0) - pp, dir, len2, lob, clp, h);
        tap(aC, aW, float2( 1.0,  0.0) - pp, dir, len2, lob, clp, g);
        tap(aC, aW, float2( 1.0,  2.0) - pp, dir, len2, lob, clp, oo);
        tap(aC, aW, float2( 0.0,  2.0) - pp, dir, len2, lob, clp, n);
        return float4(min(max4, max(min4, aC * rcpf(aW))), 1.0);
    }

    struct Rcas { float sharp; float w; float h; float ox; float oy; float pad0; float pad1; float pad2; };

    // ffx_fsr1.h FsrRcasF (32-bit, no denoise)
    fragment float4 mcRcas(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant Rcas &u [[buffer(0)]]) {
        int2 size = int2(int(u.w), int(u.h));
        int2 sp = int2(in.pos.xy) - int2(int(u.ox), int(u.oy));
        float3 b = texel(t, sp + int2(0, -1), size);
        float3 d = texel(t, sp + int2(-1, 0), size);
        float3 e = texel(t, sp, size);
        float3 f = texel(t, sp + int2(1, 0), size);
        float3 h = texel(t, sp + int2(0, 1), size);
        float3 mn4 = min(min(b, d), min(f, h));
        float3 mx4 = max(max(b, d), max(f, h));
        float3 hitMin = min(mn4, e) / max(4.0 * mx4, float3(1.0e-5));
        float3 hitMax = (1.0 - max(mx4, e)) / min(4.0 * mn4 - 4.0, float3(-1.0e-5));
        float3 lobeRGB = max(-hitMin, hitMax);
        float lobe = max(-(0.25 - 1.0 / 16.0), min(max(lobeRGB.r, max(lobeRGB.g, lobeRGB.b)), 0.0)) * u.sharp;
        return float4((lobe * (b + d + h + f) + e) / (4.0 * lobe + 1.0), 1.0);
    }
    """
}

/// Decodes compressed frames (the players' CMSampleBuffers) to NV12 for MCFsrView, with VideoToolbox.
@objc(MCFsrDecoder)
final class MCFsrDecoder: NSObject {
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private weak var view: MCFsrView?

    @objc init(view: MCFsrView) { self.view = view }

    @objc func decode(_ sb: CMSampleBuffer) {
        guard let fd = CMSampleBufferGetFormatDescription(sb) else { return }
        if session == nil || format.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: fd) }) ?? true {
            invalidate()
            format = fd
            let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                         kCVPixelBufferMetalCompatibilityKey: true]
            var s: VTDecompressionSession?
            VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil,
                                         imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &s)
            session = s
            if let s = s { VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue) }
        }
        guard let s = session else { return }
        VTDecompressionSessionDecodeFrame(s, sampleBuffer: sb, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            guard status == noErr, let pb = image else { return }
            self?.view?.display(pb)
        }
    }

    @objc func invalidate() {
        if let s = session { VTDecompressionSessionInvalidate(s) }
        session = nil
    }

    deinit { invalidate() }
}
