import Foundation

/// A CatSystem2 scene script (`.cst`, "CatScene"): the story's text and commands.
///
/// `CatScene`, the packed and inflated sizes, then a zlib stream. Inflated: four `UInt32`s
/// (script length, block count, block table offset, string table offset; offsets count from
/// the end of this 16-byte header), the block table (`count`, first line), the line offset
/// table, then the lines: a `0x01`, a type byte and NUL-terminated CP932 text.
///
/// Types: `0x02` wait for a click, `0x03` page break, `0x20` message text, `0x21` speaker
/// name, `0x30` command, `0xF0` file name, `0xF1` source line number.
public struct CatScene: Sendable {
    public enum Kind: Sendable, Equatable {
        case input
        case page
        case message
        case name
        case command
        case fileName
        case lineNumber
        case other(UInt8)

        init(_ byte: UInt8) {
            switch byte {
            case 0x02: self = .input
            case 0x03: self = .page
            case 0x20: self = .message
            case 0x21: self = .name
            case 0x30: self = .command
            case 0xF0: self = .fileName
            case 0xF1: self = .lineNumber
            default: self = .other(byte)
            }
        }

        public var tag: String {
            switch self {
            case .input: "INPUT"
            case .page: "PAGE"
            case .message: "TEXT"
            case .name: "NAME"
            case .command: "CMD"
            case .fileName: "FILE"
            case .lineNumber: "LINE"
            case .other(let b): String(format: "0x%02X", b)
            }
        }
    }

    public struct Line: Sendable {
        public let kind: Kind
        public let text: String
    }

    public let lines: [Line]
    /// Line ranges between click waits, as the block table gives them.
    public let blocks: [Range<Int>]

    /// A message as the player shows it: an optional speaker and the text lines up to the
    /// next click wait. Messages are numbered in order, which is how `.cstl` translations
    /// refer to them.
    public struct Message: Sendable {
        public let lines: Range<Int>
        public let name: String?
        public let text: String
    }

    public var messages: [Message] {
        var result: [Message] = []
        var start: Int?
        var name: String?
        var text = ""
        func close(_ end: Int) {
            if let s = start, !text.isEmpty { result.append(Message(lines: s..<end, name: name, text: text)) }
            start = nil
            name = nil
            text = ""
        }
        for (i, line) in lines.enumerated() {
            switch line.kind {
            case .name:
                if start == nil { start = i }
                name = line.text
            case .message:
                if start == nil { start = i }
                text += line.text
            case .input, .page:
                close(i + 1)
            default:
                break
            }
        }
        close(lines.count)
        return result
    }

    public enum Failure: Error, CustomStringConvertible {
        case notCatScene
        case malformed(String)

        public var description: String {
            switch self {
            case .notCatScene: "not a CatScene script"
            case .malformed(let why): "CatScene: \(why)"
            }
        }
    }

    public static func isCatScene(_ bytes: [UInt8]) -> Bool { bytes.starts(with: Array("CatScene".utf8)) }

    /// The inflated body.
    public static func inflate(_ bytes: [UInt8]) throws -> [UInt8] {
        guard isCatScene(bytes), bytes.count >= 16 else { throw Failure.notCatScene }
        let packed = Int(bytes.le32(8)), size = Int(bytes.le32(12))
        guard 16 + packed <= bytes.count else { throw Failure.malformed("packed size \(packed)") }
        // A packed size of 0 means the body is stored uncompressed.
        if packed == 0 { return Array(bytes[16..<min(16 + size, bytes.count)]) }
        return try Zlib.inflate(bytes[16..<16 + packed], size: size)
    }

    public init(_ bytes: [UInt8]) throws {
        let body = try Self.inflate(bytes)
        guard body.count >= 16 else { throw Failure.malformed("body too short") }
        let blockCount = Int(body.le32(4))
        let offsetTable = 16 + Int(body.le32(8))
        let stringTable = 16 + Int(body.le32(12))
        guard offsetTable <= stringTable, stringTable <= body.count, 16 + blockCount * 8 <= offsetTable else {
            throw Failure.malformed("tables out of order")
        }
        let lineCount = (stringTable - offsetTable) / 4
        var lines: [Line] = []
        lines.reserveCapacity(lineCount)
        for i in 0..<lineCount {
            let at = stringTable + Int(body.le32(offsetTable + i * 4))
            guard at + 2 <= body.count else { throw Failure.malformed("line \(i) out of range") }
            let raw = body.cString(at + 2, max: body.count - at - 2)
            let text = String(data: Data(raw), encoding: cp932) ?? String(decoding: raw, as: UTF8.self)
            lines.append(Line(kind: Kind(body[at + 1]), text: text))
        }
        var blocks: [Range<Int>] = []
        for b in 0..<blockCount {
            let count = Int(body.le32(16 + b * 8)), first = Int(body.le32(16 + b * 8 + 4))
            if first <= lineCount { blocks.append(first..<min(lineCount, first + max(count, 0))) }
        }
        self.lines = lines
        self.blocks = blocks
    }
}
