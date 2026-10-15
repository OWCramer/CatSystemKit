// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation

/// A CatSystem2 `.int` archive (KIF). Format as documented by GARbro
/// (github.com/crskycode/GARbro, `ArcFormats/CatSystem/ArcINT.cs`, MIT).
///
/// `KIF\0`, a `UInt32` entry count, then the entries: a NUL-padded name (64 bytes, 32 in the
/// oldest games), `UInt32` offset and size. Plain archives store everything as is.
///
/// Encrypted archives start with a `__key__.dat` entry whose size field seeds the Mersenne
/// Twister; its first number, as four little-endian bytes, is the Blowfish key for the
/// other entries' offset/size pairs (offset stored minus the entry's index) and for their
/// contents (whole 8-byte blocks only). Names are scrambled separately: a letter-rotation
/// keyed by the Twister reseeded with `nameKey + index`, where `nameKey` comes from the
/// game's passphrase (`CS2Passphrase`). The contents need no passphrase; the names do.
public final class KIFArchive: @unchecked Sendable {
    public struct Entry: Hashable, Sendable {
        public let index: Int
        public let name: String
        public let offset: UInt64
        public let size: Int
        /// The name as stored (scrambled in encrypted archives), for recovering it later.
        let rawName: [UInt8]
    }

    public enum Failure: Error, CustomStringConvertible {
        case truncated(URL)
        case malformed(URL, String)

        public var description: String {
            switch self {
            case .truncated(let url): "\(url.lastPathComponent): file is truncated"
            case .malformed(let url, let why): "\(url.lastPathComponent): \(why)"
            }
        }
    }

    public let url: URL
    public let isEncrypted: Bool
    /// Whether names were unscrambled with a name key (always true for plain archives).
    public private(set) var hasNames: Bool
    public private(set) var entries: [Entry]
    private var byName: [String: Int]
    private let cipher: CS2Blowfish?
    private let handle: FileHandle
    private let lock = NSLock()

    /// Opens an archive. `nameKey` (from `CS2Passphrase.key`) unscrambles an encrypted
    /// archive's names; without it entries are named by number (`#12`) until
    /// `applyNameKey` or `recoverNames` is called.
    public init(url: URL, nameKey: UInt32? = nil) throws {
        self.url = url
        handle = try FileHandle(forReadingFrom: url)
        let head = try Self.read(handle, at: 0, count: 8, url: url)
        guard head.prefix(4).elementsEqual([0x4B, 0x49, 0x46, 0x00]) else {
            throw Failure.malformed(url, "not a KIF archive")
        }
        let count = Int(head.le32(4))
        let fileSize = (try? handle.seekToEnd()) ?? 0
        guard count > 0, count < 1 << 20, UInt64(8 + count * 0x48) <= fileSize else {
            throw Failure.malformed(url, "entry count \(count)")
        }
        let first = try Self.read(handle, at: 8, count: 0x48, url: url)
        if first.cString(0, max: 64).elementsEqual(Array("__key__.dat".utf8)) {
            isEncrypted = true
            let table = try Self.read(handle, at: 8, count: count * 0x48, url: url)
            var twister = CS2Twister(seed: table.le32(0x44))
            let blowfishKey = withUnsafeBytes(of: twister.next().littleEndian) { [UInt8]($0) }
            guard let cipher = CS2Blowfish(key: blowfishKey) else {
                throw Failure.malformed(url, "Blowfish key setup failed")
            }
            self.cipher = cipher
            var entries: [Entry] = []
            entries.reserveCapacity(count - 1)
            for i in 1..<count {
                let base = i * 0x48
                let raw = Array(table[base..<base + 0x40])
                var offset = table.le32(base + 0x40) &+ UInt32(i)
                var size = table.le32(base + 0x44)
                cipher.decipher(&offset, &size)
                guard UInt64(offset) + UInt64(size) <= fileSize else {
                    throw Failure.malformed(url, "entry \(i) runs past the end")
                }
                let name = nameKey.map { Self.unscramble(raw, key: Self.nameKey($0, index: i)) } ?? "#\(i - 1)"
                entries.append(Entry(index: i - 1, name: name, offset: UInt64(offset), size: Int(size), rawName: raw))
            }
            self.entries = entries
            hasNames = nameKey != nil
        } else {
            isEncrypted = false
            cipher = nil
            hasNames = true
            entries = try Self.plainEntries(handle, count: count, fileSize: fileSize, url: url)
        }
        byName = [:]
        reindex()
    }

