import Foundation

/// An E-mote character (a motion PSB, `id` = `motion`), as NEKOPARA Vol. 3 ships them in
/// `psz.int`.
///
/// The model is a tree of layers in named motions grouped by object (`all_parts`,
/// `head_parts`, `face_parts` …). Layers are images from a texture atlas (`src` = `tex`,
/// `icon` = the image), invisible deformers (`src` = `blank`, `icon` = `w:h:ox:oy`) that
/// carry a Bézier patch (`mesh.bp`, 4×4 points over the layer's box) bending everything
/// below them, layout groups, references to other motions (type 3: `src` = object,
/// `icon` = motion) and stencils (type 12: their children only draw where the layers named
/// in `stencilCompositeMaskLayerList` have pixels). Each layer has a frame list; a layer
/// that names one of its motion's `parameter`s (`parameterize`) has its time set by that
/// variable (`head_LR`, `face_eye_open` …) instead of the clock, which is how expressions
/// and poses are chosen. A motion's `priority` lists its layers front to back.
///
/// `metadata` names the root (`base`: `all_parts` / `タイムライン構造`), the variables, the
/// timelines that animate them (`timelineControl`: `初期化`, `差分用_waiting_loop` …) and
/// selectors (`arm_type` picks one of `fade_a`…`fade_e`).
public final class EmoteModel {
    public struct Icon {
        public let left: Int, top: Int, width: Int, height: Int
        public let originX: Double, originY: Double
    }

    public struct Texture {
        public let width: Int, height: Int
        /// "RGBA8" rows, stored B, G, R, A (straight alpha): only the rows icons use, copied
        /// out of the PSB so the rest (a large model is a 4096² atlas) can go.
        public let pixels: [UInt8]
    }

    public struct Source {
        public let texture: Texture?
        /// The texture's place in `textures`.
        public let textureIndex: Int?
        public let icons: [String: Icon]
    }

    public struct Content {
        public var src: String?
        public var icon: String?
        public var x = 0.0, y = 0.0, z = 0.0
        public var ox = 0.0, oy = 0.0
        public var angle = 0.0
        public var scaleX = 1.0, scaleY = 1.0
        public var slantX = 0.0, slantY = 0.0
        public var flipX = false, flipY = false
        public var opacity = 1.0
        public var blend = 0
        /// 16 control points (x, y pairs, rows top to bottom), or nil for no bend.
        public var mesh: [Double]?
        public var timeOffset = 0.0
    }

    public struct Frame {
        public let time: Double
        /// 0: nothing shown from here; 2: held; 3: tweened to the next frame.
        public let type: Int
        public let content: Content
    }

    public final class Layer {
        public let label: String
        public let type: Int
        public let parameterize: Int?
        public let maskLabels: [String]
        public let meshDivision: Int
        public let frames: [Frame]
        public let children: [Layer]
        /// A shape layer's (type 1) geometry: 0 point, 1 circle, 2 rectangle, 3 quad - a 16-unit
        /// square about the layer's position, scaled and turned with it. Hit areas
        /// (`hit_head` ...) are these.
        public let shape: Int?

        init(label: String, type: Int, parameterize: Int?, maskLabels: [String], meshDivision: Int, frames: [Frame],
             children: [Layer], shape: Int? = nil) {
            self.shape = shape
            self.label = label
            self.type = type
            self.parameterize = parameterize
            self.maskLabels = maskLabels
            self.meshDivision = meshDivision
            self.frames = frames
            self.children = children
        }
    }

    public struct Parameter {
        public let id: String
        public let rangeBegin: Double, rangeEnd: Double
        public let division: Double
        public let discrete: Bool
    }

    public final class Motion {
        public let parameters: [Parameter]
        public let defaultParameter: Int?
        public let layers: [Layer]
        public let layerIndex: [String: Int]
        /// (time, layer indices front to back).
        public let priority: [(time: Double, order: [Int])]
        public let lastTime: Double

