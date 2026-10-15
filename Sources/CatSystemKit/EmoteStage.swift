// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation

/// The E-mote characters on screen over time: what `ScenePlayer` leaves as end states
/// (`mpl` positions, fades, poses) played out frame by frame, plus what the game's E-mote
/// settings add while a character stands there.
///
/// - Poses: a new expression or `m2body` moves each changed variable by its digit's
///   `#chain` (eyes and eyebrows `linear 10` between most codes, the body file's digits
///   `sin_fs 30`, the rest at once), `m2fspeed` scaling the time and `m2prmscale` the
///   values (`m2prmscale 66 head_UD head_LR` turns the head two thirds as far).
/// - Idle: the profile's idle timeline for the `:n` after the digits (`差分用_waiting_loop`:
///   the body rising and falling over three seconds), added to the pose (a difference
///   timeline).
/// - Blinking: the `#blink` entry for the eyes shown, every `minWait`…`maxWait` frames.
/// - Lip sync: while a voice plays (`A_01_001`: `a` is character `ca…`), the level from its
///   `.lv` file (one float per 1/60 s) picks the mouth's `face_talk` from `#lip_table`. A
///   voice without one (Cinnamon's in scene 12, the touch voices) runs the mouth through
///   `#lip_flow` while the voice is loud enough (its own level, measured as it decodes),
///   stopping at the flow's marked steps once it falls quiet.
/// - Inertia: `m2iner pause [variable]` holds the named springs (or all) still through the
///   moves that follow (a camera pan carrying the character), until its next pose change
///   once it stands still.
/// - Motions: `amove1/2/3` and `move` slide to their end point over their frames (easing
///   out, in, both, or linear), `fade` and `ascale` likewise, `arc` hops.
///
/// Times are in seconds (any clock); the game counts frames at 60 a second.
public final class EmoteStage {
    public let cast: EmoteCast
    public static let framesPerSecond = 60.0
    /// The screen the scene coordinates are for.
    public var width = 1280.0, height = 720.0
    /// Hair and bust physics (on).
    public var physicsEnabled = true
    /// The CONFIG's "Chest Bounciness" (`m2_setconf iner_lv N bust`, 0–200 over 100): how
    /// strongly the bust springs answer a push.
    public var bustInertia = 1.0

    public init(cast: EmoteCast) {
        self.cast = cast
    }

    // MARK: Tweens

    public enum Curve {
        case linear, easeOut, easeIn, easeInOut

        init(_ name: String) {
            switch name {
            case "sin_fs", "sin_f": self = .easeOut
            case "sin_sf", "sin_s": self = .easeIn
            case "sin", "sin_ss": self = .easeInOut
            default: self = .linear
            }
        }

        func apply(_ t: Double) -> Double {
            switch self {
            case .linear: t
            case .easeOut: sin(t * .pi / 2)
            case .easeIn: 1 - cos(t * .pi / 2)
            case .easeInOut: 0.5 - cos(t * .pi) / 2
            }
        }
    }

    /// A value moving from `from` to `to` over `frames` from frame `start`.
    struct Tween {
        var from: Double
        var to: Double
        var start = 0.0
        var frames = 0.0
        var curve = Curve.linear

        init(_ value: Double) { from = value; to = value }

        func value(at frame: Double) -> Double {
            guard frames > 0 else { return to }
            let t = min(1, max(0, (frame - start) / frames))
            return from + (to - from) * curve.apply(t)
        }

        func done(at frame: Double) -> Bool { frames <= 0 || frame >= start + frames }

        mutating func move(to target: Double, frames: Double, curve: Curve, at frame: Double) {
            from = value(at: frame)
            to = target
            start = frame
            self.frames = frames
            self.curve = curve
        }

        mutating func snap(_ target: Double) { self = Tween(target) }
    }

