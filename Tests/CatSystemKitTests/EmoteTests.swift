// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import CatSystemKit

@Test func psbSeedComesBackFromTheFirstKeystreamWord() {
    for seed: UInt32 in [1, 742_877_301, 0xDEAD_BEEF, 0xFFFF_FFFF] {
        var stream = EmoteKeystream(seed: seed)
        let word = (0..<4).reduce(UInt32(0)) { $0 | UInt32(stream.next()) << (8 * $1) }
        #expect(PSBFile.recoverSeed(firstWord: word) == seed)
    }
}

@Test func identityPatchLeavesPointsAlone() {
    for (u, v) in [(0.0, 0.0), (0.25, 0.75), (1.0, 0.5), (1.3, -0.2)] {
        let p = EmoteRenderer.patch(EmoteRenderer.identityPatch, u, v)
        #expect(abs(p.0 - u) < 1e-9 && abs(p.1 - v) < 1e-9)
    }
}

@Test func profilesTurnSceneDigitsIntoVariables() {
    let texts: [String: String] = [
        "m2view.cnf": "#profile\nca01\t\tca01.pfl\n",
        "ca01.pfl": "#charaname\n1\tbody\tca01_l_body_1\n#motname\n1\t0\twait\t\tca_m.dif\tbody.dif\n",
        "ca_m.dif": "#include\nca01.inc\n#scale\n0.6 0.6 // X Y\n#position\n-640 -204\n#scaleoffset\n0 -152\n",
        "ca01.inc": "#defval\nfade_z 1.0\n/*\n comment\n*/\n#pattern\n%1 0 none\nface_cheek 99\n%1 1 1\nface_cheek 0\n%2 b b\nface_mouth 10\nface_talk 1\n",
        "body.dif": "#pattern\n%1 1 std default\nhead_LR 0\n%1 2 left\nhead_LR -30\n",
    ]
    let profiles = EmoteProfiles(files: { texts[$0].map { Array($0.utf8) } })
    let pose = profiles.pose("ca01,1,1,b", body: ["2"])
    #expect(pose?.model == "ca01_l_body_1")
    #expect(pose?.variables["face_cheek"] == 0)
    #expect(pose?.variables["face_mouth"] == 10)
    #expect(pose?.variables["face_talk"] == 0)
    #expect(pose?.variables["fade_z"] == 1)
    #expect(pose?.variables["head_LR"] == -30)
    #expect(pose?.scaleX == 0.6 && pose?.positionY == -204 && pose?.scaleOffsetY == -152)
}

@Test func mplCommandsPlaceAndPoseCharacters() throws {
    let scene = """
    mpl 2 blend 0
    mpl 2 pos 1080 @
    mpl 2 ca01,1,1,b,3,0,4
    mpl 2 m2body 1,2,1,1,1,1
    mpl 2 fade 20 0 255
    mpl 2 m2body @,@,@,@,@,2
    mpl [2,3] amove1 70 @-300 365
    mpl 2 scale 130% 130%
    """
    let player = ScenePlayer(files: { _ in nil })
    for line in scene.split(separator: "\n") { try player.execute(String(line)) }
    let c = try #require(player.cast[2])
    #expect(c.model == "ca01,1,1,b,3,0,4")
    #expect(c.body == ["1", "2", "1", "1", "1", "2"])
    #expect(c.x == 780 && c.y == 365)
    #expect(c.alpha == 255 && c.scaleX == 130)
    #expect(player.cast[3]?.model == nil)
    try player.execute("mpl")
    #expect(player.cast.isEmpty)
}

@Test func profilesReadBlinksLipSyncChainsAndIdles() {
    let texts: [String: String] = [
        "m2view.cnf": "#profile\nca01\t\tca01.pfl\n",
        "ca01.pfl": "#charaname\n1\tbody\tca01_l_body_1\n#motname\n1\t0\t差分用_waiting_loop\tca_m.dif\tbody.dif\n1\t1\tloop2\tca_m.dif\tbody.dif\n",
        "ca_m.dif": "#include\nca01.inc\n",
        "ca01.inc": """
        #pattern
        %1 1 1
        face_mouth 0
        %1 2 2
        face_mouth 10
        %2 1 1
        face_eye_open 0
        %2 2 2
        face_eye_open 10
        #chain
        1\tfix\t1
        2\t$eye
        $eye
        default\tfix
        frame\t1
        1\t2\tlinear\t10
        #blink
        2 1 0 10 10 120 480
        #lip_table
        1 1 linear 50 700 0 0 1 2 3 4 5 6
        #lip_variable
        1 1 face_talk
        """,
        "body.dif": "#pattern\n%1 1 std default\nhead_LR 0\n%1 2 left\nhead_LR -30\n#chain\n1\tsin_fs\t30\n",
    ]
    let profiles = EmoteProfiles(files: { texts[$0].map { Array($0.utf8) } })
    let a = profiles.pose("ca01,1,1,1:1", body: ["1"])!
    let b = profiles.pose("ca01,1,2,2", body: ["2"])!
    #expect(a.idle == "loop2" && b.idle == "差分用_waiting_loop")
    #expect(a.blink?.frames == 10 && a.blink?.maxWait == 480 && b.blink == nil)
    #expect(a.lip?.levels.count == 8 && a.lip?.variable == "face_talk" && b.lip == nil)
    let t = b.transitions(from: a)
    #expect(t["face_mouth"]?.curve == "fix")
    #expect(t["face_eye_open"]?.curve == "linear" && t["face_eye_open"]?.frames == 10)
    #expect(t["head_LR"]?.curve == "sin_fs" && t["head_LR"]?.frames == 30)
    // Back from 2 to 1 isn't in the table: the default, at once.
    #expect(a.transitions(from: b)["face_eye_open"]?.curve == "fix")
}

@Test func tweensSlideFromWhereTheyAre() {
    var x = EmoteStage.Tween(1080)
    x.move(to: 780, frames: 70, curve: .easeOut, at: 0)
    #expect(x.value(at: 0) == 1080 && x.value(at: 70) == 780)
    #expect(x.value(at: 35) < 930) // easing out: past halfway at half time
    x.move(to: 900, frames: 10, curve: .linear, at: 35)
    #expect(abs(x.value(at: 35) - x.from) < 1e-9 && x.value(at: 45) == 900)
}

@Test func levelFilesAreFloatsPerFrame() {
    let bytes = [Float(0.5), 4.25].flatMap { v in withUnsafeBytes(of: v.bitPattern.littleEndian) { Array($0) } }
    #expect(EmoteStage.levels(bytes) == [0.5, 4.25])
}
