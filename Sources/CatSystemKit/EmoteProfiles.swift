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
    public struct Pattern {
        public var assignments: [(String, Double)] = []
        public var isDefault = false
    }

    public struct Expressions {
        public var scaleX = 1.0, scaleY = 1.0
        public var positionX = 0.0, positionY = 0.0
        public var scaleOffsetX = 0.0, scaleOffsetY = 0.0
        public var defaults: [String: Double] = [:]
        /// Digit → code → pattern.
        public var patterns: [Int: [String: Pattern]] = [:]
    }

    public struct Profile {
        public var bodies: [Int: String] = [:]
        public var expressions: [Int: String] = [:]
        public var bodyFile: String?
    }

    /// What `mpl N model,…` asks for: the PSB, its variables and its placement.
    public struct Pose {
        public let model: String
        public let variables: [String: Double]
        public let scaleX: Double, scaleY: Double
        public let positionX: Double, positionY: Double
        public let scaleOffsetX: Double, scaleOffsetY: Double
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
            guard let n = Int(n), p.expressions[n] == nil else { continue }
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
        if let last = digits.last, let colon = last.firstIndex(of: ":") { digits[digits.count - 1] = String(last[..<colon]) }
        for (i, code) in digits.enumerated() {
            guard let p = face.patterns[i + 1]?[code.lowercased()] else { continue }
            for (k, v) in p.assignments { variables[k] = v }
        }
        // `face_talk 1` marks a talking mouth (lip sync from the voice); at rest it is shut.
        if variables["face_talk"] != nil { variables["face_talk"] = 0 }
        if let bodyFile = profile.bodyFile {
            let b = expressions(bodyFile)
            for (_, codes) in b.patterns { for (_, p) in codes where p.isDefault { for (k, v) in p.assignments { variables[k] = v } } }
            for (i, code) in body.enumerated() where code != "@" {
                guard let p = b.patterns[i + 1]?[code.lowercased()] else { continue }
                for (k, v) in p.assignments { variables[k] = v }
            }
        }
        return Pose(model: model, variables: variables, scaleX: face.scaleX, scaleY: face.scaleY,
                    positionX: face.positionX, positionY: face.positionY,
                    scaleOffsetX: face.scaleOffsetX, scaleOffsetY: face.scaleOffsetY)
    }
}
