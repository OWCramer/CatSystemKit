import Foundation

/// A save as the game's save and load screens show it (`getsavestr`, `getsavedate`, the
/// panel's thumbnail).
public struct FESSaveInfo: Sendable {
    public var title: String
    public var comment: String
    public var date: Date
    /// Straight RGBA, any size (drawn into the panel's picture box).
    public var thumbnail: (rgba: [UInt8], width: Int, height: Int)?

    public init(title: String, comment: String, date: Date, thumbnail: (rgba: [UInt8], width: Int, height: Int)?) {
        self.title = title
        self.comment = comment
        self.date = date
        self.thumbnail = thumbnail
    }
}

/// A line of the backlog as the game's log screen (`hist_b.fes`) shows it.
public struct FESLogEntry: Sendable {
    public var name: String?
    /// The speaker's picture in `sys_meswnd_name_%LANG%` (`nametable.csv`), if there is one.
    public var nameID: Int?
    public var text: String
    public var hasVoice: Bool

    public init(name: String?, nameID: Int?, text: String, hasVoice: Bool) {
        self.name = name
        self.nameID = nameID
        self.text = text
        self.hasVoice = hasVoice
    }
}

/// What the scripts ask of the engine around them: settings (`getconf`, `getsndconfex`),
/// saves (`saveexist`, `datasave`, …), the backlog, leaving for the title. Headless runs
/// leave it nil (settings read 0, there are no saves).
public protocol FESHost: AnyObject {
    func fesConfig(_ name: String) -> Int?
    func fesSetConfig(_ name: String, value: Int)
    /// `getsndconfex 850 volume bgm` → `["volume", "bgm"]`; `volume_id 2 3` likewise.
    func fesSoundConfig(_ args: [String]) -> Int?
    func fesSetSoundConfig(_ args: [String], value: Int)
    /// 1 a save is there, 0 the slot is empty, -1 it can't be loaded.
    func fesSaveState(slot: Int) -> Int
    /// The newest save among `count` slots from `from`, or -1.
    func fesNewestSave(from: Int, count: Int) -> Int
    func fesSave(slot: Int)
    func fesDeleteSave(slot: Int)
    func fesSaveInfo(slot: Int) -> FESSaveInfo?
    func fesReturnToTitle()
    var fesLog: [FESLogEntry] { get }
    func fesPlayLogVoice(_ index: Int)
}

/// Runs FES scripts, CatSystem2's system-screen language, one frame (1/60 s) at a time, and
/// draws their objects: the boot flow (`flow.fes`: logo, language picker, title), and the
/// save and load (`saveload.fes`), CONFIG (`config.fes`), confirmation (`confirm2.fes`)
/// and backlog (`hist_b.fes`) screens.
///
/// How a script runs (worked out from NEKOPARA Vol. 3's scripts): the current label's block
/// runs from its top each frame. `next LABEL` switches label and ends the frame's run;
/// `call LABEL` runs another block inline (`break` returns from it); `wait` suspends until the
/// script's motions end, `wait N` for N frames, both resuming after the `wait`. `execfes
/// name` starts a child script; the parent keeps running and reads `_EXITCODE_` (-1 while the
/// child runs, then the code the child gave `exit`). Buttons run `#name.EVENT` blocks with
/// `@` as their index (`FOCUS` and `UNFOCUS` as the pointer comes and goes, `PUSH_L` on a
/// click), and the label's block sees the click once as `_CLICK_L_` (the button's handle, or
/// -1 off every button); `_CLICK_R_` is a right click, `_SCRL_U_`/`_SCRL_D_` the wheel.
/// Buttons are hit-tested whether or not they are drawn (the save slots and CONFIG switches
/// are drawn by other objects); sliders run `SCRL_P` as they are dragged.
public final class FESPlayer: @unchecked Sendable {
    /// CS2_TRACE=1: every statement as it runs, on standard output.
    nonisolated(unsafe) static var trace = ProcessInfo.processInfo.environment["CS2_TRACE"] != nil

