// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

/// Bytes of a PSB as the table checks read them: plain, or under a keystream from `start`.
protocol PSBByteSource {
    mutating func byte(_ i: Int) -> Int
}

struct PlainBytes: PSBByteSource {
    let bytes: [UInt8]
    mutating func byte(_ i: Int) -> Int { Int(bytes[i]) }
}

/// Decrypts on demand: the keystream is produced only as far as a read reaches.
struct KeyedBytes: PSBByteSource {
    let bytes: [UInt8]
    let start: Int
    var stream: EmoteKeystream
    var keys: [UInt8] = []

    init(bytes: [UInt8], start: Int, stream: EmoteKeystream) {
        self.bytes = bytes
        self.start = start
        self.stream = stream
    }

    mutating func byte(_ i: Int) -> Int {
        let k = i - start
        while keys.count <= k { keys.append(stream.next()) }
        return Int(bytes[i] ^ keys[k])
    }
}

extension PSBFile {
    /// Where `count` integer arrays starting at `start` end (nil if they don't read),
    /// never looking past `limit`.
    static func arraysEnd<S: PSBByteSource>(_ source: inout S, at start: Int, count: Int, limit: Int) -> Int? {
        var p = start
        for _ in 0..<count {
            guard p < limit else { return nil }
            let countSize = source.byte(p) - 0xC
            guard (1...4).contains(countSize), p + 1 + countSize < limit else { return nil }
            var n = 0
            for i in 0..<countSize { n |= source.byte(p + 1 + i) << (8 * i) }
            let width = source.byte(p + 1 + countSize) - 0xC
            guard (1...4).contains(width) else { return nil }
            p += 2 + countSize + n * width
            guard p <= limit else { return nil }
        }
        return p
    }
}
