import Foundation

/// A CatSystem2 game folder: `startup.xml` (screen size, title, `image.lst`), and every `.int`
/// archive beside the executable, searched by file name. Names inside encrypted archives
/// are unscrambled with the game's name key, recovered from the archives on first open
/// (`KIFArchive.recoverNameKey`) unless the caller already has it.
public final class CatSystemGame: @unchecked Sendable {
    public let root: URL
    public let archives: [KIFArchive]
    public let nameKey: UInt32?
    public let screenWidth: Int
    public let screenHeight: Int
    public let title: String?
    /// Lowercased file name to (archive, entry), the first archive in file order winning.
    private let index: [String: (archive: Int, entry: KIFArchive.Entry)]

    public enum Failure: Error, CustomStringConvertible {
        case notCatSystem(URL)
        case noNameKey

        public var description: String {
            switch self {
            case .notCatSystem(let url): "\(url.lastPathComponent): no .int archives"
            case .noNameKey: "the archives' name key could not be recovered"
            }
        }
    }

    public init(root: URL, nameKey: UInt32? = nil) throws {
        self.root = root
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let ints = files.filter { $0.pathExtension.lowercased() == "int" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !ints.isEmpty else { throw Failure.notCatSystem(root) }
        var archives = try ints.map { try KIFArchive(url: $0) }
        var key = nameKey
        if key == nil, archives.contains(where: { $0.isEncrypted }) {
            // The script archive types best (every entry is a CatScene), so try it first.
            let order = archives.sorted { a, _ in a.url.lastPathComponent.lowercased() == "scene.int" }
            for archive in order where archive.isEncrypted {
                if let found = archive.recoverNameKey() { key = found; break }
            }
            guard key != nil else { throw Failure.noNameKey }
        }
        if let key { for archive in archives where archive.isEncrypted { archive.applyNameKey(key) } }
        archives = archives.filter { !$0.entries.isEmpty }
        self.archives = archives
        self.nameKey = key

        var index: [String: (archive: Int, entry: KIFArchive.Entry)] = [:]
        for (a, archive) in archives.enumerated() {
            for entry in archive.entries where index[entry.name.lowercased()] == nil {
                index[entry.name.lowercased()] = (a, entry)
            }
        }
        self.index = index

        let startup = Self.startup(root.appendingPathComponent("config/startup.xml"))
        screenWidth = Int(startup["SCREEN/width"] ?? "") ?? 1280
        screenHeight = Int(startup["SCREEN/height"] ?? "") ?? 720
        title = startup["APP/title"]
    }

    /// A file by name (`op.cst`, `bg01a.hg3`), searched across every archive.
    public func file(named name: String) throws -> [UInt8]? {
        guard let hit = index[name.lowercased()] else { return nil }
        return try archives[hit.archive].data(for: hit.entry)
    }

    public func contains(_ name: String) -> Bool { index[name.lowercased()] != nil }

    /// Every file name with the given extension, sorted.
    public func names(withExtension ext: String) -> [String] {
        archives.flatMap(\.entries).map(\.name)
            .filter { $0.lowercased().hasSuffix("." + ext.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// `startup.xml` flattened to `SECTION/key` → text for the elements two levels deep.
    static func startup(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        final class Reader: NSObject, XMLParserDelegate {
            var path: [String] = []
            var text = ""
            var values: [String: String] = [:]
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String] = [:]) {
                path.append(name)
                text = ""
            }
            func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                if path.count == 3 { values[path[1] + "/" + path[2]] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                path.removeLast()
                text = ""
            }
        }
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.values
    }
}