    public func entry(named name: String) -> Entry? {
        byName[name.lowercased()].map { entries[$0] }
    }

    /// An entry's contents, deciphered.
    public func data(for entry: Entry) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        var bytes = try Self.read(handle, at: entry.offset, count: entry.size, url: url)
        cipher?.decipher(&bytes)
        return bytes
    }

    /// Part of an entry, deciphered: `count` bytes from `offset` (clipped to the entry). The
    /// cipher works on whole 8-byte blocks from the entry's start (a short last block is
    /// stored plain), so a large entry (a movie) can be read a piece at a time, in memory.
    public func read(_ entry: Entry, at offset: Int, count: Int) throws -> [UInt8] {
        let start = max(0, min(offset, entry.size)), end = max(start, min(entry.size, offset + count))
        guard end > start else { return [] }
        let blockStart = start / 8 * 8
        let whole = entry.size / 8 * 8
        let blockEnd = min(entry.size, end <= whole ? (end + 7) / 8 * 8 : entry.size)
        lock.lock()
        defer { lock.unlock() }
        var bytes = try Self.read(handle, at: entry.offset + UInt64(blockStart), count: blockEnd - blockStart, url: url)
        if let cipher {
            let cipheredEnd = min(blockEnd, whole) - blockStart
            if cipheredEnd > 0 {
                var head = Array(bytes[0..<cipheredEnd])
                cipher.decipher(&head)
                bytes.replaceSubrange(0..<cipheredEnd, with: head)
            }
        }
        return Array(bytes[(start - blockStart)..<(end - blockStart)])
    }

    /// The first bytes of an entry, deciphered (rounded up to a whole block).
    public func head(of entry: Entry, count: Int = 16) throws -> [UInt8] {
        let n = min(entry.size, (count + 7) / 8 * 8)
        lock.lock()
        defer { lock.unlock() }
        var bytes = try Self.read(handle, at: entry.offset, count: n, url: url)
        cipher?.decipher(&bytes)
        return bytes
    }

    // MARK: Names

    /// The per-entry name key: the Twister reseeded with `nameKey + index`, first number.
    static func nameKey(_ key: UInt32, index: Int) -> UInt32 {
        var twister = CS2Twister(seed: key &+ UInt32(index))
        return twister.next()
    }

    private static let alphabet = Array("zyxwvutsrqponmlkjihgfedcbaZYXWVUTSRQPONMLKJIHGFEDCBA".utf8)
    private static let alphabetIndex: [Int] = {
        var table = [Int](repeating: -1, count: 256)
        for (i, c) in alphabet.enumerated() { table[Int(c)] = i }
        return table
    }()

    /// Unscrambles a name: each ASCII letter is rotated through a reversed 52-letter
    /// alphabet by a shift that starts at the key's byte sum and grows by one per byte.
    static func unscramble(_ raw: [UInt8], key: UInt32) -> String {
        let start = Int(UInt8(truncatingIfNeeded: (key >> 24) &+ (key >> 16) &+ (key >> 8) &+ key))
        return unscramble(raw, shift: start)
    }

    static func unscramble(_ raw: [UInt8], shift start: Int) -> String {
        var out: [UInt8] = []
        var k = start
        for c in raw {
            if c == 0 { break }
            var b = c
            var j = alphabetIndex[Int(c)]
            if j >= 0 {
                j -= k % 52
                if j < 0 { j += 52 }
                b = alphabet[51 - j]
            }
            out.append(b)
            k += 1
        }
        return String(data: Data(out), encoding: cp932) ?? String(decoding: out, as: UTF8.self)
    }

    /// Without the passphrase, names are recovered from content: the extension a file's
    /// magic implies (`.hg3`, `.cst`, `.ogg` …) fixes the rotation, which reveals the rest of
    /// the name. Entries whose type can't be told keep a numbered name.
    public func recoverNames() {
        for (i, shift) in shiftsFromContent() {
            entries[i] = Entry(index: entries[i].index, name: Self.unscramble(entries[i].rawName, shift: shift),
                               offset: entries[i].offset, size: entries[i].size, rawName: entries[i].rawName)
        }
        reindex()
    }

    /// Renames every entry with a name key (from `CS2Passphrase.key` or `recoverNameKey`).
    public func applyNameKey(_ key: UInt32) {
        guard isEncrypted else { return }
        for i in entries.indices {
            entries[i] = Entry(index: entries[i].index,
                               name: Self.unscramble(entries[i].rawName, key: Self.nameKey(key, index: i + 1)),
                               offset: entries[i].offset, size: entries[i].size, rawName: entries[i].rawName)
        }
        hasNames = true
        reindex()
    }

    /// The rotation of each entry whose type its content gives away, keyed by entry index.
    /// A rotation by 26 swaps the case of every letter, so it is known modulo 26 only;
    /// Windows names are case-insensitive, so either reading will do.
    func shiftsFromContent(limit: Int = .max) -> [Int: Int] {
        var shifts: [Int: Int] = [:]
        for i in entries.indices where shifts.count < limit {
            guard let ext = (try? head(of: entries[i], count: 16)).flatMap(Self.extensionFor) else { continue }
            let raw = entries[i].rawName
            let matches = (0..<26).filter { Self.unscramble(raw, shift: $0).lowercased().hasSuffix("." + ext) }
            if matches.count == 1 { shifts[i] = matches[0] }
        }
        return shifts
    }

    /// Recovers the game's 32-bit name key from the archive itself: each entry with a known
    /// type gives its rotation (the byte sum of the Twister's first number for
    /// `key + index`, modulo 26), and a search over all 2³² keys keeps the one that fits
    /// every entry. The Twister's first number needs only seeding words 0, 1 and 397, each a
    /// closed-form step of the seeding LCG, so the search takes seconds. Nil when fewer than
    /// eight entries can be typed or no single key fits.
    public func recoverNameKey() -> UInt32? {
        let shifts = shiftsFromContent(limit: 32).map { (index: UInt32($0.key + 1), shift: UInt8($0.value)) }
            .sorted { $0.index < $1.index }
        guard shifts.count >= 8 else { return nil }
        let first = shifts[0]
        let others = Array(shifts.dropFirst())
        let chunks = 1024
        let span = UInt64(1) << 32 / UInt64(chunks)
        let rand = FirstRand.shared
        let lock = NSLock()
        nonisolated(unsafe) var keys: [UInt32] = []
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            let start = UInt64(chunk) * span
            for candidate in start..<start + span {
                let key = UInt32(truncatingIfNeeded: candidate)
                let y = rand(key &+ first.index)
                guard UInt8(truncatingIfNeeded: (y >> 24) &+ (y >> 16) &+ (y >> 8) &+ y) % 26 == first.shift
                else { continue }
                if others.allSatisfy({ Self.shift(firstRandFor: key &+ $0.index) == $0.shift }) {
                    lock.lock()
                    keys.append(key)
                    lock.unlock()
                }
            }
        }
        return keys.count == 1 ? keys[0] : nil
    }

    @inline(__always)
    static func shift(firstRandFor seed: UInt32) -> UInt8 {
        let y = FirstRand.shared(seed)
        return UInt8(truncatingIfNeeded: (y >> 24) &+ (y >> 16) &+ (y >> 8) &+ y) % 26
    }

    /// The Twister's first number for a seed without the full 624-word state: the seeding
    /// LCG (`s·69069 + 1`) after n steps is `Aₙ·s + Cₙ`, and word i takes steps 2i and 2i+1.
    struct FirstRand: Sendable {
        static let shared = FirstRand()
        private let a0, c0, a1, c1, a2, c2, a3, c3, a794, c794, a795, c795: UInt32

        init() {
            var steps: [(UInt32, UInt32)] = [(1, 0)]
            for _ in 0..<796 {
                let last = steps[steps.count - 1]
                steps.append((last.0 &* 69069, last.1 &* 69069 &+ 1))
            }
            (a0, c0) = steps[0]; (a1, c1) = steps[1]; (a2, c2) = steps[2]; (a3, c3) = steps[3]
            (a794, c794) = steps[794]; (a795, c795) = steps[795]
        }

        @inline(__always)
        func callAsFunction(_ seed: UInt32) -> UInt32 {
            let m0 = ((a0 &* seed &+ c0) & 0xFFFF_0000) | ((a1 &* seed &+ c1) >> 16)
            let m1 = ((a2 &* seed &+ c2) & 0xFFFF_0000) | ((a3 &* seed &+ c3) >> 16)
            let m397 = ((a794 &* seed &+ c794) & 0xFFFF_0000) | ((a795 &* seed &+ c795) >> 16)
            let y0 = (m0 & 0x8000_0000) | (m1 & 0x7FFF_FFFF)
            var y = m397 ^ (y0 >> 1) ^ (y0 & 1 == 0 ? 0 : 0x9908_B0DF)
            y ^= y >> 11
            y ^= (y << 7) & 0x9D2C_5680
            y ^= (y << 15) & 0xEFC6_0000
            y ^= y >> 18
            return y
        }
    }

    /// The extension a file's first bytes imply.
    static func extensionFor(_ head: [UInt8]) -> String? {
        func starts(_ s: String) -> Bool { head.starts(with: Array(s.utf8)) }
        if starts("HG-3") { return "hg3" }
        if starts("HG-2") { return "hg2" }
        if starts("CatScene") { return "cst" }
        if starts("OggS") { return "ogg" }
        if starts("PSB\0") || starts("mdf\0") { return "psb" }
        if starts("RIFF") { return "wav" }
        if starts("\u{89}PNG") { return "png" }
        if starts("FES") { return "fes" }
        return nil
    }

    private func reindex() {
        byName = [:]
        for (i, e) in entries.enumerated() { byName[e.name.lowercased()] = i }
    }

    private static func plainEntries(_ handle: FileHandle, count: Int, fileSize: UInt64, url: URL) throws -> [Entry] {
        // Names are 64 bytes in CatSystem2, 32 in older games; try both.
        for nameLength in [0x40, 0x20] {
            guard UInt64(8 + count * (nameLength + 8)) <= fileSize else { continue }
            let table = try read(handle, at: 8, count: count * (nameLength + 8), url: url)
            var entries: [Entry] = []
            var ok = true
            for i in 0..<count {
                let base = i * (nameLength + 8)
                let raw = Array(table[base..<base + nameLength])
                let name = String(data: Data(table.cString(base, max: nameLength)), encoding: cp932) ?? ""
                let offset = UInt64(table.le32(base + nameLength))
                let size = Int(table.le32(base + nameLength + 4))
                if name.isEmpty || offset < UInt64(8 + count * (nameLength + 8)) || offset + UInt64(size) > fileSize {
                    ok = false
                    break
                }
                entries.append(Entry(index: i, name: name, offset: offset, size: size, rawName: raw))
            }
            if ok { return entries }
        }
        throw Failure.malformed(url, "entry table not understood")
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int, url: URL) throws -> [UInt8] {
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw Failure.truncated(url)
        }
        return [UInt8](data)
    }
}
