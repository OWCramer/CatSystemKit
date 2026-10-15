// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation

/// The story's particles (`particle`, `particle2`, `particle3`), as sprites over time.
///
/// In NEKOPARA Vol. 3 every particle the scenes start is an emotion mark by a character's
/// head (`particle3 0 em_note tex_em04 3 37000 2 1 430 179 1 100 30 60 60`): notes or hearts
/// that float up, a question mark, an exclamation, a sweat drop, an anger mark. The game's
/// kinds are native plug-ins (`ptclpi/em_*.ppi`, Windows DLLs, not read), so how each moves
/// is Shiori's own, from the marks' pictures (`tex_em01`–`tex_em16` in `image_fg.int`) and
/// the scenes' arguments: the picture, a count, the character's bank, the place (from `mpl N
/// m2att`, by the head), a side (`0` left, `1` right) where the kind takes one, and a size
/// in percent. A mark follows its character's moves. `particle3 N fade frames from to`
/// fades a slot; `particle3 [N] stop` (and `particle stop`, `particle2 stop`) clears.
public final class ParticleStage {
    public enum Kind: String, Sendable {
        case note = "em_note", question = "em_question", exclamation = "em_double"
        case sweat = "em_sweat", angry = "em_angry"
    }

    public struct Emitter: Sendable {
        public var kind: Kind
        public var texture: String
        public var count: Int
        public var bank: Int?
        public var x: Double, y: Double
        /// 1 to the right, -1 to the left.
        public var side: Double
        /// Of the picture's own size, 1 = 100%.
        public var size: Double
        public var start: Double
        /// Where the character stood when the mark began (it follows the character).
        public var anchor: (x: Double, y: Double)?
        public var fade: (start: Double, frames: Double, from: Double, to: Double)?
    }

    /// A picture to draw: its centre at (`x`, `y`) on the 1280×720 screen, scaled, faded.
    public struct Sprite: Sendable, Equatable {
        public var texture: String
        public var x: Double, y: Double
        public var scale: Double
        public var alpha: Double
    }

    public private(set) var emitters: [String: Emitter] = [:]

    public init() {}

    public var isEmpty: Bool { emitters.isEmpty }

    /// Carries out a particle command (its numbers already worked out by `ScenePlayer`) at
    /// `time` (seconds); `place` says where a bank's character stands then.
    public func command(_ text: String, time: Double, place: (Int) -> (x: Double, y: Double)?) {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let verb = words.first, verb.hasPrefix("particle") else { return }
        let frame = time * 60
        let args = Array(words.dropFirst())
        guard let first = args.first else { clear(verb); return }
        if first == "stop" { clear(verb); return }
        let slot = verb + ":" + first
        guard args.count >= 2 else { emitters[slot] = nil; return }
        switch args[1] {
        case "stop", "end":
            emitters[slot] = nil
        case "fade":
            // `fade frames from to` (0–255).
            guard var e = emitters[slot] else { return }
            let n = args.dropFirst(2).compactMap(Double.init)
            guard let frames = n.first else { return }
            e.fade = (frame, max(1, frames), (n.count > 1 ? n[1] : 255) / 255, (n.count > 2 ? n[2] : 0) / 255)
            emitters[slot] = e
        default:
            guard let kind = Kind(rawValue: args[1].lowercased()), args.count >= 6 else { return }
            let n = args.dropFirst(3).map { Double($0) }
            // kind texture count z bank [1] x y [side] size …
            func at(_ i: Int) -> Double? { i < n.count ? n[i] : nil }
            let bank = at(2).map { Int($0) }
            var i = 3
            if kind == .note { i += 1 } // an extra flag before the place
            guard let x = at(i), let y = at(i + 1) else { return }
            i += 2
            var side = 1.0
            if kind != .sweat, kind != .angry { side = (at(i) ?? 1) == 0 ? -1 : 1; i += 1 }
            let size = max(0.1, (at(i) ?? 100) / 100)
            emitters[slot] = Emitter(kind: kind, texture: args[2], count: max(1, Int(at(0) ?? 1)), bank: bank,
                                     x: x, y: y, side: side, size: size, start: frame,
                                     anchor: bank.flatMap(place), fade: nil)
        }
    }

