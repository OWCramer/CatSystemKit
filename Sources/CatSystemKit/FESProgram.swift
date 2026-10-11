import Foundation

/// A parsed FES script. The text is a list of `#` sections:
/// - `#MACRO`: `NAME value` substitutions;
/// - `#SUBCOMMAND`: the motion words objects accept (`fade`, `move` …), read for reference;
/// - `#DEFINE`: objects, `TYPE name` or `TYPE name[count]` (`PLANE`, `CPLANE`, `IMAGE`,
///   `CIMAGE`, `BUTTON`, `SOUND`, `SNDTABLE` …);
/// - `#OBJECT COLUMN …`: a table setting those columns on objects, one row per object
///   (`name` sets every element of an array, `name[i]` one);
/// - `#PRELOAD`, `#KEYBLOCK`, `#SYSVOICE…`: preload lists, key navigation, and plain labels;
/// - any other `#LABEL`: a block of statements, entered at `#START`. `#object.EVENT`
///   (`FOCUS`, `UNFOCUS`, `PUSH_L` …) blocks run when a button gets that event.
public struct FESProgram: Sendable {
    public struct Definition: Sendable {
        public let type: String
        public let name: String
        public let count: Int?
    }

    public struct Table: Sendable {
        public let columns: [String]
        /// (object name as written, values in column order).
        public let rows: [(String, [String])]
    }

    public let macros: [String: String]
    public let definitions: [Definition]
    public let tables: [Table]
    public let blocks: [String: [String]]
    public let labelOrder: [String]

    public init(text: String) {
        var macros: [String: String] = [:]
        var definitions: [Definition] = []
        var tables: [Table] = []
        var blocks: [String: [String]] = [:]
        var labelOrder: [String] = []

        enum Section { case macro, subcommand, define, object([String]), ignore, block(String) }
        var section = Section.ignore
        var rows: [(String, [String])] = []
        func closeTable() {
            if case .object(let columns) = section { tables.append(Table(columns: columns, rows: rows)) }
            rows = []
        }
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("//") || line.hasPrefix(";") { continue }
            if line.hasPrefix("#") {
                closeTable()
                let words = line.dropFirst().split(separator: " ").map(String.init)
                let head = words.first ?? ""
                switch head {
                case "MACRO": section = .macro
                case "SUBCOMMAND": section = .subcommand
                case "DEFINE": section = .define
                case "OBJECT": section = .object(Array(words.dropFirst()))
                case "PRELOAD", "KEYBLOCK": section = .ignore
                default:
                    section = .block(head)
                    if blocks[head] == nil { labelOrder.append(head) }
                    blocks[head] = []
                }
                continue
            }
            let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            switch section {
            case .macro:
                if words.count >= 2 { macros[words[0]] = words[1] }
            case .define:
                guard words.count >= 2 else { continue }
                var name = words[1]
                var count: Int?
                if let open = name.firstIndex(of: "["), let close = name.firstIndex(of: "]") {
                    count = Int(name[name.index(after: open)..<close])
                    name = String(name[..<open])
                }
                definitions.append(Definition(type: words[0], name: name, count: count))
            case .object:
                if let first = words.first { rows.append((first, Array(words.dropFirst()))) }
            case .block(let label):
                blocks[label, default: []].append(line)
            case .subcommand, .ignore:
                break
            }
        }
        closeTable()
        self.macros = macros
        self.definitions = definitions
        self.tables = tables
        self.blocks = blocks
        self.labelOrder = labelOrder
    }
}
