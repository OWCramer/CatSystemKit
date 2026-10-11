import Foundation

/// The game's E-mote settings (`m2config.int`), which turn a scene's `mpl` arguments into a
/// model file, its variables and its place on screen.
///
/// - `m2view.cnf`: `#profile` maps a character name (`ca01`, `ca01l`, `ca01s`, `ca01z`) to a
///   profile (`ca01.pfl`). The suffix picks a size: none and `l` use the large model
///   (`ca01_l_body_N`), `s` the medium and `z` the small one.
/// - A profile (`.pfl`): `#charaname` numbers the bodies (outfits) and names their PSB
///   (`1 body ca01_l_body_1`); `#motname` gives each body its expression file (`ca_m.dif`)
///   and the shared `body.dif`.
/// - An expression file (`.dif`) includes the character's `.inc` and sets the scale, the
///   position the scene's 0,0 stands for, and the scale centre. The `.inc` sets resting
///   values (`#defval`) and the digit patterns: `%2 b b` then `face_mouth 10`,
///   `face_talk 1` says mouth digit `b` sets those variables.
/// - `body.dif` does the same for `m2body`'s digits (head and body angles, gaze, arms …).
///
/// A scene's `mpl 2 ca01,1,1,b,3,0,4,0:0` is the character, the body, then one digit per
/// `.inc` pattern (cheek, mouth, eyes, tears, eyebrows, highlight); a `:` after the last
/// digit picks the idle motion, not used here.
public final class EmoteProfiles {
    public struct Pattern: Sendable {
        public var assignments: [(String, Double)] = []
        public var isDefault = false
    }

    /// `#blink`: while digit `digit` shows `code`, the eyes blink every `minWait`…`maxWait`
    /// frames, `face_eye_open` going from `from` to `to` and back in `frames`.
    public struct Blink: Sendable {
        public var digit: Int, code: String
        public var from: Double, to: Double, frames: Double
        public var minWait: Double, maxWait: Double
    }

    /// `#lip_table`: while digit `digit` shows `code` and a voice plays, its level (the `.lv`
    /// files' values ×100) between `low` and `high` picks one of `levels` for the lip
    /// variable (`#lip_variable`, `face_talk`), linearly between them.
    public struct Lip: Sendable {
        public var digit: Int, code: String
        public var low: Double, high: Double
        public var levels: [Double]
        public var variable: String
        /// `#lip_flow`: for a voice without levels (no `.lv` beside it), the mouth runs through
        /// these (lip variable value, frames, whether it may stop here once the voice is quiet).
        public var flow: [(value: Double, frames: Double, mayStop: Bool)] = []
    }

    /// `#chain`: how a digit's variables move when its code changes: `fix` (at once),
    /// `linear` or `sin_fs` (easing out) over `frames`; `pairs` (`from>to`) override that per
    /// change, from a `$table`.
    public struct Chain: Sendable {
        public var curve = "fix"
        public var frames = 1.0
        public var pairs: [String: (curve: String, frames: Double)] = [:]
    }

    public struct Expressions: Sendable {
        public var scaleX = 1.0, scaleY = 1.0
        public var positionX = 0.0, positionY = 0.0
        public var scaleOffsetX = 0.0, scaleOffsetY = 0.0
        public var defaults: [String: Double] = [:]
        /// Digit → code → pattern.
        public var patterns: [Int: [String: Pattern]] = [:]
        public var blinks: [Blink] = []
        public var lips: [Lip] = []
        public var chains: [Int: Chain] = [:]
        /// `#material`: the inertia variables (hair, bust, `quake`) as springs.
        public var materials: [String: Material] = [:]
        /// `#inertia_lr` / `#inertia_ud`: variables that lag when the character moves.
        public var inertiaLR: [String] = []
        public var inertiaUD: [String] = []
        /// `#inertia_dif`: a pose variable's change pushes another (`head_LR` swings the
        /// hair), by `power`, up to `limit`.
        public var inertiaFromChange: [(source: String, target: String, power: Double, limit: Double)] = []
        /// `#attribute`: number → an offset from the head and an extra value (the model's
        /// size, 1–4), for `mpl N m2att`.
        public var attributes: [Int: (x: Double, y: Double, extra: Int)] = [:]
    }

    /// `#material`: mass, spring, resistance, time step (a frame's share of the spring's
    /// time), largest displacement, inverted, and the scale of a move in pixels.
    public struct Material: Sendable {
        public var mass = 1.0, spring = 1.0, resistance = 1.0, step = 0.1
        public var limit = 50.0
        public var inverted = false
        public var scale = 30.0
    }