    private func clear(_ verb: String) {
        emitters = emitters.filter { !$0.key.hasPrefix(verb + ":") }
    }

    public func reset() { emitters = [:] }

    /// The sprites at `time`, back to front.
    public func sprites(at time: Double, place: (Int) -> (x: Double, y: Double)?) -> [Sprite] {
        let frame = time * 60
        var out: [Sprite] = []
        for key in emitters.keys.sorted() {
            guard let e = emitters[key] else { continue }
            var alpha = 1.0
            if let f = e.fade {
                let t = min(1, max(0, (frame - f.start) / f.frames))
                alpha = f.from + (f.to - f.from) * t
                if t >= 1, f.to <= 0 { emitters[key] = nil; continue }
            }
            var dx = 0.0, dy = 0.0
            if let bank = e.bank, let anchor = e.anchor, let now = place(bank) { dx = now.x - anchor.x; dy = now.y - anchor.y }
            for s in Self.sprites(e, frame: frame - e.start) {
                var s = s
                s.x += dx; s.y += dy
                s.alpha *= alpha
                if s.alpha > 0.004 { out.append(s) }
            }
        }
        return out
    }

    /// One mark's pictures `t` frames after it began.
    static func sprites(_ e: Emitter, frame t: Double) -> [Sprite] {
        guard t >= 0 else { return [] }
        func pop(_ t: Double, frames: Double) -> Double {
            // 0 → 1.15 → 1: a quick pop with a little overshoot.
            let u = min(1, t / frames)
            return u < 0.7 ? 1.15 * sin(u / 0.7 * .pi / 2) : 1.15 - 0.15 * (u - 0.7) / 0.3
        }
        let s = e.size
        switch e.kind {
        case .note:
            // Notes (or hearts) rise one after another from beside the head, swaying out to
            // the mark's side, and fade as they go; each lives a second.
            let life = 60.0, every = 18.0
            var out: [Sprite] = []
            let spawned = Int(t / every) + 1
            for k in max(0, spawned - Int(life / every) - 1)..<spawned {
                let age = t - Double(k) * every
                guard age >= 0, age < life else { continue }
                let u = age / life
                let lane = Double(k % max(1, e.count)) - Double(max(1, e.count) - 1) / 2
                let x = e.x + e.side * (u * 40 + lane * 22) * s + sin(age / 9) * 8 * s
                let y = e.y - u * 90 * s + lane * 6 * s
                let a = min(1, age / 8) * (u > 0.65 ? (1 - u) / 0.35 : 1)
                out.append(Sprite(texture: e.texture, x: x, y: y, scale: s * (0.55 + 0.2 * min(1, age / 10)), alpha: a))
            }
            return out
        case .question:
            // Pops up, then sways from side to side.
            let scale = s * pop(t, frames: 10) * 0.6
            return [Sprite(texture: e.texture, x: e.x + sin(t / 14) * 4 * s, y: e.y - min(1, t / 10) * 12 * s, scale: scale, alpha: min(1, t / 4))]
        case .exclamation:
            // Pops up with a jolt.
            let jolt = t < 14 ? sin(t * 1.4) * (1 - t / 14) * 6 * s : 0
            return [Sprite(texture: e.texture, x: e.x + jolt, y: e.y - min(1, t / 7) * 10 * s, scale: s * pop(t, frames: 7) * 0.6, alpha: min(1, t / 3))]
        case .sweat:
            // A drop that slides down a little and fades, again and again.
            let cycle = 50.0
            let u = t.truncatingRemainder(dividingBy: cycle) / cycle
            let a = min(1, u / 0.15) * (u > 0.7 ? (1 - u) / 0.3 : 1)
            return [Sprite(texture: e.texture, x: e.x, y: e.y + u * 24 * s, scale: s * 0.55, alpha: a)]
        case .angry:
            // An anger mark that throbs.
            let throb = 1 + 0.12 * max(0, sin(t / 6 * .pi / 2))
            return [Sprite(texture: e.texture, x: e.x, y: e.y, scale: s * 0.55 * throb * pop(t, frames: 8), alpha: min(1, t / 4))]
        }
    }
}
