import Foundation

/// A PSB file (M2's packed binary tree, the container of E-mote models), read from a
/// `.psz` (PSB under zlib) or a bare PSB.
///
/// Layout (version 2–4): `PSB\0`, version, flags, then offsets to the name table (three
/// integer arrays spelling every key as a trie), the string table, the resources (chunk
/// offsets and lengths, then their bytes) and the root value. Values are tagged: null,
/// booleans, integers of 1–8 bytes, floats, strings and resources by index, lists and
/// dictionaries as offset tables.
///
/// NEKOPARA Vol. 3's models set flag 1: the header's offsets are XORed with an E-mote
/// keystream (xorshift128 seeded with 123456789, 362436069, 521288629 and a per-title
/// seed). The first offset is the header's own length, known from the version, so the
/// first keystream word, and from it the seed, falls out of the file itself: no key is
/// read from the game's executable.
public final class PSBFile {
    public enum Failure: Error, CustomStringConvertible {
        case notPSB
        case truncated(String)
        public var description: String {
            switch self {
            case .notPSB: "not a PSB"
            case .truncated(let what): "PSB truncated (\(what))"
            }
        }
    }

    public indirect enum Value {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case list([Value])
        case dictionary([String: Value])
        case resource(Int)
        case extraResource(Int)
        case integers([Int])

        public subscript(key: String) -> Value? {
            if case .dictionary(let d) = self { return d[key] }
            return nil
        }

        public var dictionary: [String: Value]? { if case .dictionary(let d) = self { d } else { nil } }
        public var string: String? { if case .string(let s) = self { s } else { nil } }

        public var list: [Value]? {
            switch self {
            case .list(let l): l
            case .integers(let a): a.map { .int($0) }
            default: nil
            }
        }

        public var number: Double? {
            switch self {
            case .int(let i): Double(i)
            case .double(let d): d
            case .bool(let b): b ? 1 : 0
            default: nil
            }
        }

        public var int: Int? { number.map { Int($0) } }

        /// A list of numbers (`coord`, `bp`), however it was stored.
        public var numbers: [Double]? {
            switch self {
            case .integers(let a): a.map(Double.init)
            case .list(let l): l.compactMap(\.number)
            default: nil
            }
        }
    }

    public let bytes: [UInt8]
    public let version: Int
    /// The seed that decrypted the header (0 for a plain file).
    public private(set) var seed: UInt32 = 0
    public private(set) var root: Value = .null
    private var names: [String] = []
    private var stringOffsets: [Int] = []
    private var stringData = 0
    private var chunkOffsets: [Int] = []
    private var chunkLengths: [Int] = []
    private var chunkData = 0

    /// Reads a `.psz` (`PSZ\0`, zlib length, inflated length, reserved, zlib stream) or a PSB.
    public convenience init(psz: [UInt8], bodySeed: UInt32? = nil, candidateSeeds: [UInt32] = []) throws {
        if psz.count >= 16, psz[0] == 0x50, psz[1] == 0x53, psz[2] == 0x5A, psz[3] == 0 {
            let packed = Int(Self.u32(psz, 4)), size = Int(Self.u32(psz, 8))
            guard 16 + packed <= psz.count else { throw Failure.truncated("psz") }
            try self.init(Zlib.inflate(psz[16..<(16 + packed)], size: size), bodySeed: bodySeed, candidateSeeds: candidateSeeds)
        } else {
            try self.init(psz, bodySeed: bodySeed, candidateSeeds: candidateSeeds)
        }
    }

