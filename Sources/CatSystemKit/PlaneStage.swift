import Foundation

/// The story's planes over time: what `ScenePlayer` leaves as end states (`pl N amove1`,
/// `ascale1`, `fade`) played out frame by frame, and `pl N quake` shakes.
///
/// - `amove1/2/3 frames x y` and `move` slide the plane's anchor to its end point (easing
///   out, in, both; `move` linear), `ascale1/2/3` scale it the same way, `fade frames from
///   to` fades it linearly.
/// - `quake f,x,y f,x,y …` moves the plane by each offset in turn, `f` frames each (the
///   last one is usually `0,0`). Without a plane number every plane shakes: the screen.
/// - `pl stop` ends every motion at once.
///
/// Times are in seconds (any clock), at 60 frames a second as the game counts them.
public final class PlaneStage {
    public init() {}

    final class Motion {
        var x: EmoteStage.Tween
        var y: EmoteStage.Tween
        var scaleX: EmoteStage.Tween
        var scaleY: EmoteStage.Tween
        var alpha: EmoteStage.Tween
        var quake: Quake?

        init(_ plane: ScenePlayer.Plane) {
            x = .init(Double(plane.x ?? 640)); y = .init(Double(plane.y ?? 360))
            scaleX = .init(Double(plane.scaleX ?? 100)); scaleY = .init(Double(plane.scaleY ?? plane.scaleX ?? 100))
            alpha = .init(Double(plane.alpha))
        }
    }

    /// A shake: offsets reached one after another, each over its frames.
    public struct Quake: Sendable {
        public var start: Double
        public var steps: [(frames: Double, x: Double, y: Double)]

        /// `4,0,10 4,0,-10 …`; nil when no step reads.
        public init?(_ words: [String], start: Double) {
            self.start = start
            steps = words.compactMap { word in
                let parts = word.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                return parts.count == 3 ? (max(0, parts[0]), parts[1], parts[2]) : nil
            }
            if steps.isEmpty { return nil }
        }

        var frames: Double { steps.reduce(0) { $0 + $1.frames } }

        /// The offset at `frame`, or nil once it is over.
        public func offset(at frame: Double) -> (x: Double, y: Double)? {
            var t = frame - start
            guard t >= 0 else { return (0, 0) }
            var from = (x: 0.0, y: 0.0)
            for step in steps {
                if t < step.frames {
                    let f = t / step.frames
                    return (from.x + (step.x - from.x) * f, from.y + (step.y - from.y) * f)
                }
                t -= step.frames
                from = (step.x, step.y)
            }
            return nil
        }
    }

    private var motions: [Int: Motion] = [:]
    /// A quake on every plane (`pl quake …` without a number).
    private var screenQuake: Quake?

    /// Starts again from `planes` (a loaded save), nothing moving.
    public func reset(_ planes: [Int: ScenePlayer.Plane]) {
        motions = planes.mapValues(Motion.init)
        screenQuake = nil
    }

    /// Carries out a command the scene player has just applied (`planes` is its state after).
    public func command(_ text: String, planes: [Int: ScenePlayer.Plane], time: Double) {
        let frame = time * EmoteStage.framesPerSecond
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let verb = words.first else { return }
        // Pictures and colours put on a plane, or planes cleared: no motion, the new state.
        guard verb == "pl" else {
            sync(planes)
            return
        }
        guard words.count >= 2 else { sync(planes); return }
        // `pl quake …` / `pl stop` with no plane number.
        if Int(words[1]) == nil, !words[1].hasPrefix("[") {
            switch words[1] {
            case "quake": screenQuake = Quake(Array(words.dropFirst(2)), start: frame)
            case "stop": finishMotions()
            default: break
            }
            sync(planes)
            return
        }
        let numbers = ScenePlayer.planeNumbers(words[1])
        let args = Array(words.dropFirst(2))
        guard let sub = args.first else { sync(planes); return }
        let number = { (i: Int) -> Double? in i < args.count ? Double(args[i].replacingOccurrences(of: "%", with: "")) : nil }
        for n in numbers {
            guard let plane = planes[n] else { motions[n] = nil; continue }
            guard let m = motions[n] else { motions[n] = Motion(plane); continue }
            switch sub {
            case "amove1", "amove2", "amove3", "move":
                let frames = number(1) ?? 0
                let curve: EmoteStage.Curve = sub == "amove1" ? .easeOut : sub == "amove2" ? .easeIn : sub == "amove3" ? .easeInOut : .linear
                m.x.move(to: Double(plane.x ?? 640), frames: frames, curve: curve, at: frame)
                m.y.move(to: Double(plane.y ?? 360), frames: frames, curve: curve, at: frame)
            case "ascale1", "ascale2", "ascale3":
                let frames = number(1) ?? 0
                let curve: EmoteStage.Curve = sub == "ascale1" ? .easeOut : sub == "ascale2" ? .easeIn : .easeInOut
                m.scaleX.move(to: Double(plane.scaleX ?? 100), frames: frames, curve: curve, at: frame)
                m.scaleY.move(to: Double(plane.scaleY ?? plane.scaleX ?? 100), frames: frames, curve: curve, at: frame)
            case "fade", "m2fade":
                if let frames = number(1), let from = number(2) {
                    m.alpha.snap(from)
                    m.alpha.move(to: Double(plane.alpha), frames: frames, curve: .linear, at: frame)
                } else {
                    m.alpha.snap(Double(plane.alpha))
                }
            case "quake":
                m.quake = Quake(Array(args.dropFirst()), start: frame)
            case "stop":
                finish(m)
            default:
                snap(m, plane)
            }
        }
        sync(planes)
    }

