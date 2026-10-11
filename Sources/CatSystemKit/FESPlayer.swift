import Foundation

/// Runs FES scripts, CatSystem2's system-screen language, one frame (1/60 s) at a time, and
/// draws their objects. Enough of the language for the boot flow (`flow.fes`): the brand
/// logo, the language picker and the title menu.
///
/// How a script runs (worked out from NEKOPARA Vol. 3's scripts): the current label's block
/// runs from its top each frame. `next LABEL` switches label and ends the frame's run;
/// `call LABEL` runs another block inline; `wait` suspends until the script's motions end,
/// `wait N` for N frames, both resuming after the `wait`. `execfes name` starts a child
/// script; the parent keeps running and reads `_EXITCODE_` (-1 while the child runs, then
/// the code the child gave `exit`). Buttons run `#name.EVENT` blocks with `@` as their index.
public final class FESPlayer: @unchecked Sendable {
    /// CS2_TRACE=1: every statement as it runs, on standard output.
    nonisolated(unsafe) static var trace = ProcessInfo.processInfo.environment["CS2_TRACE"] != nil

    public let game: CatSystemGame
    public let width: Int
    public let height: Int
    /// The `%LANG%` prefix in file names (`startup.xml` language 0 is English).
    public var language = "en"
    public private(set) var frameCount = 0
    /// Sounds started, unknown commands and other events, for headless runs.
    public private(set) var events: [String] = []
    /// The `$n` variables, as the scripts left them (`$512` is -3 after GAME START).
    public var variables: [Int: Int] { globals }
    /// The `$strN` string variables (`$str200` names the first scene after GAME START).
    public var stringVariables: [Int: String] { strings }
    /// The story script `execkcs` asked for (`sscript` when the game starts), if any.
    public private(set) var requestedKCS: String?

    /// A sound a script started or stopped: `channel` is its object (`voice`, `se1`,
    /// `bgmtbl`), `table` true for a music table (`SNDTABLE`), `file` the Ogg's name
    /// without extension (`A_title_002`, `se_sys_05`, `bgm_01`); nil with `stop`.
    public struct Sound: Sendable {
        public let channel: String
        public let table: Bool
        public let file: String?
        public let loop: Bool
        public var stop: Bool { file == nil }
    }

    /// Sets a `$n` variable before or while the scripts run (`$897 = 1`: the language was
    /// chosen before, so the title flow skips the picker).
    public func setVariable(_ index: Int, _ value: Int) { globals[index] = value }

    /// The code the root script gave `exit`, once it has.
    public var rootExitCode: Int? { root?.finished }

    /// Sounds since the last `takeSounds()`, for a host that plays them.
    public func takeSounds() -> [Sound] {
        defer { sounds = [] }
        return sounds
    }

    var sounds: [Sound] = []

    var globals: [Int: Int] = [:]
    var strings: [Int: String] = [:]
    var root: FESInstance?
    private var base: [UInt8]?
    private var images: [String: HGImage] = [:]
    private let imageLock = NSLock()
    private var randomState: UInt32 = 12345
    private var reported: Set<String> = []

    public init(game: CatSystemGame) {
        self.game = game
        width = game.screenWidth
        height = game.screenHeight
    }

    // MARK: Running

    public func start(_ name: String) throws {
        root = try load(name, parent: nil)
    }

    /// The running scripts from the root down, each with its label.
    public var stack: [String] {
        var out: [String] = []
        var i = root
        while let s = i { out.append("\(s.name)#\(s.label)"); i = s.child }
        return out
    }

    /// Advances one frame: every running script ticks (parent first), then motions move.
    public func step() {
        frameCount += 1
        var instance = root
        while let i = instance {
            i.tick()
            instance = i.child
        }
        var all: [FESObject] = []
        visit { all.append($0) }
        for o in all { o.advanceMotion() }
    }

    /// A left click on a button (`decide`, `btn1[0]`): runs its `PUSH_L` block if the
    /// button is shown and enabled. False when no running script has it.
    @discardableResult
    public func push(_ name: String) -> Bool {
        var deepest: FESInstance?
        var i = root
        while let s = i { if s.object(named: name) != nil { deepest = s }; i = s.child }
        guard let owner = deepest, let object = owner.object(named: name), object.disp, object.enable else { return false }
        owner.runEvent(object, "FOCUS")
        owner.runEvent(object, "PUSH_L")
        return true
    }