    public let game: CatSystemGame
    public let width: Int
    public let height: Int
    /// The `%LANG%` prefix in file names (`startup.xml` language 0 is English).
    public var language = "en"
    /// The game's fonts (file name, lower-cased, without extension) to their registered names.
    public var fonts: [String: String] = [:]
    public weak var host: FESHost?
    /// Draw over a clear screen instead of black (a screen opened over the story), and keep
    /// `baseimg` from freezing it.
    public var transparent = false
    /// Objects (by name) left out: neither drawn nor pressed (the backlog's jump-back
    /// buttons, which need a rollback Shiori's story doesn't keep).
    public var suppressed: Set<String> = []
    public private(set) var frameCount = 0
    /// Sounds started, unknown commands and other events, for headless runs.
    public private(set) var events: [String] = []
    /// The `$n` variables, as the scripts left them (`$512` is -3 after GAME START).
    public var variables: [Int: Int] { globals }
    /// The `$strN` string variables (`$str200` names the first scene after GAME START).
    public var stringVariables: [Int: String] { strings }
    /// The story script `execkcs` asked for (`sscript` when the game starts), if any.
    public private(set) var requestedKCS: String?
    /// `rettitle` ran: the game goes back to its title.
    public private(set) var returnedToTitle = false
    /// `xchgcursor btndown`: the pointer is over something to press.
    public private(set) var cursorOverButton = false
    /// A crossfade the scripts asked for (`rdraw 20`), in frames, until taken.
    public private(set) var pendingTransition: Int?

    public func takeTransition() -> Int? {
        defer { pendingTransition = nil }
        return pendingTransition
    }

    /// A sound a script started or stopped: `channel` is its object (`voice`, `se1`,
    /// `bgmtbl`), `table` true for a music table (`SNDTABLE`), `file` the Ogg's name
    /// without extension (`A_title_002`, `se_sys_05`, `bgm_01`); nil with `stop`.
    public struct Sound: Sendable {
        public let channel: String
        public let table: Bool
        public let file: String?
        public let loop: Bool
        /// The object's sound group (`voice`, `sysse`).
        public var group: String? = nil
        public var stop: Bool { file == nil }
    }

    /// Sets a `$n` variable before or while the scripts run (`$897 = 1`: the language was
    /// chosen before, so the title flow skips the picker).
    public func setVariable(_ index: Int, _ value: Int) { globals[index] = value }

    /// Sets a `$strN` string variable (`$str901` names the message window's picture).
    public func setString(_ index: Int, _ value: String) { strings[index] = value }

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
    /// The button the pointer is over (its `FOCUS` block has run).
    private var focused: (instance: FESInstance, object: FESObject)?
    /// A slider being dragged.
    private var dragging: (instance: FESInstance, object: FESObject)?
    var textCache: [String: HGImage.Frame] = [:]

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

    var instances: [FESInstance] {
        var out: [FESInstance] = []
        var i = root
        while let s = i { out.append(s); i = s.child }
        return out
    }

    /// Advances one frame: every running script ticks (parent first), then motions move.
    public func step() {
        frameCount += 1
        for i in instances {
            i.tick()
            i.clearInput()
        }
        var all: [FESObject] = []
        visit { all.append($0) }
        for o in all { o.advanceMotion() }
        if let focused, !instances.contains(where: { $0 === focused.instance }) { self.focused = nil }
    }

    /// The `$n = v` lines of a block in a script (`flow.fes`'s `INIT_GLOBAL`: the settings
    /// a first run starts with), without running it.
    public func assignments(script: String, block: String) -> [Int: Int] {
        guard let bytes = try? game.file(named: script + ".fes"), let text = try? FESScript.text(bytes) else { return [:] }
        var out: [Int: Int] = [:]
        for line in FESProgram(text: text).blocks[block] ?? [] {
            let parts = line.replacingOccurrences(of: " ", with: "").split(separator: "=")
            if parts.count == 2, parts[0].hasPrefix("$"), let n = Int(parts[0].dropFirst()), let v = Int(parts[1]) { out[n] = v }
        }
        return out
    }

    // MARK: Input

    /// A left click on a button (`decide`, `btn1[0]`): runs its `FOCUS` (unless the pointer
    /// is on it already) and `PUSH_L` blocks if the button is enabled, and the script sees
    /// `_CLICK_L_`. False when no running script has it.
    @discardableResult
    public func push(_ name: String) -> Bool {
        guard let (owner, object) = owner(of: name), object.enable, owner.planeShown(object) else { return false }
        push(owner, object)
        return true
    }

