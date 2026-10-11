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
    // A 1280×720 background stands at the top-left corner; `pl 0 pos 640 260` raises it 100.
    var placed = ScenePlayer.Plane(kind: "bg")
    placed.pictures = [ScenePlayer.Picture(kind: "bg", slot: 0, file: "bg01")]
    let frames = ["bg01": frame(1280, 720)]
    func quads(_ plane: ScenePlayer.Plane) -> [StageLayout.Quad] {
        StageLayout.quads(0, plane, PlaneStage.resting(plane), width: 1280, height: 720) { frames[$0] }
    }
    #expect(quads(placed).first?.x == 0 && quads(placed).first?.y == 0)
    placed.y = 260
    #expect(quads(placed).first?.y == -100)
}

/// A frame of the given size, its pixels left out.
func frame(_ width: Int, _ height: Int, offset: (Int, Int) = (0, 0), canvas: (Int, Int)? = nil, base: (Int, Int) = (0, 0)) -> HGImage.Frame {
    HGImage.Frame(id: 0, width: width, height: height, bitsPerPixel: 32, offsetX: offset.0, offsetY: offset.1,
                  canvasWidth: canvas?.0 ?? width, canvasHeight: canvas?.1 ?? height, baseX: base.0, baseY: base.1,
                  sections: [], rgba: [])
}

@Test func picturesStandByTheirBasePointsOnTheirPlanes() throws {
    let cmd: UInt8 = 0x30
    // Scene 03's daydream: `eg` places count from the screen's centre, `bg`/`fg` places from
    // its corner; `fg 2 … @ 1` is shown on plane 1; `\ma` masks the plane; `pl` keeps pictures.
    let files: [String: [UInt8]] = ["a.cst": sceneFile([
        "bg 0 bg30b_19", "pl 0 scale 150% 150%", "pl", "mpl", "eg 3 gg_cute01 -640 -360", "eg 5 gg_soft01 -640 -360",
        "pl 5 pri 13000", "mpl 4 ca01s,1,3,d,3,0,1,0:-1", "mpl 4 rot 0 0 3",
        "bg 1 CG3_16a 260 360 @ 1", "bg 1 pos 630 -256", "eg 1 gg_cut04b -640 -360 @ 1 \\ma",
        "fg 1 gg_cutline03b -210 0 @ 1", "fg 2 gg_cutline03b 210 0 @ 1", "pl 1 pos 950",
    ].map { (cmd, $0) })]
    let player = ScenePlayer { files[$0] }
    try player.start("a")
    while let _ = try player.next() {}
    #expect(player.planes[0]?.picture("bg")?.file == "bg30b_19" && player.planes[0]?.scaleX == nil)
    #expect(player.planes[3]?.picture("eg")?.x == 0 && player.planes[3]?.picture("eg")?.y == 0)
    #expect(player.planes[5]?.priority == 13000)
    #expect(player.cast[4]?.rotation == 3)
    let one = try #require(player.planes[1])
    #expect(one.pictures?.count == 4 && player.planes[2] == nil)
    #expect(one.picture("bg")?.x == 630 && one.picture("bg")?.y == -256)
    #expect(one.picture("eg")?.mask == true && one.picture("fg", slot: 2)?.x == 210)

    let frames = [
        "gg_cute01": frame(1536, 830, base: (124, 55)),
        "gg_soft01": frame(1536, 830, base: (124, 55)),
        "bg30b_19": frame(1280, 720),
        "CG3_16a": frame(1580, 1020, base: (790, 510)),
        "gg_cut04b": frame(427, 830, offset: (555, 0), canvas: (1536, 830), base: (128, 55)),
        "gg_cutline03b": frame(16, 830, offset: (760, 0), canvas: (1536, 830), base: (128, 55)),
    ]
    let items = StageLayout.items(planes: player.planes, cast: player.cast, state: { PlaneStage.resting($1) }, frame: { frames[$0] })
    func quad(_ name: String) -> StageLayout.Quad? {
        for case .quad(let q) in items { if case .picture(let n, _) = q.source, n == name { return q } }
        return nil
    }
    // The effect pictures' base point (the screen's corner in their canvas) at the corner.
    #expect(quad("gg_cute01")?.x == -124 && quad("gg_cute01")?.y == -55)
    // Planes 0, 1 and 3 under the character (priorities 3000–3300 against 5400), 5 over it.
    let order = items.map { item -> String in
        switch item {
        case .character(let bank): "mpl\(bank)"
        case .quad(let q): if case .picture(let n, _) = q.source { n } else { "colour" }
        }
    }
    #expect(order == ["bg30b_19", "CG3_16a", "gg_cutline03b", "gg_cutline03b", "gg_cute01", "mpl4", "gg_soft01"])
    // Plane 1 moved right by 310: the CG's centre at 630 + 310, the lines at the mask's edges.
    let cg = try #require(quad("CG3_16a"))
    #expect(cg.x == 940 - 790 && cg.mask?.x == 310 + 555 - 128)
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
    #expect(player.planes[0]?.picture("bg")?.file == "bg11b")
    #expect(player.planes[0]?.scaleX == 133 && player.planes[0]?.scaleY == 133)
    #expect(player.planes[0]?.x == 940 && player.planes[0]?.y == 260)
}