    /// Whether a button is shown and enabled in some running script.
    public func canPush(_ name: String) -> Bool {
        var i = root
        while let s = i {
            if let o = s.object(named: name), o.disp, o.enable { return true }
            i = s.child
        }
        return false
    }

    /// The button a click at (x, y) on the screen would press: the shown, enabled button
    /// with a `PUSH_L` block whose picture covers the point, topmost first.
    public func button(atX x: Int, y: Int) -> String? {
        var best: (depth: Int, pri: Int, plane: Int, key: String)?
        var depth = 0
        var i = root
        while let s = i {
            var planes: [String: FESObject] = [:]
            for o in s.objects where o.isPlane { planes[o.key] = o }
            for o in s.objects where o.type == "BUTTON" && o.disp && o.enable && s.hasBlock("\(o.baseName).PUSH_L") {
                let plane = o.plane.flatMap { planes[$0] ?? planes[$0 + "[0]"] }
                if let plane, !plane.disp { continue }
                let originX = (plane?.x ?? 0) + o.x, originY = (plane?.y ?? 0) + o.y
                var rect: (x: Int, y: Int, w: Int, h: Int)
                if o.width > 0, o.height > 0 {
                    rect = (originX, originY, o.width, o.height)
                } else if let file = o.file, let image = picture(file),
                          let frame = o.currentID.flatMap(image.frame(id:)) ?? o.ids.first.flatMap(image.frame(id:)) ?? image.frames.first {
                    rect = (originX + frame.offsetX, originY + frame.offsetY, frame.width, frame.height)
                } else {
                    continue
                }
                guard x >= rect.x, x < rect.x + rect.w, y >= rect.y, y < rect.y + rect.h else { continue }
                // A child script's buttons sit over its parent's; inside one script, by priority.
                let order = (depth, plane?.pri ?? o.pri, plane == nil ? Int.min : o.pri)
                if best.map({ order >= ($0.depth, $0.pri, $0.plane) }) ?? true {
                    best = (depth, order.1, order.2, o.key)
                }
            }
            i = s.child
            depth += 1
        }
        return best?.key
    }

    /// Changes whenever what `render()` draws may have changed (objects shown, their
    /// frames, places and fades), so a host redraws only then.
    public var drawState: Int {
        var hasher = Hasher()
        hasher.combine(base?.count ?? 0)
        hasher.combine(baseRevision)
        visit { o in
            hasher.combine(o.disp)
            guard o.disp else { return }
            hasher.combine(o.alpha)
            hasher.combine(o.x)
            hasher.combine(o.y)
            hasher.combine(o.currentID)
            hasher.combine(o.file)
        }
        return hasher.finalize()
    }

    private var baseRevision = 0

    func load(_ name: String, parent: FESInstance?) throws -> FESInstance {
        guard let bytes = try game.file(named: name.hasSuffix(".fes") ? name : name + ".fes") else {
            throw CatSystemGame.Failure.notCatSystem(URL(fileURLWithPath: name + ".fes"))
        }
        let program = FESProgram(text: try FESScript.text(bytes))
        return FESInstance(name: name.lowercased(), program: program, player: self, parent: parent)
    }

    func note(_ event: String) { events.append("[\(frameCount)] \(event)") }

    func noteOnce(_ event: String) {
        if reported.insert(event).inserted { note(event) }
    }

    func requestKCS(_ name: String) {
        requestedKCS = name
        note("execkcs \(name)")
    }

    func random(_ low: Int, _ high: Int) -> Int {
        randomState = randomState &* 1_103_515_245 &+ 12345
        return low + Int(randomState >> 16) % max(1, high - low + 1)
    }

    func snapshotBase() {
        base = render()
        baseRevision += 1
    }

    // MARK: Drawing

    func visit(_ body: (FESObject) -> Void) {
        var i = root
        while let s = i {
            for o in s.objects { body(o) }
            i = s.child
        }
    }