    /// Planes that came or went, or changed without a motion, take their new state.
    public func sync(_ planes: [Int: ScenePlayer.Plane]) {
        for n in motions.keys where planes[n] == nil { motions[n] = nil }
        for (n, plane) in planes {
            guard let m = motions[n] else { motions[n] = Motion(plane); continue }
            if m.x.to != Double(plane.x ?? 640) || m.y.to != Double(plane.y ?? 360) {
                m.x.snap(Double(plane.x ?? 640)); m.y.snap(Double(plane.y ?? 360))
            }
            if m.scaleX.to != Double(plane.scaleX ?? 100) || m.scaleY.to != Double(plane.scaleY ?? plane.scaleX ?? 100) {
                m.scaleX.snap(Double(plane.scaleX ?? 100)); m.scaleY.snap(Double(plane.scaleY ?? plane.scaleX ?? 100))
            }
            if m.alpha.to != Double(plane.alpha) { m.alpha.snap(Double(plane.alpha)) }
        }
    }

    private func snap(_ m: Motion, _ plane: ScenePlayer.Plane) {
        m.x.snap(Double(plane.x ?? 640)); m.y.snap(Double(plane.y ?? 360))
        m.scaleX.snap(Double(plane.scaleX ?? 100)); m.scaleY.snap(Double(plane.scaleY ?? plane.scaleX ?? 100))
        m.alpha.snap(Double(plane.alpha))
    }

    private func finish(_ m: Motion) {
        m.x.snap(m.x.to); m.y.snap(m.y.to)
        m.scaleX.snap(m.scaleX.to); m.scaleY.snap(m.scaleY.to)
        m.alpha.snap(m.alpha.to)
        m.quake = nil
    }

    /// Ends every motion now (a tap through a wait).
    public func finishMotions() {
        for m in motions.values { finish(m) }
        screenQuake = nil
    }

    /// A plane as it stands at `time`: its place (as `x`/`y` would give it; a plane without
    /// one counts as standing at the screen's centre while it slides), scale (percent),
    /// alpha (0–255) and the shake's offset in pixels.
    public struct State: Equatable, Sendable {
        /// Nil while the plane has no place of its own (pictures then stand where their base
        /// point or top-left corner says).
        public var x: Double?
        public var y: Double?
        public var scaleX: Double
        public var scaleY: Double
        public var alpha: Double
        public var offsetX: Double
        public var offsetY: Double
    }

    public func state(_ n: Int, _ plane: ScenePlayer.Plane, at time: Double) -> State {
        let frame = time * EmoteStage.framesPerSecond
        guard let m = motions[n] else {
            return State(x: plane.x.map(Double.init), y: plane.y.map(Double.init), scaleX: Double(plane.scaleX ?? 100),
                         scaleY: Double(plane.scaleY ?? plane.scaleX ?? 100), alpha: Double(plane.alpha), offsetX: 0, offsetY: 0)
        }
        var dx = 0.0, dy = 0.0
        if let quake = m.quake {
            if let o = quake.offset(at: frame) { dx += o.x; dy += o.y } else { m.quake = nil }
        }
        if let quake = screenQuake {
            if let o = quake.offset(at: frame) { dx += o.x; dy += o.y } else { screenQuake = nil }
        }
        return State(x: plane.x == nil ? nil : m.x.value(at: frame), y: plane.y == nil ? nil : m.y.value(at: frame), scaleX: m.scaleX.value(at: frame),
                     scaleY: m.scaleY.value(at: frame), alpha: m.alpha.value(at: frame), offsetX: dx, offsetY: dy)
    }

    /// Whether a plane is moving, scaling, fading or shaking at `time`.
    public func isMoving(at time: Double) -> Bool {
        let frame = time * EmoteStage.framesPerSecond
        if let q = screenQuake, frame < q.start + q.frames { return true }
        return motions.values.contains { m in
            !m.x.done(at: frame) || !m.y.done(at: frame) || !m.scaleX.done(at: frame) || !m.scaleY.done(at: frame)
                || !m.alpha.done(at: frame) || (m.quake.map { frame < $0.start + $0.frames } ?? false)
        }
    }
}
