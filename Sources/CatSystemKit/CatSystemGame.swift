// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation

/// A CatSystem2 game folder: `startup.xml` (screen size, title, `image.lst`), and every `.int`
/// archive beside the executable, searched by file name, with a patch folder's loose files
/// and archives over them. Names inside encrypted archives
/// are unscrambled with the game's name key, recovered from the archives on first open
/// (`KIFArchive.recoverNameKey`) unless the caller already has it.
public final class CatSystemGame: @unchecked Sendable {
    public let root: URL
    public let archives: [KIFArchive]
    public let nameKey: UInt32?
    public let screenWidth: Int
    public let screenHeight: Int
    public let title: String?
    /// The patch folder laid over `root`, if any.
    public let patch: URL?
    /// Lowercased file name to (archive, entry): among the game's own archives the first in
    /// file order wins; `patch`'s archives win over those, the last by name winning.
    private let index: [String: (archive: Int, entry: KIFArchive.Entry)]
    /// Lowercased file name to a loose file in `patch`, found before any archive's.
    private let loose: [String: URL]

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

    /// `root` is the game as delivered (`base/`); `patch`, if given, is laid over it (spec, Game
    /// folders and patching): a loose file there is found before any archive's, an `.int`
    /// there replaces the game's archive of that name, and an extra `.int` joins them. Archives
    /// from `patch` win over the game's, a later one (by name) over an earlier one.
    public init(root: URL, patch: URL? = nil, nameKey: UInt32? = nil) throws {
        self.root = root
        self.patch = patch
        let fm = FileManager.default
        func intFiles(_ folder: URL?) -> [URL] {
            guard let folder else { return [] }
            return ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "int" && !$0.lastPathComponent.hasPrefix(".") }
                .sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
        }
        let patchInts = intFiles(patch)
        let replaced = Set(patchInts.map { $0.lastPathComponent.lowercased() })
        let baseInts = intFiles(root).filter { !replaced.contains($0.lastPathComponent.lowercased()) }
        let ints = baseInts + patchInts
        guard !ints.isEmpty else { throw Failure.notCatSystem(root) }
        let patchArchiveURLs = Set(patchInts)
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
            let fromPatch = patchArchiveURLs.contains(archive.url)
            for entry in archive.entries where fromPatch || index[entry.name.lowercased()] == nil {
                index[entry.name.lowercased()] = (a, entry)
            }
        }
        self.index = index

        // Loose files anywhere in patch/ (not its archives), by file name as the archives
        // are searched.
        var loose: [String: URL] = [:]
        if let patch, let walker = fm.enumerator(at: patch, includingPropertiesForKeys: [.isRegularFileKey],
                                                 options: [.skipsHiddenFiles]) {
            for case let url as URL in walker where url.pathExtension.lowercased() != "int" {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let key = url.lastPathComponent.lowercased()
                if loose[key] == nil { loose[key] = url }
            }
        }
        self.loose = loose

        let patchedStartup = patch?.appendingPathComponent("config/startup.xml")
        let startup = Self.startup(patchedStartup.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
            ?? root.appendingPathComponent("config/startup.xml"))
        screenWidth = Int(startup["SCREEN/width"] ?? "") ?? 1280
        screenHeight = Int(startup["SCREEN/height"] ?? "") ?? 720
        title = startup["APP/title"]
    }

    /// A file by name (`op.cst`, `bg01a.hg3`), searched across every archive.
    public func file(named name: String) throws -> [UInt8]? {
        if let url = loose[name.lowercased()] { return [UInt8](try Data(contentsOf: url)) }
        guard let hit = index[name.lowercased()] else { return nil }
        return try archives[hit.archive].data(for: hit.entry)
    }

    public func contains(_ name: String) -> Bool { loose[name.lowercased()] != nil || index[name.lowercased()] != nil }

    /// Where a file is found: a loose file in `patch`, or the archive holding it (paths).
    public func source(of name: String) -> String? {
        if let url = loose[name.lowercased()] { return url.path }
        return index[name.lowercased()].map { archives[$0.archive].url.path }
    }

    /// A file read a piece at a time (a movie of 130 MB), deciphered in memory: its size, and
    /// a reader of `count` bytes from an offset.
    public func stream(named name: String) -> (size: Int, read: @Sendable (Int, Int) -> [UInt8]?)? {
        if let url = loose[name.lowercased()] {
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int else { return nil }
            return (size, { offset, count in
                guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
                defer { try? handle.close() }
                guard (try? handle.seek(toOffset: UInt64(max(0, offset)))) != nil else { return nil }
                return (try? handle.read(upToCount: count)).map { [UInt8]($0) } ?? []
            })
        }
        guard let hit = index[name.lowercased()] else { return nil }
        let archive = archives[hit.archive], entry = hit.entry
        return (entry.size, { offset, count in try? archive.read(entry, at: offset, count: count) })
    }

    /// Every file name with the given extension, sorted.
    public func names(withExtension ext: String) -> [String] {
        var seen = Set<String>()
        return (loose.values.map(\.lastPathComponent) + archives.flatMap(\.entries).map(\.name))
            .filter { $0.lowercased().hasSuffix("." + ext.lowercased()) && seen.insert($0.lowercased()).inserted }
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

extension CatSystemGame {
    /// `nametable.csv` (`config.int`): each speaker as the scenes name them (Japanese) to the
    /// number of their name picture in `sys_meswnd_name_%LANG%` (Chocola 0, Vanilla 1 …).
    public func speakerTable() -> [String: Int] {
        guard let bytes = (try? file(named: "nametable.csv")) ?? nil else { return [:] }
        let text = String(data: Data(bytes), encoding: .utf8) ?? String(data: Data(bytes), encoding: cp932) ?? ""
        var table: [String: Int] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            var id: Int?, name: String?
            if fields.count >= 2, let n = Int(fields[0].trimmingCharacters(in: .whitespaces)) {
                id = n
                name = fields[1].trimmingCharacters(in: .whitespaces)
            } else if let space = line.firstIndex(of: " ") {
                // One row has a space where the tab should be (`115 女の子１`).
                id = Int(line[..<space])
                name = line[line.index(after: space)...].split(separator: "\t").first.map { $0.trimmingCharacters(in: .whitespaces) }
            }
            if let id, let name, !name.isEmpty, table[name] == nil { table[name] = id }
        }
        return table
    }
}