    func picture(_ file: String) -> HGImage? {
        let name = file.replacingOccurrences(of: "%LANG%", with: language).lowercased()
        if let cached = imageLock.withLock({ images[name] }) { return cached }
        guard let image = Self.decode(name, game: game) else {
            noteOnce("missing picture \(name)")
            return nil
        }
        imageLock.withLock { images[name] = image }
        return image
    }

    private static func decode(_ name: String, game: CatSystemGame) -> HGImage? {
        guard let bytes = try? game.file(named: name.hasSuffix(".hg3") ? name : name + ".hg3") else { return nil }
        return try? HGImage(bytes)
    }

    /// Decodes the pictures the scripts' `#PRELOAD` lists name (in this language), so a
    /// screen doesn't stop to decode them when it appears. Safe to call from another thread
    /// while the scripts run (it only fills the picture cache).
    public func preload(scripts: [String]) {
        let others = ["jp", "en", "cn"].filter { $0 != language }
        for script in scripts {
            guard let bytes = try? game.file(named: script + ".fes"), let text = try? FESScript.text(bytes) else { continue }
            for raw in FESProgram(text: text).preload {
                let name = raw.replacingOccurrences(of: "%LANG%", with: language).lowercased()
                if others.contains(where: { name.hasSuffix("_" + $0) }) { continue }
                if imageLock.withLock({ images[name] != nil }) { continue }
                guard let image = Self.decode(name, game: game) else { continue }
                imageLock.withLock { if images[name] == nil { images[name] = image } }
            }
        }
    }

    /// The screen as straight RGBA: the `baseimg` snapshot, then shown objects by priority
    /// (a plane's children inside it, ordered by their own priority, faded with it).
    public func render() -> [UInt8] {
        var canvas = base ?? {
            var black = [UInt8](repeating: 0, count: width * height * 4)
            for i in stride(from: 3, to: black.count, by: 4) { black[i] = 255 }
            return black
        }()
        var objects: [FESObject] = []
        visit { objects.append($0) }
        var planes: [String: FESObject] = [:]
        for o in objects where o.isPlane { planes[o.key] = o }
        // Sort key: (top-level priority, priority inside the plane).
        var draws: [(Int, Int, Int, FESObject)] = []
        for (order, o) in objects.enumerated() where o.disp {
            if let planeName = o.plane, let plane = planes[planeName] ?? planes[planeName + "[0]"] {
                guard plane.disp else { continue }
                draws.append((plane.pri, o.pri, order, o))
            } else {
                draws.append((o.pri, Int.min, order, o))
            }
        }
        draws.sort { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }
        for (_, _, _, o) in draws {
            let plane = o.plane.flatMap { planes[$0] ?? planes[$0 + "[0]"] }
            let planeAlpha = plane?.alpha ?? 255
            let alpha = o.alpha * planeAlpha / 255
            guard alpha > 0 else { continue }
            let originX = (plane?.x ?? 0) + o.x, originY = (plane?.y ?? 0) + o.y
            if let color = o.color, o.width > 0 {
                fill(&canvas, x: originX, y: originY, w: o.width, h: o.height, color: color, alpha: alpha)
            } else if let file = o.file, let image = picture(file) {
                let id = o.currentID
                guard let frame = id.flatMap(image.frame(id:)) ?? (id == nil ? image.frames.first : nil) else {
                    noteOnce("no frame \(id ?? -1) in \(file)")
                    continue
                }
                blit(&canvas, frame, x: originX + frame.offsetX, y: originY + frame.offsetY, alpha: alpha)
            }
        }
        return canvas
    }

    private func fill(_ canvas: inout [UInt8], x: Int, y: Int, w: Int, h: Int, color: UInt32, alpha: Int) {
        var c = Canvas(width: width, height: height, pixels: canvas)
        canvas = []
        c.fill(x: x, y: y, w: w, h: h, color: color, alpha: alpha)
        canvas = c.pixels
    }

    private func blit(_ canvas: inout [UInt8], _ frame: HGImage.Frame, x: Int, y: Int, alpha: Int) {
        var c = Canvas(width: width, height: height, pixels: canvas)
        canvas = []
        c.blit(frame, x: x, y: y, alpha: alpha)
        canvas = c.pixels
    }
}

