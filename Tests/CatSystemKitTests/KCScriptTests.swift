// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Compression
import Foundation
import Testing
@testable import CatSystemKit

// MARK: Building test files (no game data)

private func le32(_ v: UInt32) -> [UInt8] { [0, 8, 16, 24].map { UInt8(truncatingIfNeeded: v >> $0) } }

private func zlib(_ bytes: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: bytes.count + 1024)
    let n = compression_encode_buffer(&out, out.count, bytes, bytes.count, nil, COMPRESSION_ZLIB)
    return [0x78, 0x9C] + out.prefix(n) // Zlib.inflate skips the two-byte header
}

/// A kcScript file: header, then code and string table under zlib.
private func kcsFile(code: [UInt8], strings: [(address: Int, text: String)], dataSize: Int) -> [UInt8] {
    var pairs: [UInt8] = [], texts: [UInt8] = []
    for s in strings {
        pairs += le32(UInt32(strings.count * 8 + texts.count)) + le32(UInt32(s.address))
        texts += Array(s.text.utf8) + [0]
    }
    let table = pairs + texts
    let packed = zlib(code + table)
    let header: [UInt32] = [0x0053_434B, 2, 0, 0x34, UInt32(code.count), UInt32(code.count + 0x34), UInt32(strings.count),
                            UInt32(table.count), UInt32(dataSize), 0x1000, UInt32(0x34 + packed.count), 0, 0]
    return header.flatMap(le32) + packed
}

/// A tiny assembler with labels for jump and call targets.
private struct Assembler {
    enum Value { case n(UInt8, UInt32), to(String) }
    var code: [UInt8] = []
    var labels: [String: Int] = [:]
    var fixups: [(at: Int, label: String)] = []

    mutating func label(_ name: String) { labels[name] = code.count }

    mutating func emit(_ op: KCScript.Opcode, _ values: Value...) {
        precondition(values.count == op.operandCount)
        code.append(op.rawValue)
        for v in values {
            switch v {
            case .n(let mode, let value): code += [mode] + le32(value)
            case .to(let label):
                code.append(0x03)
                fixups.append((code.count, label))
                code += le32(0)
            }
        }
    }

    func assembled() -> [UInt8] {
        var out = code
        for f in fixups { out.replaceSubrange(f.at..<f.at + 4, with: le32(UInt32(labels[f.label]!))) }
        return out
    }
}

private func imm(_ v: Int32) -> Assembler.Value { .n(0x03, UInt32(bitPattern: v)) }
private func local(_ offset: UInt32) -> Assembler.Value { .n(0x73, offset) } // int at a popped address
private let popped = Assembler.Value.n(0x63, 0)

private final class Recorder: KCSHost {
    var calls: [(id: Int, args: [UInt32])] = []
    func native(_ id: Int, _ args: [UInt32], _ machine: KCSMachine) -> UInt32 {
        calls.append((id, args))
        return 0
    }
}

private func run(_ asm: Assembler, strings: [(address: Int, text: String)] = []) throws -> (KCSMachine, Recorder) {
    let script = try KCScript(kcsFile(code: asm.assembled(), strings: strings, dataSize: 0x100))
    let machine = KCSMachine(script: script, sharedSize: 0x100, stackSize: 0x1000)
    let host = Recorder()
    machine.host = host
    try machine.run(limit: 10_000)
    return (machine, host)
}

// MARK: kcScript

@Test func kcsHeaderStringsAndDisassembly() throws {
    var a = Assembler()
    a.emit(.push, imm(0x20))
    a.emit(.halt)
    let script = try KCScript(kcsFile(code: a.assembled(), strings: [(0x20, "start.txt"), (0x2A, "r")], dataSize: 0x40))
    #expect(script.codeSize == 7)
    #expect(script.strings == [0x20: "start.txt", 0x2A: "r"])
    #expect(Array(script.data[0x20..<0x29]) == Array("start.txt".utf8))
    let code = try script.instructions()
    #expect(code.map(\.opcode) == [.push, .halt])
    #expect(script.describe(code[0]) == "000000  push   03:20 \"start.txt\"")
}