        init(parameters: [Parameter], defaultParameter: Int?, layers: [Layer], layerIndex: [String: Int],
             priority: [(time: Double, order: [Int])], lastTime: Double) {
            self.parameters = parameters
            self.defaultParameter = defaultParameter
            self.layers = layers
            self.layerIndex = layerIndex
            self.priority = priority
            self.lastTime = lastTime
        }
    }

    public struct Selector {
        public let label: String
        public let options: [(label: String, on: Double, off: Double)]
    }

    /// A timeline's key: from `time`, the variable heads for `value` and gets there one frame
    /// before the next key (E-mote's timeline control sets each key's value as a target with
    /// the gap to the next key as its transition). `value` nil is a type-0 key: the end.
    public struct Key {
        public let time: Double
        public let value: Double?
        /// The curve's exponent (`progress ^ weight`): `easing` e > 0 gives e + 1, e < 0
        /// gives 1 / (1 − e), 0 is linear.
        public let weight: Double
    }

    public struct Timeline {
        public let label: String
        public let loopBegin: Double, loopEnd: Double
        /// A difference timeline (`diff`, the `差分用_…` idle loops): its values are added to
        /// the pose rather than replacing it.
        public let difference: Bool
        /// Variable → keys.
        public let tracks: [String: [Key]]
    }

    public let sources: [String: Source]
    /// Every source's texture, in a fixed order (for a GPU to upload once).
    public let textures: [Texture]
    public let objects: [String: [String: Motion]]
    public let baseObject: String
    public let baseMotion: String
    public let variableNames: [String]
    public let selectors: [Selector]
    public let timelines: [String: Timeline]

    public init(psb: PSBFile) throws {
        let root = psb.root
        guard root["id"]?.string == "motion" else { throw PSBFile.Failure.notPSB }
        var sources: [String: Source] = [:]
        var textures: [Texture] = []
        for (name, value) in (root["source"]?.dictionary ?? [:]).sorted(by: { $0.key < $1.key }) {
            var icons: [String: Icon] = [:]
            for (iconName, icon) in value["icon"]?.dictionary ?? [:] {
                icons[iconName] = Icon(left: icon["left"]?.int ?? 0, top: icon["top"]?.int ?? 0,
                                       width: icon["width"]?.int ?? 0, height: icon["height"]?.int ?? 0,
                                       originX: icon["originX"]?.number ?? 0, originY: icon["originY"]?.number ?? 0)
            }
            var texture: Texture?
            if let t = value["texture"], let w = t["width"]?.int, let h = t["height"]?.int,
               case .resource(let index)? = t["pixel"], let pixels = psb.resource(index), pixels.count >= w * h * 4 {
                let used = min(h, icons.values.map { $0.top + $0.height }.max() ?? h)
                texture = Texture(width: w, height: used, pixels: Array(pixels.prefix(w * used * 4)))
            }
            if let texture { textures.append(texture) }
            sources[name] = Source(texture: texture, textureIndex: texture == nil ? nil : textures.count - 1, icons: icons)
        }
        self.sources = sources
        self.textures = textures

        var objects: [String: [String: Motion]] = [:]
        for (objectName, object) in root["object"]?.dictionary ?? [:] {
            var motions: [String: Motion] = [:]
            for (motionName, motion) in object["motion"]?.dictionary ?? [:] {
                motions[motionName] = Self.motion(motion)
            }
            objects[objectName] = motions
        }
        self.objects = objects

        let metadata = root["metadata"]
        baseObject = metadata?["base"]?["chara"]?.string ?? "all_parts"
        baseMotion = metadata?["base"]?["motion"]?.string ?? ""
        var names: [String] = []
        for v in metadata?["variableList"]?.list ?? [] {
            if let label = v["label"]?.string, !names.contains(label) { names.append(label) }
        }
        variableNames = names
        selectors = (metadata?["selectorControl"]?.list ?? []).compactMap { s in
            guard let label = s["label"]?.string else { return nil }
            let options = (s["optionList"]?.list ?? []).compactMap { o -> (String, Double, Double)? in
                guard let l = o["label"]?.string else { return nil }
                return (l, o["onValue"]?.number ?? 0, o["offValue"]?.number ?? 1)
            }
            return Selector(label: label, options: options.map { (label: $0.0, on: $0.1, off: $0.2) })
        }
        var timelines: [String: Timeline] = [:]
        for t in metadata?["timelineControl"]?.list ?? [] {
            guard let label = t["label"]?.string else { continue }
            var tracks: [String: [Key]] = [:]
            for v in t["variableList"]?.list ?? [] {
                guard let name = v["label"]?.string else { continue }
                let keys = (v["frameList"]?.list ?? []).map { f -> Key in
                    let easing = f["content"]?["easing"]?.number ?? 0
                    return Key(time: f["time"]?.number ?? 0,
                               value: (f["type"]?.int ?? 0) == 0 ? nil : f["content"]?["value"]?.number,
                               weight: easing > 0 ? easing + 1 : easing < 0 ? 1 / (1 - easing) : 1)
                }
                if !keys.isEmpty { tracks[name] = keys }
            }
            timelines[label] = Timeline(label: label, loopBegin: t["loopBegin"]?.number ?? -1,
                                        loopEnd: t["loopEnd"]?.number ?? -1,
                                        difference: (t["diff"]?.number ?? 0) != 0, tracks: tracks)
        }
        self.timelines = timelines
    }

