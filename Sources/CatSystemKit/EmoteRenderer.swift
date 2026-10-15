// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation

/// A drawn E-mote character: premultiplied RGBA with the model's origin at (originX, originY).
public struct EmoteImage: Sendable {
    public let width: Int
    public let height: Int
    public let originX: Int
    public let originY: Int
    /// Premultiplied RGBA, top row first.
    public let rgba: [UInt8]
}

/// Draws an E-mote model's pose for a set of variables, on the CPU.
///
/// Each layer becomes a node with its frame's transform (position, angle, zoom, flips) and,
/// for deformers, its Bézier patch. An image is cut into a grid (the layer's
/// `meshDivision` when a patch bends it, else one quad) whose points are carried up
/// through every ancestor: bent by the ancestor's patch in the ancestor's own box, then
/// moved by its transform. Layers draw in their motion's priority order (a referenced
/// motion draws where its layer stands), and stencils clip their descendants to the
/// coverage of their mask layers.
public final class EmoteRenderer: @unchecked Sendable {
    public let model: EmoteModel
    /// The object and motion drawn, when not the model's base (a plain motion file's player
    /// plays one of its motions by name).
    public var object: String?
    public var motion: String?
    /// Collects shape layers while a pose is evaluated (for `shapes`).
    private var shapeSink: ((EmoteModel.Layer, Node) -> Void)?

    /// Labels some stencil masks with: only their items are collected per layer.
    private let maskLabels: Set<String>
    /// Blank layers' boxes by their `w:h:ox:oy` text (parsed once).
    private var blankBoxes: [String: EmoteModel.Icon?] = [:]
    private let blankLock = NSLock()

    public init(model: EmoteModel) {
        self.model = model
        var labels = Set<String>()
        func collect(_ layers: [EmoteModel.Layer]) {
            for layer in layers {
                labels.formUnion(layer.maskLabels)
                collect(layer.children)
            }
        }
        for motions in model.objects.values {
            for motion in motions.values { collect(motion.layers) }
        }
        maskLabels = labels
    }

    private func blankBox(_ text: String) -> EmoteModel.Icon? {
        blankLock.lock()
        defer { blankLock.unlock() }
        if let hit = blankBoxes[text] { return hit }
        let box = Self.blankBox(text)
        blankBoxes[text] = box
        return box
    }

    // MARK: Evaluation

    final class Node {
        let parent: Node?
        // Local → parent: p' = M p + t, after the patch.
        var a = 1.0, b = 0.0, c = 0.0, d = 1.0, tx = 0.0, ty = 0.0
        var mesh: [Double]?
        var boxW = 1.0, boxH = 1.0, boxX = 0.0, boxY = 0.0
        var opacity = 1.0
        /// Depth: the sum of `coord`'s z down the tree; items draw from low to high.
        var z = 0.0
        let bent: Bool

        init(parent: Node?, bends: Bool) {
            self.parent = parent
            bent = bends || (parent?.bent ?? false)
        }

        @inline(__always) func toParent(_ x: Double, _ y: Double) -> (Double, Double) {
            var px = x, py = y
            if let mesh {
                let u = (px + boxX) / boxW, v = (py + boxY) / boxH
                let q = EmoteRenderer.patch(mesh, u, v)
                px = q.0 * boxW - boxX
                py = q.1 * boxH - boxY
            }
            return (a * px + c * py + tx, b * px + d * py + ty)
        }

        func toRoot(_ x: Double, _ y: Double) -> (Double, Double) {
            var p = (x, y)
            var node: Node? = self
            while let n = node {
                p = n.toParent(p.0, p.1)
                node = n.parent
            }
            return p
        }
    }

    final class Stencil {
        let labels: [String]
        let instance: Instance
        var mask: [UInt8]?
        init(labels: [String], instance: Instance) {
            self.labels = labels
            self.instance = instance
        }
    }

    struct Item {
        let node: Node
        let texture: EmoteModel.Texture
        let textureIndex: Int
        let icon: EmoteModel.Icon
        let divisions: Int
        let opacity: Double
        let clips: [Stencil]
        let motionName: String
        let layerLabel: String
        /// `motion/layer`, for listings.
        var label: String { motionName + "/" + layerLabel }
    }

