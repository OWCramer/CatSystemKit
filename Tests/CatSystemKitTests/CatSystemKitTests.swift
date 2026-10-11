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