    /// `bodySeed`: the title's seed for a version 2 PSB whose name and string tables are
    /// encrypted (E-mote 3 models in KiriKiri games), when already known; nil finds it
    /// from the file (see `findBodySeed`).
    /// `candidateSeeds`: seeds found before (other runs of the same games), tried before the
    /// search: finding a seed from the file alone takes a fifth of a second.
    public init(_ data: [UInt8], bodySeed: UInt32? = nil, candidateSeeds: [UInt32] = []) throws {
        guard data.count >= 0x38, data[0] == 0x50, data[1] == 0x53, data[2] == 0x42, data[3] == 0 else { throw Failure.notPSB }
        var bytes = data
        version = Int(bytes[4]) | Int(bytes[5]) << 8
        let flags = Int(bytes[6]) | Int(bytes[7]) << 8
        let headerWords = version >= 4 ? 12 : version == 3 ? 9 : 8
        if flags & 1 != 0 {
            // offsetEncrypt (the first word) is the header's length: 8 + 4 per word.
            let known = UInt32(8 + 4 * headerWords)
            let seed = Self.recoverSeed(firstWord: Self.u32(bytes, 8) ^ known)
            var stream = EmoteKeystream(seed: seed)
            for i in 8..<(8 + 4 * headerWords) { bytes[i] ^= stream.next() }
            self.seed = seed
        }
        if version == 2, !Self.tablesReadable(bytes) {
            // The tables from offsetEncrypt up to the chunk offsets are under the keystream,
            // started afresh there.
            let seed: UInt32
            if let bodySeed, Self.seedFits(bodySeed, bytes) { seed = bodySeed }
            else if let known = candidateSeeds.first(where: { Self.seedFits($0, bytes) }) { seed = known }
            else if let found = Self.findBodySeed(bytes) { seed = found }
            else { throw Failure.truncated("encrypted tables (no seed found)") }
            let start = Int(Self.u32(bytes, 8)), end = Int(Self.u32(bytes, 24))
            guard start < end, end <= bytes.count else { throw Failure.truncated("encrypted range") }
            var stream = EmoteKeystream(seed: seed)
            for i in start..<end { bytes[i] ^= stream.next() }
            self.seed = seed
        }
        self.bytes = bytes
        let offsetNames = Int(Self.u32(bytes, 12))
        let offsetStrings = Int(Self.u32(bytes, 16))
        stringData = Int(Self.u32(bytes, 20))
        let offsetChunkOffsets = Int(Self.u32(bytes, 24))
        let offsetChunkLengths = Int(Self.u32(bytes, 28))
        chunkData = Int(Self.u32(bytes, 32))
        let offsetRoot = Int(Self.u32(bytes, 36))
        guard [offsetNames, offsetStrings, stringData, offsetChunkOffsets, offsetChunkLengths, offsetRoot].allSatisfy({ $0 < bytes.count }) else {
            throw Failure.truncated("header")
        }
        var p = offsetNames
        let charset = try integers(&p), nameData = try integers(&p), tree = try integers(&p)
        names.reserveCapacity(tree.count)
        for index in tree {
            var out: [UInt8] = []
            guard index < nameData.count else { names.append(""); continue }
            var chr = nameData[index]
            while chr != 0, chr < nameData.count, out.count < 512 {
                let code = nameData[chr]
                guard code < charset.count else { break }
                out.append(UInt8(truncatingIfNeeded: chr - charset[code]))
                chr = code
            }
            names.append(String(decoding: out.reversed(), as: UTF8.self))
        }
        p = offsetStrings
        stringOffsets = try integers(&p)
        p = offsetChunkOffsets
        chunkOffsets = try integers(&p)
        p = offsetChunkLengths
        chunkLengths = try integers(&p)
        root = try value(at: offsetRoot)
    }

    /// A resource's bytes (a texture's pixels).
    public func resource(_ index: Int) -> ArraySlice<UInt8>? {
        guard index < chunkOffsets.count, index < chunkLengths.count else { return nil }
        let start = chunkData + chunkOffsets[index], end = start + chunkLengths[index]
        guard end <= bytes.count else { return nil }
        return bytes[start..<end]
    }

    // MARK: Reading

    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    /// The seed whose first xorshift128 output is `firstWord`: that output is
    /// `t ^ s ^ (t >> 8) ^ (s >> 19)` with `t` fixed by the constant seeding words and
    /// `s` the seed, and `s ^ (s >> 19)` inverts in one step.
    static func recoverSeed(firstWord: UInt32) -> UInt32 {
        let x: UInt32 = 0x075B_CD15
        let t = x ^ (x << 11)
        let y = firstWord ^ t ^ (t >> 8)
        return y ^ (y >> 19)
    }

    /// Where the name arrays must end: the next part the header places after them (the
    /// strings, or in version 2 files the root, which comes first).
    static func namesEnd(_ b: [UInt8]) -> Int? {
        let names = Int(u32(b, 12))
        let next = [16, 20, 24, 28, 32, 36].map { Int(u32(b, $0)) }.filter { $0 > names }.min()
        guard let next, next <= b.count else { return nil }
        return next
    }

    /// Whether the three name arrays read cleanly up to the part after them.
    static func tablesReadable(_ b: [UInt8]) -> Bool {
        let names = Int(u32(b, 12))
        guard let end = namesEnd(b) else { return false }
        var plain = PlainBytes(bytes: b)
        return arraysEnd(&plain, at: names, count: 3, limit: end) == end
    }

    /// Whether `seed` decrypts this file's tables.
    static func seedFits(_ seed: UInt32, _ b: [UInt8]) -> Bool {
        let names = Int(u32(b, 12)), start = Int(u32(b, 8))
        guard start == names, let end = namesEnd(b) else { return false }
        var keyed = KeyedBytes(bytes: b, start: names, stream: EmoteKeystream(seed: seed))
        return arraysEnd(&keyed, at: names, count: 3, limit: end) == end
    }

