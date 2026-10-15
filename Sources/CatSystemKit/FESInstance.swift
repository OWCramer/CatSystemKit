// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation

/// An object a script defined: a plane (a group with its own place and fade), a picture or
/// button (frames of an HG-3 chosen by id), a colour plane, a text (`STRING8`), a save
/// slot's panel (`SAVEPANEL`), a slider (`SLIDER`, `SCROLL2`), the backlog's text
/// (`LOGSTRING8`), or a sound (played by the host).
final class FESObject {
    let type: String
    let key: String
    let baseName: String
    let index: Int?
    /// What `_CLICK_L_` reads when this object is clicked, and its name in expressions.
    let handle: Int
    var file: String?
    var ids: [Int] = []
    var idIndex = 0
    var x = 0, y = 0
    var offsetX = 0, offsetY = 0
    var width = 0, height = 0
    /// The size of the picture frame `POS2` named (a slider's track, a text's box).
    var areaWidth = 0, areaHeight = 0
    /// `POS2`'s picture and frame (the backlog's blocks are that frame and the next ones).
    var areaFile: String?
    var areaID: Int?
    var plane: String?
    var parent: String?
    var pri = 0
    var disp = false
    var enable = true
    var color: UInt32?
    var alpha = 255
    /// Changes when a text, panel or slider changes what it draws.
    var revision = 0
    // Sounds.
    var sound: String?
    var soundTable: [Int: String] = [:]
    var group: String?
    // Text.
    var text = ""
    var style = FESTextStyle()
    var revealStart = 0
    // Sliders.
    var range = (min: 0, max: 10)
    var page = 0
    var value = 0
    // Save panels.
    var shownIDs: Set<Int> = []
    var simage: [Int: (w: Int, h: Int)] = [:]
    var slot: Int?
    // Backlog.
    var count = 4
    var top = 0
    var blockAreas: [(x: Int, y: Int, w: Int, h: Int)] = []
    var highlighted: [Int: Int] = [:]
    var lineInfo: Int?

    private var fade: (from: Int, to: Int, frames: Int, elapsed: Int)?
    private var arc: (frames: Int, elapsed: Int, from: Double, to: Double, dx: Double, dy: Double, x: Int, y: Int)?

    init(type: String, baseName: String, index: Int?, handle: Int) {
        self.type = type
        self.baseName = baseName
        self.index = index
        self.handle = handle
        key = index.map { "\(baseName)[\($0)]" } ?? baseName
    }

    var isPlane: Bool { type == "PLANE" || type == "CPLANE" }
    var isMoving: Bool { fade != nil || arc != nil }

    var currentID: Int? {
        if ids.isEmpty { return idIndex == 0 ? nil : idIndex }
        return idIndex < ids.count ? ids[idIndex] : ids.last
    }

    /// Letters of the text shown at a frame (all of it unless it is being revealed).
    func revealed(at frame: Int) -> Int {
        guard type == "STRING8", style.revealFrame > 0 else { return text.count }
        let perLetter = Double(style.revealFrame) * 0.5
        return min(text.count, Int(Double(frame - revealStart) / perLetter))
    }

    func isRevealing(at frame: Int) -> Bool { revealed(at: frame) < text.count }

    func startFade(frames: Int, from: Int, to: Int) {
        alpha = from
        fade = frames > 0 ? (from, to, frames, 0) : nil
        if frames <= 0 { alpha = to }
    }

    /// `arc frames from° to° dx dy`: moves by (dx, dy) × the sine's change over the angles.
    func startArc(frames: Int, from: Double, to: Double, dx: Double, dy: Double) {
        if let a = arc { finish(a) }
        arc = (max(1, frames), 0, from, to, dx, dy, x, y)
        if frames <= 0, let a = arc { finish(a) }
    }

    private func finish(_ a: (frames: Int, elapsed: Int, from: Double, to: Double, dx: Double, dy: Double, x: Int, y: Int)) {
        let s = sin(a.to * .pi / 180) - sin(a.from * .pi / 180)
        x = a.x + Int((a.dx * s).rounded())
        y = a.y + Int((a.dy * s).rounded())
        arc = nil
    }

    func advanceMotion() {
        if var f = fade {
            f.elapsed += 1
            alpha = f.from + (f.to - f.from) * f.elapsed / f.frames
            fade = f.elapsed >= f.frames ? nil : f
        }
        if var a = arc {
            a.elapsed += 1
            if a.elapsed >= a.frames {
                finish(a)
            } else {
                let angle = a.from + (a.to - a.from) * Double(a.elapsed) / Double(a.frames)
                let s = sin(angle * .pi / 180) - sin(a.from * .pi / 180)
                x = a.x + Int((a.dx * s).rounded())
                y = a.y + Int((a.dy * s).rounded())
                arc = a
            }
        }
    }