/// An object a script defined: a plane (a group with its own fade), a picture or button
/// (frames of an HG-3 chosen by id), a colour plane, or a sound (only logged headless).
final class FESObject {
    let type: String
    let key: String
    let baseName: String
    let index: Int?
    var file: String?
    var ids: [Int] = []
    var idIndex = 0
    var x = 0, y = 0
    var width = 0, height = 0
    var plane: String?
    var pri = 0
    var disp = false
    var enable = true
    var color: UInt32?
    var alpha = 255
    /// A sound's loaded file, and a music table's entries.
    var sound: String?
    var soundTable: [Int: String] = [:]
    private var fade: (from: Int, to: Int, frames: Int, elapsed: Int)?

    init(type: String, baseName: String, index: Int?) {
        self.type = type
        self.baseName = baseName
        self.index = index
        key = index.map { "\(baseName)[\($0)]" } ?? baseName
    }

    var isPlane: Bool { type == "PLANE" || type == "CPLANE" }
    var isMoving: Bool { fade != nil }

    var currentID: Int? {
        if ids.isEmpty { return idIndex == 0 ? nil : idIndex }
        return idIndex < ids.count ? ids[idIndex] : ids.last
    }

    func startFade(frames: Int, from: Int, to: Int) {
        alpha = from
        fade = frames > 0 ? (from, to, frames, 0) : nil
        if frames <= 0 { alpha = to }
    }

    func advanceMotion() {
        guard var f = fade else { return }
        f.elapsed += 1
        alpha = f.from + (f.to - f.from) * f.elapsed / f.frames
        fade = f.elapsed >= f.frames ? nil : f
    }

    func finishMotion() {
        if let f = fade { alpha = f.to }
        fade = nil
    }
}

final class FESInstance: FESContext {
    let name: String
    let program: FESProgram
    unowned let player: FESPlayer
    weak var parent: FESInstance?
    var child: FESInstance?
    private(set) var objects: [FESObject] = []
    private var byKey: [String: FESObject] = [:]
    private var locals: [Int: Int] = [:]
    private(set) var label = "START"
    private var exitCode = -1
    private(set) var finished: Int?
    /// A suspended run: the call stack of (label, next statement) to resume.
    private var suspended: [(String, Int)]?
    private var waitFrames = 0
    private var waitMotion = false
    /// The button whose event block is running (`@`).
    private var eventObject: FESObject?

    func hasBlock(_ name: String) -> Bool { program.blocks[name] != nil }

    init(name: String, program: FESProgram, player: FESPlayer, parent: FESInstance?) {
        self.name = name
        self.program = program
        self.player = player
        self.parent = parent
        for d in program.definitions {
            if let count = d.count {
                for i in 0..<count { add(FESObject(type: d.type, baseName: d.name, index: i)) }
            } else {
                add(FESObject(type: d.type, baseName: d.name, index: nil))
            }
        }
        for table in program.tables {
            for (target, values) in table.rows {
                for o in elements(target) { apply(table.columns, values, to: o) }
            }
        }
    }

    private func add(_ o: FESObject) {
        objects.append(o)
        byKey[o.key] = o
    }

    /// `name` (every element) or `name[i]`.
    func elements(_ target: String) -> [FESObject] {
        if let o = byKey[target] { return [o] }
        return objects.filter { $0.baseName == target }
    }

    func object(named name: String) -> FESObject? { byKey[name] }

    private func apply(_ columns: [String], _ values: [String], to o: FESObject) {
        for (column, value) in zip(columns, values) {
            func pair() -> (Int, Int) {
                let parts = value.split(separator: ",").map { Int($0) ?? 0 }
                return (parts.first ?? 0, parts.count > 1 ? parts[1] : 0)
            }
            switch column {
            case "FILE": o.file = value
            case "POS": (o.x, o.y) = pair()
            case "SIZE": (o.width, o.height) = pair()
            case "PRI": o.pri = Int(value) ?? 0
            case "DISP": o.disp = value != "0"
            case "ENABLE": o.enable = value != "0"
            case "PL": o.plane = value
            case "COLOR": o.color = UInt32(value.replacingOccurrences(of: "0x", with: ""), radix: 16)
            default:
                if column.hasPrefix("ID."), let k = Int(column.dropFirst(3)) {
                    while o.ids.count <= k { o.ids.append(0) }
                    o.ids[k] = Int(value) ?? 0
                }
            }
        }
    }

