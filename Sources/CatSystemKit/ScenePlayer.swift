import Foundation

/// Plays CatScene scenes (`.cst`) in order, headless: messages with their speakers in the
/// chosen language (from the `.cstl` beside each scene, matched by message number), and the
/// commands as changes to the screen's state.
///
/// In the game, `sscript.kcs` does this: it loads the scene the title chose (`$str200`,
/// `01` for a new game; `KCSBoot` runs the scripts to find it) and carries out each line.
/// The story's order lives in the scenes themselves: `next NAME` goes on to another scene,
/// `call NAME` runs one and comes back, `if (expr) command` and `#n = expr` work on the
/// same numbered variables FES calls `$n`, and `title` returns to the title screen.
///
/// Screen state: `bg`, `cg`, `eg`, `fg` and `fw` put pictures (or `$AARRGGBB` colours) on
/// numbered planes, which `pl N …` then moves, fades and blends (plane numbers are shared:
/// `bg 0` is plane 0, `eg 1` plane 1). `mpl N model,…` shows an E-mote character in bank
/// N, which `mpl N pos`, `fade`, `scale`, `m2body` … then place and pose (`EmoteCast` draws
/// them). Sounds (`bgm`, `se`, `pcm` for voices) are recorded.
/// Waits and transitions (`wait`, `rwipe`, `rdraw`) take no time headless.
public final class ScenePlayer {
    /// Reads a file by name (`01.cst`, `01.cstl`); nil when the game has no such file.
    private let files: (String) throws -> [UInt8]?
    /// The language of messages: `en`, `jp` or `cn` (as the `.cstl` files name them).
    public var language = "en"

    public struct Message: Sendable {
        public let scene: String
        /// The message's number in its scene (the `.cstl` index).
        public let index: Int
        public let speaker: String?
        public let text: String
        /// The text as the scene has it (Japanese), for when a translation is missing.
        public let original: String
        public let voice: String?
    }

    public enum Event: Sendable {
        case scene(String)
        case command(String)
        case message(Message)
        /// A scene the story asked for isn't in the game (the Steam release leaves out the
        /// adult scenes the PC version adds as a patch).
        case missingScene(String)
        case end(String)
    }

    public struct Plane: Sendable, Codable, Equatable {
        public var kind: String
        public var file: String?
        public var color: UInt32?
        public var x: Int?
        public var y: Int?
        public var baseX: Int?
        public var baseY: Int?
        public var alpha = 255
        public var visible = true
    }

    /// An E-mote character on screen (`mpl` bank N).
    public struct Character: Sendable, Codable, Equatable {
        /// The character and expression digits (`ca01,1,1,b,3,0,4,0:0`); nil until set.
        public var model: String?
        /// `m2body` digits (head and body angles, gaze …); `@` keeps the last one.
        public var body: [String] = []
        /// Scene coordinates of the profile's origin (640, 360 is the default place).
        public var x: Int?
        public var y: Int?
        /// `scale` in percent.
        public var scaleX = 100
        public var scaleY = 100
        public var alpha = 255
        public var visible = true

        public init(model: String? = nil) { self.model = model }
    }

    public private(set) var planes: [Int: Plane] = [:]
    /// E-mote characters by bank.
    public private(set) var cast: [Int: Character] = [:]
    /// The characters' model arguments by bank (`ca01,1,1,b,3,0,4`).
    public var characters: [Int: String] { cast.compactMapValues(\.model) }
    public private(set) var bgm: String?
    public private(set) var sounds: [Int: String] = [:]
    public private(set) var voice: String?
    public private(set) var finished = false
    public var variables: [Int: Int]

    private struct Frame {
        let name: String
        let scene: CatScene
        let translation: SceneTranslation?
        var line = 0
        var messageIndex = 0
    }

    private var frames: [Frame] = []
    private var pending: [Event] = []
    private var speaker: String?
    private var text = ""
    private var inMessage = false
    private var pendingVoice: String?
    private lazy var expressions = Context(player: self)

    public convenience init(game: CatSystemGame, variables: [Int: Int] = [:]) {
        self.init(variables: variables, files: { try game.file(named: $0) })
    }

    public init(variables: [Int: Int] = [:], files: @escaping (String) throws -> [UInt8]?) {
        self.files = files
        self.variables = variables
    }

    public func start(_ scene: String) throws {
        frames = []
        finished = false
        try enter(scene)
    }

