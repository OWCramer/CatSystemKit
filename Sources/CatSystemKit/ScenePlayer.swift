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
/// `bg 0` is plane 0, `eg 1` plane 1). `mpl N model,…` shows an E-mote character, which
/// is recorded but not drawn yet. Sounds (`bgm`, `se`, `pcm` for voices) are recorded.
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

    public struct Plane: Sendable {
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

    public private(set) var planes: [Int: Plane] = [:]
    /// E-mote characters by plane: the model and motion argument (`ca01,1,1,b,3,0,4`).
    public private(set) var characters: [Int: String] = [:]
    public private(set) var characterX: [Int: Int] = [:]
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
            characterCommand(args)
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

    /// Plane numbers: `N`, or `[a-b]`.
    private static func planeNumbers(_ text: String) -> [Int] {
        if text.hasPrefix("["), text.hasSuffix("]") {
            let inner = text.dropFirst().dropLast().split(separator: "-").compactMap { Int($0) }
            if inner.count == 2, inner[0] <= inner[1] { return Array(inner[0]...inner[1]) }
            return inner
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

    /// `mpl`, `mpl stop`, `mpl N model,…`, `mpl N pos x y`.
    private func characterCommand(_ args: [String]) {
        guard let first = args.first else {
            characters = [:]
            characterX = [:]
            return
        }
        guard let n = Int(first), args.count >= 2 else { return }
        let word = args[1]
        if word.contains(",") {
            characters[n] = word
        } else if word == "pos" || word == "amove1" || word == "amove2" || word == "amove3" {
            let at = word == "pos" ? 2 : 3
            if args.count > at, let x = coordinate(args[at]) { characterX[n] = x }
        }
    }

    // MARK: Drawing

    /// The screen as straight RGBA (`width`×`height`): planes by number, pictures from HG-3
    /// (frame 0, anchored at its base point when it has one), colour planes, and a
    /// placeholder silhouette for each E-mote character over the background.
    public func render(width: Int, height: Int, pictures: (String) -> HGImage?) -> [UInt8] {
        var canvas = Canvas(width: width, height: height)
        let order = planes.keys.sorted()
        var charactersDrawn = false
        func drawCharacters() {
            charactersDrawn = true
            let shown = characters.keys.sorted()
            for (i, n) in shown.enumerated() {
                let x = characterX[n] ?? width * (i + 1) / (shown.count + 1)
                // One colour per character (the model's second letter: `ca01` Chocola, `cb01` Vanilla …).
                let palette: [UInt32] = [0xFF8A_5A44, 0xFFE8_E8F0, 0xFFE0_A040, 0xFF90_80E0, 0xFF40_3040, 0xFFF0_D080, 0xFF80_C0E0]
                let letter = (characters[n] ?? "").unicodeScalars.dropFirst().first.map { Int($0.value) } ?? 0
                let color = palette[letter % palette.count]
                canvas.fill(x: x - 130, y: height / 4, w: 260, h: height * 3 / 4, color: color, alpha: 150)
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