    final class Actor: @unchecked Sendable {
        var spec: String?
        var body: [String] = []
        var pose: EmoteProfiles.Pose?
        var renderer: EmoteRenderer?
        var resting: [String: Double] = [:]
        /// Pose variables (with `m2prmscale`), moving by their chains.
        var variables: [String: Tween] = [:]
        var x = Tween(640), y = Tween(360)
        var alpha = Tween(255)
        var scaleX = Tween(100), scaleY = Tween(100)
        var rotation = 0.0
        var visible = true
        var idleStart = 0.0
        var nextBlink = 0.0
        var blinkStart: Double?
        var lipEnabled = true
        var blinkEnabled = true
        /// `m2fspeed`: percent speed of the named variables' transitions.
        var speeds: [String: Double] = [:]
        /// `m2prmscale`: percent of the named variables' pose values.
        var parameterScales: [String: Double] = [:]
        var arc: (start: Double, frames: Double, from: Double, to: Double, x: Double, y: Double)?
        /// `quake f,x,y …`: offsets in turn; `shake frames amplitude … count`: a bounce.
        var quake: PlaneStage.Quake?
        var shake: (start: Double, frames: Double, amplitude: Double, count: Double)?
        /// Inertia variables: displacement and velocity.
        var springs: [String: (x: Double, v: Double)] = [:]
        /// What moved them last frame: the pose variables and the position.
        var lastSources: [String: Double] = [:]
        var lastFrame: Double?
        /// `m2iner pause`: springs held (`*` all of them).
        var pausedSprings: Set<String> = []
        /// `#lip_flow` under way: the step and the frame it began.
        var flow: (step: Int, start: Double)?
    }

    // MARK: Inertia

    /// Hair, bust and `quake` variables as the game's `#material` springs: each lags behind
    /// a move of the character (`#inertia_lr` / `#inertia_ud`, by the pixels moved over the
    /// material's scale) and a change of the pose variables `#inertia_dif` names (a head
    /// turn swings the hair, the idle loop's breathing bobs it), then springs back. Each
    /// frame moves the spring on by the material's time step.
    private func inertia(_ a: Actor, pose: EmoteProfiles.Pose, variables v: inout [String: Double], x: Double, y: Double, frame: Double) {
        let face = pose.face
        guard !face.materials.isEmpty else { return }
        let frames = min(4, max(0, frame - (a.lastFrame ?? frame)))
        a.lastFrame = frame
        var sources = ["@x": x, "@y": y]
        for (source, _, _, _) in face.inertiaFromChange { sources[source] = v[source] ?? 0 }
        var kicks: [String: Double] = [:]
        if !a.lastSources.isEmpty {
            let dx = x - (a.lastSources["@x"] ?? x), dy = y - (a.lastSources["@y"] ?? y)
            for name in face.inertiaLR { kicks[name, default: 0] -= dx / (face.materials[name]?.scale ?? 30) }
            for name in face.inertiaUD { kicks[name, default: 0] -= dy / (face.materials[name]?.scale ?? 30) }
            for (source, target, power, _) in face.inertiaFromChange {
                kicks[target, default: 0] -= ((sources[source] ?? 0) - (a.lastSources[source] ?? 0)) * power
            }
        }
        a.lastSources = sources
        var limits: [String: Double] = [:]
        for (_, target, _, limit) in face.inertiaFromChange { limits[target] = max(limits[target] ?? 0, limit) }
        for (name, m) in face.materials {
            var s = a.springs[name] ?? (0, 0)
            let bust = name.lowercased().contains("bust") ? bustInertia : 1
            let held = a.pausedSprings.contains("*") || a.pausedSprings.contains(name)
            s.x += held ? 0 : (kicks[name] ?? 0) * (m.inverted ? -1 : 1) * bust
            // Integrated in small steps for stability: a = (−k·x − c·v) / m.
            let steps = max(1, Int((frames * 4).rounded(.up)))
            let h = frames * m.step / Double(steps)
            for _ in 0..<steps where h > 0 {
                let accel = (-m.spring * s.x - m.resistance * s.v) / m.mass
                s.v += accel * h
                s.x += s.v * h
            }
            s.x = min(m.limit, max(-m.limit, s.x))
            a.springs[name] = s
            let limit = limits[name] ?? 30
            v[name] = (v[name] ?? 0) + min(limit, max(-limit, s.x))
        }
    }

    private var actors: [Int: Actor] = [:]
    private var random = SystemRandomNumberGenerator()

    // MARK: Voice

    private var voiceName: String?
    private var voiceLevels: [Float] = []
    private var voiceStart = 0.0
    /// The voice's own loudness (RMS, one per 1/60 s), for `#lip_flow`.
    private var voiceEnvelope: [Float] = []
    /// How loud (RMS of samples in -1…1) a voice must be for the flow to run.
    public static let flowThreshold: Float = 0.02