    /// Where the story is and what the screen shows, for a save: the scenes running (a
    /// `call` keeps its caller below it), the planes, characters, music and variables.
    /// Taken while a message is shown, it resumes with the message after it.
    public struct Snapshot: Codable, Sendable {
        public struct Position: Codable, Sendable {
            public var scene: String
            public var line: Int
            public var messageIndex: Int
        }

        public var stack: [Position]
        public var planes: [Int: Plane]
        public var characters: [Int: String]
        public var characterX: [Int: Int]
        /// The characters in full (saves before E-mote drawing have only the two above).
        public var cast: [Int: Character]?
        public var bgm: String?
        public var variables: [Int: Int]
    }

    public func snapshot() -> Snapshot {
        Snapshot(stack: frames.map { .init(scene: $0.name, line: $0.line, messageIndex: $0.messageIndex) },
                 planes: planes, characters: characters, characterX: cast.compactMapValues(\.x), cast: cast,
                 bgm: bgm, variables: variables)
    }

    /// Picks the story up where `snapshot` was taken.
    public func restore(_ snapshot: Snapshot) throws {
        frames = []
        pending = []
        speaker = nil
        text = ""
        inMessage = false
        pendingVoice = nil
        finished = false
        for position in snapshot.stack {
            guard let bytes = try files(position.scene + ".cst") else {
                throw CatSystemGame.Failure.notCatSystem(URL(fileURLWithPath: position.scene + ".cst"))
            }
            let scene = try CatScene(bytes)
            let translation = try files(position.scene + ".cstl").flatMap { try? SceneTranslation($0) }
            frames.append(Frame(name: position.scene, scene: scene, translation: translation,
                                line: min(position.line, scene.lines.count), messageIndex: position.messageIndex))
        }
        planes = snapshot.planes
        if let saved = snapshot.cast {
            cast = saved
        } else {
            cast = snapshot.characters.mapValues { Character(model: $0) }
            for (n, x) in snapshot.characterX { cast[n, default: Character()].x = x }
        }
        bgm = snapshot.bgm
        sounds = [:]
        voice = nil
        variables = snapshot.variables
    }

    /// The scene and line the player is at.
    public var position: (scene: String, line: Int)? { frames.last.map { ($0.name, $0.line) } }

    private func enter(_ name: String) throws {
        guard let bytes = try files(name + ".cst") else {
            pending.append(.missingScene(name))
            finished = true
            return
        }
        let scene = try CatScene(bytes)
        let translation = try files(name + ".cstl").flatMap { try? SceneTranslation($0) }
        frames.append(Frame(name: name, scene: scene, translation: translation))
        pending.append(.scene(name))
    }

    /// The next thing that happens: a scene starting, a command, a message (once its click
    /// wait is reached), or the end. Nil once the story has ended.
    public func next() throws -> Event? {
        while pending.isEmpty {
            if finished { return nil }
            try advance()
        }
        return pending.removeFirst()
    }

    private func advance() throws {
        guard var frame = frames.popLast() else {
            finished = true
            pending.append(.end("no scene"))
            return
        }
        guard frame.line < frame.scene.lines.count else {
            // A `call` returns to its caller's frame (often in the middle of a message,
            // which the caller closes); the last scene ending ends the story.
            if frames.isEmpty {
                closeMessage(&frame)
                finished = true
                pending.append(.end("end of \(frame.name)"))
            }
            return
        }
        let line = frame.scene.lines[frame.line]
        frame.line += 1
        switch line.kind {
        case .name:
            inMessage = true
            speaker = line.text
            frames.append(frame)
        case .message:
            inMessage = true
            text += line.text
            frames.append(frame)
        case .input, .page:
            closeMessage(&frame)
            frames.append(frame)
        case .command:
            frames.append(frame)
            try execute(line.text)
        default:
            frames.append(frame)
        }
    }

    private func closeMessage(_ frame: inout Frame) {
        defer { speaker = nil; text = ""; inMessage = false }
        guard inMessage, !text.isEmpty else { return }
        let translated = frame.translation.flatMap { t in
            frame.messageIndex < t.messages.count ? t.messages[frame.messageIndex][language] : nil
        }
        let name = translated.map(\.name) ?? speaker
        let message = Message(scene: frame.name, index: frame.messageIndex,
                              speaker: (name?.isEmpty ?? true) ? nil : name,
                              text: Self.clean(translated?.text ?? text), original: text, voice: pendingVoice)
        frame.messageIndex += 1
        pendingVoice = nil
        pending.append(.message(message))
    }

    /// Message text without the scene's inline codes (`\@` click marks, `\n` breaks).
    static func clean(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "\\n", with: " ")
        for code in ["\\@", "\\fs", "\\fn", "\\fl"] { t = t.replacingOccurrences(of: code, with: "") }
        return t.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Commands

