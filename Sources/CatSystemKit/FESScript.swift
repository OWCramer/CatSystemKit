import Foundation

/// A FES script (`.fes`): CatSystem2's system screens (title, menus, save/load, message
/// window) in its text scripting language. `FES\0`, the packed and inflated sizes, a
/// reserved word, then a zlib stream of CP932 text.
public enum FESScript {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public static func text(_ bytes: [UInt8]) throws -> String {
        guard bytes.starts(with: Array("FES\0".utf8)), bytes.count >= 16 else {
            throw Failure(description: "not a FES script")
        }
        let packed = Int(bytes.le32(4)), size = Int(bytes.le32(8))
        guard 16 + packed <= bytes.count else { throw Failure(description: "FES packed size \(packed)") }
        let body = try Zlib.inflate(bytes[16..<16 + packed], size: size)
        let trimmed = body.prefix { $0 != 0 }
        return String(data: Data(trimmed), encoding: cp932) ?? String(decoding: trimmed, as: UTF8.self)
    }
}
