import Testing
@testable import CatSystemKit

@Test func scenePlayerShowsContinuingLinesAtOnce() throws {
    let cmd: UInt8 = 0x30, text: UInt8 = 0x20, input: UInt8 = 0x02
    // `「…」\@`, commands while it is read, the empty text and the click wait.
    let files: [String: [UInt8]] = [
        "a.cst": sceneFile([(cmd, "pcm V1"), (text, "one\\@"), (cmd, "wait 30"), (text, "\\n"), (input, ""),
                            (text, "two"), (input, "")]),
    ]
    let player = ScenePlayer { files[$0] }
    try player.start("a")
    var log: [String] = []
    while let event = try player.next() {
        switch event {
        case .message(let m):
            log.append("message \(m.text) \(m.index) \(m.continues)")
            if m.continues { #expect(player.snapshot().beforeInput == true) }
        case .command(let c): log.append(c)
        case .input: log.append("input")
        default: break
        }
    }
    #expect(log == ["pcm V1", "message one 0 true", "wait 30", "input", "message two 1 false"])
}

@Test func particlesFollowTheScenesArguments() {
    let stage = ParticleStage()
    stage.command("particle3 0 em_note tex_em04 3 37000 2 1 430 179 1 100 30 60 60", time: 0) { _ in (640, 360) }
    let e = stage.emitters["particle3:0"]
    #expect(e?.kind == .note && e?.x == 430 && e?.y == 179 && e?.side == 1 && e?.size == 1 && e?.count == 3 && e?.bank == 2)
    stage.command("particle3 1 em_sweat tex_em05 30 37000 3 500 200 80 20 30", time: 0) { _ in nil }
    #expect(stage.emitters["particle3:1"]?.size == 0.8)
    // A mark follows its character.
    let still = stage.sprites(at: 0.5) { _ in (640, 360) }.filter { $0.texture == "tex_em04" }
    let moved = stage.sprites(at: 0.5) { _ in (700, 360) }.filter { $0.texture == "tex_em04" }
    #expect(!still.isEmpty && moved.first.map { $0.x - still[0].x } == 60)
    stage.command("particle3 0 fade 15 255 0", time: 1) { _ in nil }
    #expect(stage.sprites(at: 1.3) { _ in nil }.allSatisfy { $0.texture != "tex_em04" })
    stage.command("particle3 stop", time: 2) { _ in nil }
    #expect(stage.isEmpty)
}
