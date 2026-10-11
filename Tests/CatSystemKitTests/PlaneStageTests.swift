import Testing
@testable import CatSystemKit

@Test func planeQuakeStepsThroughItsOffsets() throws {
    let quake = try #require(PlaneStage.Quake(["4,0,10", "4,0,-10", "4,0,0"], start: 0))
    #expect(quake.offset(at: 2)! == (0, 5))
    #expect(quake.offset(at: 4)! == (0, 10))
    #expect(quake.offset(at: 6)! == (0, 0))
    #expect(quake.offset(at: 10)! == (0, -5))
    #expect(quake.offset(at: 12) == nil)
}

@Test func planeMotionsPlayOutAndPlacementFollowsTheCanvasCentre() {
    var bg = ScenePlayer.Plane(kind: "bg", file: "bg01")
    let stage = PlaneStage()
    stage.reset([0: bg])
    // `pl 0 amove1 60 @-300 @`: ScenePlayer leaves the end point; the stage slides there.
    bg.x = 340
    stage.command("pl 0 amove1 60 @-300 @", planes: [0: bg], time: 0)
    let start = stage.state(0, bg, at: 0), half = stage.state(0, bg, at: 0.5), end = stage.state(0, bg, at: 1.5)
    #expect(start.x == 640)
    #expect(half.x! < 640 && half.x! > 340)
    #expect(end.x == 340)
    #expect(stage.isMoving(at: 0.5) && !stage.isMoving(at: 1.5))
    // `pl 0 quake …` shakes; `pl quake …` (no number) shakes every plane.
    stage.command("pl quake 4,10,0 4,0,0", planes: [0: bg], time: 2)
    #expect(abs(stage.state(0, bg, at: 2 + 4.0 / 60).offsetX - 10) < 0.001)
    // A 1280×720 background without a base point stands by its canvas's centre.
    var placed = ScenePlayer.Plane(kind: "bg", file: "bg01")
    #expect(placed.placement(baseX: 0, baseY: 0, canvasWidth: 1280, canvasHeight: 720, width: 1280, height: 720).originX == 0)
    placed.y = 260
    #expect(placed.placement(baseX: 0, baseY: 0, canvasWidth: 1280, canvasHeight: 720, width: 1280, height: 720).originY == -100)
}

@Test func scenePlayerKeepsPlaneScaleAndPlaceAcrossPictures() throws {
    let cmd: UInt8 = 0x30
    func scene(_ lines: [String]) -> [UInt8] {
        // As `sceneFile` in KCScriptTests builds them.
        sceneFile(lines.map { (cmd, $0) })
    }
    let files: [String: [UInt8]] = ["a.cst": scene(["pl 0 scale 133% 133%", "pl 0 pos 640 260", "bg 0 bg11b", "pl 0 amove1 50 @+300 @"])]
    let player = ScenePlayer { files[$0] }
    try player.start("a")
    while let _ = try player.next() {}
    #expect(player.planes[0]?.file == "bg11b")
    #expect(player.planes[0]?.scaleX == 133 && player.planes[0]?.scaleY == 133)
    #expect(player.planes[0]?.x == 940 && player.planes[0]?.y == 260)
}
