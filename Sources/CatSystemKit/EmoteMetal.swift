#if canImport(Metal)
import Foundation
@preconcurrency import Metal

/// Draws E-mote characters with Metal: each image of an `EmoteDrawList` is a grid of
/// triangles whose points the vertex shader carries up the node chain (Bézier patch in the
/// node's box, then its transform) to the target's pixels; stencils are masks rendered
/// first into small R8 textures (the coverage of their layers, as the CPU renderer does)
/// and multiplied in. Textures are uploaded once per model, premultiplied, with mipmaps.
///
/// `EmoteRenderer.render` (the CPU) is the reference: `cs2-cli emotecompare` draws a pose
/// both ways and reports how far apart they are.
public final class EmoteGPU: @unchecked Sendable {
    public let device: MTLDevice
    public let pixelFormat: MTLPixelFormat
    private let itemPipeline: MTLRenderPipelineState
    private let maskPipeline: MTLRenderPipelineState
    private let quadPipeline: MTLRenderPipelineState
    private let premultiply: MTLComputePipelineState
    private let sampler: MTLSamplerState
    private let plainSampler: MTLSamplerState
    private let lock = NSLock()
    // Keyed by the model's identity, not its address: a model freed and another allocated at
    // the same address drew with the first one's atlas (NEKOPARA Vol. 0's third character in
    // scattered pieces once several models had come and gone).
    private var textures: [UInt64: [MTLTexture]] = [:]
    private var textureOrder: [UInt64] = []
    private var pool: [String: [MTLTexture]] = [:]
    /// Mipmapped, trilinear sampling (on); off samples the base level only, as the CPU does.
    public let mipmaps: Bool
    public var textureLimit = 6

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice(), pixelFormat: MTLPixelFormat = .bgra8Unorm, mipmaps: Bool = true) {
        guard let device, let library = try? device.makeLibrary(source: Self.shaders, options: nil) else { return nil }
        self.device = device
        self.pixelFormat = pixelFormat
        self.mipmaps = mipmaps
        func pipeline(_ vertex: String, _ fragment: String, format: MTLPixelFormat) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            let a = d.colorAttachments[0]!
            a.pixelFormat = format
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let item = pipeline("emoteVertex", "emoteFragment", format: pixelFormat),
              let mask = pipeline("emoteVertex", "emoteMaskFragment", format: .r8Unorm),
              let quad = pipeline("quadVertex", "quadFragment", format: pixelFormat),
              let kernel = library.makeFunction(name: "premultiply"),
              let compute = try? device.makeComputePipelineState(function: kernel) else { return nil }
        itemPipeline = item
        maskPipeline = mask
        quadPipeline = quad
        premultiply = compute
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear; s.magFilter = .linear
        s.mipFilter = mipmaps ? .linear : .notMipmapped
        s.sAddressMode = .clampToEdge; s.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: s) else { return nil }
        self.sampler = sampler
        s.mipFilter = .notMipmapped
        guard let plain = device.makeSamplerState(descriptor: s) else { return nil }
        plainSampler = plain
    }

    // MARK: Textures

    private var uploading: Set<UInt64> = []

    /// Whether the model's textures are on the GPU; if not, they are uploaded in the
    /// background (so a frame never waits for a large atlas).
    public func texturesReady(for model: EmoteModel) -> Bool {
        let key = model.identity
        lock.lock()
        let ready = textures[key] != nil
        let start = !ready && !uploading.contains(key)
        if start { uploading.insert(key) }
        lock.unlock()
        if start {
            nonisolated(unsafe) let model = model
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                _ = self.textures(for: model)
                self.lock.withLock { _ = self.uploading.remove(key) }
            }
        }
        return ready
    }

    /// The model's textures on the GPU (uploaded on first use; the last few models kept).
    public func textures(for model: EmoteModel) -> [MTLTexture]? {
        let key = model.identity
        lock.lock()
        if let hit = textures[key] {
            textureOrder.removeAll { $0 == key }
            textureOrder.append(key)
            lock.unlock()
            return hit
        }
        lock.unlock()
        guard let queue = device.makeCommandQueue(), let buffer = queue.makeCommandBuffer() else { return nil }
        var out: [MTLTexture] = []
        for t in model.textures {
            guard t.width > 0, t.height > 0 else { return nil }
            let staging = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: t.width, height: t.height, mipmapped: false)
            staging.usage = .shaderRead
            staging.storageMode = .shared
            let final = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: t.width, height: t.height, mipmapped: mipmaps)
            final.usage = [.shaderRead, .shaderWrite]
            final.storageMode = .private
            guard let source = device.makeTexture(descriptor: staging), let texture = device.makeTexture(descriptor: final) else { return nil }
            t.pixels.withUnsafeBytes { raw in
                source.replace(region: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0,
                               withBytes: raw.baseAddress!, bytesPerRow: t.width * 4)
            }
            // B, G, R, A straight → R, G, B, A premultiplied.
            guard let compute = buffer.makeComputeCommandEncoder() else { return nil }
            compute.setComputePipelineState(premultiply)
            compute.setTexture(source, index: 0)
            compute.setTexture(texture, index: 1)
            let group = MTLSize(width: 16, height: 16, depth: 1)
            compute.dispatchThreadgroups(MTLSize(width: (t.width + 15) / 16, height: (t.height + 15) / 16, depth: 1), threadsPerThreadgroup: group)
            compute.endEncoding()
            if mipmaps, let blit = buffer.makeBlitCommandEncoder() {
                blit.generateMipmaps(for: texture)
                blit.endEncoding()
            }
            out.append(texture)
        }
        buffer.commit()
        buffer.waitUntilCompleted()
        lock.lock()
        textures[key] = out
        textureOrder.append(key)
        while textureOrder.count > textureLimit { textures[textureOrder.removeFirst()] = nil }
        lock.unlock()
        return out
    }

    // MARK: Scratch textures

    /// A render target from the pool (`size` rounded up), handed back when `buffer` completes.
    public func scratch(width: Int, height: Int, format: MTLPixelFormat, for buffer: MTLCommandBuffer) -> MTLTexture? {
        let w = (max(1, width) + 31) / 32 * 32, h = (max(1, height) + 31) / 32 * 32
        let key = "\(format.rawValue):\(w)x\(h)"
        lock.lock()
        var texture = pool[key]?.popLast()
        lock.unlock()
        if texture == nil {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            texture = device.makeTexture(descriptor: d)
        }
        guard let texture else { return nil }
        buffer.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.pool[key, default: []].append(texture)
            self.lock.unlock()
        }
        return texture
    }

    // MARK: Drawing

    /// A draw list ready for a render pass: its buffers and its stencils' masks (rendered
    /// into `buffer` by `prepare`, so before the pass that draws the items begins).
    public struct Prepared {
        let list: EmoteDrawList
        let textures: [MTLTexture]
        let nodes: MTLBuffer
        let meshes: MTLBuffer
        let masks: [(texture: MTLTexture, x: Float, y: Float)?]
        /// How many images it draws.
        public var itemCount: Int { list.items.count }
    }

    struct ItemUniforms {
        var rect: SIMD4<Float>
        var origin: SIMD2<Float>
        var textureSize: SIMD2<Float>
        var viewport: SIMD2<Float>
        var offset: SIMD2<Float>
        var node: Int32
        var divisions: Int32
        var opacity: Float
        var clipCount: Int32
        var clip0: SIMD4<Float>
        var clip1: SIMD4<Float>
    }

    /// Uploads `list`'s nodes and renders its masks. Nil when the model's textures can't be
    /// made.
    public func prepare(_ list: EmoteDrawList, model: EmoteModel, buffer: MTLCommandBuffer) -> Prepared? {
        guard let textures = textures(for: model) else { return nil }
        let nodes = list.nodes.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: max(16, $0.count)) }
        let meshes = list.meshes.isEmpty ? device.makeBuffer(length: 16) : list.meshes.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
        guard let nodes, let meshes else { return nil }
        var masks: [(texture: MTLTexture, x: Float, y: Float)?] = []
        for stencil in list.stencils {
            guard stencil.minX.isFinite, stencil.maxX > stencil.minX, stencil.maxY > stencil.minY,
                  stencil.maxX - stencil.minX < 8192, stencil.maxY - stencil.minY < 8192 else { masks.append(nil); continue }
            let x = stencil.minX.rounded(.down), y = stencil.minY.rounded(.down)
            let w = Int((stencil.maxX - x).rounded(.up)), h = Int((stencil.maxY - y).rounded(.up))
            guard let texture = scratch(width: w, height: h, format: .r8Unorm, for: buffer) else { masks.append(nil); continue }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { masks.append(nil); continue }
            encoder.setRenderPipelineState(maskPipeline)
            encoder.setVertexBuffer(nodes, offset: 0, index: 1)
            encoder.setVertexBuffer(meshes, offset: 0, index: 2)
            encoder.setFragmentSamplerState(mipmaps ? sampler : plainSampler, index: 0)
            let viewport = SIMD2<Float>(Float(texture.width), Float(texture.height))
            for item in stencil.items {
                encode(item, textures: textures, encoder: encoder, viewport: viewport, offset: SIMD2(x, y), opacity: 1, clips: [])
            }
            encoder.endEncoding()
            masks.append((texture, x, y))
        }
        return Prepared(list: list, textures: textures, nodes: nodes, meshes: meshes, masks: masks)
    }

    /// Draws a prepared list into the current pass (a `width`×`height` target), its
    /// opacity multiplied by `opacity`.
    public func draw(_ p: Prepared, encoder: MTLRenderCommandEncoder, width: Int, height: Int, opacity: Float = 1) {
        encoder.setRenderPipelineState(itemPipeline)
        encoder.setVertexBuffer(p.nodes, offset: 0, index: 1)
        encoder.setVertexBuffer(p.meshes, offset: 0, index: 2)
        encoder.setFragmentSamplerState(mipmaps ? sampler : plainSampler, index: 0)
        let viewport = SIMD2<Float>(Float(width), Float(height))
        for item in p.list.items {
            let clips = item.clips.compactMap { $0 < p.masks.count ? p.masks[$0] : nil }
            // A clip whose mask couldn't be made hides the item, as an empty mask would.
            guard clips.count == item.clips.count else { continue }
            encode(item, textures: p.textures, encoder: encoder, viewport: viewport, offset: .zero, opacity: opacity, clips: clips)
        }
    }

    private func encode(_ item: EmoteDrawList.Item, textures: [MTLTexture], encoder: MTLRenderCommandEncoder,
                        viewport: SIMD2<Float>, offset: SIMD2<Float>, opacity: Float,
                        clips: [(texture: MTLTexture, x: Float, y: Float)]) {
        guard item.texture < textures.count, item.divisions > 0 else { return }
        let texture = textures[item.texture]
        func clip(_ i: Int) -> SIMD4<Float> {
            guard i < clips.count else { return .zero }
            let c = clips[i]
            return SIMD4(c.x, c.y, 1 / Float(c.texture.width), 1 / Float(c.texture.height))
        }
        var u = ItemUniforms(rect: SIMD4(Float(item.left), Float(item.top), Float(item.width), Float(item.height)),
                             origin: SIMD2(item.originX, item.originY),
                             textureSize: SIMD2(Float(texture.width), Float(texture.height)),
                             viewport: viewport, offset: offset, node: Int32(item.node), divisions: Int32(item.divisions),
                             opacity: item.opacity * opacity, clipCount: Int32(min(2, clips.count)), clip0: clip(0), clip1: clip(1))
        encoder.setVertexBytes(&u, length: MemoryLayout<ItemUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<ItemUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentTexture(clips.count > 0 ? clips[0].texture : texture, index: 1)
        encoder.setFragmentTexture(clips.count > 1 ? clips[1].texture : texture, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: item.divisions * item.divisions * 6)
    }

    /// A textured rectangle (premultiplied) in a `width`×`height` target: `rect` in target
    /// pixels, `source` the part of the texture (0–1), faded by `opacity`.
    public func drawQuad(_ texture: MTLTexture, encoder: MTLRenderCommandEncoder, width: Int, height: Int,
                         rect: SIMD4<Float>, source: SIMD4<Float> = SIMD4(0, 0, 1, 1), opacity: Float = 1) {
        var u = SIMD4<Float>(rect.x / Float(width) * 2 - 1, 1 - rect.y / Float(height) * 2,
                             rect.z / Float(width) * 2, -rect.w / Float(height) * 2)
        var s = source
        var o = opacity
        encoder.setRenderPipelineState(quadPipeline)
        encoder.setVertexBytes(&u, length: 16, index: 0)
        encoder.setVertexBytes(&s, length: 16, index: 1)
        encoder.setFragmentBytes(&o, length: 4, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(plainSampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    // MARK: Headless

    /// Draws `list` into a `width`×`height` premultiplied RGBA image (for comparisons with the
    /// CPU renderer).
    public func image(_ list: EmoteDrawList, model: EmoteModel, width: Int, height: Int) -> [UInt8]? {
        guard pixelFormat == .rgba8Unorm || pixelFormat == .bgra8Unorm,
              let queue = device.makeCommandQueue(), let buffer = queue.makeCommandBuffer() else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = device.makeTexture(descriptor: d), let prepared = prepare(list, model: model, buffer: buffer) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        draw(prepared, encoder: encoder, width: width, height: height)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        var out = [UInt8](repeating: 0, count: width * height * 4)
        out.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        if pixelFormat == .bgra8Unorm {
            for i in stride(from: 0, to: out.count, by: 4) { out.swapAt(i, i + 2) }
        }
        return out
    }

    static let shaders = """
    #include <metal_stdlib>
    using namespace metal;

    struct Node { float a, b, c, d, tx, ty, boxX, boxY, boxW, boxH; int parent; int mesh; };
    struct ItemUniforms {
        float4 rect; float2 origin; float2 textureSize; float2 viewport; float2 offset;
        int node; int divisions; float opacity; int clipCount;
        float4 clip0; float4 clip1;
    };
    struct VOut { float4 position [[position]]; float2 uv; };

    static float2 patch(constant float2 *p, float2 uv) {
        float u = uv.x, v = uv.y, iu = 1 - u, iv = 1 - v;
        float4 bu = float4(iu * iu * iu, 3 * u * iu * iu, 3 * u * u * iu, u * u * u);
        float4 bv = float4(iv * iv * iv, 3 * v * iv * iv, 3 * v * v * iv, v * v * v);
        float2 r = 0;
        for (int row = 0; row < 4; row++) {
            float2 x = bu.x * p[row * 4] + bu.y * p[row * 4 + 1] + bu.z * p[row * 4 + 2] + bu.w * p[row * 4 + 3];
            r += bv[row] * x;
        }
        return r;
    }

    vertex VOut emoteVertex(uint vid [[vertex_id]], constant ItemUniforms &u [[buffer(0)]],
                            constant Node *nodes [[buffer(1)]], constant float2 *meshes [[buffer(2)]]) {
        const uint2 corners[6] = { uint2(0, 0), uint2(1, 0), uint2(1, 1), uint2(0, 0), uint2(1, 1), uint2(0, 1) };
        uint n = uint(u.divisions);
        uint cell = vid / 6;
        uint2 g = uint2(cell % n, cell / n) + corners[vid % 6];
        float2 f = float2(g) / float(n);
        float2 p = u.rect.zw * f - u.origin;
        int k = u.node;
        for (int guard = 0; k >= 0 && guard < 96; guard++) {
            Node nd = nodes[k];
            if (nd.mesh >= 0) {
                float2 box = float2(nd.boxW, nd.boxH), o = float2(nd.boxX, nd.boxY);
                p = patch(meshes + nd.mesh, (p + o) / box) * box - o;
            }
            p = float2(nd.a * p.x + nd.c * p.y + nd.tx, nd.b * p.x + nd.d * p.y + nd.ty);
            k = nd.parent;
        }
        p -= u.offset;
        VOut out;
        out.position = float4(p.x / u.viewport.x * 2 - 1, 1 - p.y / u.viewport.y * 2, 0, 1);
        out.uv = u.rect.xy + u.rect.zw * f;
        return out;
    }

    static float4 texel(ItemUniforms u, float2 uv, texture2d<float> t, sampler s) {
        // Inside the image's own rectangle (the atlas packs images edge to edge).
        float2 lo = u.rect.xy + 0.5, hi = u.rect.xy + u.rect.zw - 0.5;
        return t.sample(s, clamp(uv, lo, hi) / u.textureSize);
    }

    fragment float4 emoteFragment(VOut in [[stage_in]], constant ItemUniforms &u [[buffer(0)]],
                                  texture2d<float> t [[texture(0)]], texture2d<float> m0 [[texture(1)]],
                                  texture2d<float> m1 [[texture(2)]], sampler s [[sampler(0)]]) {
        constexpr sampler ms(coord::normalized, address::clamp_to_zero, filter::nearest);
        float k = u.opacity;
        if (u.clipCount > 0) k *= m0.sample(ms, (in.position.xy - u.clip0.xy) * u.clip0.zw).r;
        if (u.clipCount > 1) k *= m1.sample(ms, (in.position.xy - u.clip1.xy) * u.clip1.zw).r;
        return texel(u, in.uv, t, s) * k;
    }

    fragment float4 emoteMaskFragment(VOut in [[stage_in]], constant ItemUniforms &u [[buffer(0)]],
                                      texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
        float a = texel(u, in.uv, t, s).a;
        return float4(a, a, a, a);
    }

    struct QOut { float4 position [[position]]; float2 uv; };

    vertex QOut quadVertex(uint vid [[vertex_id]], constant float4 &r [[buffer(0)]], constant float4 &s [[buffer(1)]]) {
        float2 c = float2(vid & 1, vid >> 1);
        QOut out;
        out.position = float4(r.xy + r.zw * c, 0, 1);
        out.uv = s.xy + s.zw * c;
        return out;
    }

    fragment float4 quadFragment(QOut in [[stage_in]], constant float &opacity [[buffer(0)]],
                                 texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
        return t.sample(s, in.uv) * opacity;
    }

    kernel void premultiply(texture2d<float, access::read> source [[texture(0)]],
                            texture2d<float, access::write> target [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= target.get_width() || gid.y >= target.get_height()) return;
        float4 c = source.read(gid).bgra;
        target.write(float4(c.rgb * c.a, c.a), gid);
    }
    """
}
#endif
