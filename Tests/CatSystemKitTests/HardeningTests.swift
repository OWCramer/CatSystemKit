// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import CatSystemKit

// Malformed game files must fail cleanly: no out-of-bounds reads, traps or runaway allocations.

@Test func iconsOutsideTheirTextureDrawNothing() {
    let texture = EmoteModel.Texture(width: 4, height: 4, pixels: [UInt8](repeating: 255, count: 4 * 4 * 4))
    // One quad covering a 4×4 output.
    let points: [Float] = [0, 0, 4, 0, 0, 4, 4, 4]
    for icon in [EmoteModel.Icon(left: -4, top: 0, width: 4, height: 4, originX: 0, originY: 0),
                 EmoteModel.Icon(left: 0, top: -1, width: 4, height: 4, originX: 0, originY: 0),
                 EmoteModel.Icon(left: 2, top: 0, width: 4, height: 4, originX: 0, originY: 0),
                 EmoteModel.Icon(left: 0, top: 0, width: Int.max, height: 4, originX: 0, originY: 0)] {
        var drawn = 0
        EmoteRenderer.rasterize(texture: texture, icon: icon, points: points, n: 1, width: 4, height: 4,
                                x0: 0, y0: 0, opacity: 1, masks: []) { _, _, _, _, _ in drawn += 1 }
        #expect(drawn == 0)
        #expect(!icon.isPlausible || icon.left + icon.width > texture.width)
    }
    // Pixels shorter than the texture says: nothing is read.
    let short = EmoteModel.Texture(width: 4, height: 4, pixels: [UInt8](repeating: 255, count: 8))
    var drawn = 0
    EmoteRenderer.rasterize(texture: short, icon: .init(left: 0, top: 0, width: 4, height: 4, originX: 0, originY: 0),
                            points: points, n: 1, width: 4, height: 4, x0: 0, y0: 0, opacity: 1, masks: []) { _, _, _, _, _ in drawn += 1 }
    #expect(drawn == 0)
    // A good icon still draws.
    EmoteRenderer.rasterize(texture: texture, icon: .init(left: 0, top: 0, width: 4, height: 4, originX: 0, originY: 0),
                            points: points, n: 1, width: 4, height: 4, x0: 0, y0: 0, opacity: 1, masks: []) { _, _, _, _, _ in drawn += 1 }
    #expect(drawn == 16)
}

@Test func zlibRefusesSizesTheStreamCannotHold() {
    let stream: ArraySlice<UInt8> = [0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]
    #expect(throws: Zlib.Failure.self) { try Zlib.inflate(stream, size: 1 << 30) }
    #expect(throws: Zlib.Failure.self) { try Zlib.inflate(stream, size: 1 << 20) }
    #expect(throws: Zlib.Failure.self) { try Zlib.inflate(stream, size: -1) }
}

@Test func psbArrayWithAnEightByteNegativeCountThrows() {
    // Version 3, every header offset at 0x30, where an array claims 2^64 - 1 entries.
    var bytes = [UInt8](repeating: 0, count: 0x40)
    bytes.replaceSubrange(0..<8, with: [0x50, 0x53, 0x42, 0x00, 3, 0, 0, 0])
    for field in stride(from: 8, to: 0x2C, by: 4) { bytes[field] = 0x30 }
    bytes[0x30] = 0x14
    for i in 0x31...0x38 { bytes[i] = 0xFF }
    bytes[0x39] = 0x0D
    #expect(throws: PSBFile.Failure.self) { try PSBFile(bytes) }
}

@Test func psbValuesNestOnlySoDeep() {
    // The root is a list whose one entry is another list right after it, 1000 deep.
    var bytes = [UInt8](repeating: 0, count: 0x30)
    bytes.replaceSubrange(0..<8, with: [0x50, 0x53, 0x42, 0x00, 3, 0, 0, 0])
    let empty: [UInt8] = [0x0D, 0x00, 0x0D] // an array of no entries
    for _ in 0..<3 { bytes += empty } // name arrays
    let strings = bytes.count; bytes += empty
    let chunkOffsets = bytes.count; bytes += empty
    let chunkLengths = bytes.count; bytes += empty
    let root = bytes.count
    for _ in 0..<1000 { bytes += [0x20, 0x0D, 0x01, 0x0D, 0x00] } // list of one, at offset 0
    bytes.append(0x01)
    func put(_ at: Int, _ v: Int) { for i in 0..<4 { bytes[at + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) } }
    put(8, 0x2C); put(12, 0x30); put(16, strings); put(20, 0x2C); put(24, chunkOffsets); put(28, chunkLengths)
    put(32, 0x2C); put(36, root)
    #expect(throws: PSBFile.Failure.self) { try PSBFile(bytes) }
}

private final class Macros: FESContext {
    let macros: [String: String]
    init(_ macros: [String: String]) { self.macros = macros }
    func global(_ index: Int) -> Int { 0 }
    func setGlobal(_ index: Int, _ value: Int) {}
    func local(_ index: Int) -> Int { 0 }
    func setLocal(_ index: Int, _ value: Int) {}
    func system(_ name: String) -> Int? { name == "MIN" ? Int.min : nil }
    func macro(_ name: String) -> String? { macros[name] }
}

@Test func fesExpressionsSurviveHostileInput() {
    let context = Macros(["SELF": "SELF + 1", "TWICE": "TWICE + TWICE", "ONE": "1"])
    #expect(FESExpression.evaluate("MIN / -1", context) == Int.min)
    #expect(FESExpression.evaluate("MIN % -1", context) == 0)
    _ = FESExpression.evaluate("SELF", context)
    _ = FESExpression.evaluate("TWICE", context)
    _ = FESExpression.evaluate(String(repeating: "(", count: 100_000), context)
    _ = FESExpression.evaluate(String(repeating: "-", count: 100_000) + "1", context)
    #expect(FESExpression.evaluate("ONE + 2 * (3 - 1)", context) == 5)
}

@Test func saturatingConversionNeverTraps() {
    #expect(Int(saturating: Double.nan) == 0)
    #expect(Int(saturating: Double.infinity) == 1 << 52)
    #expect(Int(saturating: -1e300) == -(1 << 52))
    #expect(Int(saturating: Float(-2.75)) == -2)
}