    /// The voice playing (`A_01_001`) and when it began, or nil. Its `.lv` levels are read
    /// once per voice; `envelope` is its loudness per 1/60 s (for voices without them).
    public func setVoice(_ name: String?, startedAt start: Double, envelope: [Float] = []) {
        guard let name else {
            voiceName = nil
            voiceLevels = []
            voiceEnvelope = []
            return
        }
        if name.lowercased() != voiceName?.lowercased() {
            voiceName = name
            voiceLevels = cast.files(name.lowercased() + ".lv").map(Self.levels) ?? []
        }
        voiceEnvelope = envelope
        voiceStart = start
    }

    /// Loudness per 1/60 s (RMS) of mono or interleaved samples at `rate` a second.
    public static func envelope(_ samples: UnsafeBufferPointer<Float>, rate: Double) -> [Float] {
        let step = max(1, Int(rate / framesPerSecond))
        var out: [Float] = []
        out.reserveCapacity(samples.count / step + 1)
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + step)
            var sum: Float = 0
            for j in i..<end { sum += samples[j] * samples[j] }
            out.append((sum / Float(end - i)).squareRoot())
            i = end
        }
        return out
    }

    /// The `#lip_flow` value for a mouth at `frame` of the voice, or nil while it rests.
    private func flowValue(_ a: Actor, _ flow: [(value: Double, frames: Double, mayStop: Bool)], voiceFrame: Double, frame: Double) -> Double? {
        let i = Int(voiceFrame)
        let sounding = voiceEnvelope.isEmpty ? true : (i >= 0 && i < voiceEnvelope.count && voiceEnvelope[i] >= Self.flowThreshold)
        guard var state = a.flow else {
            guard sounding else { return nil }
            a.flow = (0, frame)
            return flow[0].value
        }
        var steps = 0
        while frame >= state.start + flow[state.step].frames, steps < 64 {
            steps += 1
            if flow[state.step].mayStop, !sounding {
                a.flow = nil
                return nil
            }
            state.start += flow[state.step].frames
            state.step = (state.step + 1) % flow.count
        }
        // Far behind (a pause): start again from here.
        if frame - state.start > 120 { state = (state.step, frame) }
        a.flow = state
        return flow[state.step].value
    }

    /// `.lv` files: little-endian 32-bit floats, one per 1/60 s of the voice.
    public static func levels(_ bytes: [UInt8]) -> [Float] {
        stride(from: 0, to: bytes.count - 3, by: 4).map { o in
            Float(bitPattern: UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24)
        }
    }

    // MARK: Commands

    /// Starts again from `cast` (a loaded save), everything at rest.
    public func reset(_ cast: [Int: ScenePlayer.Character], time: Double) {
        actors = [:]
        let frame = time * Self.framesPerSecond
        for (n, c) in cast { actors[n] = makeActor(c, frame: frame) }
    }

    private func makeActor(_ c: ScenePlayer.Character, frame: Double) -> Actor {
        let a = Actor()
        a.x.snap(Double(c.x ?? 640)); a.y.snap(Double(c.y ?? 360))
        a.alpha.snap(Double(c.alpha))
        a.scaleX.snap(Double(c.scaleX)); a.scaleY.snap(Double(c.scaleY))
        a.rotation = Double(c.rotation ?? 0)
        a.visible = c.visible
        // Characters that come on together don't breathe in step.
        a.idleStart = frame - Double.random(in: 0..<90, using: &random)
        a.nextBlink = frame + Double.random(in: 30...120, using: &random)
        setPose(a, c, frame: frame, animate: false)
        return a
    }

    /// Carries out an `mpl` command the scene player has just applied (`cast` is its cast
    /// after it).
    public func command(_ text: String, cast: [Int: ScenePlayer.Character], time: Double) {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // `fmpl` (faces in the message window) works the same, in a stage of its own.
        guard words.first == "mpl" || words.first == "fmpl" else { return }
        let frame = time * Self.framesPerSecond
        guard words.count >= 2 else { actors = [:]; return }
        // `mpl quake …` without a bank shakes every character (with `pl quake`: the screen).
        if words[1] == "quake" || words[1] == "mcquake" {
            for a in actors.values { a.quake = PlaneStage.Quake(Array(words.dropFirst(2)), start: frame) }
            return
        }
        let banks = ScenePlayer.planeNumbers(words[1])
        let args = Array(words.dropFirst(2))
        for n in banks {
            guard let c = cast[n] else { actors[n] = nil; continue }
            guard let a = actors[n] else { actors[n] = makeActor(c, frame: frame); continue }
            guard let verb = args.first else { continue }
            let number = { (i: Int) -> Double? in i < args.count ? Double(args[i].replacingOccurrences(of: "%", with: "")) : nil }
            switch verb {
            case "pos":
                a.x.snap(Double(c.x ?? 640)); a.y.snap(Double(c.y ?? 360))
            case "amove1", "amove2", "amove3", "move", "m2move":
                // `m2move`: a long, slow move (with its plane's `pl N m2move`).
                let frames = number(1) ?? 0
                let curve: Curve = verb == "amove1" ? .easeOut : verb == "amove2" ? .easeIn : verb == "amove3" ? .easeInOut : .linear
                a.x.move(to: Double(c.x ?? 640), frames: frames, curve: curve, at: frame)
                a.y.move(to: Double(c.y ?? 360), frames: frames, curve: curve, at: frame)
            case "fade":
                if let frames = number(1), let from = number(2) {
                    a.alpha.snap(from)
                    a.alpha.move(to: Double(c.alpha), frames: frames, curve: .linear, at: frame)
                } else {
                    a.alpha.snap(Double(c.alpha))
                }
            case "blend":
                a.alpha.snap(Double(c.alpha))
            case "disp":
                a.visible = c.visible
            case "rot":
                a.rotation = Double(c.rotation ?? 0)
            case "scale":
                a.scaleX.snap(Double(c.scaleX)); a.scaleY.snap(Double(c.scaleY))
            case "ascale1", "ascale2", "ascale3":
                let frames = number(1) ?? 0
                let curve: Curve = verb == "ascale1" ? .easeOut : verb == "ascale2" ? .easeIn : .easeInOut
                a.scaleX.move(to: Double(c.scaleX), frames: frames, curve: curve, at: frame)
                a.scaleY.move(to: Double(c.scaleY), frames: frames, curve: curve, at: frame)
            case "arc":
                // `arc frames fromDegrees toDegrees x y`: a hop along a sine.
                if let frames = number(1), let from = number(2), let to = number(3) {
                    a.arc = (frame, frames, from, to, number(4) ?? 0, number(5) ?? 0)
                }
            case "quake", "mcquake":
                a.quake = PlaneStage.Quake(Array(args.dropFirst()), start: frame)
            case "shake", "mcshake":
                // `shake frames amplitude [mode] [count]`: as the game has it the character
                // bobs (a glad hop, a nod); a decaying vertical bounce, `count` times.
                if let frames = number(1), let amplitude = number(2) {
                    let count = args.count >= 5 ? number(4) ?? 1 : args.count == 4 ? number(3) ?? 1 : 1
                    a.shake = (frame, max(1, frames), amplitude, max(1, count))
                }
            case "m2body":
                setPose(a, c, frame: frame, animate: true)
            case "m2fspeed", "m2prmscale":
                guard let percent = number(1) else { break }
                for name in args.dropFirst(2) {
                    if verb == "m2fspeed" { a.speeds[name] = percent } else { a.parameterScales[name] = percent }
                }
                if verb == "m2prmscale" { setPose(a, c, frame: frame, animate: true, force: true) }
            case "m2iner":
                // `m2iner pause [variable …]`: those springs (all without names) stay still.
                if args.count >= 2, args[1] == "pause" {
                    let names = args.dropFirst(2)
                    if names.isEmpty { a.pausedSprings.insert("*") } else { a.pausedSprings.formUnion(names) }
                }
            case "m2enable_lip":
                a.lipEnabled = (number(1) ?? 1) != 0
            case "m2enable_blink":
                a.blinkEnabled = (number(1) ?? 1) != 0
            default:
                if verb.contains(","), verb.first?.isLetter == true { setPose(a, c, frame: frame, animate: true) }
            }
        }
    }

    /// Takes the character's model and `m2body` from `c`. A new model starts at rest; a new
    /// expression on the same model moves there by its chains.
    private func setPose(_ a: Actor, _ c: ScenePlayer.Character, frame: Double, animate: Bool, force: Bool = false) {
        guard let spec = c.model else { return }
        guard force || spec != a.spec || c.body != a.body else { return }
        guard let pose = cast.pose(spec, body: c.body) else { return }
        let old = a.pose
        let sameModel = old?.model == pose.model
        // Held springs move again with the next pose once the character stands still.
        if !a.pausedSprings.isEmpty, !sameModel || (a.x.done(at: frame) && a.y.done(at: frame)) { a.pausedSprings = [] }
        a.spec = spec
        a.body = c.body
        a.pose = pose
        if !sameModel {
            a.renderer = cast.loadedRenderer(pose.model)
            a.resting = a.renderer?.model.restingVariables() ?? [:]
            if a.renderer == nil {
                let name = pose.model
                cast.preload(name) { [weak a] renderer in
                    guard let a, a.pose?.model == name else { return }
                    a.renderer = renderer
                    a.resting = renderer?.model.restingVariables() ?? [:]
                }
            }
        }
        let rules = (animate && sameModel) ? old.map { pose.transitions(from: $0) } ?? [:] : [:]
        for (name, value) in pose.variables {
            let target = value * (a.parameterScales[name] ?? 100) / 100
            guard animate, sameModel, var tween = a.variables[name] else {
                a.variables[name] = Tween(target)
                continue
            }
            guard tween.to != target else { continue }
            let rule = rules[name] ?? (curve: "fix", frames: 1)
            let frames = rule.frames * 100 / max(1, a.speeds[name] ?? 100)
            if rule.curve == "fix" || frames <= 1 {
                tween.snap(target)
            } else {
                tween.move(to: target, frames: frames, curve: Curve(rule.curve), at: frame)
            }
            a.variables[name] = tween
        }
        if !sameModel, old != nil { a.idleStart = frame }
    }

    // MARK: Frames

    /// A character to draw: its model with these variables, its origin at (`x`, `y`) on the
    /// 1280×720 screen and `scale` (the profile's times `scale`), faded to `alpha` (0–1).
    public struct Drawing {
        public let bank: Int
        public let renderer: EmoteRenderer
        public let variables: [String: Double]
        public let x: Double, y: Double
        public let scaleX: Double, scaleY: Double
        public let alpha: Double
        public let model: String
        /// `mpl N rot 0 0 degrees`: turned clockwise about its origin.
        public var rotation = 0.0

        /// The same drawing at another opacity.
        public func fading(_ alpha: Double) -> Drawing {
            Drawing(bank: bank, renderer: renderer, variables: variables, x: x, y: y, scaleX: scaleX, scaleY: scaleY, alpha: alpha,
                    model: model, rotation: rotation)
        }
    }

    /// The characters at `time`, by bank (those still loading are left out).
    public func drawings(at time: Double) -> [Drawing] {
        let frame = time * Self.framesPerSecond
        var out: [Drawing] = []
        let speaker = voiceName.flatMap(\.first).map { "c" + String($0).lowercased() }
        let voiceFrame = (time - voiceStart) * Self.framesPerSecond
        for n in actors.keys.sorted() {
            guard let a = actors[n], a.visible, let pose = a.pose, let renderer = a.renderer else { continue }
            let alpha = a.alpha.value(at: frame)
            guard alpha > 0.5 else { continue }
            var v = a.resting
            for (name, tween) in a.variables { v[name] = tween.value(at: frame) }
            // Idle loop.
            if let idle = pose.idle, let timeline = renderer.model.timelines[idle] {
                for (name, value) in renderer.model.timelineValues(idle, at: frame - a.idleStart) {
                    v[name] = timeline.difference ? (v[name] ?? 0) + value : value
                }
            }
            // Blinking.
            if a.blinkEnabled, let blink = pose.blink {
                if a.blinkStart == nil, frame >= a.nextBlink { a.blinkStart = frame }
                if let start = a.blinkStart {
                    let t = (frame - start) / max(1, blink.frames)
                    if t >= 1 {
                        a.blinkStart = nil
                        a.nextBlink = frame + Double.random(in: blink.minWait...max(blink.minWait, blink.maxWait), using: &random)
                    } else {
                        let base = v["face_eye_open"] ?? blink.from
                        v["face_eye_open"] = t < 0.5 ? blink.from + (blink.to - blink.from) * t * 2
                                                     : blink.to + (base - blink.to) * (t - 0.5) * 2
                    }
                }
            } else {
                a.blinkStart = nil
            }
            // Lip sync.
            let speaking = a.lipEnabled && speaker.map { pose.model.lowercased().hasPrefix($0) } == true && voiceFrame >= 0
            if speaking, voiceLevels.isEmpty, let lip = pose.lip, !lip.flow.isEmpty {
                if let value = flowValue(a, lip.flow, voiceFrame: voiceFrame, frame: frame) { v[lip.variable] = value }
            } else {
                a.flow = nil
            }
            if a.lipEnabled, let lip = pose.lip, let speaker, pose.model.lowercased().hasPrefix(speaker),
               voiceFrame >= 0, Int(voiceFrame) < voiceLevels.count {
                let level = Double(voiceLevels[Int(voiceFrame)]) * 100
                let levels = lip.levels.count > 1 ? Array(lip.levels.dropFirst()) : lip.levels
                if !levels.isEmpty {
                    let position = min(1, max(0, (level - lip.low) / max(1, lip.high - lip.low))) * Double(levels.count - 1)
                    let i = Int(position), f = position - Double(i)
                    let value = i + 1 < levels.count ? levels[i] + (levels[i + 1] - levels[i]) * f : levels[i]
                    v[lip.variable] = value
                }
            }
            var x = a.x.value(at: frame), y = a.y.value(at: frame)
            if let arc = a.arc {
                let t = (frame - arc.start) / max(1, arc.frames)
                if t >= 1 {
                    a.arc = nil
                } else {
                    let s = sin((arc.from + (arc.to - arc.from) * t) * .pi / 180)
                    x += arc.x * s
                    y -= arc.y * s
                }
            }
            if let quake = a.quake {
                if let o = quake.offset(at: frame) { x += o.x; y += o.y } else { a.quake = nil }
            }
            if let shake = a.shake {
                let t = (frame - shake.start) / shake.frames
                if t >= 1 {
                    a.shake = nil
                } else if t >= 0 {
                    y -= shake.amplitude * abs(sin(t * shake.count * .pi)) * (1 - t * 0.5)
                }
            }
            if physicsEnabled { inertia(a, pose: pose, variables: &v, x: x, y: y, frame: frame) }
            renderer.model.applySelectors(&v)
            let mx = a.scaleX.value(at: frame) / 100, my = a.scaleY.value(at: frame) / 100
            out.append(Drawing(bank: n, renderer: renderer, variables: v,
                               x: x + pose.positionX + width / 2 + pose.scaleOffsetX * (1 - mx),
                               y: y + pose.positionY + height / 2 + pose.scaleOffsetY * (1 - my),
                               scaleX: pose.scaleX * mx, scaleY: pose.scaleY * my,
                               alpha: alpha / 255, model: pose.model, rotation: a.rotation))
        }
        return out
    }

    /// Where the character in a bank stands at `time` (scene coordinates: its `pos`, slides
    /// under way), or nil when there is none.
    public func place(bank: Int, at time: Double) -> (x: Double, y: Double)? {
        guard let a = actors[bank] else { return nil }
        let frame = time * Self.framesPerSecond
        return (a.x.value(at: frame), a.y.value(at: frame))
    }

    /// Whether anything is moving at `time` besides the idle loops and blinks (a slide, fade,
    /// pose change or hop under way): a wait can be cut short only by a tap meanwhile.
    public func isMoving(at time: Double) -> Bool {
        let frame = time * Self.framesPerSecond
        return actors.values.contains { a in
            a.arc != nil || a.quake != nil || a.shake != nil || !a.x.done(at: frame) || !a.y.done(at: frame) || !a.alpha.done(at: frame)
                || a.variables.values.contains { !$0.done(at: frame) }
        }
    }

    /// Ends every slide, fade and pose change now (a tap through a wait).
    public func finishMotions() {
        for a in actors.values {
            a.x.snap(a.x.to); a.y.snap(a.y.to); a.alpha.snap(a.alpha.to)
            a.scaleX.snap(a.scaleX.to); a.scaleY.snap(a.scaleY.to)
            for (k, t) in a.variables { a.variables[k] = Tween(t.to) }
            a.arc = nil
            a.quake = nil
            a.shake = nil
        }
    }
}