    func finishMotion() {
        if let f = fade { alpha = f.to }
        fade = nil
        if let a = arc { finish(a) }
    }

    /// Whether a click can land on it: a button with a `PUSH_L` block or a polled handle,
    /// or a slider.
    func isPressable(in s: FESInstance) -> Bool {
        switch type {
        case "BUTTON": return true
        case "SLIDER", "SCROLL2": return true
        default: return false
        }
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
    private var byHandle: [Int: FESObject] = [:]
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
    /// Set when a click, right click or wheel turn reaches this script, for one tick.
    var clickL = 0, clickR = 0, scrollUp = 0, scrollDown = 0
    private var inputSeen = false

    func hasBlock(_ name: String) -> Bool { program.blocks[name] != nil }

    /// The objects `#OBJECT KEYBLOCK` puts in the screen's key navigation, by name (every
    /// element of an array named there: the save screen's table leaves two slots out).
    lazy var keyNames: Set<String> = {
        var names: Set<String> = []
        for table in program.tables where table.columns == ["KEYBLOCK"] {
            for (target, _) in table.rows {
                names.insert(target.firstIndex(of: "[").map { String(target[..<$0]) } ?? target)
            }
        }
        return names
    }()

    init(name: String, program: FESProgram, player: FESPlayer, parent: FESInstance?) {
        self.name = name
        self.program = program
        self.player = player
        self.parent = parent
        var handle = 0x1000
        for d in program.definitions {
            if let count = d.count {
                for i in 0..<count { handle += 1; add(FESObject(type: d.type, baseName: d.name, index: i, handle: handle)) }
            } else {
                handle += 1
                add(FESObject(type: d.type, baseName: d.name, index: nil, handle: handle))
            }
        }
        for table in program.tables {
            for (target, values) in table.rows {
                var found = elements(target)
                // Rows for objects `#DEFINE` leaves out (`effect_check_bg[0]` in config.fes)
                // make pictures, as the game does.
                if found.isEmpty, !table.columns.contains("KEYBLOCK") {
                    var base = target, index: Int?
                    if let open = target.firstIndex(of: "["), target.hasSuffix("]") {
                        base = String(target[..<open])
                        index = Int(target[target.index(after: open)..<target.index(before: target.endIndex)])
                    }
                    handle += 1
                    let o = FESObject(type: "IMAGE", baseName: base, index: index, handle: handle)
                    add(o)
                    found = [o]
                }
                for o in found { apply(table.columns, values, to: o) }
            }
        }
    }

    private func add(_ o: FESObject) {
        objects.append(o)
        byKey[o.key] = o
        byHandle[o.handle] = o
    }

    /// `name` (every element) or `name[i]`.
    func elements(_ target: String) -> [FESObject] {
        if let o = byKey[target] { return [o] }
        if target.hasSuffix("]"), let open = target.firstIndex(of: "[") {
            let base = String(target[..<open])
            let inner = String(target[target.index(after: open)..<target.index(before: target.endIndex)])
            if let o = byKey["\(base)[\(value(inner))]"] { return [o] }
            return []
        }
        return objects.filter { $0.baseName == target }
    }

    func object(named name: String) -> FESObject? { byKey[name] }

    /// A `file:id` reference (`sys_saveload:400`, `$str901:0`): that frame of that picture.
    private func frameReference(_ value: String) -> (file: String, id: Int, frame: HGImage.Frame?)? {
        guard let colon = value.lastIndex(of: ":"), let id = Int(value[value.index(after: colon)...]) else { return nil }
        let file = text(String(value[..<colon]))
        return (file, id, player.picture(file)?.frame(id: id))
    }

    private func apply(_ columns: [String], _ values: [String], to o: FESObject) {
        for (column, value) in zip(columns, values) {
            func pair() -> (Int, Int) {
                let parts = value.split(separator: ",").map { Int($0) ?? 0 }
                return (parts.first ?? 0, parts.count > 1 ? parts[1] : 0)
            }
            switch column {
            case "FILE": o.file = text(value)
            case "POS": (o.x, o.y) = pair()
            case "POS2":
                if let ref = frameReference(value) {
                    o.x = ref.frame?.offsetX ?? 0
                    o.y = ref.frame?.offsetY ?? 0
                    o.areaWidth = ref.frame?.width ?? 0
                    o.areaHeight = ref.frame?.height ?? 0
                    o.areaFile = ref.file
                    o.areaID = ref.id
                } else {
                    (o.x, o.y) = pair()
                }
            case "SIZE": (o.width, o.height) = pair()
            case "SIZE2":
                if let ref = frameReference(value) {
                    o.areaWidth = ref.frame?.width ?? 0
                    o.areaHeight = ref.frame?.height ?? 0
                    if !o.isPlane, o.type != "STRING8" { o.width = o.areaWidth; o.height = o.areaHeight }
                } else {
                    (o.width, o.height) = pair()
                }
            case "PRI": o.pri = Int(value) ?? 0
            case "DISP": o.disp = value != "0"
            case "ENABLE": o.enable = value != "0"
            case "PL": o.plane = value
            case "PARENT": o.parent = value
            case "GROUP": o.group = value
            case "COUNT": o.count = Int(value) ?? 4
            case "COLOR": o.color = UInt32(value.replacingOccurrences(of: "0x", with: ""), radix: 16)
            case "IDN": if let n = Int(value) { o.idIndex = max(0, n) }
            default:
                if column.hasPrefix("ID."), let k = Int(column.dropFirst(3)) {
                    while o.ids.count <= k { o.ids.append(0) }
                    o.ids[k] = Int(value) ?? 0
                }
            }
        }
    }

    // MARK: Places

    /// The plane an object sits in (`PL`) or hangs from (`PARENT`).
    func plane(of o: FESObject) -> FESObject? {
        guard let name = o.plane ?? o.parent else { return nil }
        return byKey[name] ?? byKey[name + "[0]"]
    }

    /// Whether every plane above the object is shown.
    func planeShown(_ o: FESObject) -> Bool {
        var p = plane(of: o)
        var depth = 0
        while let plane = p, depth < 8 {
            if !plane.disp { return false }
            p = self.plane(of: plane)
            depth += 1
        }
        return true
    }

    /// Where the object's origin is on the screen and how faded its planes are.
    func origin(of o: FESObject) -> (x: Int, y: Int, alpha: Int) {
        var x = o.x, y = o.y, alpha = 255
        var p = plane(of: o)
        var depth = 0
        while let plane = p, depth < 8 {
            x += plane.x
            y += plane.y
            alpha = alpha * plane.alpha / 255
            p = self.plane(of: plane)
            depth += 1
        }
        return (x, y, alpha)
    }

    func hitRect(_ o: FESObject) -> (x: Int, y: Int, w: Int, h: Int)? {
        let at = origin(of: o)
        if o.type == "SLIDER" || o.type == "SCROLL2" {
            guard o.areaWidth > 0 else { return nil }
            return (at.x, at.y, o.areaWidth, o.areaHeight)
        }
        if o.width > 0, o.height > 0 { return (at.x, at.y, o.width, o.height) }
        guard let file = o.file, let image = player.picture(file),
              let frame = o.currentID.flatMap(image.frame(id:)) ?? o.ids.first.flatMap(image.frame(id:)) ?? image.frames.first else { return nil }
        return (at.x + frame.offsetX, at.y + frame.offsetY, frame.width, frame.height)
    }

    // MARK: Text, panels, sliders, the backlog

    func textFrame(_ o: FESObject) -> HGImage.Frame? {
        let shown = String(o.text.prefix(o.revealed(at: player.frameCount)))
        guard !shown.isEmpty else { return nil }
        let key = "\(o.style.hashValue) \(o.areaWidth) \(shown)"
        if let hit = player.textCache[key] { return hit }
        let single = o.areaHeight > 0 && o.areaHeight < o.style.size * 2
        let frame = FESText.render(shown, style: o.style, maxWidth: o.areaWidth, singleLine: single, fonts: player.fonts)
        if player.textCache.count > 200 { player.textCache.removeAll() }
        player.textCache[key] = frame
        return frame
    }

    private var thumbnails: [Int: HGImage.Frame?] = [:]

    func thumbnail(_ o: FESObject, width: Int, height: Int) -> HGImage.Frame? {
        guard let slot = o.slot else { return nil }
        if let hit = thumbnails[slot] { return hit }
        var frame: HGImage.Frame?
        if let thumb = player.host?.fesSaveInfo(slot: slot)?.thumbnail, thumb.width > 0, thumb.height > 0 {
            frame = Self.scaled(thumb.rgba, thumb.width, thumb.height, to: width, height)
        }
        thumbnails[slot] = frame
        return frame
    }

    /// A box-filtered copy at the panel's picture size.
    private static func scaled(_ rgba: [UInt8], _ w: Int, _ h: Int, to tw: Int, _ th: Int) -> HGImage.Frame {
        var out = [UInt8](repeating: 0, count: tw * th * 4)
        for y in 0..<th {
            let y0 = y * h / th, y1 = max(y0 + 1, (y + 1) * h / th)
            for x in 0..<tw {
                let x0 = x * w / tw, x1 = max(x0 + 1, (x + 1) * w / tw)
                var sum = [0, 0, 0, 0], n = 0
                for yy in y0..<min(h, y1) {
                    for xx in x0..<min(w, x1) {
                        let s = (yy * w + xx) * 4
                        for c in 0..<4 { sum[c] += Int(rgba[s + c]) }
                        n += 1
                    }
                }
                let d = (y * tw + x) * 4
                for c in 0..<4 { out[d + c] = UInt8(sum[c] / max(1, n)) }
            }
        }
        return HGImage.Frame(id: 0, width: tw, height: th, bitsPerPixel: 32, offsetX: 0, offsetY: 0,
                             canvasWidth: tw, canvasHeight: th, baseX: 0, baseY: 0, sections: [], rgba: out)
    }

    /// The slider's knob (or the scroll bar's thumb) on the screen.
    func knob(_ o: FESObject) -> (x: Int, y: Int, w: Int, h: Int) {
        let at = origin(of: o)
        let span = max(1, o.range.max - o.range.min - (o.type == "SCROLL2" ? o.page : 0))
        let t = Double(min(max(o.value - o.range.min, 0), span)) / Double(span)
        if o.type == "SCROLL2" {
            let total = max(1, o.range.max - o.range.min)
            let h = max(24, o.areaHeight * min(o.page, total) / max(total, 1))
            return (at.x + (o.areaWidth - 11) / 2, at.y + Int(Double(o.areaHeight - h) * t), 11, h)
        }
        let size = o.file.flatMap { player.picture($0).flatMap { $0.frame(id: 0) ?? $0.frames.first } }.map { ($0.width, $0.height) } ?? (25, 25)
        return (at.x + Int(Double(o.areaWidth - size.0) * t), at.y + (o.areaHeight - size.1) / 2, size.0, size.1)
    }

    /// Moves a slider to a point and runs its `SCRL_P` block when its value changes.
    func slide(_ o: FESObject, toX x: Int, y: Int) {
        let at = origin(of: o)
        let span = o.range.max - o.range.min - (o.type == "SCROLL2" ? o.page : 0)
        guard span > 0 else { return }
        let t: Double
        if o.type == "SCROLL2" {
            let k = knob(o)
            t = Double(y - at.y - k.h / 2) / Double(max(1, o.areaHeight - k.h))
        } else {
            let k = knob(o)
            t = Double(x - at.x - k.w / 2) / Double(max(1, o.areaWidth - k.w))
        }
        let v = o.range.min + Int((min(1, max(0, t)) * Double(span)).rounded())
        guard v != o.value else { return }
        o.value = v
        o.revision += 1
        runEvent(o, "SCRL_P")
    }

    /// The backlog's blocks as drawn: one picture per line shown.
    func logBlocks(_ o: FESObject) -> [HGImage.Frame?] {
        let log = player.host?.fesLog ?? []
        if o.blockAreas.isEmpty, let file = o.areaFile, let id = o.areaID, let image = player.picture(file) {
            o.blockAreas = (0..<o.count).compactMap { i in
                image.frame(id: id + i).map { (x: $0.offsetX, y: $0.offsetY, w: $0.width, h: $0.height) }
            }
        }
        return (0..<o.count).map { i in
            let n = o.top + i
            guard n >= 0, n < log.count else { return nil }
            var style = o.style
            if o.highlighted[i] == 1 { style.color = [255, 192, 128]; style.edge = [0, 0, 0] }
            let area = o.blockAreas.indices.contains(i) ? o.blockAreas[i].w : 802
            let key = "log \(style.hashValue) \(area) \(log[n].text)"
            if let hit = player.textCache[key] { return hit }
            let frame = FESText.render(log[n].text, style: style, maxWidth: area, fonts: player.fonts)
            player.textCache[key] = frame
            return frame
        }
    }

    // MARK: FESContext

    func global(_ index: Int) -> Int { player.globals[index] ?? 0 }
    func setGlobal(_ index: Int, _ value: Int) { player.globals[index] = value }
    func local(_ index: Int) -> Int { locals[index] ?? 0 }
    func setLocal(_ index: Int, _ value: Int) { locals[index] = value }
    func macro(_ name: String) -> String? { program.macros[name] }

    func objectHandle(_ name: String, index: Int?) -> Int? {
        let key = index.map { "\(name)[\($0)]" } ?? name
        return byKey[key]?.handle
    }

    func system(_ name: String) -> Int? {
        switch name {
        case "_EXITCODE_": exitCode
        case "_CLICK_L_": clickL
        case "_CLICK_R_": clickR
        case "_SCRL_U_", "_PAGE_U_": scrollUp
        case "_SCRL_D_", "_PAGE_D_": scrollDown
        case "_FRAME_": player.frameCount
        case "_MOUSE_X_": player.mouse.x
        case "_MOUSE_Y_": player.mouse.y
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

    /// Input reaches a script for one tick (clicks while it waits are dropped, as the game's
    /// buttons are disabled then).
    func clearInput() {
        clickL = 0
        clickR = 0
        scrollUp = 0
        scrollDown = 0
    }

    /// A button event block (`#decide.PUSH_L`), run straight away. A `next` in it changes
    /// what the script does from the next frame, dropping any wait.
    func runEvent(_ object: FESObject, _ event: String) {
        let block = "\(object.baseName).\(event)"
        guard program.blocks[block] != nil, finished == nil else { return }
        let before = label
        let saved = eventObject
        eventObject = object
        let wasSuspended = suspended
        suspended = nil
        let jumped = run([(block, 0)])
        eventObject = saved
        if jumped || label != before {
            suspended = nil
            waitFrames = 0
            waitMotion = false
        } else if suspended == nil {
            suspended = wasSuspended
        }
    }

    /// Runs from the given call stack; true if a `next` ended the run.
    @discardableResult
    private func run(_ start: [(String, Int)]) -> Bool {
        var stack = start
        var budget = 20_000
        while var (block, pc) = stack.popLast() {
            guard let lines = program.blocks[block] else { continue }
            while pc < lines.count {
                budget -= 1
                if budget == 0 {
                    player.noteOnce("\(name)#\(block): runaway loop")
                    return false
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
                case .return:
                    pc = lines.count
                case .suspend:
                    stack.append((block, pc))
                    suspended = stack
                    return false
                case .stop:
                    return true
                }
            }
        }
        return false
    }

    private enum Outcome {
        case `continue`
        case call(String)
        case `return`
        case suspend
        case stop
    }

    private func value(_ token: String) -> Int { FESExpression.evaluate(token, self) }

    /// A string argument: `$strN` anywhere in it replaced by the variable, `\_` a space,
    /// `\n` a line break.
    func text(_ token: String) -> String {
        guard token.contains("$str") || token.contains("\\") else { return token }
        var out = ""
        var chars = token[...]
        while let c = chars.first {
            if chars.hasPrefix("$str") {
                chars = chars.dropFirst(4)
                let digits = chars.prefix(while: \.isNumber)
                chars = chars.dropFirst(digits.count)
                out += Int(digits).flatMap { player.strings[$0] } ?? ""
            } else if chars.hasPrefix("\\_") {
                out += " "
                chars = chars.dropFirst(2)
            } else if chars.hasPrefix("\\n") {
                out += "\n"
                chars = chars.dropFirst(2)
            } else {
                out.append(c)
                chars = chars.dropFirst()
            }
        }
        return out
    }

    /// `[0-200]` or a single id.
    private func idRange(_ token: String) -> ClosedRange<Int> {
        if token.hasPrefix("["), token.hasSuffix("]") {
            let parts = token.dropFirst().dropLast().split(separator: "-").map { value(String($0)) }
            if parts.count == 2 { return min(parts[0], parts[1])...max(parts[0], parts[1]) }
        }
        let v = value(token)
        return v...v
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
        if head == "break" { return .return }

        // Assignments: `$n = expr`, `\n = expr`, `$(expr) = expr`, `\n++`.
        if head.hasPrefix("$") || head.hasPrefix("\\") {
            assign(line)
            return .continue
        }

        if let macro = program.macros[head] { words[0] = macro }
        let args = Array(words.dropFirst())
        func store(_ i: Int, _ v: Int) { if let n = args.indices.contains(i) ? Int(args[i]) : nil { setGlobal(n, v) } }
        switch head {
        case "next":
            if let target = args.first { label = text(target) }
            return .stop
        case "call":
            return args.first.map { .call(text($0)) } ?? .continue
        case "wait":
            if let n = args.first.flatMap({ Int($0) != nil || $0.hasPrefix("\\") || $0.hasPrefix("$") ? value($0) : nil }), n > 0 {
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
            startChild(text(target))
            return .continue
        case "endfes":
            child = nil
            return .continue
        case "execkcs":
            let target = text(args.first ?? "")
            // CONFIG is a kcScript that only opens config.fes.
            if target == "call_config" {
                startChild("config")
                return .continue
            }
            exitCode = -1
            player.requestKCS(target)
            return .continue
        case "baseimg":
            player.snapshotBase()
            return .continue
        case "rdraw":
            player.requestTransition(args.first.map(value) ?? 20)
            return .continue
        case "strvar":
            guard args.count >= 2, let n = Int(args[0]) else { return .continue }
            player.strings[n] = Self.format(text(args[1]), args.dropFirst(2).map(value))
            return .continue
        case "strcmp":
            // `strcmp 850 $str1001`: whether the string is set (the speaker's name).
            store(0, args.count > 1 && !text(args[1]).isEmpty ? 1 : 0)
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
        case "getconf":
            if args.count >= 2 { store(0, player.host?.fesConfig(args[1]) ?? 0) }
            return .continue
        case "setconf":
            if args.count >= 2 { player.host?.fesSetConfig(args[1], value: value(args[0])) }
            return .continue
        case "getsndconfex":
            if args.count >= 2 { store(0, player.host?.fesSoundConfig(Array(args.dropFirst()).map(soundArgument)) ?? 0) }
            return .continue
        case "setsndconfex":
            if args.count >= 2 { player.host?.fesSetSoundConfig(Array(args.dropFirst()).map(soundArgument), value: value(args[0])) }
            return .continue
        case "m2_getconf":
            // `m2_getconf iner_lv 84 bust`: into the local.
            if args.count >= 3, let n = Int(args[1]) { setLocal(n, player.host?.fesConfig("m2_" + args[0] + "_" + (args.count > 2 ? args[2] : "")) ?? 0) }
            return .continue
        case "m2_setconf":
            if args.count >= 3 { player.host?.fesSetConfig("m2_" + args[0] + "_" + args[2], value: value(args[1])) }
            return .continue
        case "saveexist":
            if args.count >= 2 {
                let slot = value(args[0])
                store(1, player.host?.fesSaveState(slot: slot) ?? 0)
                // The load screen's two extra pages (wheel past page 10: 50 the quick saves,
                // 60 the autosaves) load the slot `$880 + i` names.
                if slot >= 400 { setGlobal(880 + slot % 8, slot) }
            }
            return .continue
        case "newsave":
            if args.count >= 3 { store(0, player.host?.fesNewestSave(from: value(args[1]), count: value(args[2])) ?? -1) }
            return .continue
        case "datasave":
            if let slot = args.first.map(value) { player.host?.fesSave(slot: slot); dropThumbnails() }
            return .continue
        case "savedelete":
            if let slot = args.first.map(value), slot < 7000 { player.host?.fesDeleteSave(slot: slot); dropThumbnails() }
            return .continue
        case "gettime":
            let c = Calendar.current.dateComponents([.year, .month, .day, .weekday, .hour, .minute, .second], from: Date())
            for (i, v) in [c.year, c.month, c.day, c.weekday.map { $0 - 1 }, c.hour, c.minute, c.second].enumerated() { store(i, v ?? 0) }
            return .continue
        case "rettitle":
            player.returnToTitle()
            return .stop
        case "send":
            send(args.map(value))
            return .continue
        case "steam_isenable", "steam_isbroadcast", "cgreg_t", "input_text":
            if let n = args.first.flatMap({ Int($0) }) { setGlobal(n, 0) }
            return .continue
        case "xchgcursor":
            player.setCursor(down: args.first == "btndown")
            return .continue
        case "keyskip", "dbgstr", "dbgstru8", "debug", "cgreg_init", "savecopy", "endkcs", "steam_enablescreenshot",
             "steam_achievement", "wndmenu", "deletebgbutton", "automove", "react", "saveapend_str", "basebtnpri",
             "sendbtn", "force_redraw", "decode":
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

    /// `getsndconfex 850 volume_id 2 \0`: numbers in the arguments evaluated.
    private func soundArgument(_ token: String) -> String {
        token.first.map { $0.isNumber || $0 == "\\" || $0 == "$" || $0 == "(" } == true ? String(value(token)) : token
    }

    private func dropThumbnails() { thumbnails = [:] }

    /// The engine messages the log screen sends (`_SYS_LOG_GETNAMEID`, `_SYS_LOG_PLAYVOICE`).
    private func send(_ v: [Int]) {
        guard let code = v.first else { return }
        switch UInt32(truncatingIfNeeded: code) {
        case 0xFFFE_0002 where v.count >= 3:
            // The speaker picture of log line v[1] into $v[2].
            let log = player.host?.fesLog ?? []
            setGlobal(v[2], v[1] >= 0 && v[1] < log.count ? (log[v[1]].nameID ?? -1) : -1)
        case 0xFFFE_0000:
            if let line = objects.first(where: { $0.type == "LOGSTRING8" })?.lineInfo { player.host?.fesPlayLogVoice(line) }
        default:
            player.noteOnce("send \(String(format: "0x%X", code))")
        }
    }

    private func startChild(_ target: String) {
        do {
            child = try player.load(target, parent: self)
            exitCode = -1
            player.note("execfes \(target)")
        } catch {
            player.noteOnce("execfes \(target): \(error)")
        }
    }

    private func command(_ o: FESObject, _ sub: String, _ params: [String]) {
        let p = { (i: Int) -> Int in i < params.count ? self.value(params[i]) : 0 }
        switch sub {
        case "disp":
            let shown = (params.first.map(value) ?? 1) != 0
            if shown, !o.disp, o.type == "STRING8" { o.revealStart = player.frameCount }
            o.disp = shown
        case "enable": o.enable = (params.first.map(value) ?? 1) != 0
        case "setid":
            if o.type == "SLIDER" || o.type == "SCROLL2" { break }
            o.idIndex = params.first.map(value) ?? 0
        case "settbl":
            if params.count >= 2 {
                let k = p(0)
                while o.ids.count <= k { o.ids.append(0) }
                o.ids[k] = p(1)
            }
        case "fade", "fade2":
            o.startFade(frames: params.isEmpty ? 30 : p(0), from: params.count > 1 ? p(1) : 0, to: params.count > 2 ? p(2) : 255)
        case "arc":
            o.startArc(frames: p(0), from: Double(p(1)), to: Double(p(2)), dx: Double(p(3)), dy: Double(p(4)))
        case "stop":
            if o.type == "SOUND" || o.type == "SNDTABLE" {
                player.sounds.append(.init(channel: o.key, table: o.type == "SNDTABLE", file: nil, loop: false, group: o.group))
            } else {
                o.finishMotion()
            }
        case "blend":
            if o.type == "SOUND" || o.type == "SNDTABLE" { break }
            o.alpha = params.first.map(value) ?? 255
        case "pos":
            if o.type == "SLIDER" || o.type == "SCROLL2" {
                o.value = p(0)
                o.revision += 1
            } else if o.type == "LOGSTRING8" {
                o.top = max(0, min(p(0), (player.host?.fesLog.count ?? 0) - 1))
                o.revision += 1
            } else if params.count >= 2 {
                o.x = p(0); o.y = p(1)
            }
        case "pos2":
            if let ref = params.first.flatMap(frameReference) {
                o.x = ref.frame?.offsetX ?? 0
                o.y = ref.frame?.offsetY ?? 0
            }
        case "getpos":
            if o.type == "SLIDER" || o.type == "SCROLL2" {
                if let n = params.first.flatMap({ Int($0) }) { setGlobal(n, o.value) }
            } else if o.type == "LOGSTRING8" {
                if let n = params.first.flatMap({ Int($0) }) { setGlobal(n, o.top) }
            } else {
                if let n = params.first.flatMap({ Int($0) }) { setGlobal(n, o.x) }
                if params.count > 1, let n = Int(params[1]) { setGlobal(n, o.y) }
            }
        case "getpos2":
            if let n = params.first.flatMap({ Int($0) }) { setGlobal(n, o.x) }
            if params.count > 1, let n = Int(params[1]) { setGlobal(n, o.y) }
        case "page":
            o.range = (p(0), params.count > 1 ? p(1) : 10)
            o.page = params.count > 2 ? p(2) : 0
            o.revision += 1
        case "load":
            o.sound = params.first.map(text)
            player.note("\(o.key) load \(params.first.map(text) ?? "")")
        case "play":
            let table = o.type == "SNDTABLE"
            let file = table ? o.soundTable[o.idIndex] ?? o.soundTable.sorted { $0.key < $1.key }.first?.value : o.sound
            if let file { player.sounds.append(.init(channel: o.key, table: table, file: file, loop: table, group: o.group)) }
            player.note("\(o.key) play")
        case "sndtbl":
            // `bgmtbl sndtbl 00 bgm_01 $600`: entry 0 is bgm_01.
            if params.count >= 2, let n = Int(params[0]) { o.soundTable[n] = params[1] }
        // Text (`STRING8`).
        case "str":
            o.text = text(params.joined(separator: " "))
            o.revealStart = player.frameCount
            o.revision += 1
        case "clear":
            o.text = ""
            o.revision += 1
        case "draw":
            o.revealStart = player.frameCount
            o.revision += 1
        case "isdraw":
            setLocal(0, o.isRevealing(at: player.frameCount) ? 1 : 0)
        case "skip":
            o.revealStart = Int.min / 2
        case "reset":
            if o.type == "STRING8" || o.type == "LOGSTRING8" { o.style = FESTextStyle() }
        case "layout":
            layout(o, params)
        // Save panels.
        case "ptype":
            if params.first == "SIMAGE", params.count >= 5 { o.simage[p(1)] = (p(3), p(4)) }
        case "dispid":
            guard params.count >= 2 else { break }
            let on = p(0) != 0
            for id in idRange(params[1]) { if on { o.shownIDs.insert(id) } else { o.shownIDs.remove(id) } }
            o.revision += 1
        case "setsave":
            o.slot = p(0)
            o.revision += 1
        case "getsavestr":
            guard params.count >= 2, let n = Int(params[0]), let slot = o.slot else { break }
            let info = player.host?.fesSaveInfo(slot: slot)
            let key = UInt32(truncatingIfNeeded: value(params[1]))
            let date = info.map { Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: $0.date) }
            switch key {
            case 0x201: player.strings[n] = info?.title ?? ""
            case 0x200: player.strings[n] = info?.comment ?? ""
            case 0x8000_0000: player.strings[n] = date.map { String(format: "%04d/%02d/%02d", $0.year ?? 0, $0.month ?? 0, $0.day ?? 0) } ?? ""
            case 0x8000_0001: player.strings[n] = date.map { String(format: "%02d:%02d", $0.hour ?? 0, $0.minute ?? 0) } ?? ""
            default: player.strings[n] = ""
            }
        case "getsavedate":
            guard let slot = o.slot, let info = player.host?.fesSaveInfo(slot: slot) else { break }
            let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: info.date)
            for (i, v) in [c.year, c.month, c.day, c.hour, c.minute, c.second].enumerated() where i < params.count {
                if let n = Int(params[i]) { setGlobal(n, v ?? 0) }
            }
        // The backlog (`LOGSTRING8`).
        case "pathinfo":
            // `log pathinfo line a b`: where backlog line `line` is in the story, for the jump
            // back (`exit -2`); the host keeps the place by the line's number, so `$a` gets it.
            if params.count >= 2, let n = Int(params[1]) { setGlobal(n, p(0)) }
            if params.count >= 3, let n = Int(params[2]) { setGlobal(n, 0) }
        case "setlog", "remake", "userfontobj", "userfont", "attach":
            if sub == "setlog" || sub == "remake" {
                o.top = max(0, (player.host?.fesLog.count ?? 0) - o.count)
                o.revision += 1
            }
        case "max":
            if let n = params.first.flatMap({ Int($0) }) { setGlobal(n, player.host?.fesLog.count ?? 0) }
        case "next" where o.type == "LOGSTRING8":
            let total = player.host?.fesLog.count ?? 0
            o.top = max(0, min(o.top + (params.isEmpty ? 1 : p(0)), total - o.count))
            o.revision += 1
        case "rev" where o.type == "LOGSTRING8":
            o.top = max(0, o.top - 1)
            o.revision += 1
        case "blockcolor":
            o.highlighted[p(0)] = p(1)
            o.revision += 1
        case "lineinfo":
            o.lineInfo = p(0)
        case "blockinfo":
            let log = player.host?.fesLog ?? []
            let n = p(0)
            if let last = params.last.flatMap({ Int($0) }) { setGlobal(last, n >= 0 && n < log.count && log[n].hasVoice ? 1 : 0) }
        case "noact", "setid_s", "crossfade", "loop", "shuffle", "getid", "next", "rev", "setanm", "anm", "delay",
             "lock", "scale", "attr", "base", "refex", "apend", "apendmark", "linecnt", "endpos":
            break
        default:
            player.noteOnce("\(name): \(o.type) \(o.baseName) \(sub) not handled")
        }
    }

    /// `layout size 18 22 25 28 32`, `layout color …`, `layout fontind 1 face.ttf`,
    /// `layout frame N`.
    private func layout(_ o: FESObject, _ params: [String]) {
        guard let what = params.first else { return }
        let rest = params.dropFirst().map(value)
        switch what {
        case "size":
            // One size per font-size setting; the middle one is the default.
            if !rest.isEmpty { o.style.size = rest.count >= 3 ? rest[2] : rest[0] }
        case "color":
            if rest.count >= 3 { o.style.color = Array(rest[0..<3]) }
            if rest.count >= 6 { o.style.edge = Array(rest[3..<6]) }
        case "fontind":
            if params.count >= 3 { o.style.font = params[2] }
        case "frame":
            o.style.revealFrame = rest.first ?? 0
        case "shadow":
            break
        default:
            break
        }
        o.revision += 1
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
        for op in ["+=", "-=", "*=", "/=", "|=", "&="] {
            if let r = trimmed.range(of: op) {
                let t = target(String(trimmed[..<r.lowerBound]))
                let v = value(String(trimmed[r.upperBound...]))
                let old = load(t)
                switch op {
                case "+=": store(t, old + v)
                case "-=": store(t, old - v)
                case "*=": store(t, old * v)
                case "/=": store(t, v == 0 ? 0 : old / v)
                case "|=": store(t, old | v)
                default: store(t, old & v)
                }
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
