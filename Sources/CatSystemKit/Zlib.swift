// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Compression
import Foundation

enum Zlib {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Inflates a zlib stream (2-byte header, deflate body) whose inflated size is known.
    /// The size comes from the file, so it is held to what the stream could inflate to and
    /// to `Limits.allocation` before the buffer is made.
    static func inflate(_ input: ArraySlice<UInt8>, size: Int) throws -> [UInt8] {
        guard input.count > 2 else { throw Failure(description: "zlib stream too short") }
        guard size >= 0, size <= Limits.allocation, size / Limits.deflateRatio <= input.count else {
            throw Failure(description: "zlib inflated size \(size) for \(input.count) bytes")
        }
        if size == 0 { return [] }
        let body = input.dropFirst(2)
        var output = [UInt8](repeating: 0, count: size)
        let written = body.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, size, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else {
            throw Failure(description: "zlib inflated \(written) of \(size) bytes")
        }
        return output
    }
}