    /// The items `render` would draw, back to front: label, icon, place and stencils.
    public func listing(variables: [String: Double], time: Double = 0) -> [String] {
        let (items, instances) = items(variables: variables, time: time, root: Node(parent: nil, bends: false))
        defer { for instance in instances { instance.subtree = [:] } }
        return items.map { item in
            let p = item.node.toRoot(0, 0)
            let clips = item.clips.isEmpty ? "" : " clipped by " + item.clips.map { $0.labels.joined(separator: "+") }.joined(separator: ", ")
            return "\(item.label) \(item.icon.width)×\(item.icon.height) at \(Int(p.0)),\(Int(p.1)) opacity \(item.opacity)\(clips)"
        }
    }

    /// Where the first image of a layer whose label contains `name` (`輪郭`, the face's
    /// outline) is placed, in the model's coordinates: its icon's origin.
    public func position(ofLayer name: String, variables: [String: Double], time: Double = 0) -> (x: Double, y: Double)? {
        let (items, instances) = items(variables: variables, time: time, root: Node(parent: nil, bends: false))
        defer { for instance in instances { instance.subtree = [:] } }
        guard let item = items.first(where: { $0.label.contains(name) }) else { return nil }
        let p = item.node.toRoot(0, 0)
        return (p.0, p.1)
    }

    final class Instance {
        /// Items by layer label, with every descendant's items (for stencil masks).
        var subtree: [String: [Item]] = [:]
    }

    /// Evaluates the model and returns its items back to front (root transform `root`),
    /// with the motion instances (whose `subtree` the caller clears when done: stencils
    /// and instances refer to each other).
    /// Runs `body` with `sink` collecting shape layers.
    func withShapeSink(_ sink: @escaping (EmoteModel.Layer, Node) -> Void, _ body: () -> Void) {
        shapeSink = sink
        defer { shapeSink = nil }
        body()
    }

    func items(variables: [String: Double], time: Double, root: Node) -> (items: [Item], instances: [Instance]) {
        let motionName = self.motion ?? model.baseMotion
        guard let motion = model.objects[object ?? model.baseObject]?[motionName] else { return ([], []) }
        var instances: [Instance] = []
        var items: [Item] = []
        items.reserveCapacity(256)
        evaluate(motion, named: motionName, time: time, parent: root, clips: [], variables: variables,
                 instances: &instances, depth: 0, into: &items)
        return (items, instances)
    }

