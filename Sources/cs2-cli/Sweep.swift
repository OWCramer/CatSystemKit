import CatSystemKit
import Foundation

/// `cs2-cli sweep <base> [--decode]`: plays every story scene headless (the 20 with
/// translations, from `01` on through their `next`/`call`s, and any the chain misses) and
/// reports what Shiori doesn't carry out or what looks wrong:
/// - picture commands (`bg`/`cg`/`fg`/`fw`/`eg`) with words or arguments the player ignores,
///   `pl` and `mpl` sub-commands only recorded, blend modes and picture modes it doesn't know;
/// - pictures that aren't in the game or don't decode (`--decode` decodes every one's pixels);
/// - at each line, planes standing mostly off the screen, and pictures shown that leave part
///   of the screen uncovered (black) when no colour plane or character explains it.
func sweep(_ g: CatSystemGame, decode: Bool) {
    let story = g.names(withExtension: "cstl").map { ($0 as NSString).deletingPathExtension }.filter { g.contains($0 + ".cst") }.sorted()
    var headers: [String: HGImage.Frame?] = [:]
    var failures: [String: String] = [:]
    func frame(_ name: String) -> HGImage.Frame? {
        let key = name.lowercased()
        if let hit = headers[key] { return hit }
        var found: HGImage.Frame?
        do {
            if let bytes = try g.file(named: name + ".hg3") {
                let image = try HGImage(bytes, pixels: decode)
                found = image.frames.first
                if decode, let f = found, f.rgba.count != f.width * f.height * 4 { failures[key] = "no pixels" }
            } else {
                failures[key] = "not in the game"
            }
        } catch {
            failures[key] = "\(error)"
        }
        headers[key] = found
        return found
    }

    var handled: [String: Int] = [:], ignored: [String: Int] = [:]
    var examples: [String: String] = [:]
    func note(_ key: String, handledIt: Bool, _ at: String) {
        if handledIt { handled[key, default: 0] += 1 } else {
            ignored[key, default: 0] += 1
            if examples[key] == nil { examples[key] = at }
        }
    }
    let pictureKinds: Set<String> = ["bg", "cg", "fg", "fw", "eg"]
    let mplHandled: Set<String> = ["pos", "amove1", "amove2", "amove3", "move", "fade", "blend", "disp", "scale", "ascale1",
                                   "ascale2", "ascale3", "m2body", "pri", "rot", "arc", "quake", "mcquake", "shake", "mcshake",
                                   "stop", "m2fspeed", "m2prmscale", "m2iner", "m2att", "touch", "m2enable_blink",
                                   "m2enable_lip", "m2fade", "m2move"]

    func classify(_ text: String, at: String) {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let verb = words.first else { return }
        let args = Array(words.dropFirst())
        if pictureKinds.contains(verb) {
            guard let first = args.first else { note("\(verb) (clear all)", handledIt: true, at); return }
            if ScenePlayer.planeNumbers(first).isEmpty {
                let known = ["shift"].contains(first) || (["tone", "mode", "blur"].contains(first) && args.count == 1)
                note("\(verb) \(first)" + (args.count > 1 ? " …" : ""), handledIt: known, at)
                return
            }
            guard args.count >= 2 else { note("\(verb) N (clear)", handledIt: true, at); return }
            let word = args[1]
            if word.hasPrefix("$") { note("\(verb) N $colour", handledIt: true, at); return }
            if ScenePlayer.pictureVerbs.contains(word) {
                if word == "mode", args.count >= 3, args[2] != "sepia" { note("\(verb) N mode \(args[2])", handledIt: false, at); return }
                note("\(verb) N \(word)", handledIt: true, at)
                return
            }
            if word.first?.isLetter == true, frame(word) == nil, !word.contains(where: { "#$".contains($0) }) {
                // A word the player takes for a picture but the game hasn't: a sub-command?
                note("\(verb) N \(word) (no such picture)", handledIt: false, at)
                return
            }
            let rest = Array(args.dropFirst(2))
            let flags = rest.filter { $0.hasPrefix("\\") }, values = rest.filter { !$0.hasPrefix("\\") }
            for flag in flags { note("\(verb) picture flag \(flag)", handledIt: ["\\lr", "\\ud", "\\ma"].contains(flag), at) }
            if values.count >= 3 { note("\(verb) picture 3rd value (frame?) \(values[2] == "@" ? "@" : "number")", handledIt: values[2] == "@" || values[2] == "0", at) }
            if values.count >= 4 { note("\(verb) picture plane argument", handledIt: true, at) }
            if values.count > 4 { note("\(verb) picture extra values", handledIt: false, at) }
            note("\(verb) N picture" + (values.isEmpty ? "" : " x y"), handledIt: true, at)
        } else if verb == "pl" {
            guard let first = args.first else { note("pl (reset all)", handledIt: true, at); return }
            if ScenePlayer.planeNumbers(first).isEmpty {
                note("pl \(first)", handledIt: ["quake", "stop"].contains(first), at)
                return
            }
            guard args.count >= 2 else { note("pl N (reset)", handledIt: true, at); return }
            let word = args[1]
            if word.hasPrefix("$") { note("pl N $colour", handledIt: true, at); return }
            if word == "bmode" { note("pl N bmode \(args.count > 2 ? args[2] : "")", handledIt: args.count > 2 && ["0", "1"].contains(args[2]), at); return }
            note("pl N \(word)", handledIt: ScenePlayer.planeVerbs.contains(word), at)
        } else if verb == "mpl" {
            guard args.count >= 2, !ScenePlayer.planeNumbers(args[0]).isEmpty else { return }
            let word = args[1]
            if word.contains(","), word.first?.isLetter == true { return }
            if word == "mode" { note("mpl N mode \(args.count > 2 ? args[2] : "")", handledIt: args.count == 2, at); return }
            note("mpl N \(word)", handledIt: mplHandled.contains(word), at)
        }
    }

    var flagged: [String] = []
    var seenStates = Set<String>()
    func checkFrame(_ player: ScenePlayer, at: String) {
        let planes = player.planes
        let key = planes.keys.sorted().map { "\($0):\(String(describing: planes[$0]!))" }.joined(separator: ";")
            + "|" + player.cast.keys.sorted().map { "\($0)\(player.cast[$0]!.visible)" }.joined()
        guard seenStates.insert(key).inserted else { return }
        var notes: [String] = []
        for (n, plane) in planes { for p in plane.pictures ?? [] where p.file != nil && frame(p.file!) == nil {
            notes.append("plane \(n): \(p.kind) \(p.slot) \(p.file!) \(failures[p.file!.lowercased()] ?? "doesn't load")")
        } }
        let items = StageLayout.items(planes: planes, cast: player.cast, state: { PlaneStage.resting($1) }, frame: frame)
        // Coverage on a 64×36 grid of 20-pixel cells (cell centres).
        var covered = [Bool](repeating: false, count: 64 * 36)
        var colour = false
        var characters = false
        for item in items {
            guard case .quad(let q) = item else { characters = true; continue }
            if case .color = q.source { colour = true }
            let visibleW = max(0, min(1280, q.x + q.width) - max(0, q.x)), visibleH = max(0, min(720, q.y + q.height) - max(0, q.y))
            let share = visibleW * visibleH / max(1, q.width * q.height)
            // Little of the picture shows, and that little is a small part of the screen
            // (a zoomed background shows little of itself but fills the screen).
            if share < 0.05, visibleW * visibleH < 0.2 * 1280 * 720, q.alpha > 0.01 {
                notes.append(String(format: "plane %d: %@ mostly off the screen (%.0f%% shown, at %.0f,%.0f %.0f×%.0f)", q.plane,
                                    { if case .picture(let n, _) = q.source { n } else { "colour" } }(), share * 100, q.x, q.y, q.width, q.height))
            }
            guard q.alpha > 0.9, !q.additive else { continue }
            for cy in 0..<36 { for cx in 0..<64 {
                let x = Double(cx) * 20 + 10, y = Double(cy) * 20 + 10
                guard x >= q.x, x < q.x + q.width, y >= q.y, y < q.y + q.height else { continue }
                if let m = q.mask, !(x >= m.x && x < m.x + m.width && y >= m.y && y < m.y + m.height) { continue }
                covered[cy * 64 + cx] = true
            } }
        }
        let quads = items.filter { if case .quad = $0 { true } else { false } }.count
        let share = Double(covered.filter { $0 }.count) / Double(covered.count)
        if quads > 0, share < 0.9, !colour {
            notes.append(String(format: "%.0f%% of the screen uncovered%@", (1 - share) * 100, characters ? " (characters shown)" : ""))
        }
        if !notes.isEmpty {
            let shown = planes.keys.sorted().map { n in
                "\(n):" + (planes[n]!.orderedPictures.map { ($0.file ?? "colour") + ($0.mask == true ? "(mask)" : "") }).joined(separator: "+")
            }.joined(separator: " ")
            flagged.append("\(at): " + notes.joined(separator: "; ") + "  [" + shown + "]")
        }
    }

    var reached = Set<String>()
    var lines = 0
    func run(from scene: String) {
        let player = ScenePlayer(game: g)
        do { try player.start(scene) } catch { flagged.append("\(scene): \(error)"); return }
        var current = scene
        do {
            while let event = try player.next() {
                let at = "\(player.position?.scene ?? current) line \(player.position?.line ?? 0)"
                switch event {
                case .scene(let name):
                    current = name
                    if reached.contains(name), story.contains(name) { return }
                    reached.insert(name)
                case .command(let text): classify(text, at: at)
                case .message(let m):
                    lines += 1
                    checkFrame(player, at: at + " (message \(m.index))")
                case .missingScene(let name): flagged.append("\(at): no scene \(name)")
                default: break
                }
            }
        } catch { flagged.append("\(current): \(error)") }
    }
    run(from: "01")
    for scene in story where !reached.contains(scene) { run(from: scene) }
    print("Story scenes: \(story.count) (\(story.filter(reached.contains).count) reached), \(lines) lines checked")
    print("\nCarried out:")
    for (k, v) in handled.sorted(by: { $0.key < $1.key }) { print(String(format: "  %5d  %@", v, k)) }
    print("\nIgnored or only recorded:")
    for (k, v) in ignored.sorted(by: { $0.key < $1.key }) { print(String(format: "  %5d  %@   (first at %@)", v, k, examples[k] ?? "")) }
    print("\nPictures that fail to load: \(failures.isEmpty ? "none" : "")")
    for (k, v) in failures.sorted(by: { $0.key < $1.key }) { print("  \(k): \(v)") }
    print("\nFrames flagged: \(flagged.count)")
    for f in flagged { print("  " + f) }
}