    private func push(_ owner: FESInstance, _ object: FESObject) {
        if focused?.object !== object {
            unfocus()
            owner.runEvent(object, "FOCUS")
            focused = (owner, object)
        }
        owner.runEvent(object, "PUSH_L")
        owner.clickL = object.handle
        owner.runEvent(object, "RELEASE_L")
    }

    /// Whether a button is enabled in some running script.
    public func canPush(_ name: String) -> Bool {
        guard let (owner, o) = owner(of: name) else { return false }
        return o.enable && owner.planeShown(o)
    }

    private func owner(of name: String) -> (FESInstance, FESObject)? {
        var found: (FESInstance, FESObject)?
        for s in instances { if let o = s.object(named: name) { found = (s, o) } }
        return found
    }

    /// A click (or tap) at a point on the screen: the button there is pressed; a slider
    /// there jumps to the point. Off every button, the topmost script sees `_CLICK_L_` -1.
    /// `pointer` false (a finger) takes the focus away again afterwards, as nothing hovers.
    /// Returns the button pressed, if any.
    @discardableResult
    public func click(atX x: Int, y: Int, pointer: Bool = false) -> String? {
        if let (owner, o) = hit(x, y) {
            if o.type == "SLIDER" || o.type == "SCROLL2" {
                if focused?.object !== o { unfocus(); owner.runEvent(o, "FOCUS"); focused = (owner, o) }
                owner.slide(o, toX: x, y: y)
                if !pointer { unfocus() }
                return o.key
            }
            push(owner, o)
            if !pointer { unfocus() }
            return o.key
        }
        instances.last?.clickL = -1
        return nil
    }

    /// A right click (Escape, a two-finger tap): the topmost script sees `_CLICK_R_`.
    public func rightClick() { instances.last?.clickR = 1 }

    /// The wheel: up (back) or down.
    public func scroll(up: Bool) {
        if up { instances.last?.scrollUp = 1 } else { instances.last?.scrollDown = 1 }
    }

    /// The pointer moved (or left the screen with nil): the button under it gets `FOCUS`
    /// and the one it left `UNFOCUS`, as the game's buttons light up.
    public func hover(atX x: Int?, y: Int?) {
        mouse = (x ?? mouse.x, y ?? mouse.y)
        if let dragging, let x, let y {
            dragging.instance.slide(dragging.object, toX: x, y: y)
            return
        }
        guard let x, let y, let (owner, o) = hit(x, y) else { unfocus(); return }
        if focused?.object === o { return }
        unfocus()
        owner.runEvent(o, "FOCUS")
        focused = (owner, o)
    }

    /// The pointer's last place, for `_MOUSE_X_`/`_MOUSE_Y_`.
    var mouse = (x: 0, y: 0)

    /// A drag on a slider: begins where it is pressed, follows, and ends.
    public func beginDrag(atX x: Int, y: Int) -> Bool {
        guard let (owner, o) = hit(x, y), o.type == "SLIDER" || o.type == "SCROLL2" else { return false }
        if focused?.object !== o { unfocus(); owner.runEvent(o, "FOCUS"); focused = (owner, o) }
        dragging = (owner, o)
        owner.slide(o, toX: x, y: y)
        return true
    }

    public func endDrag() {
        dragging = nil
    }

    public var isDragging: Bool { dragging != nil }

    private func unfocus() {
        guard let f = focused else { return }
        focused = nil
        if instances.contains(where: { $0 === f.instance }) { f.instance.runEvent(f.object, "UNFOCUS") }
    }

    /// Enter or Space: presses the button the pointer is on, if any.
    @discardableResult
    public func pressFocused() -> Bool {
        guard let f = focused, instances.contains(where: { $0 === f.instance }), f.object.enable,
              f.object.type == "BUTTON" else { return false }
        push(f.instance, f.object)
        return true
    }

    /// Whether a drag at (x, y) would move a slider.
    public func isSlider(atX x: Int, y: Int) -> Bool {
        guard let (_, o) = hit(x, y) else { return false }
        return o.type == "SLIDER" || o.type == "SCROLL2"
    }