    // MARK: FESContext

    func global(_ index: Int) -> Int { player.globals[index] ?? 0 }
    func setGlobal(_ index: Int, _ value: Int) { player.globals[index] = value }
    func local(_ index: Int) -> Int { locals[index] ?? 0 }
    func setLocal(_ index: Int, _ value: Int) { locals[index] = value }
    func macro(_ name: String) -> String? { program.macros[name] }

    func system(_ name: String) -> Int? {
        switch name {
        case "_EXITCODE_": exitCode
        case "_CLICK_L_", "_CLICK_R_": 0
        case "@": eventObject?.index ?? 0
        default: nil
        }
    }

    // MARK: Running

    func tick() {
        guard finished == nil else { return }
        if waitFrames > 0 {
            waitFrames -= 1
            if waitFrames > 0 { return }
        }
        if waitMotion {
            if objects.contains(where: \.isMoving) { return }
            waitMotion = false
        }
        let stack = suspended ?? [(label, 0)]
        suspended = nil
        run(stack)
    }

    /// A button event block (`#decide.PUSH_L`), run straight away.
    func runEvent(_ object: FESObject, _ event: String) {
        let block = "\(object.baseName).\(event)"
        guard program.blocks[block] != nil else { return }
        eventObject = object
        run([(block, 0)])
        eventObject = nil
    }

    private func run(_ start: [(String, Int)]) {
        var stack = start
        var budget = 20_000
        while var (block, pc) = stack.popLast() {
            guard let lines = program.blocks[block] else { continue }
            while pc < lines.count {
                budget -= 1
                if budget == 0 {
                    player.noteOnce("\(name)#\(block): runaway loop")
                    return
                }
                let line = lines[pc]
                if FESPlayer.trace { print("    \(name)#\(block):\(pc) \(line)") }
                pc += 1
                switch execute(line, lines: lines, pc: &pc) {
                case .continue:
                    break
                case .call(let target):
                    stack.append((block, pc))
                    stack.append((target, 0))
                    pc = lines.count  // leave this block; the call runs next
                case .suspend:
                    stack.append((block, pc))
                    suspended = stack
                    return
                case .stop:
                    return
                }
            }
        }
    }

    private enum Outcome {
        case `continue`
        case call(String)
        case suspend
        case stop
    }

    private func value(_ token: String) -> Int { FESExpression.evaluate(token, self) }

    private func text(_ token: String) -> String {
        if token.hasPrefix("$str"), let n = Int(token.dropFirst(4)) { return player.strings[n] ?? "" }
        return token
    }

