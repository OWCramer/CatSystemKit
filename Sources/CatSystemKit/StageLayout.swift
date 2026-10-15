// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation

/// What a picture's effects (`KIND N mode sepia`, `tone r g b`, `blur x y`) do to its pixels.
public struct PictureEffect: Hashable, Sendable {
    public var sepia = false
    /// Red, green and blue in percent.
    public var tone: [Int]?
    /// Pixels across, horizontally and vertically.
    public var blur: [Int]?

    public init(sepia: Bool = false, tone: [Int]? = nil, blur: [Int]? = nil) {
        self.sepia = sepia
        self.tone = tone.flatMap { $0.count >= 3 && Array($0.prefix(3)) != [100, 100, 100] ? Array($0.prefix(3)) : nil }
        self.blur = blur.flatMap { $0.contains { $0 > 0 } ? $0 : nil }
    }

    public var isNone: Bool { !sepia && tone == nil && blur == nil }

    /// A key for caches ("" for none).
    public var key: String {
        var parts: [String] = []
        if sepia { parts.append("sepia") }
        if let tone { parts.append("tone" + tone.map(String.init).joined(separator: ",")) }
        if let blur { parts.append("blur" + blur.map(String.init).joined(separator: ",")) }
        return parts.joined(separator: "+")
    }
}

extension HGImage.Frame {
    /// The frame with `effect` applied to its pixels (itself when there is none).
    public func applying(_ effect: PictureEffect) -> HGImage.Frame {
        guard !effect.isNone, !rgba.isEmpty else { return self }
        var px = rgba
        if let blur = effect.blur {
            let rx = max(0, (blur.first ?? 0) / 2), ry = max(0, (blur.count > 1 ? blur[1] : blur.first ?? 0) / 2)
            // Two box passes each way: close to a Gaussian.
            for _ in 0..<2 {
                if rx > 0 { Self.boxBlur(&px, width: width, height: height, radius: rx, horizontal: true) }
                if ry > 0 { Self.boxBlur(&px, width: width, height: height, radius: ry, horizontal: false) }
            }
        }
        if effect.sepia || effect.tone != nil {
            let tone = (effect.tone ?? [100, 100, 100]).map { Double($0) / 100 }
            for i in stride(from: 0, to: px.count, by: 4) {
                var r = Double(px[i]), g = Double(px[i + 1]), b = Double(px[i + 2])
                if effect.sepia {
                    let grey = 0.299 * r + 0.587 * g + 0.114 * b
                    r = grey * 1.07; g = grey * 0.89; b = grey * 0.66
                }
                px[i] = UInt8(min(255, max(0, r * tone[0]).rounded()))
                px[i + 1] = UInt8(min(255, max(0, g * tone[1]).rounded()))
                px[i + 2] = UInt8(min(255, max(0, b * tone[2]).rounded()))
            }
        }
        var frame = HGImage.Frame(id: id, width: width, height: height, bitsPerPixel: bitsPerPixel, offsetX: offsetX, offsetY: offsetY,
                                  canvasWidth: canvasWidth, canvasHeight: canvasHeight, baseX: baseX, baseY: baseY,
                                  sections: sections, rgba: px)
        frame.metadata = metadata
        return frame
    }

    /// A running mean `radius` pixels each side, along rows or columns (edges held).
    private static func boxBlur(_ px: inout [UInt8], width: Int, height: Int, radius: Int, horizontal: Bool) {
        let count = horizontal ? width : height, lines = horizontal ? height : width
        let step = horizontal ? 4 : width * 4
        var line = [Int](repeating: 0, count: count * 4)
        let span = 2 * radius + 1
        for l in 0..<lines {
            let start = horizontal ? l * width * 4 : l * 4
            for i in 0..<count { for c in 0..<4 { line[i * 4 + c] = Int(px[start + i * step + c]) } }
            var sum = [0, 0, 0, 0]
            for k in -radius...radius {
                let i = min(count - 1, max(0, k))
                for c in 0..<4 { sum[c] += line[i * 4 + c] }
            }
            for i in 0..<count {
                for c in 0..<4 { px[start + i * step + c] = UInt8(sum[c] / span) }
                let out = min(count - 1, max(0, i - radius)), into = min(count - 1, max(0, i + radius + 1))
                for c in 0..<4 { sum[c] += line[into * 4 + c] - line[out * 4 + c] }
            }
        }
    }
}

/// The story's screen as drawing steps, shared by the headless renderer (`ScenePlayer.render`)
/// and the app's Metal stage: each plane's pictures as rectangles in game pixels, and where
/// the characters go among them.
///
/// A picture's base point stands at its place (`ScenePlayer.Picture`), mirrored and scaled
/// about it; then its plane moves it: the plane's base point (the screen's centre unless `pl N
/// base` says) goes to its place (`pl N pos`, the centre unless set), scaled about it. Planes
/// and characters are drawn by priority (`pl N pri`, `mpl N pri`; planes 3000 + 100·N,
/// characters 5000 + 100·N), a plane before a character of the same priority.
public enum StageLayout {
    public struct Mask: Sendable, Equatable {
        public var name: String
        public var x: Double, y: Double, width: Double, height: Double
        public var flipX: Bool, flipY: Bool
    }

    public struct Quad: Sendable, Equatable {
        public enum Source: Sendable, Equatable {
            case picture(String, PictureEffect)
            /// `0xAARRGGBB`.
            case color(UInt32)
        }

