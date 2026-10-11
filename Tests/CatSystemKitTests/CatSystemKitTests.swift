import Testing
@testable import CatSystemKit

@Test func passphraseFoldsToGARbroKey() {
    // GARbro's database lists NEKOPARA Vol.3 as passphrase AMN-8ETQF49S, key 0x31B5B027.
    #expect(CS2Passphrase.key("AMN-8ETQF49S") == 0x31B5_B027)
}

@Test func closedFormFirstRandMatchesTwister() {
    for seed: UInt32 in [0, 1, 0x31B5_B027, 0xDEAD_BEEF, 0xFFFF_FFFF, 12345] {
        var twister = CS2Twister(seed: seed)
        #expect(KIFArchive.FirstRand.shared(seed) == twister.next())
    }
}

@Test func nameUnscrambleRoundTrip() {
    // Scrambling is the inverse rotation; unscrambling with the same shift restores it.
    let alphabet = Array("zyxwvutsrqponmlkjihgfedcbaZYXWVUTSRQPONMLKJIHGFEDCBA".utf8)
    let name = Array("title.fes".utf8)
    var k = 17
    let scrambled: [UInt8] = name.map { c in
        defer { k += 1 }
        guard let j = alphabet.firstIndex(of: c) else { return c }
        return alphabet[(51 - j + k % 52) % 52]
    }
    #expect(KIFArchive.unscramble(scrambled, shift: 17) == "title.fes")
}

private final class StubContext: FESContext {
    var globals: [Int: Int] = [850: 3, 897: 0]
    var locals: [Int: Int] = [10: 16]
    func global(_ index: Int) -> Int { globals[index] ?? 0 }
    func setGlobal(_ index: Int, _ value: Int) { globals[index] = value }
    func local(_ index: Int) -> Int { locals[index] ?? 0 }
    func setLocal(_ index: Int, _ value: Int) { locals[index] = value }
    func system(_ name: String) -> Int? { name == "_EXITCODE_" ? -1 : nil }
    func macro(_ name: String) -> String? { name == "VER_MIN" ? "3500" : nil }
}

@Test func fesExpressions() {
    let c = StubContext()
    #expect(FESExpression.evaluate("$850==3&&$897==0", c) == 1)
    #expect(FESExpression.evaluate("_EXITCODE_!=-1", c) == 0)
    #expect(FESExpression.evaluate("\\10*3+1", c) == 49)
    #expect(FESExpression.evaluate("$(840+10)", c) == 3)
    #expect(FESExpression.evaluate("VER_MIN+1", c) == 3501)
    #expect(FESExpression.evaluate("0xff000000", c) == 0xFF00_0000)
}

@Test func fesProgramSections() {
    let text = "#DEFINE\r\nPLANE pl\r\nBUTTON btn1[5]\r\n#OBJECT FILE PL PRI DISP ENABLE\r\n"
        + "btn1 sys_title_%LANG% pl 100 1 0\r\n#START\r\n$30 = 0\r\nnext WAIT\r\n#btn1.PUSH_L\r\n@ setid 3\r\n"
    let program = FESProgram(text: text)
    #expect(program.definitions.map(\.name) == ["pl", "btn1"])
    #expect(program.definitions[1].count == 5)
    #expect(program.tables.first?.rows.first?.1 == ["sys_title_%LANG%", "pl", "100", "1", "0"])
    #expect(program.blocks["START"] == ["$30 = 0", "next WAIT"])
    #expect(program.blocks["btn1.PUSH_L"] == ["@ setid 3"])
    #expect(FESInstance.format("se_sys_%02d", [5]) == "se_sys_05")
}