    private static func motion(_ value: PSBFile.Value) -> Motion {
        let parameters = (value["parameter"]?.list ?? []).map { p in
            Parameter(id: p["id"]?.string ?? "", rangeBegin: p["rangeBegin"]?.number ?? 0,
                      rangeEnd: p["rangeEnd"]?.number ?? 0, division: p["division"]?.number ?? 0,
                      discrete: (p["discretization"]?.int ?? 0) != 0)
        }
        var layerIndex: [String: Int] = [:]
        for (k, v) in value["layerIndexMap"]?.dictionary ?? [:] { if let i = v.int { layerIndex[k] = i } }
        let priority = (value["priority"]?.list ?? []).compactMap { f -> (time: Double, order: [Int])? in
            guard let order = f["content"]?.numbers else { return nil }
            return (f["time"]?.number ?? 0, order.map { Int($0) })
        }
        return Motion(parameters: parameters, defaultParameter: value["parameterize"]?.int,
                      layers: (value["layer"]?.list ?? []).map(layer), layerIndex: layerIndex,
                      priority: priority, lastTime: value["lastTime"]?.number ?? 0)
    }

    private static func layer(_ value: PSBFile.Value) -> Layer {
        let type = value["type"]?.int ?? 0
        let frames = (value["frameList"]?.list ?? []).map { f in
            Frame(time: f["time"]?.number ?? 0, type: f["type"]?.int ?? 0,
                  content: f["content"].map { content($0, layerType: type) } ?? Content())
        }
        return Layer(label: value["label"]?.string ?? "", type: type, parameterize: value["parameterize"]?.int,
                     maskLabels: (value["stencilCompositeMaskLayerList"]?.list ?? []).compactMap(\.string),
                     meshDivision: value["meshDivision"]?.int ?? 16, frames: frames,
                     children: (value["children"]?.list ?? []).map(layer),
                     shape: type == 1 ? value["shape"]?.int : nil)
    }