    func execute(_ command: String) throws {
        var line = command.trimmingCharacters(in: .whitespaces)
        // `if (cond) command`, `if( cond ) command`.
        while line.hasPrefix("if"), let open = line.firstIndex(of: "("),
              line[line.index(line.startIndex, offsetBy: 2)..<open].allSatisfy({ $0 == " " }) {
            var depth = 0
            var close: String.Index?
            for i in line[open...].indices {
                if line[i] == "(" { depth += 1 } else if line[i] == ")" { depth -= 1; if depth == 0 { close = i; break } }
            }
            guard let close else { break }
            let condition = String(line[line.index(after: open)..<close])
            guard evaluate(condition) != 0 else { return }
            line = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        if line.hasPrefix("#") { assign(line); return }
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let verb = words.first else { return }
        let args = Array(words.dropFirst())
        switch verb {
        case "next":
            pending.append(.command(line))
            if let name = args.first {
                _ = frames.popLast()
                try enter(name)
            }
            return
        case "call":
            pending.append(.command(line))
            if let name = args.first { try enter(name) }
            return
        case "title":
            pending.append(.command(line))
            finished = true
            pending.append(.end("title"))
            frames = []
            return
        case "bg", "cg", "eg", "fg", "fw":
            planeCommand(verb, args)
        case "pl":
            planeProperty(args)
        case "mpl", "fmpl":
            characterCommand(verb, args)
        case "bgm":
            bgm = args.count >= 2 && args[1] != "end" ? args[1] : (args.count == 1 && Int(args[0]) == nil ? args[0] : nil)
        case "se":
            if let n = args.first.flatMap(Int.init) {
                if args.count >= 2, !["end", "vol", "stop"].contains(args[1]) { sounds[n] = args[1] } else if args.count < 2 { sounds[n] = nil }
            } else {
                sounds = [:]
            }
        case "pcm":
            pendingVoice = args.first
            voice = args.first
        default:
            break
        }
        pending.append(.command(line))
    }

    private func assign(_ line: String) {
        // `#196 = #197 = #198 = 0`: every target gets the last expression's value.
        let parts = line.components(separatedBy: "=")
        var targets: [Int] = []
        var i = 0
        while i < parts.count - 1 {
            let lhs = parts[i].trimmingCharacters(in: .whitespaces)
            // `==`, `<=`, `!=` inside the expression: stop collecting targets.
            if lhs.isEmpty || !lhs.hasPrefix("#") || Int(lhs.dropFirst()) == nil { break }
            targets.append(Int(lhs.dropFirst())!)
            i += 1
        }
        let expression = parts[i...].joined(separator: "=")
        let value = evaluate(expression)
        for t in targets { variables[t] = value }
        pending.append(.command(line))
    }

    func evaluate(_ expression: String) -> Int {
        FESExpression.evaluate(expression.replacingOccurrences(of: "#", with: "$"), expressions)
    }

    private final class Context: FESContext {
        unowned let player: ScenePlayer
        init(player: ScenePlayer) { self.player = player }
        func global(_ index: Int) -> Int { player.variables[index] ?? 0 }
        func setGlobal(_ index: Int, _ value: Int) { player.variables[index] = value }
        func local(_ index: Int) -> Int { 0 }
        func setLocal(_ index: Int, _ value: Int) {}
        func system(_ name: String) -> Int? { nil }
        func macro(_ name: String) -> String? { nil }
    }

    /// A number, `@` (unchanged: nil) or an expression such as `640+120`.
    private func coordinate(_ text: String) -> Int? {
        if text.hasPrefix("@") { return nil }
        return evaluate(text)
    }

    private static func color(_ text: String) -> UInt32? {
        guard text.hasPrefix("$") else { return nil }
        return UInt32(text.dropFirst(), radix: 16)
    }

    /// `bg`, `bg shift`, `bg N`, `bg N file [x y]`, `bg N $AARRGGBB`, `bg N pos x y`.
    private func planeCommand(_ kind: String, _ args: [String]) {
        guard let first = args.first else {
            planes = planes.filter { $0.value.kind != kind }
            return
        }
        guard let n = Int(first) else { return } // shift, tone, blur: no change to what is shown
        guard args.count >= 2 else {
            planes[n] = nil
            return
        }
        var plane = planes[n] ?? Plane(kind: kind)
        let word = args[1]
        if let color = Self.color(word) {
            plane = Plane(kind: kind, color: color)
        } else if word == "pos", args.count >= 4 {
            plane.x = coordinate(args[2]) ?? plane.x
            plane.y = coordinate(args[3]) ?? plane.y
        } else if ["scale", "amove1", "amove2", "amove3", "mode", "fade", "rot"].contains(word) {
            // Motions and effects: recorded, not applied.
        } else {
            plane = Plane(kind: kind, file: word)
            if args.count >= 4 {
                plane.x = coordinate(args[2])
                plane.y = coordinate(args[3])
            }
        }
        planes[n] = plane
    }

    /// Plane numbers: `N`, `[a-b]` or `[a,b,…]`.
    static func planeNumbers(_ text: String) -> [Int] {
        if text.hasPrefix("["), text.hasSuffix("]") {
            var out: [Int] = []
            for part in text.dropFirst().dropLast().split(separator: ",") {
                let ends = part.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                if ends.count == 2, ends[0] <= ends[1] { out += Array(ends[0]...ends[1]) } else { out += ends }
            }
            return out
        }
        return Int(text).map { [$0] } ?? []
    }

    /// `pl`, `pl N $AARRGGBB`, `pl N disp 0|1`, `pl N fade frames from to`, `pl N blend a`,
    /// `pl N pos x y`, `pl N base x y`; other properties are motions, recorded only.
    private func planeProperty(_ args: [String]) {
        guard let first = args.first else {
            planes = [:]
            return
        }
        let numbers = Self.planeNumbers(first)
        guard args.count >= 2 else {
            for n in numbers { planes[n] = nil }
            return
        }
        for n in numbers {
            var plane = planes[n] ?? Plane(kind: "pl")
            let word = args[1]
            if let color = Self.color(word) {
                // A colour plane of its own shows once `disp 1`; its alpha comes from fades.
                if planes[n] == nil { plane.visible = false }
                plane.color = color | 0xFF00_0000
                plane.file = nil
            } else {
                switch word {
                case "disp": plane.visible = (args.count > 2 ? Int(args[2]) : 1) != 0
                case "fade" where args.count >= 5, "m2fade" where args.count >= 5: plane.alpha = Int(args[4]) ?? plane.alpha
                case "blend" where args.count >= 3: plane.alpha = Int(args[2]) ?? plane.alpha
                case "pos" where args.count >= 4:
                    plane.x = coordinate(args[2]) ?? plane.x
                    plane.y = coordinate(args[3]) ?? plane.y
                case "base" where args.count >= 4:
                    plane.baseX = coordinate(args[2]) ?? plane.baseX
                    plane.baseY = coordinate(args[3]) ?? plane.baseY
                default: break
                }
            }
            planes[n] = plane
        }
    }

    /// A character coordinate: a number or expression, `@` (unchanged), or `@+n`/`@-n`
    /// (relative to the current value).
    private func characterCoordinate(_ text: String, current: Int?, fallback: Int) -> Int? {
        guard text.hasPrefix("@") else { return evaluate(text) }
        let rest = text.dropFirst()
        guard !rest.isEmpty else { return current }
        return (current ?? fallback) + evaluate(String(rest.hasPrefix("+") ? rest.dropFirst() : rest))
    }

    private static func percent(_ text: String) -> Int? { Int(text.replacingOccurrences(of: "%", with: "")) }

    /// `mpl` (clear), `mpl stop`/`tone` (no change), `mpl N` (remove), `mpl N model,…`,
    /// `mpl N pos x y`, `amove1|2|3`/`move frames x y` (their end point), `fade frames from
    /// to`, `blend a`, `disp 0|1`, `scale x% y%`, `ascale1 frames x% y%`, `m2body d,d,…`.
    /// Motions over time (`arc`, `shake`, `quake`), touch, lip and physics settings are
    /// recorded only. `fmpl` is the face beside the message window, not drawn yet.
    private func characterCommand(_ verb: String, _ args: [String]) {
        guard verb == "mpl" else { return }
        guard let first = args.first else {
            cast = [:]
            return
        }
        let banks = Self.planeNumbers(first)
        guard !banks.isEmpty else { return }
        guard args.count >= 2 else {
            for n in banks { cast[n] = nil }
            return
        }
        let word = args[1]
        for n in banks {
            var c = cast[n] ?? Character()
            if word.contains(","), word.first?.isLetter == true {
                c.model = word
            } else {
                switch word {
                case "pos" where args.count >= 3:
                    c.x = characterCoordinate(args[2], current: c.x, fallback: 640)
                    if args.count >= 4 { c.y = characterCoordinate(args[3], current: c.y, fallback: 360) }
                case "amove1", "amove2", "amove3", "move":
                    if args.count >= 4 { c.x = characterCoordinate(args[3], current: c.x, fallback: 640) }
                    if args.count >= 5 { c.y = characterCoordinate(args[4], current: c.y, fallback: 360) }
                case "fade" where args.count >= 5: c.alpha = Int(args[4]) ?? c.alpha
                case "blend" where args.count >= 3: c.alpha = Int(args[2]) ?? c.alpha
                case "disp": c.visible = (args.count > 2 ? Int(args[2]) : 1) != 0
                case "scale" where args.count >= 3:
                    c.scaleX = Self.percent(args[2]) ?? c.scaleX
                    c.scaleY = args.count >= 4 ? Self.percent(args[3]) ?? c.scaleX : c.scaleX
                case "ascale1", "ascale2", "ascale3":
                    if args.count >= 4 { c.scaleX = Self.percent(args[3]) ?? c.scaleX }
                    if args.count >= 5 { c.scaleY = Self.percent(args[4]) ?? c.scaleY }
                case "m2body" where args.count >= 3:
                    let digits = args[2].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                    var body = c.body
                    for (i, d) in digits.enumerated() {
                        while body.count <= i { body.append("@") }
                        if d != "@", !d.isEmpty { body[i] = d }
                    }
                    c.body = body
                default:
                    if cast[n] == nil { continue }
                }
            }
            cast[n] = c
        }
    }

    // MARK: Drawing

    /// Where a character's drawing goes: its top-left corner on screen.
    ///
    /// The profile's `#position` is where the scene's 0,0 puts the model's origin relative
    /// to the screen centre; scenes place characters around (640, 360). `scale` grows the
    /// character about the profile's `#scaleoffset` point.
    public static func placement(_ c: Character, image: EmoteImage, pose: EmoteProfiles.Pose,
                                 width: Int, height: Int) -> (x: Int, y: Int) {
        let m = Double(c.scaleX) / 100
        let originX = Double(c.x ?? 640) + pose.positionX + Double(width) / 2 + pose.scaleOffsetX * (1 - m)
        let originY = Double(c.y ?? 360) + pose.positionY + Double(height) / 2 + pose.scaleOffsetY * (1 - m)
        return (Int(originX.rounded()) - image.originX, Int(originY.rounded()) - image.originY)
    }

    /// The screen as straight RGBA (`width`×`height`): planes by number, pictures from HG-3
    /// (frame 0, anchored at its base point when it has one), colour planes, and the E-mote
    /// characters (drawn by `emote`) over the background, in bank order.
    public func render(width: Int, height: Int, emote: EmoteCast? = nil,
                       pictures: (String) -> HGImage?) -> [UInt8] {
        var canvas = Canvas(width: width, height: height)
        let order = planes.keys.sorted()
        var charactersDrawn = false
        func drawCharacters() {
            charactersDrawn = true
            guard let emote else { return }
            for n in cast.keys.sorted() {
                guard let c = cast[n], c.visible, c.alpha > 0, let model = c.model,
                      let drawn = emote.draw(model, body: c.body, scale: Double(c.scaleX) / 100) else { continue }
                let at = Self.placement(c, image: drawn.image, pose: drawn.pose, width: width, height: height)
                canvas.blitPremultiplied(drawn.image.rgba, width: drawn.image.width, height: drawn.image.height,
                                         x: at.x, y: at.y, alpha: c.alpha)
            }
        }
        for n in order {
            guard let plane = planes[n], plane.visible, plane.alpha > 0 else { continue }
            if n > 0, !charactersDrawn { drawCharacters() }
            if let color = plane.color {
                canvas.fill(x: 0, y: 0, w: width, h: height, color: color, alpha: plane.alpha)
            } else if let file = plane.file, let image = pictures(file), let frame = image.frames.first {
                let hasBase = (plane.baseX ?? frame.baseX) != 0 || (plane.baseY ?? frame.baseY) != 0
                let originX = hasBase ? (plane.x ?? width / 2) - (plane.baseX ?? frame.baseX) : (plane.x ?? 0)
                let originY = hasBase ? (plane.y ?? height / 2) - (plane.baseY ?? frame.baseY) : (plane.y ?? 0)
                canvas.blit(frame, x: originX + frame.offsetX, y: originY + frame.offsetY, alpha: plane.alpha)
            }
        }
        if !charactersDrawn { drawCharacters() }
        return canvas.pixels
    }
}