@Test func kcsLoopCallAndNative() throws {
    // main: i = 0; sum = 0; while (i < 5) { sum += i; i++ }  report(sum, "sum"); return sum
    var a = Assembler()
    a.emit(.call, .to("main"), imm(0))
    a.emit(.halt)
    a.label("main")
    a.emit(.alloc, imm(8)) // no arguments: header 0..0xc, i at 0xc, sum at 0x10
    a.emit(.addressOfLocal, imm(0xC)); a.emit(.assign, local(0xC), imm(0)); a.emit(.pop)
    a.emit(.addressOfLocal, imm(0x10)); a.emit(.assign, local(0x10), imm(0)); a.emit(.pop)
    a.label("loop")
    a.emit(.addressOfLocal, imm(0xC)); a.emit(.less, local(0xC), imm(5)); a.emit(.jumpIfZero, .to("end"))
    // Operands pop in order, so the destination's address goes on last.
    a.emit(.addressOfLocal, imm(0xC)); a.emit(.addressOfLocal, imm(0x10)); a.emit(.addAssign, local(0x10), local(0xC)); a.emit(.pop)
    a.emit(.addressOfLocal, imm(0xC)); a.emit(.postIncrement, local(0xC)); a.emit(.pop)
    a.emit(.jump, .to("loop"))
    a.label("end")
    a.emit(.addressOfLocal, imm(0x10)); a.emit(.push, local(0x10))
    a.emit(.push, imm(0x40))
    a.emit(.native, imm(7), imm(8)); a.emit(.pop)
    a.emit(.addressOfLocal, imm(0x10)); a.emit(.push, local(0x10))
    a.emit(.ret, imm(4), imm(0))
    let (machine, host) = try run(a, strings: [(0x40, "sum")])
    #expect(machine.halted)
    #expect(host.calls.count == 1)
    #expect(host.calls[0].id == 7)
    #expect(host.calls[0].args.first == 10)
    #expect(machine.string(at: host.calls[0].args[1]) == "sum")
}

@Test func kcsArgumentsSwitchAndFloats() throws {
    var a = Assembler()
    // add(20, 22) → native 1
    a.emit(.push, imm(20)); a.emit(.push, imm(22))
    a.emit(.call, .to("add"), imm(8))
    a.emit(.native, imm(1), imm(4)); a.emit(.pop)
    // switch (7) { case 1: case 2: …; 5...9: native 3 }
    a.emit(.push, imm(7))
    a.emit(.switchValue)
    a.emit(.caseValue, imm(1), .to("one"))
    a.emit(.caseRange, imm(5), imm(9), .to("range"))
    a.emit(.jump, .to("after"))
    a.label("one"); a.emit(.native, imm(2), imm(0)); a.emit(.pop); a.emit(.jump, .to("after"))
    a.label("range"); a.emit(.native, imm(3), imm(0)); a.emit(.pop)
    a.label("after")
    // (int)((float)3 * 2.5) → native 4
    a.emit(.intToFloat, imm(3))
    a.emit(.mul, .n(0x64, 0), .n(0x04, Float(2.5).bitPattern))
    a.emit(.floatToInt, .n(0x64, 0))
    a.emit(.native, imm(4), imm(4)); a.emit(.pop)
    // (0x00ff0000 & 0x12345678) >> 16 → native 5
    a.emit(.and, imm(0x00FF_0000), imm(0x1234_5678))
    a.emit(.shr, popped, imm(16))
    a.emit(.native, imm(5), imm(4)); a.emit(.pop)
    a.emit(.halt)
    a.label("add") // arguments at 0 and 4
    a.emit(.addressOfLocal, imm(4)); a.emit(.addressOfLocal, imm(0)); a.emit(.add, local(0), local(4))
    a.emit(.ret, imm(4), imm(8))
    let (_, host) = try run(a)
    #expect(host.calls.map(\.id) == [1, 3, 4, 5])
    #expect(host.calls[0].args == [42])
    #expect(host.calls[2].args == [7])
    #expect(host.calls[3].args == [0x34])
}