    private func execute(_ line: String, lines: [String], pc: inout Int) -> Outcome {
        var words = line.split(separator: " ").map(String.init)
        guard let head = words.first else { return .continue }

        // Control flow.
        if head == "if" || head.hasPrefix("if(") {
            let (condition, rest) = Self.condition(line)
            let truth = value(condition) != 0
            if !rest.isEmpty {
                return truth ? execute(rest, lines: lines, pc: &pc) : .continue
            }
            if !truth { pc = Self.skip(lines, from: pc, stopAtElse: true) }
            return .continue
        }
        if head == "else" { pc = Self.skip(lines, from: pc, stopAtElse: false); return .continue }
        if head == "endif" { return .continue }

        // Assignments: `$n = expr`, `\n = expr`, `$(expr) = expr`, `\n++`.
        if head.hasPrefix("$") || head.hasPrefix("\\") {
            assign(line)
            return .continue
        }

        if let macro = program.macros[head] { words[0] = macro }
        let args = Array(words.dropFirst())
        switch head {
        case "next":
            if let target = args.first { label = target }
            return .stop
        case "call":
            return args.first.map { .call($0) } ?? .continue
        case "wait":
            if let n = args.first.map(value), n > 0 {
                waitFrames = n
                return .suspend
            }
            if args.isEmpty, objects.contains(where: \.isMoving) {
                waitMotion = true
                return .suspend
            }
            return .continue
        case "exit":
            finished = args.first.map(value) ?? 0
            parent?.childExited(code: finished ?? 0)
            return .stop
        case "execfes":
            guard let target = args.first else { return .continue }
            do {
                child = try player.load(target, parent: self)
                exitCode = -1
                player.note("execfes \(target)")
            } catch {
                player.noteOnce("execfes \(target): \(error)")
            }
            return .continue
        case "endfes":
            child = nil
            return .continue
        case "execkcs":
            exitCode = -1
            player.requestKCS(args.first ?? "")
            return .continue
        case "baseimg":
            player.snapshotBase()
            return .continue
        case "strvar":
            guard args.count >= 2, let n = Int(args[0]) else { return .continue }
            player.strings[n] = Self.format(args[1], args.dropFirst(2).map(value))
            return .continue
        case "rand":
            if args.count >= 3, let n = Int(args[0]) { setGlobal(n, player.random(value(args[1]), value(args[2]))) }
            return .continue
        case "fileexist":
            if args.count >= 2, let n = Int(args[1]) {
                let file = args[0].split(separator: "/").last.map(String.init) ?? args[0]
                setGlobal(n, player.game.contains(file) ? 1 : 0)
            }
            return .continue
        case "getconf", "getsndconfex", "cgreg_t", "saveexist", "steam_isenable", "steam_isbroadcast":
            // Settings, CG registry, saves and Steam: nothing set yet, so 0.
            if let n = args.first.flatMap({ Int($0) }) { setGlobal(n, 0) }
            return .continue
        case "keyskip", "xchgcursor", "dbgstr", "debug", "setconf", "setsndconfex", "cgreg_init", "savecopy",
             "savedelete", "endkcs", "steam_enablescreenshot", "rettitle":
            return .continue
        default:
            break
        }

        // Object commands: `name sub args`, `@ sub args` for the button whose event runs.
        let targets: [FESObject]
        if head == "@", let o = eventObject {
            targets = [o]
        } else {
            targets = elements(head)
        }
        guard !targets.isEmpty, let sub = args.first else {
            player.noteOnce("\(name): unhandled `\(line)`")
            return .continue
        }
        let params = Array(args.dropFirst())
        for o in targets { command(o, sub, params) }
        return .continue
    }

    private func command(_ o: FESObject, _ sub: String, _ params: [String]) {
        switch sub {
        case "disp": o.disp = (params.first.map(value) ?? 1) != 0
        case "enable": o.enable = (params.first.map(value) ?? 1) != 0
        case "setid": o.idIndex = params.first.map(value) ?? 0
        case "fade", "fade2":
            let p = params.map(value)
            o.startFade(frames: p.first ?? 30, from: p.count > 1 ? p[1] : 0, to: p.count > 2 ? p[2] : 255)
        case "blend":
            if o.type == "SOUND" || o.type == "SNDTABLE" { break }
            o.alpha = params.first.map(value) ?? 255
        case "pos":
            let p = params.map(value)
            if p.count >= 2 { o.x = p[0]; o.y = p[1] }
        case "load":
            o.sound = params.first.map(text)
            player.note("\(o.key) load \(params.first.map(text) ?? "")")
        case "play":
            let table = o.type == "SNDTABLE"
            let file = table ? o.soundTable[o.idIndex] ?? o.soundTable.sorted { $0.key < $1.key }.first?.value : o.sound
            if let file { player.sounds.append(.init(channel: o.key, table: table, file: file, loop: table)) }
            player.note("\(o.key) play")
        case "stop":
            if o.type == "SOUND" || o.type == "SNDTABLE" { player.sounds.append(.init(channel: o.key, table: o.type == "SNDTABLE", file: nil, loop: false)) }
        case "sndtbl":
            // `bgmtbl sndtbl 00 bgm_01 $600`: entry 0 is bgm_01.
            if params.count >= 2, let n = Int(params[0]) { o.soundTable[n] = params[1] }
        case "noact", "setid_s", "crossfade", "loop", "shuffle", "getid", "next", "rev":
            break
        default:
            player.noteOnce("\(name): \(o.type) \(o.baseName) \(sub) not handled")
        }
    }