    public struct Profile {
        public var bodies: [Int: String] = [:]
        public var expressions: [Int: String] = [:]
        public var bodyFile: String?
        /// Body → idle number (the `:n` after a scene's digits) → timeline label.
        public var idles: [Int: [Int: String]] = [:]
    }

    /// What `mpl N model,…` asks for: the PSB, its variables and its placement.
    public struct Pose: Sendable {
        public let model: String
        public let variables: [String: Double]
        public let scaleX: Double, scaleY: Double
        public let positionX: Double, positionY: Double
        public let scaleOffsetX: Double, scaleOffsetY: Double
        /// The expression digits' codes (digit → code) and `m2body`'s.
        public var codes: [Int: String] = [:]
        public var bodyCodes: [Int: String] = [:]
        /// The idle timeline (`差分用_waiting_loop` …), or nil for none.
        public var idle: String?
        /// The expression file's settings (blinks, lip sync, chains) and the body file's.
        public var face = Expressions()
        public var body = Expressions()

        /// The blink for the eyes shown, if they blink.
        public var blink: Blink? { face.blinks.first { codes[$0.digit] == $0.code } }
        /// The lip sync for the mouth shown, if it has one.
        public var lip: Lip? { face.lips.first { codes[$0.digit] == $0.code } }

        /// How each variable that differs between `old` and this pose gets here: the chain
        /// of the digit whose code changed (curve and frames; `fix` is at once).
        public func transitions(from old: Pose) -> [String: (curve: String, frames: Double)] {
            var out: [String: (curve: String, frames: Double)] = [:]
            for (file, oldCodes, newCodes) in [(face, old.codes, codes), (body, old.bodyCodes, bodyCodes)] {
                for (digit, code) in newCodes where oldCodes[digit] != code {
                    let chain = file.chains[digit] ?? Chain()
                    let rule = oldCodes[digit].flatMap { chain.pairs[$0 + ">" + code] } ?? (chain.curve, chain.frames)
                    var names = Set((file.patterns[digit]?[code]?.assignments ?? []).map(\.0))
                    if let previous = oldCodes[digit] { names.formUnion((file.patterns[digit]?[previous]?.assignments ?? []).map(\.0)) }
                    for name in names { out[name] = rule }
                }
            }
            return out
        }
    }

    private let files: (String) -> [UInt8]?
    private var profileFiles: [String: String] = [:]
    private var profiles: [String: Profile] = [:]
    private var expressionCache: [String: Expressions] = [:]

    public init(files: @escaping (String) -> [UInt8]?) {
        self.files = files
        for (key, values) in Self.sections(text("m2view.cnf"))["profile"] ?? [] where values.count >= 1 {
            profileFiles[key.lowercased()] = values[0]
        }
    }

    public convenience init(game: CatSystemGame) {
        self.init(files: { try? game.file(named: $0) })
    }

    public var isEmpty: Bool { profileFiles.isEmpty }

    private func text(_ name: String) -> String {
        guard let bytes = files(name) else { return "" }
        return String(data: Data(bytes), encoding: cp932) ?? String(decoding: bytes, as: UTF8.self)
    }

