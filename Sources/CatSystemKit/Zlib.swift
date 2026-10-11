import Compression
import Foundation

enum Zlib {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Inflates a zlib stream (2-byte header, deflate body) whose inflated size is known.
    static func inflate(_ input: ArraySlice<UInt8>, size: Int) throws -> [UInt8] {
        guard input.count > 2 else { throw Failure(description: "zlib stream too short") }
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
