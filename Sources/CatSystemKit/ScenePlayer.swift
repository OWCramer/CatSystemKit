// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

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
        /// The speaker as the scene has it (Japanese), as `nametable.csv` names speakers.
        public var originalSpeaker: String? = nil
        /// The text ended with `\@`: it shows now and the scene goes on (voices, motions,
        /// expressions while it is read) until the click wait, an `.input` event.
        public var continues = false
    }

    public enum Event: Sendable {
        case scene(String)
        case command(String)
        case message(Message)
        /// A scene the story asked for isn't in the game (the Steam release leaves out the
        /// adult scenes the PC version adds as a patch).
        case missingScene(String)
        /// The click wait after a message that `continues` (`\@`): the story waits for a
        /// click here, with that message still shown.
        case input
        case end(String)
    }

    /// A picture on a plane: `bg`, `cg`, `fg`, `eg` or `fw` number `slot` (`eg 3 gg_cute01`), a
    /// file or a colour. It shows on plane `slot` unless the command names another plane
    /// (`fg 2 gg_cutline03b 210 0 @ 1` puts fg 2 on plane 1), and a plane composites its
    /// pictures in kind order (`bg`, `cg`, `fg`, `fw`, `eg`), then by slot.
    ///
    /// The picture's base point (HG-3 `stdinfo`) stands at `x`, `y` in screen pixels. The
    /// commands give `bg`/`cg`/`fg`/`fw` places on the screen (`bg 2 bg02c_19 0 0` is the
    /// top-left corner, `fg 4 gg_cutline09a 0 0` too) and `eg` places from the screen's centre
    /// (`eg 3 gg_cute01 -640 -360` puts the picture's base point, the screen's corner in that
    /// 1536×830 canvas, at the screen's corner); both are stored as screen places. Without a
    /// place, `bg`/`cg` pictures stand at the top-left corner (backgrounds have their base point
    /// there) and `fg`/`fw`/`eg` pictures at the centre (`eg 1 CG3_17b`, `fg 5 gg_CG3_16line`:
    /// the scenes' CGs and their lines have it in the middle).
    public struct Picture: Sendable, Codable, Equatable {
        public var kind: String
        public var slot: Int
        public var file: String?
        /// A plain colour (`eg 0 $ffffffff`): a screen-sized rectangle with its top-left corner
        /// at the picture's place.
        public var color: UInt32?
        public var x: Int?
        public var y: Int?
        /// `KIND N scale x% y%`, about the base point.
        public var scaleX: Int?
        public var scaleY: Int?
        /// `KIND N blend a`, `KIND N fade frames from to` (its end).
        public var alpha: Int?
        /// `\lr`, `\ud`: mirrored about the base point.
        public var flipX: Bool?
        public var flipY: Bool?
        /// `\ma`: not drawn; its alpha masks the plane's other pictures (split screens: the
        /// `gg_cut…` shapes).
        public var mask: Bool?
        /// `KIND N mode sepia`.
        public var sepia: Bool?
        /// `KIND N tone r g b`: each channel in percent.
        public var tone: [Int]?
        /// `KIND N blur x y`: a blur this many pixels across.
        public var blur: [Int]?

        public init(kind: String, slot: Int, file: String? = nil, color: UInt32? = nil, x: Int? = nil, y: Int? = nil) {
            self.kind = kind
            self.slot = slot
            self.file = file
            self.color = color
            self.x = x
            self.y = y
        }

        /// Where a picture of this kind stands without a place of its own.
        public static func defaultPlace(_ kind: String, width: Int = 1280, height: Int = 720) -> (x: Int, y: Int) {
            kind == "bg" || kind == "cg" ? (0, 0) : (width / 2, height / 2)
        }

        /// What its effects do to its pixels.
        public var effect: PictureEffect { PictureEffect(sepia: sepia == true, tone: tone, blur: blur) }

        /// Kinds in the order a plane draws them.
        public static let kinds = ["bg", "cg", "fg", "fw", "eg"]
    }

    /// A numbered plane (`pl N`): where it stands, its scale, fade, visibility, draw order and
    /// blend, and the pictures shown on it. Planes and characters are drawn by priority
    /// (`pl N pri`, `mpl N pri`): a plane's is 3000 + 100·N unless set, a character's
    /// 5000 + 100·N, so pictures stand under the characters and the white of `pl 31` over them.
    public struct Plane: Sendable, Codable, Equatable {
        /// What made the plane (`bg`, `eg` … or `pl`).
        public var kind: String
        /// Saves from before pictures had places of their own: the plane's one picture
        /// (`restore` moves it into `pictures`).
        public var file: String?
        /// `pl N $AARRGGBB`: the whole screen in a colour.
        public var color: UInt32?
        /// `pl N pos`: where the plane's base point stands (the screen's centre unless set).
        public var x: Int?
        public var y: Int?
        /// `pl N base x y`: the plane's base point (its scale's centre) in the 1536×830 canvas
        /// the effect pictures share (the screen's corner at 128, 55): 768, 415 unless set.
        public var baseX: Int?
        public var baseY: Int?
        public var alpha = 255
        public var visible = true
        /// `pl N scale` in percent (nil: 100), about the plane's base point.
        public var scaleX: Int?
        public var scaleY: Int?
        public var pictures: [Picture]?
        /// `pl N pri`.
        public var priority: Int?
        /// `pl N bmode 1`: added to what is under it (the white flashes of `pl 31`).
        public var blendMode: Int?

        public init(kind: String, file: String? = nil, color: UInt32? = nil, x: Int? = nil, y: Int? = nil,
                    scaleX: Int? = nil, scaleY: Int? = nil) {
            self.kind = kind
            self.file = file
            self.color = color
            self.x = x
            self.y = y
            self.scaleX = scaleX
            self.scaleY = scaleY
        }

        /// The picture of this kind and slot on the plane.
        public func picture(_ kind: String, slot: Int? = nil) -> Picture? {
            pictures?.first { $0.kind == kind && (slot == nil || $0.slot == slot) }
        }

        /// The pictures in drawing order.
        public var orderedPictures: [Picture] {
            (pictures ?? []).sorted {
                let a = Picture.kinds.firstIndex(of: $0.kind) ?? 0, b = Picture.kinds.firstIndex(of: $1.kind) ?? 0
                return a != b ? a < b : $0.slot < $1.slot
            }
        }

        /// Whether it shows anything: pictures or a colour of its own.
        public var isEmpty: Bool { (pictures ?? []).isEmpty && color == nil && file == nil }

        /// Whether its own settings are all as `pl N` leaves them.
        public var isDefault: Bool {
            var plain = Plane(kind: kind)
            plain.pictures = pictures
            plain.file = file
            plain.color = color
            return self == plain
        }

        public func priority(number n: Int) -> Int { priority ?? 3000 + 100 * n }

        /// The plane's base point in screen pixels (the screen's centre unless set), where
        /// `pos` puts it.
        public var base: (x: Double, y: Double) {
            (Double(baseX.map { $0 - 128 } ?? 640), Double(baseY.map { $0 - 55 } ?? 360))
        }
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
        /// `mpl N pri` (nil: 5000 + 100·N).
        public var priority: Int?
        /// `mpl N rot 0 0 degrees`: turned about its origin, clockwise.
        public var rotation: Int?

        public init(model: String? = nil) { self.model = model }

        public func priority(bank n: Int) -> Int { priority ?? 5000 + 100 * n }
    }

    public private(set) var planes: [Int: Plane] = [:]
    /// E-mote characters by bank.
    public private(set) var cast: [Int: Character] = [:]
    /// Faces in the message window (`fmpl` bank N: the character's small model).
    public private(set) var faces: [Int: Character] = [:]
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
    /// A message that `continues` was shown; its click wait is the next input line.
    private var awaitingInput = false
    private lazy var expressions = Context(player: self)
    /// The E-mote profiles and models, for `mpl N m2att` (where a character's head is).
    public var emote: EmoteCast?

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
        awaitingInput = false
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
        public var faces: [Int: Character]?
        public var bgm: String?
        public var variables: [Int: Int]
        /// Taken while a message that `continues` was shown, before its click wait (nil in
        /// older saves, which were all taken at the click wait).
        public var beforeInput: Bool?
    }

    public func snapshot() -> Snapshot {
        Snapshot(stack: frames.map { .init(scene: $0.name, line: $0.line, messageIndex: $0.messageIndex) },
                 planes: planes, characters: characters, characterX: cast.compactMapValues(\.x), cast: cast,
                 faces: faces, bgm: bgm, variables: variables, beforeInput: awaitingInput)
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
        awaitingInput = snapshot.beforeInput ?? false
        for position in snapshot.stack {
            guard let bytes = try files(position.scene + ".cst") else {
                throw CatSystemGame.Failure.notCatSystem(URL(fileURLWithPath: position.scene + ".cst"))
            }
            let scene = try CatScene(bytes)
            let translation = try files(position.scene + ".cstl").flatMap { try? SceneTranslation($0) }
            frames.append(Frame(name: position.scene, scene: scene, translation: translation,
                                line: min(position.line, scene.lines.count), messageIndex: position.messageIndex))
        }
        planes = snapshot.planes.mapValues(Self.migrated)
        if let saved = snapshot.cast {
            cast = saved
        } else {
            cast = snapshot.characters.mapValues { Character(model: $0) }
            for (n, x) in snapshot.characterX { cast[n, default: Character()].x = x }
        }
        faces = snapshot.faces ?? [:]
        bgm = snapshot.bgm
        sounds = [:]
        voice = nil
        variables = snapshot.variables
    }

    /// A plane from a save made before planes had pictures of their own: its picture on it,
    /// at its default place (the plane's place was the picture's then).
    static func migrated(_ plane: Plane) -> Plane {
        guard plane.pictures == nil else { return plane }
        var p = plane
        if let file = plane.file {
            p.pictures = [Picture(kind: plane.kind == "pl" ? "eg" : plane.kind, slot: 0, file: file)]
            p.file = nil
        } else {
            p.pictures = []
        }
        return p
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
            // `「…」\@`: the line shows now; the commands after it run while it is read.
            if line.text.hasSuffix("\\@") {
                closeMessage(&frame)
                awaitingInput = true
            }
            frames.append(frame)
        case .input, .page:
            if awaitingInput, Self.clean(text).isEmpty {
                // The click wait of the message already shown (the scene's empty text line
                // before it is `\n`).
                awaitingInput = false
                speaker = nil; text = ""; inMessage = false
                pending.append(.input)
            } else {
                awaitingInput = false
                closeMessage(&frame)
            }
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
                              text: Self.clean(translated?.text ?? text), original: text, voice: pendingVoice,
                              originalSpeaker: speaker, continues: text.hasSuffix("\\@"))
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
        var words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let verb = words.first else { return }
        // Numbers given as variables (`mpl #210 m2att …`, `particle3 0 em_note … #205+#218+#196 …`)
        // are worked out here, so the command as reported has plain numbers.
        if ["mpl", "fmpl", "particle", "particle2", "particle3"].contains(verb), words.dropFirst().contains(where: { $0.contains("#") }) {
            for i in words.indices.dropFirst() where words[i].contains("#") { words[i] = String(evaluate(words[i])) }
            line = words.joined(separator: " ")
        }
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
        case "mpl" where args.count >= 6 && args[1] == "m2att":
            attribute(args)
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

    /// `mpl N m2att att pos xVar yVar exVar`: where the character in bank N has its
    /// attribute `att` (the `.dif`'s `#attribute`: by the head), into `#xVar`/`#yVar` in
    /// screen pixels, and the attribute's extra value (the model's size, 1–4) into `#exVar`.
    /// The scenes put emotion marks (`particle3 … em_note`) there.
    private func attribute(_ args: [String]) {
        guard let bank = Int(args[0]), let number = Int(args[2]), let xVar = Int(args[4]), let yVar = Int(args[5]) else { return }
        let exVar = args.count > 6 ? Int(args[6]) : nil
        guard let c = cast[bank], c.model != nil else { return }
        let found = emote?.attribute(c, number: number)
        variables[xVar] = Int((found?.x ?? Double(c.x ?? 640)).rounded())
        variables[yVar] = Int((found?.y ?? Double((c.y ?? 360) - 170)).rounded())
        if let exVar { variables[exVar] = found?.extra ?? 3 }
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

    /// Picture commands: `bg` (every bg cleared), `bg N` (cleared), `bg N file [x y [frame
    /// [plane]]] [\lr] [\ud] [\ma]`, `bg N $AARRGGBB [x y]`, and changes to the picture in
    /// slot N: `pos x y`, `scale x% y%`, `amove1/2/3`/`move frames x y` (their end), `blend a`,
    /// `fade frames from to` (its end), `mode sepia`, `tone r g b`, `blur x y` (each alone:
    /// off). `bg tone`, `bg mode`, `bg blur` alone clear that effect from every bg; `bg shift`
    /// changes nothing shown. Places are kept as screen pixels (see `Picture`).
    private func planeCommand(_ kind: String, _ args: [String]) {
        guard let first = args.first else {
            removePictures { $0.kind == kind }
            return
        }
        let slots = Self.planeNumbers(first)
        guard !slots.isEmpty else {
            if ["tone", "mode", "blur"].contains(first), args.count == 1 {
                editPictures({ $0.kind == kind }) { p in
                    if first == "tone" { p.tone = nil } else if first == "mode" { p.sepia = nil } else { p.blur = nil }
                }
            }
            return
        }
        guard args.count >= 2 else {
            let numbers = Set(slots)
            removePictures { $0.kind == kind && numbers.contains($0.slot) }
            return
        }
        let word = args[1]
        let flags = Set(args.dropFirst(2).filter { $0.hasPrefix("\\") })
        let values = Array(args.dropFirst(2).filter { !$0.hasPrefix("\\") })
        for slot in slots {
            if let color = Self.color(word) {
                var p = Picture(kind: kind, slot: slot, color: color)
                if values.count >= 2 {
                    p.x = pictureCoordinate(values[0], kind: kind, current: nil)
                    p.y = pictureCoordinate(values[1], kind: kind, current: nil, vertical: true)
                }
                put(p, onPlane: slot)
                continue
            }
            if Self.pictureVerbs.contains(word) {
                editPicture(kind, slot) { p in self.pictureProperty(&p, word, Array(args.dropFirst(2))) }
                continue
            }
            // A new picture (keeping the slot's effects: `bg 3 mode sepia` may come first).
            let old = picture(kind, slot)
            var p = Picture(kind: kind, slot: slot, file: word)
            p.sepia = old?.sepia; p.tone = old?.tone; p.blur = old?.blur
            // `@` for a place: the default one (the new picture's, not the old one's).
            if values.count >= 1, values[0] != "@" { p.x = pictureCoordinate(values[0], kind: kind, current: nil) }
            if values.count >= 2, values[1] != "@" { p.y = pictureCoordinate(values[1], kind: kind, current: nil, vertical: true) }
            if flags.contains("\\lr") { p.flipX = true }
            if flags.contains("\\ud") { p.flipY = true }
            if flags.contains("\\ma") { p.mask = true }
            let target = values.count >= 4 ? Int(values[3]) ?? slot : slot
            put(p, onPlane: target)
        }
    }

    /// What `KIND N word …` may change on a picture already shown.
    public static let pictureVerbs: Set<String> = ["pos", "scale", "amove1", "amove2", "amove3", "move", "blend", "fade",
                                                   "mode", "tone", "blur", "ascale1", "ascale2", "ascale3"]

    private func pictureProperty(_ p: inout Picture, _ word: String, _ rest: [String]) {
        switch word {
        case "pos", "amove1", "amove2", "amove3", "move":
            // `pos x y`; `amove1 frames x y`: the end point.
            let at = word == "pos" ? 0 : 1
            if rest.count > at { p.x = pictureCoordinate(rest[at], kind: p.kind, current: p.x) }
            if rest.count > at + 1 { p.y = pictureCoordinate(rest[at + 1], kind: p.kind, current: p.y, vertical: true) }
        case "scale" where !rest.isEmpty:
            p.scaleX = Self.percent(rest[0]) ?? p.scaleX
            p.scaleY = rest.count >= 2 ? Self.percent(rest[1]) ?? p.scaleX : p.scaleX
        case "ascale1", "ascale2", "ascale3":
            if rest.count >= 2 { p.scaleX = Self.percent(rest[1]) ?? p.scaleX }
            if rest.count >= 3 { p.scaleY = Self.percent(rest[2]) ?? p.scaleY }
        case "blend" where !rest.isEmpty: p.alpha = Int(rest[0]) ?? p.alpha
        case "fade" where rest.count >= 3: p.alpha = Int(rest[2]) ?? p.alpha
        case "mode": p.sepia = rest.first == "sepia" ? true : nil
        case "tone": p.tone = rest.count >= 3 ? rest.prefix(3).map { Int($0) ?? 100 } : nil
        case "blur": p.blur = rest.isEmpty ? nil : rest.prefix(2).map { Int($0) ?? 0 }
        default: break
        }
    }

    /// A picture place as screen pixels: `eg` places count from the screen's centre, the
    /// others from its top-left corner; `@` keeps the current place, `@+n` moves from it (from
    /// the kind's default place when there is none).
    private func pictureCoordinate(_ text: String, kind: String, current: Int?, vertical: Bool = false) -> Int? {
        let origin = kind == "eg" ? (vertical ? 360 : 640) : 0
        guard text.hasPrefix("@") else { return origin + evaluate(text) }
        let rest = text.dropFirst()
        guard !rest.isEmpty else { return current }
        let home = Picture.defaultPlace(kind)
        let start = current ?? (vertical ? home.y : home.x)
        return start + evaluate(String(rest.hasPrefix("+") ? rest.dropFirst() : rest))
    }

    private func picture(_ kind: String, _ slot: Int) -> Picture? {
        for plane in planes.values { if let p = plane.picture(kind, slot: slot) { return p } }
        return nil
    }

    /// Puts a picture on plane `n`, in place of the one in its kind and slot (wherever that was).
    private func put(_ picture: Picture, onPlane n: Int) {
        removePictures { $0.kind == picture.kind && $0.slot == picture.slot }
        var plane = planes[n] ?? Plane(kind: picture.kind)
        plane.pictures = (plane.pictures ?? []) + [picture]
        planes[n] = plane
    }

    private func editPicture(_ kind: String, _ slot: Int, _ change: (inout Picture) -> Void) {
        editPictures({ $0.kind == kind && $0.slot == slot }, change)
    }

    private func editPictures(_ match: (Picture) -> Bool, _ change: (inout Picture) -> Void) {
        for n in planes.keys {
            guard var plane = planes[n], var pictures = plane.pictures, pictures.contains(where: match) else { continue }
            for i in pictures.indices where match(pictures[i]) { change(&pictures[i]) }
            plane.pictures = pictures
            planes[n] = plane
        }
    }

    /// Takes pictures off their planes. A plane keeps its own settings (`pl 0 scale 150%`
    /// often comes before `bg 0 …`); one left with nothing at all goes.
    private func removePictures(_ match: (Picture) -> Bool) {
        for n in planes.keys {
            guard var plane = planes[n], let pictures = plane.pictures, pictures.contains(where: match) else { continue }
            plane.pictures = pictures.filter { !match($0) }
            planes[n] = plane.isEmpty && plane.isDefault ? nil : plane
        }
    }

    /// Plane numbers: `N`, `[a-b]` or `[a,b,…]`.
    public static func planeNumbers(_ text: String) -> [Int] {
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

    /// The plane properties `planeProperty` and `PlaneStage` carry out; others are recorded only.
    public static let planeVerbs: Set<String> = ["disp", "fade", "m2fade", "blend", "pos", "base", "scale", "ascale1", "ascale2",
                                                 "ascale3", "amove1", "amove2", "amove3", "move", "pri", "bmode",
                                                 "quake", "stop", "m2move", "m2amove1", "m2amove1p", "m2scale", "m2ascale1p"]

    /// `pl` (every plane back to its defaults), `pl N` (plane N back to its defaults: place,
    /// scale, fade, colour, priority; its pictures stay), `pl N $AARRGGBB`, `pl N disp 0|1`,
    /// `pl N fade frames from to`, `pl N blend a`, `pl N pos x y`, `pl N base x y`, `pl N
    /// scale`, `pl N pri p`, `pl N bmode m`; motions leave their end points (`PlaneStage` plays
    /// them).
    private func planeProperty(_ args: [String]) {
        guard let first = args.first else {
            for n in planes.keys { reset(plane: n) }
            return
        }
        let numbers = Self.planeNumbers(first)
        guard args.count >= 2 else {
            for n in numbers { reset(plane: n) }
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
                case "pos" where args.count == 2:
                    // `pl 0 pos` alone: back to the screen's centre.
                    plane.x = nil; plane.y = nil
                case "pos" where args.count >= 3:
                    plane.x = characterCoordinate(args[2], current: plane.x, fallback: 640)
                    if args.count >= 4 { plane.y = characterCoordinate(args[3], current: plane.y, fallback: 360) }
                case "base" where args.count >= 4:
                    plane.baseX = coordinate(args[2]) ?? plane.baseX
                    plane.baseY = coordinate(args[3]) ?? plane.baseY
                case "scale" where args.count >= 3:
                    plane.scaleX = Self.percent(args[2]) ?? plane.scaleX
                    plane.scaleY = args.count >= 4 ? Self.percent(args[3]) ?? plane.scaleX : plane.scaleX
                case "ascale1", "ascale2", "ascale3", "m2scale", "m2ascale1p":
                    // `ascale1 frames x% y%`: the end of the motion (`PlaneStage` plays it). The
                    // `m2` motions are the long, slow ones (`pl [3,4] m2scale 6000 100% 100%`).
                    if args.count >= 4 { plane.scaleX = Self.percent(args[3]) ?? plane.scaleX }
                    if args.count >= 5 { plane.scaleY = Self.percent(args[4]) ?? plane.scaleY }
                case "amove1", "amove2", "amove3", "move", "m2move", "m2amove1", "m2amove1p":
                    // `amove1 frames x y`, `@` unchanged, `@+n` relative: the end point.
                    if args.count >= 4 { plane.x = characterCoordinate(args[3], current: plane.x, fallback: 640) }
                    if args.count >= 5 { plane.y = characterCoordinate(args[4], current: plane.y, fallback: 360) }
                case "pri" where args.count >= 3: plane.priority = Int(args[2]) ?? plane.priority
                case "bmode": plane.blendMode = args.count >= 3 ? Int(args[2]) : nil
                default: break
                }
            }
            planes[n] = plane
        }
    }

    /// `pl N`: the plane's own settings back to their defaults; what is on it stays.
    private func reset(plane n: Int) {
        guard let old = planes[n] else { return }
        var plane = Plane(kind: old.kind)
        plane.pictures = old.pictures
        planes[n] = plane.isEmpty ? nil : plane
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
    /// recorded only. `fmpl` does the same for the faces in the message window (`faces`).
    private func characterCommand(_ verb: String, _ args: [String]) {
        if verb == "fmpl" {
            characterCommand(args, &faces)
        } else {
            characterCommand(args, &cast)
        }
    }

    private func characterCommand(_ args: [String], _ cast: inout [Int: Character]) {
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
                case "amove1", "amove2", "amove3", "move", "m2move":
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
                case "pri" where args.count >= 3: c.priority = Int(args[2]) ?? c.priority
                case "rot": c.rotation = args.count >= 5 ? Int(args[4]).flatMap { $0 == 0 ? nil : $0 } : nil
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

    /// The screen as straight RGBA (`width`×`height`): planes and characters by priority
    /// (`StageLayout`), pictures from HG-3 (frame 0, by their base points, mirrored, masked,
    /// with their effects), colour planes, and the E-mote characters drawn by `emote`.
    public func render(width: Int, height: Int, emote: EmoteCast? = nil,
                       pictures: (String) -> HGImage?) -> [UInt8] {
        render(width: width, height: height, layer: .all, emote: emote, pictures: pictures)
    }

    /// Which planes `render` draws: all of them, those under the characters (opaque) or those
    /// over them (premultiplied, clear where empty).
    public enum Layer: Sendable { case all, below, above }

    public func render(width: Int, height: Int, layer: Layer, emote: EmoteCast? = nil,
                       pictures: (String) -> HGImage?) -> [UInt8] {
        var canvas = Canvas(width: width, height: height, transparent: layer == .above)
        let items = StageLayout.items(planes: planes, cast: cast, width: width, height: height,
                                      state: { PlaneStage.resting($1) }, frame: { pictures($0)?.frames.first })
        let firstCharacter = items.firstIndex { if case .character = $0 { true } else { false } }
        let lastCharacter = items.lastIndex { if case .character = $0 { true } else { false } }
        var effected: [String: HGImage.Frame] = [:]
        for (i, item) in items.enumerated() {
            switch layer {
            case .all: break
            case .below: if let firstCharacter, i >= firstCharacter { continue }
            case .above: if let lastCharacter { if i <= lastCharacter { continue } } else { continue }
            }
            switch item {
            case .character(let n):
                guard let emote, let c = cast[n], c.alpha > 0, let model = c.model,
                      let drawn = emote.draw(model, body: c.body, scale: Double(c.scaleX) / 100) else { continue }
                let at = Self.placement(c, image: drawn.image, pose: drawn.pose, width: width, height: height)
                canvas.blitPremultiplied(drawn.image.rgba, width: drawn.image.width, height: drawn.image.height,
                                         x: at.x, y: at.y, alpha: c.alpha)
            case .quad(let q):
                var maskFrame: HGImage.Frame?
                if let m = q.mask { maskFrame = pictures(m.name)?.frames.first }
                switch q.source {
                case .color(let color):
                    canvas.draw(color: color, quad: q, mask: maskFrame)
                case .picture(let name, let effect):
                    guard let base = pictures(name)?.frames.first else { continue }
                    let key = name.lowercased() + "|" + effect.key
                    let frame = effected[key] ?? base.applying(effect)
                    effected[key] = frame
                    canvas.draw(frame, quad: q, mask: maskFrame)
                }
            }
        }
        return canvas.pixels
    }
}