    /// The button a click at (x, y) on the screen would press, if any.
    public func button(atX x: Int, y: Int) -> String? { hit(x, y)?.1.key }

    /// The enabled button or slider whose picture (or area) covers the point, in the
    /// topmost script, by priority. Shown or not: the game's slots and switches are
    /// invisible buttons under pictures drawn by other objects.
    private func hit(_ x: Int, _ y: Int) -> (FESInstance, FESObject)? {
        var best: (depth: Int, pri: Int, sub: Int, instance: FESInstance, object: FESObject)?
        for (depth, s) in instances.enumerated() {
            for o in s.objects where o.enable && o.isPressable(in: s) && !suppressed.contains(o.baseName) {
                guard s.planeShown(o), let rect = s.hitRect(o) else { continue }
                guard x >= rect.x, x < rect.x + rect.w, y >= rect.y, y < rect.y + rect.h else { continue }
                let plane = s.plane(of: o)
                let order = (depth, plane?.pri ?? o.pri, plane == nil ? Int.min : o.pri)
                if best.map({ order >= ($0.depth, $0.pri, $0.sub) }) ?? true {
                    best = (order.0, order.1, order.2, s, o)
                }
            }
        }
        return best.map { ($0.instance, $0.object) }
    }

    /// Changes whenever what `render()` draws may have changed (objects shown, their
    /// frames, places and fades), so a host redraws only then.
    public var drawState: Int {
        var hasher = Hasher()
        hasher.combine(base?.count ?? 0)
        hasher.combine(baseRevision)
        hasher.combine(focused.map { ObjectIdentifier($0.object) })
        hasher.combine(dragging.map { ObjectIdentifier($0.object) })
        visit { o in
            hasher.combine(o.disp)
            guard o.disp else { return }
            hasher.combine(o.alpha)
            hasher.combine(o.x)
            hasher.combine(o.y)
            hasher.combine(o.offsetX)
            hasher.combine(o.offsetY)
            hasher.combine(o.currentID)
            hasher.combine(o.file)
            hasher.combine(o.revision)
            hasher.combine(o.revealed(at: frameCount))
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

    func returnToTitle() {
        returnedToTitle = true
        host?.fesReturnToTitle()
    }

    func setCursor(down: Bool) { cursorOverButton = down }

    func requestTransition(_ frames: Int) { pendingTransition = frames }

    func random(_ low: Int, _ high: Int) -> Int {
        randomState = randomState &* 1_103_515_245 &+ 12345
        return low + Int(randomState >> 16) % max(1, high - low + 1)
    }

    func snapshotBase() {
        guard !transparent else { return }
        base = render()
        baseRevision += 1
    }

    // MARK: Drawing

    func visit(_ body: (FESObject) -> Void) {
        for s in instances { for o in s.objects { body(o) } }
    }

    func picture(_ file: String) -> HGImage? {
        let name = file.replacingOccurrences(of: "%LANG_M%", with: language).replacingOccurrences(of: "%LANG%", with: language).lowercased()
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
            for raw in FESProgram(text: text).preload where !raw.hasPrefix("$") {
                let name = raw.replacingOccurrences(of: "%LANG%", with: language).lowercased()
                if others.contains(where: { name.hasSuffix("_" + $0) }) { continue }
                if imageLock.withLock({ images[name] != nil }) { continue }
                guard let image = Self.decode(name, game: game) else { continue }
                imageLock.withLock { if images[name] == nil { images[name] = image } }
            }
        }
    }

    /// The screen as straight RGBA (premultiplied when `transparent`): the `baseimg`
    /// snapshot, then shown objects by priority (a plane's children inside it, ordered by
    /// their own priority, faded with it).
    public func render() -> [UInt8] {
        var canvas = Canvas(width: width, height: height, pixels: base ?? Canvas(width: width, height: height, transparent: transparent).pixels)
        var draws: [(Int, Int, Int, FESInstance, FESObject)] = []
        var order = 0
        for s in instances {
            for o in s.objects where o.disp && !suppressed.contains(o.baseName) {
                order += 1
                guard s.planeShown(o) else { continue }
                if let plane = s.plane(of: o), o.plane != nil {
                    draws.append((plane.pri, o.pri, order, s, o))
                } else {
                    draws.append((o.pri, Int.min, order, s, o))
                }
            }
        }
        draws.sort { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }
        for (_, _, _, s, o) in draws {
            let place = s.origin(of: o)
            let alpha = o.alpha * place.alpha / 255
            guard alpha > 0 else { continue }
            draw(o, in: s, x: place.x, y: place.y, alpha: alpha, canvas: &canvas)
        }
        return canvas.pixels
    }

    private func draw(_ o: FESObject, in s: FESInstance, x originX: Int, y originY: Int, alpha: Int, canvas: inout Canvas) {
        switch o.type {
        case "STRING8":
            if let frame = s.textFrame(o) { canvas.blit(frame, x: originX + frame.offsetX, y: originY + frame.offsetY, alpha: alpha) }
        case "SAVEPANEL":
            guard let file = o.file, let image = picture(file) else { return }
            for id in o.shownIDs.sorted() {
                if let box = o.simage[id] {
                    let at = image.frame(id: id)
                    let bx = originX + (at?.offsetX ?? 0), by = originY + (at?.offsetY ?? 0)
                    if let thumb = s.thumbnail(o, width: box.w, height: box.h) {
                        canvas.blit(thumb, x: bx, y: by, alpha: alpha)
                    } else if let at {
                        canvas.blit(at, x: bx, y: by, alpha: alpha)
                    }
                } else if let frame = image.frame(id: id) {
                    canvas.blit(frame, x: originX + frame.offsetX, y: originY + frame.offsetY, alpha: alpha)
                }
            }
        case "SLIDER", "SCROLL2":
            guard let file = o.file, let image = picture(file) else { return }
            if o.type == "SCROLL2" {
                // The bar: its top, a stretched middle and its bottom (`sys_log_scrl` 1/0/2).
                guard let top = image.frame(id: 1), let mid = image.frame(id: 0), let bottom = image.frame(id: 2) else { return }
                let knob = s.knob(o)
                canvas.blit(top, x: knob.x, y: knob.y, alpha: alpha)
                let middle = max(0, knob.h - top.height - bottom.height)
                if middle > 0 {
                    canvas.blit(mid, x: Double(knob.x), y: Double(knob.y + top.height), scaleX: 1,
                                scaleY: Double(middle) / Double(mid.height), alpha: alpha)
                }
                canvas.blit(bottom, x: knob.x, y: knob.y + top.height + middle, alpha: alpha)
            } else if let frame = image.frame(id: dragging?.object === o ? 3 : focused?.object === o ? 2 : o.enable ? 0 : 1) ?? image.frames.last {
                // `sys_config_slider`: 0 the knob, 1 disabled, 2 under the pointer, 3 held.
                let knob = s.knob(o)
                canvas.blit(frame, x: knob.x, y: knob.y, alpha: alpha)
            }
        case "LOGSTRING8":
            for (i, block) in s.logBlocks(o).enumerated() {
                guard let frame = block else { continue }
                let area = o.blockAreas.indices.contains(i) ? o.blockAreas[i] : (x: originX, y: originY + i * 155, w: 802, h: 111)
                canvas.blit(frame, x: area.x + frame.offsetX, y: area.y + frame.offsetY, alpha: alpha)
            }
        default:
            if let color = o.color, o.width > 0 {
                // Colour planes are opaque colours faded by their blend (`pl_base` 0x00000000
                // at 50 dims the screen under a dialog).
                let opaque = o.type == "CPLANE" || o.type == "CIMAGE" ? color | 0xFF00_0000 : color
                canvas.fill(x: originX, y: originY, w: o.width, h: o.height, color: opaque, alpha: alpha)
            } else if let file = o.file, let image = picture(file) {
                let id = o.currentID
                guard let frame = id.flatMap(image.frame(id:)) ?? (id == nil ? image.frames.first : nil) else {
                    noteOnce("no frame \(id ?? -1) in \(file)")
                    return
                }
                canvas.blit(frame, x: originX + frame.offsetX, y: originY + frame.offsetY, alpha: alpha)
            }
        }
    }
}