    /// Appends the motion's items to `out`, back to front in tree order (no copies of partial
    /// lists: drawing several characters a frame spends its time here).
    private func evaluate(_ motion: EmoteModel.Motion, named motionName: String, time: Double, parent: Node, clips: [Stencil],
                          variables: [String: Double], instances: inout [Instance], depth: Int, into out: inout [Item]) {
        guard depth < 16 else { return }
        let instance = Instance()
        instances.append(instance)

        func layerTime(_ layer: EmoteModel.Layer) -> Double {
            guard let index = layer.parameterize ?? motion.defaultParameter, index >= 0, index < motion.parameters.count else { return time }
            let p = motion.parameters[index]
            let range = p.rangeEnd - p.rangeBegin
            guard abs(range) > 1e-7 else { return 0 }
            let value = min(max(variables[p.id] ?? p.rangeBegin, min(p.rangeBegin, p.rangeEnd)), max(p.rangeBegin, p.rangeEnd))
            var normalized = (value - p.rangeBegin) / range
            if p.discrete {
                let steps = abs(range).rounded() >= 1 && abs(abs(range) - abs(range).rounded()) < 1e-7 ? abs(range).rounded() : p.division
                if steps > 0 { normalized = (normalized * steps).rounded() / steps }
            }
            normalized = min(1, max(0, normalized))
            let end = motion.lastTime > 0 ? max(0, motion.lastTime - 1) : max(0, p.division)
            return normalized * end
        }

        func visit(_ layer: EmoteModel.Layer, parent: Node, clips: [Stencil], into out: inout [Item]) {
            let state = Self.state(layer, at: layerTime(layer))
            guard state != nil || layer.type == 2 else { return }
            let first = out.count
            let content = state ?? EmoteModel.Content()
            let src = content.src ?? ""
            var bends = content.mesh != nil
            var icon: EmoteModel.Icon?
            if layer.type == 0, src == "blank", let i = content.icon { icon = blankBox(i) }
            if layer.type == 0, src != "blank", let i = content.icon { icon = model.sources[src]?.icons[i] }
            if icon == nil { bends = false }
            let node = Node(parent: parent, bends: bends)
            Self.place(node, content)
            if bends, let box = icon {
                node.mesh = content.mesh
                node.boxW = Double(max(1, box.width)); node.boxH = Double(max(1, box.height))
                node.boxX = box.originX; node.boxY = box.originY
            }
            node.opacity = parent.opacity * (state == nil ? 1 : content.opacity)
            node.z = parent.z + content.z
            if state != nil, layer.type == 1, layer.shape != nil { shapeSink?(layer, node) }

            if state != nil {
                switch layer.type {
                case 0 where src != "blank":
                    if let icon, let source = model.sources[src], let texture = source.texture,
                       let textureIndex = source.textureIndex, node.opacity > 0 {
                        out.append(Item(node: node, texture: texture, textureIndex: textureIndex, icon: icon,
                                        divisions: node.bent ? max(1, min(32, layer.meshDivision)) : 1,
                                        opacity: node.opacity, clips: clips, motionName: motionName, layerLabel: layer.label))
                    }
                case 3:
                    if let object = content.src, let name = content.icon, let sub = model.objects[object]?[name] {
                        evaluate(sub, named: name, time: Self.playTime(time + content.timeOffset, of: sub), parent: node, clips: clips,
                                 variables: variables, instances: &instances, depth: depth + 1, into: &out)
                    }
                default:
                    break
                }
            }

            var childClips = clips
            if layer.type == 12, state != nil, !layer.maskLabels.isEmpty {
                childClips.append(Stencil(labels: layer.maskLabels, instance: instance))
            }
            for child in layer.children { visit(child, parent: node, clips: childClips, into: &out) }
            // Only labels a stencil masks with need their subtree's items.
            if maskLabels.contains(layer.label), out.count > first {
                instance.subtree[layer.label, default: []] += out[first...]
            }
        }

        for layer in motion.layers { visit(layer, parent: parent, clips: clips, into: &out) }
    }

    /// Where a motion is at `time` from its start: past its last frame it loops back to
    /// `loopTime`, or holds just before its end keys (which end its layers) when it doesn't loop.
    public static func playTime(_ time: Double, of motion: EmoteModel.Motion) -> Double {
        guard motion.lastTime > 0, time > motion.lastTime else { return time }
        if motion.loopTime >= 0, motion.lastTime > motion.loopTime {
            return motion.loopTime + (time - motion.loopTime).truncatingRemainder(dividingBy: motion.lastTime - motion.loopTime)
        }
        return max(0, motion.lastTime - 0.001)
    }

    /// A frame list's content at `time`, or nil when nothing shows then.
    static func state(_ layer: EmoteModel.Layer, at time: Double) -> EmoteModel.Content? {
        // The last frame at or before `time` (frames are in time order): a binary search.
        let frames = layer.frames
        var lo = 0, hi = frames.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if frames[mid].time <= time { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return nil }
        let i = lo - 1
        let a = layer.frames[i]
        guard a.type != 0 else { return nil }
        guard a.type == 3, i + 1 < layer.frames.count else { return a.content }
        let b = layer.frames[i + 1]
        let span = b.time - a.time
        guard span > 0, b.type != 0 else { return a.content }
        let t = min(1, max(0, (time - a.time) / span))
        guard t > 0 else { return a.content }
        var c = a.content
        let n = b.content
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        c.x = mix(c.x, n.x); c.y = mix(c.y, n.y); c.z = mix(c.z, n.z)
        c.ox = mix(c.ox, n.ox); c.oy = mix(c.oy, n.oy)
        c.angle = mix(c.angle, n.angle)
        c.scaleX = mix(c.scaleX, n.scaleX); c.scaleY = mix(c.scaleY, n.scaleY)
        c.slantX = mix(c.slantX, n.slantX); c.slantY = mix(c.slantY, n.slantY)
        c.opacity = mix(c.opacity, n.opacity)
        if c.mesh != nil || n.mesh != nil {
            let p = c.mesh ?? identityPatch, q = n.mesh ?? identityPatch
            c.mesh = zip(p, q).map { $0 + ($1 - $0) * t }
        }
        return c
    }