    /// A frame's content, reading only what its `mask` says is there (as M2's player does).
    private static func content(_ c: PSBFile.Value, layerType: Int) -> Content {
        var out = Content()
        let mask = c["mask"]?.int ?? 0
        out.src = c["src"]?.string
        out.icon = c["icon"]?.string
        if mask & 0x1 != 0 { out.ox = c["ox"]?.number ?? 0; out.oy = c["oy"]?.number ?? 0 }
        if mask & 0x2 != 0, let coord = c["coord"]?.numbers {
            if coord.count > 0 { out.x = coord[0] }
            if coord.count > 1 { out.y = coord[1] }
            if coord.count > 2 { out.z = coord[2] }
        }
        if mask & 0x400 != 0 { out.opacity = min(1, max(0, (c["opa"]?.number ?? 255) / 255)) }
        if mask & 0x10 != 0 { out.angle = c["angle"]?.number ?? 0 }
        if mask & 0x4 != 0 { out.flipX = (c["fx"]?.number ?? 0) != 0 }
        if mask & 0x8 != 0 { out.flipY = (c["fy"]?.number ?? 0) != 0 }
        if mask & 0x60 != 0 { out.scaleX = c["zx"]?.number ?? 1; out.scaleY = c["zy"]?.number ?? 1 }
        if mask & 0x80 != 0 { out.slantX = c["sx"]?.number ?? 0 }
        if mask & 0x100 != 0 { out.slantY = c["sy"]?.number ?? 0 }
        if mask & 0x20000 != 0 { out.blend = c["bm"]?.int ?? 0 }
        if mask & 0x0200_0000 != 0, let bp = c["mesh"]?["bp"]?.numbers, bp.count == 32 { out.mesh = bp }
        if mask & 0x80000 != 0 { out.timeOffset = c["motion"]?["timeOffset"]?.number ?? 0 }
        return out
    }

    /// The model's variables at rest: 0, then the `初期化` timeline's first keys, then each
    /// selector's first option.
    public func restingVariables() -> [String: Double] {
        var v: [String: Double] = [:]
        for name in variableNames { v[name] = 0 }
        if let reset = timelines["初期化"] {
            for (name, keys) in reset.tracks { if let value = keys.first?.value { v[name] = value } }
        }
        applySelectors(&v)
        return v
    }

    /// Sets each selector's option variables from the selector's value (`arm_type` 2 shows
    /// `fade_c` and hides the others).
    public func applySelectors(_ v: inout [String: Double]) {
        for s in selectors {
            let chosen = Int(v[s.label] ?? 0)
            for (i, option) in s.options.enumerated() { v[option.label] = i == chosen ? option.on : option.off }
        }
    }

    /// A timeline's variables at `time` (frames; looping between its loop points).
    public func timelineValues(_ label: String, at time: Double) -> [String: Double] {
        guard let timeline = timelines[label] else { return [:] }
        var t = time
        if timeline.loopEnd > timeline.loopBegin, timeline.loopBegin >= 0, t >= timeline.loopBegin {
            t = timeline.loopBegin + (t - timeline.loopBegin).truncatingRemainder(dividingBy: timeline.loopEnd - timeline.loopBegin)
        }
        let looping = timeline.loopEnd > timeline.loopBegin && timeline.loopBegin >= 0
        var out: [String: Double] = [:]
        for (name, keys) in timeline.tracks {
            let valued = keys.indices.filter { keys[$0].value != nil }
            guard let firstValued = valued.first else { continue }
            guard let i = valued.last(where: { keys[$0].time <= t }) else {
                out[name] = keys[firstValued].value
                continue
            }
            let key = keys[i], target = key.value!
            // Where the variable was when this key began: the key before's target (the last
            // one, in a loop that has come round).
            let previous = valued.last(where: { $0 < i }).flatMap { keys[$0].value }
                ?? (looping ? valued.last.flatMap { keys[$0].value } : nil) ?? target
            let duration = i + 1 < keys.count ? max(0, keys[i + 1].time - key.time - 1) : 0
            guard duration > 0 else { out[name] = target; continue }
            let progress = min(1, max(0, (t - key.time) / duration))
            out[name] = previous + (target - previous) * pow(progress, key.weight)
        }
        return out
    }
}