    func childExited(code: Int) {
        exitCode = code
        child = nil
    }

    private func assign(_ line: String) {
        let trimmed = line.replacingOccurrences(of: " ", with: "")
        func target(_ lhs: String) -> (global: Bool, index: Int) {
            let global = lhs.hasPrefix("$")
            let body = String(lhs.dropFirst())
            let index = body.hasPrefix("(") ? value(body) : Int(body) ?? 0
            return (global, index)
        }
        func store(_ t: (global: Bool, index: Int), _ v: Int) {
            if t.global { setGlobal(t.index, v) } else { setLocal(t.index, v) }
        }
        func load(_ t: (global: Bool, index: Int)) -> Int { t.global ? global(t.index) : local(t.index) }
        if trimmed.hasSuffix("++") || trimmed.hasSuffix("--") {
            let t = target(String(trimmed.dropLast(2)))
            store(t, load(t) + (trimmed.hasSuffix("++") ? 1 : -1))
            return
        }
        for op in ["+=", "-=", "*="] {
            if let r = trimmed.range(of: op) {
                let t = target(String(trimmed[..<r.lowerBound]))
                let v = value(String(trimmed[r.upperBound...]))
                store(t, op == "+=" ? load(t) + v : op == "-=" ? load(t) - v : load(t) * v)
                return
            }
        }
        // `a = b = expr`: every target takes the value.
        var parts: [String] = []
        var depth = 0, current = "", chars = Array(trimmed), i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "(" { depth += 1 } else if c == ")" { depth -= 1 }
            if c == "=", depth == 0, (i + 1 >= chars.count || chars[i + 1] != "="),
               (i == 0 || !"!<>=".contains(chars[i - 1])) {
                parts.append(current)
                current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        parts.append(current)
        guard parts.count >= 2 else { return }
        let v = value(parts.last!)
        for lhs in parts.dropLast() { store(target(lhs), v) }
    }

    /// `if (cond) rest`: the condition and any statement after it on the same line.
    static func condition(_ line: String) -> (String, String) {
        guard let open = line.firstIndex(of: "(") else { return ("0", "") }
        var depth = 0
        var i = open
        while i < line.endIndex {
            if line[i] == "(" { depth += 1 } else if line[i] == ")" {
                depth -= 1
                if depth == 0 { break }
            }
            i = line.index(after: i)
        }
        let condition = String(line[line.index(after: open)..<min(i, line.endIndex)])
        let rest = i < line.endIndex ? line[line.index(after: i)...].trimmingCharacters(in: .whitespaces) : ""
        return (condition, rest)
    }

    /// The statement after the matching `else` (when `stopAtElse`) or `endif`.
    static func skip(_ lines: [String], from start: Int, stopAtElse: Bool) -> Int {
        var depth = 0
        var i = start
        while i < lines.count {
            let head = lines[i].split(separator: " ").first.map(String.init) ?? ""
            if head == "if" || head.hasPrefix("if(") {
                if condition(lines[i]).1.isEmpty { depth += 1 }
            } else if head == "endif" {
                if depth == 0 { return i + 1 }
                depth -= 1
            } else if head == "else", depth == 0, stopAtElse {
                return i + 1
            }
            i += 1
        }
        return i
    }

    /// `strvar`'s printf: `%d` and `%02d`-style fields filled from `values` in order.
    static func format(_ pattern: String, _ values: [Int]) -> String {
        var out = ""
        var values = values[...]
        var chars = pattern[...]
        while let c = chars.first {
            chars = chars.dropFirst()
            guard c == "%" else { out.append(c); continue }
            var spec = ""
            while let d = chars.first, d.isNumber { spec.append(d); chars = chars.dropFirst() }
            guard chars.first == "d" else { out.append("%" + spec); continue }
            chars = chars.dropFirst()
            let v = values.popFirst() ?? 0
            if spec.hasPrefix("0"), let width = Int(spec) {
                out += String(format: "%0\(width)d", v)
            } else {
                out += String(v)
            }
        }
        return out
    }
}