    static let identityPatch: [Double] = (0..<16).flatMap { i in [Double(i % 4) / 3, Double(i / 4) / 3] }

    /// `w:h:ox:oy`, a blank layer's box.
    static func blankBox(_ text: String) -> EmoteModel.Icon? {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        return EmoteModel.Icon(left: 0, top: 0, width: Int(parts[0]), height: Int(parts[1]), originX: parts[2], originY: parts[3])
    }

    /// The frame's transform: flip, slant, zoom, then rotate (the models' `transformOrder`
    /// 0, 3, 2, 1), then move to `coord`.
    static func place(_ node: Node, _ c: EmoteModel.Content) {
        var a = c.flipX ? -1.0 : 1.0, b = 0.0, cc = 0.0, d = c.flipY ? -1.0 : 1.0
        if c.slantX != 0 || c.slantY != 0 {
            let sx = tan(c.slantX * .pi / 180), sy = tan(c.slantY * .pi / 180)
            b = sy * a; cc = sx * d
        }
        a *= c.scaleX; cc *= c.scaleX
        b *= c.scaleY; d *= c.scaleY
        if c.angle != 0 {
            let r = c.angle * .pi / 180, cs = cos(r), sn = sin(r)
            (a, b, cc, d) = (cs * a - sn * b, sn * a + cs * b, cs * cc - sn * d, sn * cc + cs * d)
        }
        node.a = a; node.b = b; node.c = cc; node.d = d
        node.tx = c.x - (a * c.ox + cc * c.oy)
        node.ty = c.y - (b * c.ox + d * c.oy)
    }

    /// A bicubic Bézier patch (16 points, rows of four) at (u, v).
    @inline(__always) static func patch(_ p: [Double], _ u: Double, _ v: Double) -> (Double, Double) {
        let iu = 1 - u, iv = 1 - v
        let bu = (iu * iu * iu, 3 * u * iu * iu, 3 * u * u * iu, u * u * u)
        let bv = (iv * iv * iv, 3 * v * iv * iv, 3 * v * v * iv, v * v * v)
        var x = 0.0, y = 0.0
        p.withUnsafeBufferPointer { q in
            for row in 0..<4 {
                let wv = row == 0 ? bv.0 : row == 1 ? bv.1 : row == 2 ? bv.2 : bv.3
                let o = row * 8
                let rx = bu.0 * q[o] + bu.1 * q[o + 2] + bu.2 * q[o + 4] + bu.3 * q[o + 6]
                let ry = bu.0 * q[o + 1] + bu.1 * q[o + 3] + bu.2 * q[o + 5] + bu.3 * q[o + 7]
                x += wv * rx
                y += wv * ry
            }
        }
        return (x, y)
    }

    // MARK: Drawing

