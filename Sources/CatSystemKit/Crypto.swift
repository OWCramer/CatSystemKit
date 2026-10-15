// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import CommonCrypto
import Foundation

/// Blowfish as CatSystem2 uses it: the standard cipher (CommonCrypto's, ECB) over
/// little-endian 32-bit halves, where the standard reads them big-endian. Only whole
/// 8-byte blocks are enciphered; a tail shorter than a block is stored as is.
final class CS2Blowfish: @unchecked Sendable {
    private let cryptor: CCCryptorRef
    private let lock = NSLock()

    /// `key` may be shorter than CommonCrypto's 8-byte minimum: Blowfish's key schedule
    /// cycles through the key bytes, so a key repeated to 8 bytes schedules identically.
    init?(key: [UInt8]) {
        guard !key.isEmpty else { return nil }
        var material = key
        while material.count < kCCKeySizeMinBlowfish { material += key }
        var ref: CCCryptorRef?
        let status = CCCryptorCreate(
            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmBlowfish), CCOptions(kCCOptionECBMode),
            material, material.count, nil, &ref)
        guard status == kCCSuccess, let ref else { return nil }
        cryptor = ref
    }

    deinit { CCCryptorRelease(cryptor) }

    /// Deciphers the whole blocks of `bytes` in place.
    func decipher(_ bytes: inout [UInt8]) {
        let length = bytes.count / 8 * 8
        guard length > 0 else { return }
        bytes.withUnsafeMutableBytes { raw in
            let words = raw.baseAddress!.assumingMemoryBound(to: UInt32.self)
            for i in 0..<length / 4 { words[i] = words[i].byteSwapped }
            lock.lock()
            var moved = 0
            // ECB keeps no state between blocks, so one cryptor serves every call.
            CCCryptorUpdate(cryptor, raw.baseAddress, length, raw.baseAddress, length, &moved)
            lock.unlock()
            for i in 0..<length / 4 { words[i] = words[i].byteSwapped }
        }
    }

    /// Deciphers one block given as two words.
    func decipher(_ left: inout UInt32, _ right: inout UInt32) {
        var block: [UInt8] = []
        withUnsafeBytes(of: left.littleEndian) { block += $0 }
        withUnsafeBytes(of: right.littleEndian) { block += $0 }
        decipher(&block)
        left = block.le32(0)
        right = block.le32(4)
    }
}

/// The Mersenne Twister in the 1998 form with the Knuth `69069` seeding (`sgenrand`),
/// which CatSystem2 uses to derive archive keys.
struct CS2Twister {
    private var mt = [UInt32](repeating: 0, count: 624)
    private var index = 624

    init(seed: UInt32) { reseed(seed) }

    mutating func reseed(_ seed: UInt32) {
        var seed = seed
        for i in 0..<624 {
            let upper = seed & 0xFFFF_0000
            seed = seed &* 69069 &+ 1
            mt[i] = upper | (seed & 0xFFFF_0000) >> 16
            seed = seed &* 69069 &+ 1
        }
        index = 624
    }

    mutating func next() -> UInt32 {
        if index >= 624 {
            func twist(_ a: Int, _ b: Int, _ c: Int) -> UInt32 {
                let y = (mt[a] & 0x8000_0000) | (mt[b] & 0x7FFF_FFFF)
                return mt[c] ^ (y >> 1) ^ (y & 1 == 0 ? 0 : 0x9908_B0DF)
            }
            for k in 0..<(624 - 397) { mt[k] = twist(k, k + 1, k + 397) }
            for k in (624 - 397)..<623 { mt[k] = twist(k, k + 1, k + 397 - 624) }
            mt[623] = twist(623, 0, 396)
            index = 0
        }
        var y = mt[index]
        index += 1
        y ^= y >> 11
        y ^= (y << 7) & 0x9D2C_5680
        y ^= (y << 15) & 0xEFC6_0000
        y ^= y >> 18
        return y
    }
}

/// CatSystem2's archive passphrase ("V_CODE", e.g. `AMN-XXXXXXXX`) folded to the 32-bit
/// key that unscrambles file names: a CRC-32 (MSB-first table) without the final inversion,
/// each step inverted instead.
public enum CS2Passphrase {
    public static func key(_ passphrase: String) -> UInt32 {
        let bytes = passphrase.data(using: cp932).map { [UInt8]($0) } ?? Array(passphrase.utf8)
        var key: UInt32 = 0xFFFF_FFFF
        for c in bytes { key = ~table[Int((key >> 24) ^ UInt32(c))] ^ (key << 8) }
        return key
    }

    private static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i) << 24
        for _ in 0..<8 { c = c & 0x8000_0000 != 0 ? (c << 1) ^ 0x04C1_1DB7 : c << 1 }
        return c
    }
}

/// Windows code page 932 (Shift-JIS with Microsoft's extensions), CatSystem2's text encoding.
let cp932 = String.Encoding(
    rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))

extension Collection where Element == UInt8, Index == Int {
    func le32(_ at: Int) -> UInt32 {
        let i = startIndex + at
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }

    func le16(_ at: Int) -> UInt16 {
        let i = startIndex + at
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    /// The bytes up to the first NUL (or the end).
    func cString(_ at: Int, max: Int) -> ArraySlice<UInt8> {
        let start = startIndex + at
        let end = Swift.min(start + max, endIndex)
        var stop = start
        while stop < end, self[stop] != 0 { stop += 1 }
        return Array(self[start..<stop])[...]
    }
}