    /// `#section` blocks of whitespace-separated lines, `//` and `/* */` comments removed:
    /// section → (first word, the rest).
    static func sections(_ text: String) -> [String: [(String, [String])]] {
        var out: [String: [(String, [String])]] = [:]
        var current = ""
        var inComment = false
        for raw in text.components(separatedBy: .newlines) {
            var line = raw
            if inComment {
                guard let end = line.range(of: "*/") else { continue }
                line = String(line[end.upperBound...])
                inComment = false
            }
            if let start = line.range(of: "/*") {
                if let end = line.range(of: "*/", range: start.upperBound..<line.endIndex) {
                    line.removeSubrange(start.lowerBound..<end.upperBound)
                } else {
                    line = String(line[..<start.lowerBound])
                    inComment = true
                }
            }
            if let c = line.range(of: "//") { line = String(line[..<c.lowerBound]) }
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).map(String.init)
            guard let first = words.first else { continue }
            if first.hasPrefix("#") {
                current = String(first.dropFirst()).lowercased()
                continue
            }
            out[current, default: []].append((first, Array(words.dropFirst())))
        }
        return out
    }

    func profile(_ name: String) -> Profile? {
        let key = name.lowercased()
        if let p = profiles[key] { return p }
        guard let file = profileFiles[key] else { return nil }
        let s = Self.sections(text(file))
        var p = Profile()
        for (n, rest) in s["charaname"] ?? [] {
            if let n = Int(n), let psb = rest.last { p.bodies[n] = psb }
        }
        for (n, rest) in s["motname"] ?? [] {
            guard let n = Int(n) else { continue }
            // `1 0 差分用_waiting_loop ca_m.dif body.dif`: body 1's idle 0.
            if rest.count >= 2, let idle = Int(rest[0]) { p.idles[n, default: [:]][idle] = rest[1] }
            guard p.expressions[n] == nil else { continue }
            let difs = rest.filter { $0.lowercased().hasSuffix(".dif") }
            if let first = difs.first { p.expressions[n] = first }
            if difs.count > 1 { p.bodyFile = difs[1] }
        }
        profiles[key] = p
        return p
    }

    func expressions(_ file: String) -> Expressions {
        if let hit = expressionCache[file] { return hit }
        var e = Expressions()
        read(file, into: &e, depth: 0)
        expressionCache[file] = e
        return e
    }

    private func read(_ file: String, into e: inout Expressions, depth: Int) {
        guard depth < 4 else { return }
        let content = text(file)
        let s = Self.sections(content)
        for (included, _) in s["include"] ?? [] { read(included, into: &e, depth: depth + 1) }
        if let (x, rest) = s["scale"]?.first, let sx = Double(x) { e.scaleX = sx; e.scaleY = rest.first.flatMap(Double.init) ?? sx }
        if let (x, rest) = s["position"]?.first, let px = Double(x) { e.positionX = px; e.positionY = rest.first.flatMap(Double.init) ?? 0 }
        if let (x, rest) = s["scaleoffset"]?.first, let ox = Double(x) { e.scaleOffsetX = ox; e.scaleOffsetY = rest.first.flatMap(Double.init) ?? 0 }
        for (name, rest) in s["defval"] ?? [] { if let v = rest.first.flatMap(Double.init) { e.defaults[name] = v } }
        // Patterns: `%digit code label [default]`, then `variable value` lines.
        var digit: Int?
        var code = ""
        for (first, rest) in s["pattern"] ?? [] {
            if first.hasPrefix("%"), let d = Int(first.dropFirst()), let c = rest.first {
                digit = d
                code = c.lowercased()
                var p = e.patterns[d]?[code] ?? Pattern()
                p.assignments = []
                p.isDefault = rest.dropFirst().contains("default")
                e.patterns[d, default: [:]][code] = p
            } else if let d = digit, let v = rest.first.flatMap(Double.init) {
                e.patterns[d]?[code]?.assignments.append((first, v))
            }
        }
        // `#blink`: digit code from to speed minWait maxWait.
        for (first, rest) in s["blink"] ?? [] {
            guard let d = Int(first), rest.count >= 6 else { continue }
            let n = rest.dropFirst().compactMap(Double.init)
            guard n.count >= 5 else { continue }
            e.blinks.append(Blink(digit: d, code: rest[0].lowercased(), from: n[0], to: n[1], frames: n[2], minWait: n[3], maxWait: n[4]))
        }
        // `#lip_variable`: digit code variable; `#lip_table`: digit code curve low high levels…
        var lipVariables: [String: String] = [:]
        for (first, rest) in s["lip_variable"] ?? [] where rest.count >= 2 { lipVariables[first + ":" + rest[0].lowercased()] = rest[1] }
        for (first, rest) in s["lip_table"] ?? [] {
            guard let d = Int(first), rest.count >= 5, let low = Double(rest[2]), let high = Double(rest[3]) else { continue }
            let code = rest[0].lowercased()
            e.lips.append(Lip(digit: d, code: code, low: low, high: high, levels: rest.dropFirst(4).compactMap(Double.init),
                              variable: lipVariables[first + ":" + code] ?? "face_talk"))
        }
        // `#lip_flow`: digit code `value,frames,check` steps.
        for (first, rest) in s["lip_flow"] ?? [] {
            guard let d = Int(first), rest.count >= 2 else { continue }
            let code = rest[0].lowercased()
            let steps = rest.dropFirst().compactMap { step -> (value: Double, frames: Double, mayStop: Bool)? in
                let n = step.split(separator: ",").compactMap { Double($0) }
                return n.count >= 2 ? (n[0], max(1, n[1]), n.count > 2 && n[2] != 0) : nil
            }
            if let i = e.lips.firstIndex(where: { $0.digit == d && $0.code == code }) { e.lips[i].flow = steps }
        }
        // `#attribute`: number x y extra.
        for (first, rest) in s["attribute"] ?? [] {
            guard let n = Int(first), rest.count >= 2, let x = Double(rest[0]), let y = Double(rest[1]) else { continue }
            e.attributes[n] = (x, y, rest.count > 2 ? Int(rest[2]) ?? 3 : 3)
        }
        // `#chain`: `digit curve frames` or `digit $table`, then the tables: `$name`,
        // `default curve`, `frame n`, `from to curve frames`.
        var tables: [String: Chain] = [:]
        var tableDigits: [Int: String] = [:]
        var table: String?
        for (first, rest) in s["chain"] ?? [] {
            if first.hasPrefix("$"), rest.isEmpty {
                table = first
                tables[first] = Chain()
            } else if let t = table {
                switch first {
                case "default": tables[t]?.curve = rest.first ?? "fix"
                case "frame": tables[t]?.frames = rest.first.flatMap(Double.init) ?? 1
                default:
                    if rest.count >= 3, let frames = Double(rest[2]) { tables[t]?.pairs[first.lowercased() + ">" + rest[0].lowercased()] = (rest[1], frames) }
                }
            } else if let d = Int(first), let curve = rest.first {
                if curve.hasPrefix("$") {
                    tableDigits[d] = curve
                } else {
                    e.chains[d] = Chain(curve: curve, frames: rest.count > 1 ? Double(rest[1]) ?? 1 : 1)
                }
            }
        }
        for (d, name) in tableDigits { if let t = tables[name] { e.chains[d] = t } }
        // Inertia.
        for (name, rest) in s["material"] ?? [] {
            let n = rest.compactMap(Double.init)
            guard n.count >= 5 else { continue }
            e.materials[name] = Material(mass: max(0.01, n[0]), spring: n[1], resistance: n[2], step: n[3], limit: n[4],
                                         inverted: n.count > 5 && n[5] != 0, scale: n.count > 6 ? max(1, n[6]) : 30)
        }
        e.inertiaLR += (s["inertia_lr"] ?? []).map(\.0)
        e.inertiaUD += (s["inertia_ud"] ?? []).map(\.0)
        for (source, rest) in s["inertia_dif"] ?? [] where rest.count >= 3 {
            if let power = Double(rest[1]), let limit = Double(rest[2]) { e.inertiaFromChange.append((source, rest[0], power, limit)) }
        }
    }

    /// The pose for `spec` (`ca01,1,1,b,3,0,4,0:0`) and `m2body` digits (`1,2,1,1,1,1`; `@`
    /// keeps the resting value).
    public func pose(_ spec: String, body: [String] = []) -> Pose? {
        let fields = spec.split(separator: ",", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let name = fields.first, let profile = profile(name) else { return nil }
        let bodyNumber = fields.count > 1 ? Int(fields[1]) ?? 1 : 1
        guard let model = profile.bodies[bodyNumber] ?? profile.bodies.sorted(by: { $0.key < $1.key }).first?.value else { return nil }
        let expressionFile = profile.expressions[bodyNumber] ?? profile.expressions.values.first
        let face = expressionFile.map(expressions) ?? Expressions()
        var variables = face.defaults
        // Each digit's default pattern, then the scene's digits.
        for (_, codes) in face.patterns { for (_, p) in codes where p.isDefault { for (k, v) in p.assignments { variables[k] = v } } }
        var digits = Array(fields.dropFirst(2))
        var idleNumber = 0
        if let last = digits.last, let colon = last.firstIndex(of: ":") {
            digits[digits.count - 1] = String(last[..<colon])
            idleNumber = Int(last[last.index(after: colon)...]) ?? 0
        }
        var codes: [Int: String] = [:]
        for (digit, digitCodes) in face.patterns {
            if let d = digitCodes.first(where: { $0.value.isDefault })?.key { codes[digit] = d }
        }
        for (i, code) in digits.enumerated() {
            guard let p = face.patterns[i + 1]?[code.lowercased()] else { continue }
            codes[i + 1] = code.lowercased()
            for (k, v) in p.assignments { variables[k] = v }
        }
        // `face_talk 1` marks a talking mouth (lip sync from the voice); at rest it is shut.
        if variables["face_talk"] != nil { variables["face_talk"] = 0 }
        var bodyCodes: [Int: String] = [:]
        var b = Expressions()
        if let bodyFile = profile.bodyFile {
            b = expressions(bodyFile)
            for (digit, digitCodes) in b.patterns {
                for (code, p) in digitCodes where p.isDefault {
                    bodyCodes[digit] = code
                    for (k, v) in p.assignments { variables[k] = v }
                }
            }
            for (i, code) in body.enumerated() where code != "@" {
                guard let p = b.patterns[i + 1]?[code.lowercased()] else { continue }
                bodyCodes[i + 1] = code.lowercased()
                for (k, v) in p.assignments { variables[k] = v }
            }
        }
        var pose = Pose(model: model, variables: variables, scaleX: face.scaleX, scaleY: face.scaleY,
                        positionX: face.positionX, positionY: face.positionY,
                        scaleOffsetX: face.scaleOffsetX, scaleOffsetY: face.scaleOffsetY)
        pose.codes = codes
        pose.bodyCodes = bodyCodes
        pose.idle = profile.idles[bodyNumber]?[idleNumber]
        pose.face = face
        pose.body = b
        return pose
    }
}