    /// The pose for `variables` at `time` (frames, for clock-driven layers), drawn at `scale`.
    public func render(variables: [String: Double], time: Double = 0, scale: Double = 1) -> EmoteImage {
        let root = Node(parent: nil, bends: false)
        root.a = scale; root.d = scale
        let (unsorted, instances) = items(variables: variables, time: time, root: root)
        // Back to front by depth, keeping the tree's order among equals (as M2's player).
        let items = unsorted.enumerated().sorted { ($0.element.node.z, $0.offset) < ($1.element.node.z, $1.offset) }.map(\.element)
        defer { for instance in instances { instance.subtree = [:] } }

        // Every item's grid in output coordinates.
        struct Mesh { let item: Item; let points: [Float]; let n: Int }
        var meshes: [Mesh] = []
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        var gridCache: [ObjectIdentifier: [Float]] = [:]
        func grid(_ item: Item) -> [Float] {
            let key = ObjectIdentifier(item.node)
            if let hit = gridCache[key] { return hit }
            let n = item.divisions
            var pts = [Float](repeating: 0, count: (n + 1) * (n + 1) * 2)
            let w = Double(item.icon.width), h = Double(item.icon.height)
            for j in 0...n {
                for i in 0...n {
                    let lx = w * Double(i) / Double(n) - item.icon.originX
                    let ly = h * Double(j) / Double(n) - item.icon.originY
                    let p = item.node.toRoot(lx, ly)
                    pts[(j * (n + 1) + i) * 2] = Float(p.0)
                    pts[(j * (n + 1) + i) * 2 + 1] = Float(p.1)
                }
            }
            gridCache[key] = pts
            return pts
        }
        for item in items {
            let pts = grid(item)
            meshes.append(Mesh(item: item, points: pts, n: item.divisions))
            for k in stride(from: 0, to: pts.count, by: 2) {
                minX = min(minX, Double(pts[k])); maxX = max(maxX, Double(pts[k]))
                minY = min(minY, Double(pts[k + 1])); maxY = max(maxY, Double(pts[k + 1]))
            }
        }
        guard minX.isFinite, maxX - minX < 16384, maxY - minY < 16384 else {
            return EmoteImage(width: 0, height: 0, originX: 0, originY: 0, rgba: [])
        }
        let x0 = Int(minX.rounded(.down)) - 1, y0 = Int(minY.rounded(.down)) - 1
        let width = Int(maxX.rounded(.up)) - x0 + 2, height = Int(maxY.rounded(.up)) - y0 + 2
        var canvas = [UInt8](repeating: 0, count: width * height * 4)

        func maskBuffer(_ stencil: Stencil) -> [UInt8] {
            if let m = stencil.mask { return m }
            var m = [UInt8](repeating: 0, count: width * height)
            for label in stencil.labels {
                for item in stencil.instance.subtree[label] ?? [] {
                    Self.rasterize(texture: item.texture, icon: item.icon, points: grid(item), n: item.divisions,
                                   width: width, height: height, x0: x0, y0: y0, opacity: 1, masks: []) { o, _, _, _, a in
                        m[o] = UInt8(min(255, Int(m[o]) + (Int(a) * (255 - Int(m[o])) + 127) / 255))
                    }
                }
            }
            stencil.mask = m
            return m
        }

        canvas.withUnsafeMutableBufferPointer { dst in
            for mesh in meshes {
                let masks = mesh.item.clips.map { maskBuffer($0) }
                Self.rasterize(texture: mesh.item.texture, icon: mesh.item.icon, points: mesh.points, n: mesh.n,
                               width: width, height: height, x0: x0, y0: y0, opacity: mesh.item.opacity, masks: masks) { o, r, g, b, a in
                    let d = o * 4
                    let ia = 255 - Int(a)
                    dst[d] = UInt8(min(255, Int(r) + (Int(dst[d]) * ia + 127) / 255))
                    dst[d + 1] = UInt8(min(255, Int(g) + (Int(dst[d + 1]) * ia + 127) / 255))
                    dst[d + 2] = UInt8(min(255, Int(b) + (Int(dst[d + 2]) * ia + 127) / 255))
                    dst[d + 3] = UInt8(min(255, Int(a) + (Int(dst[d + 3]) * ia + 127) / 255))
                }
            }
        }
        return EmoteImage(width: width, height: height, originX: -x0, originY: -y0, rgba: canvas)
    }

