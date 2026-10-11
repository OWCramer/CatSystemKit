import Foundation

/// A scene's translations (`.cstl`, beside the `.cst` of the same name): for each of the
/// scene's messages, a speaker name and text per language. The Steam release of NEKOPARA
/// ships Chinese, English and Japanese this way; the `.cst` itself holds the Japanese.
///
/// `CSTL`, a reserved word, the language count and their codes, the message count, then
/// for each message and each language a name and a text. Counts and string lengths are
/// stored as a run of `0xFF` bytes (255 each) ended by a byte below `0xFF`; strings are UTF-8.
public struct SceneTranslation: Sendable {
    public struct Message: Sendable {
        public let name: String
        public let text: String
    }

    public let languages: [String]
    /// `messages[i][language]`, in the order of the scene's `TEXT` blocks.
    public let messages: [[String: Message]]

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public static func isTranslation(_ bytes: [UInt8]) -> Bool { bytes.starts(with: Array("CSTL".utf8)) }

    public init(_ bytes: [UInt8]) throws {
        guard Self.isTranslation(bytes), bytes.count >= 9 else { throw Failure(description: "not a CSTL file") }
        var at = 8
        func number() throws -> Int {
            var n = 0
            while true {
                guard at < bytes.count else { throw Failure(description: "CSTL runs off the end") }
                let b = bytes[at]
                at += 1
                n += Int(b)
                if b != 0xFF { return n }
            }
        }
        func string() throws -> String {
            let length = try number()
            guard at + length <= bytes.count else { throw Failure(description: "CSTL string runs off the end") }
            defer { at += length }
            return String(decoding: bytes[at..<at + length], as: UTF8.self)
        }
        let languageCount = try number()
        var languages: [String] = []
        for _ in 0..<languageCount { languages.append(try string()) }
        let count = try number()
        var messages: [[String: Message]] = []
        messages.reserveCapacity(count)
        for _ in 0..<count {
            var entry: [String: Message] = [:]
            for language in languages {
                let name = try string()
                entry[language] = Message(name: name, text: try string())
            }
            messages.append(entry)
        }
        self.languages = languages
        self.messages = messages
        if at != bytes.count {
            throw Failure(description: "CSTL has \(bytes.count - at) bytes after \(count) messages")
        }
    }
}
