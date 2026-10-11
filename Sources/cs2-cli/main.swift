import CatSystemKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// cs2-cli — CatSystem2 developer tool.
///   cs2-cli key <passphrase>                      the name key a passphrase folds to
///   cs2-cli findkey <archive.int>                 recovers the name key from the archive
///   cs2-cli archives <base folder>                every archive: entries and file types
///   cs2-cli list <archive.int>                    entries with size and magic
///   cs2-cli hex <base folder> <file> [bytes]      a file's first bytes (scenes inflated)
///   cs2-cli hg <base folder> <file.hg3>           an HG-3's frames and sections
///   cs2-cli png <base folder> <file.hg3> <out.png> [frame]
///   cs2-cli scenes <base folder>                  every scene with line and command counts
///   cs2-cli scene <base folder> <name.cst>        a scene, one line per entry
///   cs2-cli commands <base folder>                command words across every scene
///   cs2-cli fes <base folder> <name.fes>          a FES (system screen) script as text
///   cs2-cli boot <base folder> <out dir> [frames]  flow.fes headless, screens to PNG
///   cs2-cli raw <base folder> <file> <out>         a file as stored, decrypted (for a scratch folder)
///   cs2-cli kcs <base folder> <name.kcs>|all [from] [to]   kcScript disassembly
///   cs2-cli kcsrun <base folder> <name.kcs> [steps]    run a kcScript, list its native calls
///   cs2-cli play <base folder> [--lines N] [--from SCENE] [--text]   the story, headless
///   cs2-cli snapshot <base folder> <out.png> [--lines N] [--from SCENE] [--save save.json]  the screen after N lines
///   cs2-cli emote <base folder> <ca01,1,1,b,3,0,4> <out.png> [m2body] [scale]  one E-mote character
/// Options: --key <passphrase> or --namekey <0xHEX> instead of recovering the name key.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
let passphrase = option("--key")
let hexKey = option("--namekey").flatMap { UInt32($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }
let language = option("--lang")
let clickList = option("--click")
let givenKey = hexKey ?? passphrase.map(CS2Passphrase.key)
let stopNative = option("--stop").flatMap { Int($0, radix: 16) }
let savePath = option("--save")
var stringVariables: [Int: String] = [:]
while let pair = option("--strvar"), let eq = pair.firstIndex(of: "="), let n = Int(pair[..<eq]) {
    stringVariables[n] = String(pair[pair.index(after: eq)...])
}
var sharedWords: [(UInt32, UInt32)] = []
while let pair = option("--shared"), let eq = pair.firstIndex(of: "="),
      let offset = UInt32(pair[..<eq].replacingOccurrences(of: "0x", with: ""), radix: 16),
      let value = Int64(pair[pair.index(after: eq)...]) {
    sharedWords.append((offset, UInt32(truncatingIfNeeded: value)))
}
var answers: [Int: UInt32] = [:]
while let pair = option("--answer"), let eq = pair.firstIndex(of: "="), let id = Int(pair[..<eq], radix: 16),
      let value = Int64(pair[pair.index(after: eq)...]) {
    answers[id] = UInt32(truncatingIfNeeded: value)
}
let lineLimit = option("--lines").flatMap { Int($0) }
let startScene = option("--from")
let textOnly = args.contains("--text")
args.removeAll { $0 == "--text" }
guard let command = args.first else { fail("usage: cs2-cli key|findkey|archives|list|hex|hg|png|scenes|scene|commands|fes …") }
let rest = Array(args.dropFirst())

func archive(_ path: String) -> KIFArchive {
    do {
        let kif = try KIFArchive(url: URL(fileURLWithPath: path), nameKey: givenKey)
        if !kif.hasNames {
            if let key = kif.recoverNameKey() { kif.applyNameKey(key) } else { kif.recoverNames() }
        }
        return kif
    } catch { fail("\(error)") }
}

func game(_ path: String) -> CatSystemGame {
    do { return try CatSystemGame(root: URL(fileURLWithPath: path), nameKey: givenKey) } catch { fail("\(error)") }
}

func file(_ game: CatSystemGame, _ name: String) -> [UInt8] {
    do {
        guard let bytes = try game.file(named: name) else { fail("no file \(name)") }
        return bytes
    } catch { fail("\(error)") }
}

func writePNG(_ rgba: [UInt8], width: Int, height: Int, to url: URL) {
    let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                     provider: CGDataProvider(data: Data(rgba) as CFData)!, decode: nil,
                     shouldInterpolate: false, intent: .defaultIntent)!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
}