        public var source: Source
        /// The plane it is on.
        public var plane: Int
        /// The picture's pixels land here (game pixels; it may reach past the screen).
        public var x: Double, y: Double, width: Double, height: Double
        public var flipX = false, flipY = false
        /// 0–1.
        public var alpha: Double
        /// Added to what is under it (`pl N bmode 1`) instead of laid over it.
        public var additive = false
        /// The plane's `\ma` picture: only where it is opaque does this show.
        public var mask: Mask?
    }

    public enum Item: Sendable, Equatable {
        case quad(Quad)
        case character(bank: Int)
    }

    /// The screen's drawing steps, back to front. `state` gives each plane as it stands now
    /// (`PlaneStage`, or `PlaneStage.resting`); `frame` a picture's first frame (pixels or not).
    public static func items(planes: [Int: ScenePlayer.Plane], cast: [Int: ScenePlayer.Character],
                             width: Int = 1280, height: Int = 720,
                             state: (Int, ScenePlayer.Plane) -> PlaneStage.State,
                             frame: (String) -> HGImage.Frame?) -> [Item] {
        var ordered: [(priority: Int, rank: Int, number: Int, items: [Item])] = []
        for (n, plane) in planes where plane.visible {
            let st = state(n, plane)
            guard st.alpha > 0.5 else { continue }
            let quads = self.quads(n, plane, st, width: width, height: height, frame: frame)
            if !quads.isEmpty { ordered.append((plane.priority(number: n), 0, n, quads.map(Item.quad))) }
        }
        for (n, c) in cast where c.visible && c.model != nil {
            ordered.append((c.priority(bank: n), 1, n, [.character(bank: n)]))
        }
        ordered.sort { ($0.priority, $0.rank, $0.number) < ($1.priority, $1.rank, $1.number) }
        return ordered.flatMap(\.items)
    }

    /// A plane's pictures (and colour) as rectangles, in drawing order.
    static func quads(_ n: Int, _ plane: ScenePlayer.Plane, _ st: PlaneStage.State, width: Int, height: Int,
                      frame: (String) -> HGImage.Frame?) -> [Quad] {
        let alpha = st.alpha / 255
        let additive = plane.blendMode == 1
        var out: [Quad] = []
        if let color = plane.color {
            out.append(Quad(source: .color(color), plane: n, x: st.offsetX, y: st.offsetY, width: Double(width), height: Double(height),
                            alpha: alpha, additive: additive))
        }
        let px = (st.x ?? Double(width) / 2) + st.offsetX, py = (st.y ?? Double(height) / 2) + st.offsetY
        let base = plane.base
        let sx = st.scaleX / 100, sy = st.scaleY / 100
        // A rectangle where the picture stands unmoved, carried by the plane.
        func placed(_ r: (x: Double, y: Double, w: Double, h: Double)) -> (x: Double, y: Double, w: Double, h: Double) {
            (px + (r.x - base.x) * sx, py + (r.y - base.y) * sy, r.w * sx, r.h * sy)
        }
        func rect(_ p: ScenePlayer.Picture) -> (x: Double, y: Double, w: Double, h: Double)? {
            let psx = Double(p.scaleX ?? 100) / 100, psy = Double(p.scaleY ?? p.scaleX ?? 100) / 100
            if p.color != nil {
                return placed((Double(p.x ?? 0), Double(p.y ?? 0), Double(width) * psx, Double(height) * psy))
            }
            guard let file = p.file, let f = frame(file) else { return nil }
            let home = ScenePlayer.Picture.defaultPlace(p.kind, width: width, height: height)
            let ax = Double(p.x ?? home.x), ay = Double(p.y ?? home.y)
            let left = p.flipX == true ? -(f.offsetX + f.width - f.baseX) : f.offsetX - f.baseX
            let top = p.flipY == true ? -(f.offsetY + f.height - f.baseY) : f.offsetY - f.baseY
            return placed((ax + Double(left) * psx, ay + Double(top) * psy, Double(f.width) * psx, Double(f.height) * psy))
        }
        let pictures = plane.orderedPictures
        var mask: Mask?
        if let m = pictures.first(where: { $0.mask == true }), let file = m.file, let r = rect(m) {
            mask = Mask(name: file, x: r.x, y: r.y, width: r.w, height: r.h, flipX: m.flipX == true, flipY: m.flipY == true)
        }
        for p in pictures where p.mask != true {
            guard let r = rect(p) else { continue }
            let a = alpha * Double(p.alpha ?? 255) / 255
            guard a > 0.002 else { continue }
            let source: Quad.Source = p.color.map { .color($0) } ?? .picture(p.file ?? "", p.effect)
            out.append(Quad(source: source, plane: n, x: r.x, y: r.y, width: r.w, height: r.h,
                            flipX: p.flipX == true, flipY: p.flipY == true, alpha: a, additive: additive, mask: mask))
        }
        return out
    }
}

extension PlaneStage {
    /// A plane standing still as `ScenePlayer` left it (headless drawing).
    public static func resting(_ plane: ScenePlayer.Plane) -> State {
        State(x: plane.x.map(Double.init), y: plane.y.map(Double.init), scaleX: Double(plane.scaleX ?? 100),
              scaleY: Double(plane.scaleY ?? plane.scaleX ?? 100), alpha: Double(plane.alpha), offsetX: 0, offsetY: 0)
    }
}