    /// The seed of a version 2 PSB's encrypted tables, found from the file alone: the
    /// first four bytes at the name offset are an array header (type, count, then the
    /// width or more count), so each plausible header gives the keystream's first word and
    /// from it a seed; the right one makes all three name arrays end exactly where the
    /// header's next part begins. Nothing is read from the game's program. (A title uses
    /// one seed: callers keep it and pass it as `bodySeed` for the rest.)
    public static func findBodySeed(_ b: [UInt8]) -> UInt32? {
        guard b.count >= 0x28, Int(b[4]) | Int(b[5]) << 8 == 2 else { return nil }
        let start = Int(u32(b, 8)), names = Int(u32(b, 12))
        guard start == names, let strings = namesEnd(b), names + 8 < strings else { return nil }
        let first = u32(b, names)
        func check(_ plain: UInt32) -> UInt32? {
            let seed = recoverSeed(firstWord: first ^ plain)
            var keyed = KeyedBytes(bytes: b, start: names, stream: EmoteKeystream(seed: seed))
            // The first two arrays must read before the whole table is tried.
            guard arraysEnd(&keyed, at: names, count: 2, limit: strings) != nil else { return nil }
            return seedFits(seed, b) ? seed : nil
        }
        for width in UInt32(0x0D)...0x10 {
            // One count byte: type, count, width, first entry's low byte.
            for count in UInt32(1)...255 { for entry in UInt32(0)...255 {
                if let s = check(0x0D | count << 8 | width << 16 | entry << 24) { return s }
            } }
            // Two count bytes: type, count, width.
            for count in UInt32(1)...0xFFFF {
                if let s = check(0x0E | count << 8 | width << 24) { return s }
            }
        }
        return nil
    }

    private func uint(_ p: Int, _ n: Int) -> Int {
        var v = 0
        for i in 0..<n where p + i < bytes.count { v |= Int(bytes[p + i]) << (8 * i) }
        return v
    }

    private func integers(_ p: inout Int) throws -> [Int] {
        guard p < bytes.count else { throw Failure.truncated("array") }
        let countSize = Int(bytes[p]) - 0xC
        guard (1...8).contains(countSize) else { throw Failure.truncated("array header") }
        let count = uint(p + 1, countSize)
        let widthAt = p + 1 + countSize
        guard widthAt < bytes.count else { throw Failure.truncated("array width") }
        let width = Int(bytes[widthAt]) - 0xC
        let start = widthAt + 1
        guard (1...8).contains(width), start + count * width <= bytes.count else { throw Failure.truncated("array body") }
        var out = [Int](repeating: 0, count: count)
        for i in 0..<count { out[i] = uint(start + i * width, width) }
        p = start + count * width
        return out
    }

    private func string(_ index: Int) -> String {
        guard index < stringOffsets.count else { return "" }
        let start = stringData + stringOffsets[index]
        var end = start
        while end < bytes.count, bytes[end] != 0 { end += 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    private func value(at p: Int) throws -> Value {
        guard p < bytes.count else { throw Failure.truncated("value") }
        let type = Int(bytes[p])
        switch type {
        case 1: return .null
        case 2: return .bool(false)
        case 3: return .bool(true)
        case 4: return .int(0)
        case 5...0xC:
            let n = type - 4
            var v = uint(p + 1, n)
            if n < 8, v & (1 << (8 * n - 1)) != 0 { v -= 1 << (8 * n) }
            return .int(v)
        case 0xD...0x14:
            var q = p
            return .integers(try integers(&q))
        case 0x15...0x18: return .string(string(uint(p + 1, type - 0x14)))
        case 0x19...0x1C: return .resource(uint(p + 1, type - 0x18))
        case 0x1D: return .double(0)
        case 0x1E:
            return .double(Double(Float(bitPattern: Self.u32(bytes, p + 1))))
        case 0x1F:
            let lo = UInt64(Self.u32(bytes, p + 1)), hi = UInt64(Self.u32(bytes, p + 5))
            return .double(Double(bitPattern: lo | hi << 32))
        case 0x20:
            var q = p + 1
            let offsets = try integers(&q)
            return .list(try offsets.map { try value(at: q + $0) })
        case 0x21:
            var q = p + 1
            let keys = try integers(&q)
            let offsets = try integers(&q)
            var d: [String: Value] = [:]
            d.reserveCapacity(keys.count)
            for (k, o) in zip(keys, offsets) where k < names.count { d[names[k]] = try value(at: q + o) }
            return .dictionary(d)
        case 0x22...0x25: return .extraResource(uint(p + 1, type - 0x21))
        default:
            throw Failure.truncated(String(format: "value type 0x%02X at 0x%X", type, p))
        }
    }
}

/// E-mote's PSB keystream: xorshift128, an output word's bytes low first. A new word is
/// drawn once what is left of the last one has shifted down to zero, so a word whose top
/// bytes are zero gives fewer than four (as M2's decrypter does).
struct EmoteKeystream {
    private var x: UInt32 = 0x075B_CD15, y: UInt32 = 0x159A_55E5, z: UInt32 = 0x1F12_3BB5, w: UInt32
    private var word: UInt32 = 0

    init(seed: UInt32) { w = seed }

    mutating func next() -> UInt8 {
        if word == 0 {
            let t = x ^ (x << 11)
            x = y; y = z; z = w
            w = t ^ w ^ ((t ^ (w >> 11)) >> 8)
            word = w
        }
        defer { word >>= 8 }
        return UInt8(truncatingIfNeeded: word)
    }
}