func printable(_ bytes: some Collection<UInt8>) -> String {
    String(decoding: bytes.map { $0 >= 32 && $0 < 127 ? $0 : 46 }, as: UTF8.self)
}

func scene(_ game: CatSystemGame, _ name: String) -> CatScene {
    do { return try CatScene(file(game, name)) } catch { fail("\(name): \(error)") }
}

switch command {
case "key":
    guard let text = rest.first else { fail("key <passphrase>") }
    print(String(format: "0x%08X", CS2Passphrase.key(text)))

case "findkey":
    guard let path = rest.first else { fail("findkey <archive>") }
    let kif: KIFArchive
    do { kif = try KIFArchive(url: URL(fileURLWithPath: path)) } catch { fail("\(error)") }
    let started = Date()
    guard let key = kif.recoverNameKey() else { fail("no single key fits") }
    print(String(format: "0x%08X", key), String(format: "(%.1f s)", Date().timeIntervalSince(started)))

case "archives":
    guard let path = rest.first else { fail("archives <base>") }
    let g = game(path)
    print("name key", g.nameKey.map { String(format: "0x%08X", $0) } ?? "none", "· screen \(g.screenWidth)×\(g.screenHeight)",
          "· title \(g.title ?? "?")")
    for kif in g.archives {
        var types: [String: Int] = [:]
        for e in kif.entries { types[(e.name as NSString).pathExtension.lowercased(), default: 0] += 1 }
        let summary = types.sorted { $0.value > $1.value }.map { "\($0.key.isEmpty ? "?" : $0.key) \($0.value)" }.joined(separator: ", ")
        print("\(kif.url.lastPathComponent)\t\(kif.entries.count)\t\(kif.isEncrypted ? "encrypted" : "plain")\t\(summary)")
    }

case "list":
    guard let path = rest.first else { fail("list <archive>") }
    let kif = archive(path)
    print("\(kif.entries.count) entries, \(kif.isEncrypted ? "encrypted" : "plain")\(kif.hasNames ? "" : ", names from content only")")
    for e in kif.entries {
        let head = (try? kif.head(of: e, count: 8)).map { printable($0.prefix(8)) } ?? ""
        print("\(e.index)\t\(e.name)\t\(e.size)\t\(head)")
    }

case "hex":
    guard rest.count >= 2 else { fail("hex <base> <file> [bytes]") }
    var bytes = file(game(rest[0]), rest[1])
    if CatScene.isCatScene(bytes), let body = try? CatScene.inflate(bytes) { bytes = body }
    let count = min(bytes.count, rest.count > 2 ? Int(rest[2]) ?? 512 : 512)
    for row in stride(from: 0, to: count, by: 16) {
        let line = bytes[row..<min(row + 16, count)]
        print(String(format: "%06x  ", row) + line.map { String(format: "%02x", $0) }.joined(separator: " ")
              .padding(toLength: 48, withPad: " ", startingAt: 0) + "  " + printable(line))
    }

case "hg":
    guard rest.count >= 2 else { fail("hg <base> <file.hg3>") }
    do {
        let image = try HGImage(file(game(rest[0]), rest[1]), pixels: false)
        for f in image.frames {
            print("frame \(f.id): \(f.width)×\(f.height) \(f.bitsPerPixel)bpp at \(f.offsetX),\(f.offsetY) on \(f.canvasWidth)×\(f.canvasHeight), base \(f.baseX),\(f.baseY) — \(f.sections.joined(separator: " "))")
        }
    } catch { fail("\(error)") }

case "png":
    guard rest.count >= 3 else { fail("png <base> <file.hg3> <out.png> [frame]") }
    do {
        let started = Date()
        let image = try HGImage(file(game(rest[0]), rest[1]))
        let index = rest.count > 3 ? Int(rest[3]) ?? 0 : 0
        guard index < image.frames.count else { fail("\(image.frames.count) frames") }
        let f = image.frames[index]
        print("frame \(f.id): \(f.width)×\(f.height) at \(f.offsetX),\(f.offsetY) on \(f.canvasWidth)×\(f.canvasHeight)",
              String(format: "(decoded in %.0f ms)", Date().timeIntervalSince(started) * 1000))
        let cg = CGImage(width: f.width, height: f.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: f.width * 4,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                         provider: CGDataProvider(data: Data(f.rgba) as CFData)!, decode: nil,
                         shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: rest[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    } catch { fail("\(error)") }

case "scenes":
    guard let path = rest.first else { fail("scenes <base>") }
    let g = game(path)
    var totals = (scenes: 0, lines: 0, failed: 0)
    for name in g.names(withExtension: "cst") {
        do {
            let s = try CatScene(file(g, name))
            let messages = s.lines.filter { if case .message = $0.kind { true } else { false } }.count
            let commands = s.lines.filter { if case .command = $0.kind { true } else { false } }.count
            let base = (name as NSString).deletingPathExtension
            var translated = "no translation"
            if let bytes = try g.file(named: base + ".cstl") {
                let t = try SceneTranslation(bytes)
                translated = "\(t.messages.count) translated (\(t.languages.joined(separator: "/")))"
                    + (t.messages.count == s.messages.count ? "" : " ≠ \(s.messages.count) messages")
            }
            print("\(name)\t\(s.lines.count) lines\t\(messages) text\t\(commands) commands\t\(s.messages.count) messages\t\(translated)")
            totals.scenes += 1
            totals.lines += s.lines.count
        } catch {
            print("\(name)\tFAILED \(error)")
            totals.failed += 1
        }
    }
    print("\(totals.scenes) scenes, \(totals.lines) lines, \(totals.failed) failed")

case "scene":
    guard rest.count >= 2 else { fail("scene <base> <name.cst>") }
    let g = game(rest[0])
    let s = scene(g, rest[1])
    // --lang en: each message's translation after its last line.
    let translation = language.flatMap { _ in
        try? g.file(named: (rest[1] as NSString).deletingPathExtension + ".cstl").map(SceneTranslation.init)
    }
    var messageEnds: [Int: Int] = [:]
    for (m, message) in s.messages.enumerated() { messageEnds[message.lines.upperBound - 1] = m }
    for (i, line) in s.lines.enumerated() {
        let block = s.blocks.firstIndex { $0.contains(i) }.map { "\($0)" } ?? "-"
        print("\(block)\t\(line.kind.tag)\t\(line.text)")
        if let language, let translation, let m = messageEnds[i], m < translation.messages.count,
           let t = translation.messages[m][language] {
            print("\(block)\t\(language.uppercased())\t\(t.name.isEmpty ? "" : t.name + ": ")\(t.text)")
        }
    }

case "commands":
    guard let path = rest.first else { fail("commands <base>") }
    let g = game(path)
    var counts: [String: Int] = [:]
    var example: [String: String] = [:]
    for name in g.names(withExtension: "cst") {
        guard let s = try? CatScene(file(g, name)) else { continue }
        for line in s.lines {
            guard case .command = line.kind else { continue }
            let word = line.text.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            counts[word, default: 0] += 1
            if example[word] == nil { example[word] = line.text }
        }
    }
    for (word, n) in counts.sorted(by: { $0.value > $1.value }) { print("\(n)\t\(word)\t\(example[word] ?? "")") }

case "raw":
    // A file's bytes as stored (decrypted), for study in a scratch folder.
    guard rest.count >= 3 else { fail("raw <base> <file> <out>") }
    do { try Data(file(game(rest[0]), rest[1])).write(to: URL(fileURLWithPath: rest[2])) } catch { fail("\(error)") }

case "kcs":
    // Disassembly, optionally only [from, to) (hex addresses).
    guard rest.count >= 2 else { fail("kcs <base> <name.kcs>|all [from] [to]") }
    if rest[1] == "all" {
        // Every kcScript: instruction counts, and whether the whole code decodes.
        let g = game(rest[0])
        var total = 0, failed = 0
        for name in g.names(withExtension: "kcs") {
            do {
                let script = try KCScript(file(g, name))
                let count = try script.instructions().count
                total += count
                print("\(name)\t\(script.codeSize) bytes\t\(count) instructions\t\(script.strings.count) strings")
            } catch {
                failed += 1
                print("\(name)\tFAILED \(error)")
            }
        }
        print("\(total) instructions, \(failed) failed")
        break
    }
    do {
        let script = try KCScript(file(game(rest[0]), rest[1]))
        let from = rest.count > 2 ? Int(rest[2], radix: 16) ?? 0 : 0
        let to = rest.count > 3 ? Int(rest[3], radix: 16) ?? Int.max : Int.max
        print("code \(script.codeSize) bytes, data \(script.dataSize), stack \(script.stackSize), \(script.strings.count) strings")
        for i in try script.instructions() where i.address >= from && i.address < to { print(script.describe(i)) }
    } catch { fail("\(error)") }

case "kcsrun":
    // Runs a kcScript headless with the recording host and lists the natives it called.
    // --stop <hex id>: stop at that native (sscript: 145, the scene load).
    guard rest.count >= 2 else { fail("kcsrun <base> <name.kcs> [steps] [--stop id] [--strvar n=text] [--shared off=value] [--answer id=value]") }
    do {
        let script = try KCScript(file(game(rest[0]), rest[1]))
        let host = KCSRecordingHost()
        if let stop = stopNative { host.stopAt = [stop] }
        for (n, text) in stringVariables { host.stringVariables[n] = text }
        host.answers = answers
        let machine = KCSMachine(script: script)
        machine.host = host
        for (offset, value) in sharedWords { try machine.store(KCSMachine.sharedBase + offset, value, width: 4) }
        let limit = rest.count > 2 ? Int(rest[2]) ?? 2_000_000 : 2_000_000
        var failure: Error?
        while !machine.halted, host.stopped == nil, machine.steps < limit {
            do { try machine.step() } catch { failure = error; break }
        }
        var counts: [Int: Int] = [:]
        for c in host.calls { counts[c.id, default: 0] += 1 }
        let shown = host.calls.count > 400 ? Array(host.calls.prefix(200)) + Array(host.calls.suffix(200)) : host.calls
        for c in shown {
            print(String(format: "%8d  pc %06x  native %03x", c.step, c.pc, c.id),
                  c.args.map { String(format: "%x", $0) }.joined(separator: " "), c.note ?? "")
        }
        print("\(machine.steps) steps, \(host.calls.count) native calls (\(counts.count) different)",
              machine.halted ? "halted" : host.stopped.map { String(format: "stopped at native %03x", $0.id) }
                ?? failure.map { "failed: \($0)" } ?? "step limit")
    } catch { fail("\(error)") }

case "play", "snapshot":
    // play <base>: the boot flow headless (logo, language OK, title GAME START), the kcScripts
    // up to the first scene, then the story: English lines with speakers, and the commands.
    // snapshot <base> <out.png>: the same, drawing the screen after the last line.
    // --lines N stops after N lines; --from SCENE skips the boot; --text prints lines only.
    guard rest.count >= (command == "play" ? 1 : 2) else { fail("\(command) <base>\(command == "play" ? "" : " <out.png>") [--lines N] [--from SCENE] [--text]") }
    let g = game(rest[0])
    var variables: [Int: Int] = [:]
    let first: String
    if let startScene {
        first = startScene
    } else {
        let fes = FESPlayer(game: g)
        do { try fes.start("flow") } catch { fail("\(error)") }
        var clicks = ["decide", "btn1[0]"]
        var idle = 0
        var last: [String] = []
        while fes.requestedKCS == nil, fes.frameCount < 6000 {
            fes.step()
            if fes.stack != last { last = fes.stack; idle = 0 } else { idle += 1 }
            if idle >= 20, let next = clicks.first, fes.canPush(next) {
                fes.push(next)
                clicks.removeFirst()
            }
        }
        guard fes.requestedKCS == "sscript" else { fail("the title didn't start the story (frame \(fes.frameCount))") }
        print("boot: flow.fes → title → GAME START in \(fes.frameCount) frames; $512 = \(fes.variables[512] ?? 0), $str200 = \(fes.stringVariables[200] ?? "")")
        do {
            let boot = try KCSBoot.firstScene(game: g, variables: fes.variables, strings: fes.stringVariables)
            print("kcs: main.kcs \(boot.mainSteps) instructions (starts flow), sscript.kcs \(boot.sscriptSteps) instructions, \(boot.nativeCalls) native calls → scene \(boot.scene)")
            first = boot.scene
            variables = boot.variables
        } catch { fail("\(error)") }
    }
    let player = ScenePlayer(game: g, variables: variables)
    do { try player.start(first) } catch { fail("\(error)") }
    var lines = 0, scenes = 0, commands = 0
    var lastMessage: ScenePlayer.Message?
    var lastSnapshot: ScenePlayer.Snapshot?
    let limit = lineLimit ?? Int.max
    do {
        while lines < limit, let event = try player.next() {
            switch event {
            case .scene(let name):
                scenes += 1
                if command == "play" { print("== \(name)") }
            case .command(let text):
                commands += 1
                if command == "play", !textOnly { print("   > \(text)") }
            case .message(let m):
                lines += 1
                lastMessage = m
                lastSnapshot = player.snapshot()
                if command == "play" {
                    print((m.speaker.map { "\($0): " } ?? "") + m.text + (m.voice.map { "  [\($0)]" } ?? ""))
                }
            case .missingScene(let name):
                print("(no scene \(name) in this release)")
            case .end(let why):
                print("== end: \(why)")
            }
        }
    } catch { fail("\(error)") }
    print("\(lines) lines, \(scenes) scenes, \(commands) commands" + (player.position.map { "; at \($0.scene) line \($0.line)" } ?? ""))
    if let savePath, let m = lastMessage, let snap = lastSnapshot {
        // The app's save format (CatSystemSave), for loading this line in Shiori.
        struct Save: Encodable {
            var date = Date()
            var snapshot: ScenePlayer.Snapshot
            var speaker: String?
            var text: String
            var voice: String?
            var messageIndex: Int
            var scene: String
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            try encoder.encode(Save(snapshot: snap, speaker: m.speaker, text: m.text, voice: m.voice,
                                    messageIndex: m.index, scene: m.scene)).write(to: URL(fileURLWithPath: savePath))
        } catch { fail("\(error)") }
        print("saved line \(m.index) of \(m.scene) to \(savePath)")
    }
    if command == "snapshot" {
        var cache: [String: HGImage] = [:]
        let rgba = player.render(width: g.screenWidth, height: g.screenHeight, emote: EmoteCast(game: g)) { name in
            if let hit = cache[name] { return hit }
            let image = (try? g.file(named: name + ".hg3")).flatMap { $0 }.flatMap { try? HGImage($0) }
            if image == nil { print("missing picture \(name)") }
            cache[name] = image
            return image
        }
        writePNG(rgba, width: g.screenWidth, height: g.screenHeight, to: URL(fileURLWithPath: rest[1]))
        let shown = player.planes.keys.sorted().compactMap { n -> String? in
            guard let p = player.planes[n], p.visible, p.alpha > 0 else { return nil }
            return "\(n):\(p.file ?? p.color.map { String(format: "$%08X", $0) } ?? "?")"
        }
        print("planes \(shown.joined(separator: " ")); characters \(player.characters.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " "))")
    }

case "fes":
    guard rest.count >= 2 else { fail("fes <base> <name.fes>") }
    do { print(try FESScript.text(file(game(rest[0]), rest[1]))) } catch { fail("\(error)") }

case "boot":
    // Runs flow.fes (brand logo, language picker, title) headless, clicking the buttons in
    // --click (default `decide`, the language picker's OK) once each is enabled, and
    // writes the screen to <out dir> whenever the running scripts change, then stops a
    // second after the title menu is waiting (or after [frames]).
    guard rest.count >= 2 else { fail("boot <base> <out dir> [frames]") }
    let g = game(rest[0])
    let out = URL(fileURLWithPath: rest[1])
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let limit = rest.count > 2 ? Int(rest[2]) ?? 3600 : 3600
    var clicks = (clickList ?? "decide").split(separator: ",").map(String.init)
    let player = FESPlayer(game: g)
    do { try player.start("flow") } catch { fail("\(error)") }
    var last: [String] = []
    var idle = 0
    var titleWaiting = 0
    func save(_ name: String) {
        let rgba = player.render()
        let cg = CGImage(width: player.width, height: player.height, bitsPerComponent: 8, bitsPerPixel: 32,
                         bytesPerRow: player.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                         provider: CGDataProvider(data: Data(rgba) as CFData)!, decode: nil,
                         shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }
    for _ in 0..<limit {
        player.step()
        let stack = player.stack
        if stack != last {
            print(String(format: "%5d", player.frameCount), stack.joined(separator: " › "))
            last = stack
            idle = 0
        } else {
            idle += 1
        }
        if idle == 20 { save(String(format: "%05d.png", player.frameCount)) }
        if idle >= 20, let next = clicks.first, player.canPush(next) {
            print(String(format: "%5d", player.frameCount), "click \(next)")
            player.push(next)
            clicks.removeFirst()
        }
        if stack.last == "title#WAIT" { titleWaiting += 1 } else { titleWaiting = 0 }
        if titleWaiting == 60 || player.requestedKCS != nil { break }
    }
    save("final.png")
    print("stopped at frame \(player.frameCount): \(player.stack.joined(separator: " › "))")
    for e in player.events { print("  " + e) }

case "emote":
    // emote <base> <spec> <out.png> [m2body digits] [scale]: one E-mote character on grey,
    // e.g. `emote base ca01s,1,1,1,1,0,1 out.png 1,1,1,1,1,1`.
    guard rest.count >= 3 else { fail("emote <base> <ca01,1,1,b,3,0,4> <out.png> [m2body] [scale]") }
    let g = game(rest[0])
    let cast = EmoteCast(game: g)
    guard let pose = cast.profiles.pose(rest[1]) else { fail("no profile for \(rest[1])") }
    let body = rest.count > 3 ? rest[3].split(separator: ",").map(String.init) : []
    let scale = rest.count > 4 ? Double(rest[4]) ?? 1 : 1
    let started = Date()
    guard let renderer = cast.renderer(pose.model) else { fail("no model \(pose.model)") }
    let loaded = Date()
    guard let drawn = cast.draw(rest[1], body: body, scale: scale) else { fail("draw failed") }
    var image = drawn.image
    if let set = ProcessInfo.processInfo.environment["CS2_SET"] {
        // CS2_SET="face_talk=3,head_LR=10": variables over the pose's.
        var variables = renderer.model.restingVariables()
        for (k, v) in drawn.pose.variables { variables[k] = v }
        for pair in set.split(separator: ",") {
            let kv = pair.split(separator: "=")
            if kv.count == 2, let v = Double(kv[1]) { variables[String(kv[0])] = v }
        }
        renderer.model.applySelectors(&variables)
        image = renderer.render(variables: variables, scale: drawn.pose.scaleX * scale)
    }
    print("\(pose.model): \(renderer.model.objects.count) objects, \(image.width)×\(image.height), origin \(image.originX),\(image.originY);",
          String(format: "load %.2f s, draw %.2f s", loaded.timeIntervalSince(started), Date().timeIntervalSince(loaded)))
    print("variables:", drawn.pose.variables.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
    if ProcessInfo.processInfo.environment["CS2_LIST"] != nil {
        var variables = renderer.model.restingVariables()
        for (k, v) in drawn.pose.variables { variables[k] = v }
        renderer.model.applySelectors(&variables)
        for line in renderer.listing(variables: variables) { print("  " + line) }
    }
    guard image.width > 0 else { fail("nothing drawn") }
    var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
    for i in 0..<(image.width * image.height) {
        let a = Int(image.rgba[i * 4 + 3])
        for c in 0..<3 { rgba[i * 4 + c] = UInt8(min(255, Int(image.rgba[i * 4 + c]) + 96 * (255 - a) / 255)) }
        rgba[i * 4 + 3] = 255
    }
    writePNG(rgba, width: image.width, height: image.height, to: URL(fileURLWithPath: rest[2]))

case "emotecompare":
    // emotecompare <base> <spec> [m2body] [scale] [out prefix]: the pose drawn on the CPU and
    // with Metal (base mip level, as the CPU samples), and how far apart they are.
    guard rest.count >= 2 else { fail("emotecompare <base> <ca01,1,1,b,3,0,4> [m2body] [scale] [out prefix]") }
    let g = game(rest[0])
    let cast = EmoteCast(game: g)
    guard let pose = cast.profiles.pose(rest[1], body: rest.count > 2 ? rest[2].split(separator: ",").map(String.init) : []),
          let renderer = cast.renderer(pose.model) else { fail("no model for \(rest[1])") }
    let scale = (rest.count > 3 ? Double(rest[3]) ?? 1 : 1) * pose.scaleX
    var variables = renderer.model.restingVariables()
    for (k, v) in pose.variables { variables[k] = v }
    renderer.model.applySelectors(&variables)
    var t0 = Date()
    let cpu = renderer.render(variables: variables, scale: scale)
    let cpuTime = Date().timeIntervalSince(t0)
    guard cpu.width > 0, let gpu = EmoteGPU(pixelFormat: .rgba8Unorm, mipmaps: false) else { fail("no CPU drawing or no Metal device") }
    t0 = Date()
    var list = renderer.drawList(variables: variables, transform: (scale, 0, 0, scale, Double(cpu.originX), Double(cpu.originY)))
    let evalTime = Date().timeIntervalSince(t0)
    for _ in 0..<20 { list = renderer.drawList(variables: variables, transform: (scale, 0, 0, scale, Double(cpu.originX), Double(cpu.originY))) }
    let evalAverage = Date().timeIntervalSince(t0) / 21
    _ = gpu.textures(for: renderer.model)
    t0 = Date()
    guard let metal = gpu.image(list, model: renderer.model, width: cpu.width, height: cpu.height) else { fail("Metal drawing failed") }
    let gpuTime = Date().timeIntervalSince(t0)
    var maxDiff = 0, total = 0, over8 = 0, over32 = 0, covered = 0
    for i in 0..<(cpu.width * cpu.height) {
        var d = 0
        for c in 0..<4 { d = max(d, abs(Int(cpu.rgba[i * 4 + c]) - Int(metal[i * 4 + c]))) }
        if cpu.rgba[i * 4 + 3] > 0 || metal[i * 4 + 3] > 0 { covered += 1 }
        maxDiff = max(maxDiff, d); total += d
        if d > 8 { over8 += 1 }
        if d > 32 { over32 += 1 }
    }
    print("\(pose.model) \(cpu.width)×\(cpu.height): \(list.items.count) images, \(list.nodes.count) nodes, \(list.stencils.count) stencils, \(list.gridCount()) grid points")
    print(String(format: "CPU draw %.1f ms; evaluation %.2f ms (first %.2f); Metal draw %.1f ms (one-off, with readback)", cpuTime * 1000, evalAverage * 1000, evalTime * 1000, gpuTime * 1000))
    print(String(format: "difference: max %d, mean %.3f over covered pixels; %.3f%% of covered pixels differ by more than 8, %.3f%% by more than 32",
                 maxDiff, Double(total) / Double(max(1, covered)), 100 * Double(over8) / Double(max(1, covered)), 100 * Double(over32) / Double(max(1, covered))))
    if rest.count > 4 {
        func flatten(_ rgba: [UInt8]) -> [UInt8] {
            var out = rgba
            for i in 0..<(cpu.width * cpu.height) {
                let a = Int(rgba[i * 4 + 3])
                for c in 0..<3 { out[i * 4 + c] = UInt8(min(255, Int(rgba[i * 4 + c]) + 96 * (255 - a) / 255)) }
                out[i * 4 + 3] = 255
            }
            return out
        }
        var diff = [UInt8](repeating: 255, count: cpu.rgba.count)
        for i in 0..<(cpu.width * cpu.height) {
            var d = 0
            for c in 0..<4 { d = max(d, abs(Int(cpu.rgba[i * 4 + c]) - Int(metal[i * 4 + c]))) }
            let v = UInt8(min(255, d * 8))
            diff[i * 4] = v; diff[i * 4 + 1] = 0; diff[i * 4 + 2] = 0
        }
        writePNG(flatten(cpu.rgba), width: cpu.width, height: cpu.height, to: URL(fileURLWithPath: rest[4] + "-cpu.png"))
        writePNG(flatten(metal), width: cpu.width, height: cpu.height, to: URL(fileURLWithPath: rest[4] + "-metal.png"))
        writePNG(diff, width: cpu.width, height: cpu.height, to: URL(fileURLWithPath: rest[4] + "-diff.png"))
    }

case "emoteinfo":
    // emoteinfo <base> <model>: a model's variables, the parameters that read them, and its
    // timelines (idle loops) with their tracks.
    guard rest.count >= 2 else { fail("emoteinfo <base> <ca01_l_body_1>") }
    let g = game(rest[0])
    guard let renderer = EmoteCast(game: g).renderer(rest[1]) else { fail("no model \(rest[1])") }
    let m = renderer.model
    if let label = ProcessInfo.processInfo.environment["CS2_TIMELINE"],
       let psb = try? PSBFile(psz: file(g, rest[1] + ".psz")) {
        // The timeline as stored, for working out its frame types.
        for t in psb.root["metadata"]?["timelineControl"]?.list ?? [] where t["label"]?.string == label {
            print(t)
        }
    }
    print("base \(m.baseObject)/\(m.baseMotion); \(m.objects.count) objects, \(m.objects.values.reduce(0) { $0 + $1.count }) motions")
    var ranges: [String: (Double, Double, Bool)] = [:]
    for (_, motions) in m.objects {
        for (_, motion) in motions {
            for p in motion.parameters {
                let r = ranges[p.id] ?? (p.rangeBegin, p.rangeEnd, p.discrete)
                ranges[p.id] = (min(r.0, p.rangeBegin, p.rangeEnd), max(r.1, p.rangeBegin, p.rangeEnd), r.2 || p.discrete)
            }
        }
    }
    let resting = m.restingVariables()
    for name in m.variableNames {
        let r = ranges[name].map { String(format: " range %g…%g%@", $0.0, $0.1, $0.2 ? " discrete" : "") } ?? ""
        print("  \(name) = \(resting[name] ?? 0)\(r)")
    }
    var blends: [Int: Int] = [:], stencilDepth = 0, divisions: [Int: Int] = [:]
    func walk(_ layer: EmoteModel.Layer, stencils: Int) {
        for f in layer.frames { blends[f.content.blend, default: 0] += 1 }
        divisions[layer.meshDivision, default: 0] += 1
        let s = stencils + (layer.type == 12 && !layer.maskLabels.isEmpty ? 1 : 0)
        stencilDepth = max(stencilDepth, s)
        for c in layer.children { walk(c, stencils: s) }
    }
    for (_, motions) in m.objects { for (_, motion) in motions { for l in motion.layers { walk(l, stencils: 0) } } }
    print("blend modes \(blends.sorted { $0.key < $1.key }); nested stencils up to \(stencilDepth) (within a motion); mesh divisions \(divisions.sorted { $0.key < $1.key })")
    for s in m.selectors { print("selector \(s.label): \(s.options.map(\.label).joined(separator: ", "))") }
    for (label, t) in m.timelines.sorted(by: { $0.key < $1.key }) {
        print("timeline \(label) loop \(t.loopBegin)…\(t.loopEnd)\(t.difference ? " (difference)" : "")")
        for (name, keys) in t.tracks.sorted(by: { $0.key < $1.key }) {
            print("    \(name): " + keys.prefix(12).map { "\(Int($0.time))=\($0.value.map { String(format: "%g", $0) } ?? "-")\($0.weight != 1 ? String(format: "^%g", $0.weight) : "")" }.joined(separator: " ") + (keys.count > 12 ? " … (\(keys.count))" : ""))
        }
    }

default:
    fail("unknown command \(command)")
}
