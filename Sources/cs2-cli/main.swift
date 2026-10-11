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

default:
    fail("unknown command \(command)")
}