    /// Fills the grid's triangles, sampling the icon's pixels (bilinear, premultiplied) and
    /// handing each covered pixel (index, premultiplied r, g, b, a) to `put`.
    static func rasterize(texture: EmoteModel.Texture, icon: EmoteModel.Icon, points: [Float], n: Int,
                         width: Int, height: Int, x0: Int, y0: Int, opacity: Double, masks: [[UInt8]],
                         put: (Int, UInt8, UInt8, UInt8, UInt8) -> Void) {
        let tw = texture.width
        let left = Float(icon.left), top = Float(icon.top)
        let iw = Float(icon.width), ih = Float(icon.height)
        let maxU = icon.left + icon.width - 1, maxV = icon.top + icon.height - 1
        guard icon.width > 0, icon.height > 0, maxU < texture.width, maxV < texture.height else { return }
        let alphaScale = Float(opacity)
        texture.pixels.withUnsafeBufferPointer { tex in
            func sample(_ u: Float, _ v: Float) -> (Float, Float, Float, Float) {
                let fu = min(max(u - 0.5, Float(icon.left)), Float(maxU)), fv = min(max(v - 0.5, Float(icon.top)), Float(maxV))
                let iu = Int(fu), iv = Int(fv)
                let iu1 = min(iu + 1, maxU), iv1 = min(iv + 1, maxV)
                let du = fu - Float(iu), dv = fv - Float(iv)
                var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 0
                @inline(__always) func add(_ x: Int, _ y: Int, _ w: Float) {
                    guard w > 0 else { return }
                    let o = (y * tw + x) * 4
                    let pa = Float(tex[o + 3]) * w
                    b += Float(tex[o]) * pa; g += Float(tex[o + 1]) * pa; r += Float(tex[o + 2]) * pa; a += pa
                }
                add(iu, iv, (1 - du) * (1 - dv)); add(iu1, iv, du * (1 - dv))
                add(iu, iv1, (1 - du) * dv); add(iu1, iv1, du * dv)
                return (r / 255, g / 255, b / 255, a)
            }
            func triangle(_ p0: (Float, Float, Float, Float), _ p1: (Float, Float, Float, Float), _ p2: (Float, Float, Float, Float)) {
                // (x, y, u, v); x, y in output pixels relative to (x0, y0).
                let area = (p1.0 - p0.0) * (p2.1 - p0.1) - (p2.0 - p0.0) * (p1.1 - p0.1)
                guard abs(area) > 1e-6 else { return }
                let minX = max(0, Int(min(p0.0, p1.0, p2.0).rounded(.down))), maxX = min(width - 1, Int(max(p0.0, p1.0, p2.0).rounded(.up)))
                let minY = max(0, Int(min(p0.1, p1.1, p2.1).rounded(.down))), maxY = min(height - 1, Int(max(p0.1, p1.1, p2.1).rounded(.up)))
                guard minX <= maxX, minY <= maxY else { return }
                let inv = 1 / area
                for y in minY...maxY {
                    let py = Float(y) + 0.5
                    for x in minX...maxX {
                        let px = Float(x) + 0.5
                        var w0 = ((p1.0 - px) * (p2.1 - py) - (p2.0 - px) * (p1.1 - py)) * inv
                        var w1 = ((p2.0 - px) * (p0.1 - py) - (p0.0 - px) * (p2.1 - py)) * inv
                        var w2 = 1 - w0 - w1
                        // Shared edges belong to one triangle only (no double-blended seams).
                        guard w0 >= 0, w1 >= 0, w2 >= 0 else { continue }
                        if w0 == 0 || w1 == 0 || w2 == 0 {
                            if w0 == 0, !Self.ownsEdge(p1, p2, area) { continue }
                            if w1 == 0, !Self.ownsEdge(p2, p0, area) { continue }
                            if w2 == 0, !Self.ownsEdge(p0, p1, area) { continue }
                        }
                        w0 = max(0, w0); w1 = max(0, w1); w2 = max(0, w2)
                        let u = w0 * p0.2 + w1 * p1.2 + w2 * p2.2
                        let v = w0 * p0.3 + w1 * p1.3 + w2 * p2.3
                        var s = sample(u, v)
                        var k = alphaScale
                        let o = y * width + x
                        for m in masks { k *= Float(m[o]) / 255 }
                        guard s.3 * k > 0.5 else { continue }
                        s.0 *= k; s.1 *= k; s.2 *= k; s.3 *= k
                        put(o, UInt8(min(255, s.0 + 0.5)), UInt8(min(255, s.1 + 0.5)), UInt8(min(255, s.2 + 0.5)), UInt8(min(255, s.3 + 0.5)))
                    }
                }
            }
            let stride = n + 1
            func vertex(_ i: Int, _ j: Int) -> (Float, Float, Float, Float) {
                let k = (j * stride + i) * 2
                return (points[k] - Float(x0), points[k + 1] - Float(y0),
                        left + iw * Float(i) / Float(n), top + ih * Float(j) / Float(n))
            }
            for j in 0..<n {
                for i in 0..<n {
                    let a = vertex(i, j), b = vertex(i + 1, j), c = vertex(i, j + 1), d = vertex(i + 1, j + 1)
                    triangle(a, b, d)
                    triangle(a, d, c)
                }
            }
        }
    }

    /// The top-left rule: a pixel on an edge belongs to the triangle when the edge is a top
    /// or a left edge (for the triangle's winding).
    @inline(__always) static func ownsEdge(_ a: (Float, Float, Float, Float), _ b: (Float, Float, Float, Float), _ area: Float) -> Bool {
        let dx = b.0 - a.0, dy = b.1 - a.1
        let sdx = area > 0 ? dx : -dx, sdy = area > 0 ? dy : -dy
        return (sdy == 0 && sdx < 0) || sdy > 0
    }
}