@Test func kcsInlineFormatReferences() throws {
    var a = Assembler()
    a.emit(.halt)
    let script = try KCScript(kcsFile(code: a.assembled(), strings: [(0x10, "save")], dataSize: 0x40))
    let machine = KCSMachine(script: script, sharedSize: 0x100, stackSize: 0x100)
    try machine.store(KCSMachine.stackBase + 64, 200, width: 4)
    try machine.store(0x20, 0x1F, width: 4)
    #expect(KCSRecordingHost.format("$str%d[L64]", machine) == "$str200")
    #expect(KCSRecordingHost.format("%s[G16]%04d[L64] %x[G32] 100%%", machine) == "save0200 1f 100%")
}

// MARK: Scenes

/// A CatScene file stored uncompressed: lines of (type, text).
func sceneFile(_ lines: [(UInt8, String)]) -> [UInt8] {
    var offsets: [UInt8] = [], strings: [UInt8] = []
    for (type, text) in lines {
        offsets += le32(UInt32(strings.count))
        strings += [0x01, type] + Array(text.utf8) + [0]
    }
    let body = le32(UInt32(offsets.count + strings.count)) + le32(0) + le32(0) + le32(UInt32(offsets.count)) + offsets + strings
    return Array("CatScene".utf8) + le32(0) + le32(UInt32(body.count)) + body
}

/// A `.cstl` with English only: (name, text) per message.
private func translationFile(_ messages: [(String, String)]) -> [UInt8] {
    func string(_ s: String) -> [UInt8] { [UInt8(s.utf8.count)] + Array(s.utf8) }
    return Array("CSTL".utf8) + [0, 0, 0, 0] + [1] + string("en") + [UInt8(messages.count)]
        + messages.flatMap { string($0.0) + string($0.1) }
}

@Test func scenePlayerRunsTheStoryFlow() throws {
    let cmd: UInt8 = 0x30, name: UInt8 = 0x21, text: UInt8 = 0x20, input: UInt8 = 0x02
    let files: [String: [UInt8]] = [
        "a.cst": sceneFile([(cmd, "#10 = #11 = 3"), (cmd, "bg 0 bgA"), (cmd, "pcm V1"), (name, "ja"), (text, "jtext"),
                            (cmd, "call sub"), (input, ""), (cmd, "if (#10 == 3 && !#12) next b"), (cmd, "next c")]),
        "a.cstl": translationFile([("Alice", "Hello\\nthere\\@")]),
        "sub.cst": sceneFile([(cmd, "#12 = 0"), (cmd, "eg 1 CG1"), (cmd, "pl 1 base 10 20"), (cmd, "pl [1-2] blend 128")]),
        "b.cst": sceneFile([(text, "j2"), (input, ""), (input, ""), (cmd, "next missing")]),
        "b.cstl": translationFile([("", "Narration.")]),
    ]
    let player = ScenePlayer { files[$0] }
    try player.start("a")
    var messages: [ScenePlayer.Message] = []
    var scenes: [String] = []
    var missing: [String] = []
    while let event = try player.next() {
        switch event {
        case .message(let m): messages.append(m)
        case .scene(let s): scenes.append(s)
        case .missingScene(let s): missing.append(s)
        default: break
        }
    }
    #expect(scenes == ["a", "sub", "b"])
    #expect(missing == ["missing"])
    #expect(messages.map(\.speaker) == ["Alice", nil])
    #expect(messages.map(\.text) == ["Hello there", "Narration."])
    #expect(messages.map(\.index) == [0, 0])
    #expect(messages.first?.voice == "V1")
    #expect(player.variables[10] == 3 && player.variables[11] == 3)
    #expect(player.planes[0]?.picture("bg")?.file == "bgA")
    #expect(player.planes[1]?.picture("eg")?.file == "CG1")
    #expect(player.planes[1]?.baseX == 10 && player.planes[1]?.alpha == 128)
}
