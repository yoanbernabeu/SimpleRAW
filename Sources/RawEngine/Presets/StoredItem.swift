import Foundation

/// Something a `JSONFileStore` keeps: a named value with a JSON form.
public protocol StoredItem: Sendable {
    var name: String { get }
    func encoded() throws -> Data
    /// - Parameter fallbackName: the name of the file, for documents that carry no name.
    static func decode(from data: Data, fallbackName: String) throws -> Self
}

extension StoredItem where Self: Codable {
    public func encoded() throws -> Data {
        try JSONEncoder.document.encode(self)
    }

    public static func decode(from data: Data, fallbackName: String) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }
}

/// A folder of JSON files, one per item, plus read-only built-ins. Files can be dropped in,
/// edited or removed by hand: the folder is the source of truth, nothing is cached.
///
/// An item is known by its name, whatever its case (on the volumes macOS formats, "Look" and
/// "look" are one file). The name inside a file is the one that counts, not the file's: a
/// file dropped in by hand may be called anything.
public struct JSONFileStore<Item: StoredItem>: Sendable {
    /// An item and the file it came from.
    public struct Entry: Sendable {
        public let item: Item
        /// `nil` for a built-in.
        public let url: URL?

        public var isBuiltIn: Bool { url == nil }
    }

    public let directory: URL
    private let builtIns: [Item]

    public init(directory: URL, builtIns: [Item] = []) {
        self.directory = directory
        self.builtIns = builtIns
    }

    /// Every item, sorted by name. A user item replaces a built-in of the same name, and
    /// files that cannot be read are skipped rather than failing the whole list.
    public func all() -> [Item] {
        entries().map(\.item)
    }

    /// Every item with the file it came from. Of several files carrying the same name, the
    /// most recent one is the item.
    public func entries() -> [Entry] {
        var names = Set<String>()
        let saved = savedFiles().filter { names.insert(Self.key($0.item.name)).inserted }
        let shipped = builtIns.filter { !names.contains(Self.key($0.name)) }.map { Entry(item: $0, url: nil) }
        return (shipped + saved).sorted { $0.item.name.localizedCaseInsensitiveCompare($1.item.name) == .orderedAscending }
    }

    /// Updates the file the item lives in, if it has one; else writes a new file, named after
    /// the item, and never over a file that holds something else: "a/b", "a:b" and "a-b" all
    /// want the same file name, and the last one saved used to wipe the others out.
    public func save(_ item: Item) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let current = savedFiles().first { Self.key($0.item.name) == Self.key(item.name) }?.url
        try item.encoded().write(to: current ?? FileName.free(file(named: item.name)), options: .atomic)
    }

    /// Removes every file carrying that name, wherever the name of the file says: an older
    /// twin must not come back. Built-ins cannot be deleted; asking to is not an error.
    public func delete(named name: String) throws {
        for entry in savedFiles() where Self.key(entry.item.name) == Self.key(name) {
            if let url = entry.url { try FileManager.default.removeItem(at: url) }
        }
    }

    /// Whether `name` is a built-in that no file of that name replaces. Costs one look at the
    /// file system, so that a view may ask: it does not see a file dropped in by hand under
    /// another file name, which `entries()` does (`Entry.isBuiltIn`).
    public func isBuiltIn(_ name: String) -> Bool {
        builtIns.contains { Self.key($0.name) == Self.key(name) } && !FileManager.default.fileExists(atPath: file(named: name).path)
    }

    /// Every readable file of the folder, most recent first.
    private func savedFiles() -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { file -> (entry: Entry, date: Date)? in
                guard let data = try? DocumentFile.data(contentsOf: file),
                      let item = try? Item.decode(from: data, fallbackName: file.deletingPathExtension().lastPathComponent) else { return nil }
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (Entry(item: item, url: file), date)
            }
            .sorted { $0.date > $1.date }
            .map(\.entry)
    }

    /// What makes two names the same item.
    private static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    private func file(named name: String) -> URL {
        let safe = FileName.sanitized(name, fallback: FileName.lastResort, reserving: ".json".utf8.count + 4)
        return directory.appendingPathComponent(safe).appendingPathExtension("json")
    }
}

extension JSONFileStore {
    /// What a user typed: the name of an item, whatever its case, unless it reads as a path,
    /// with a separator or the `.json` extension. A name is never looked up as a file: one
    /// called "Web" lying in the current folder would be read in place of the look.
    public func resolve(_ nameOrPath: String) throws -> Item {
        if nameOrPath.contains("/") || nameOrPath.lowercased().hasSuffix(".json") {
            let file = URL(fileURLWithPath: nameOrPath)
            return try Item.decode(from: DocumentFile.data(contentsOf: file), fallbackName: file.deletingPathExtension().lastPathComponent)
        }
        let items = all()
        guard let match = items.first(where: { $0.name.caseInsensitiveCompare(nameOrPath) == .orderedSame }) else {
            throw RawEngineError.unknownPreset(nameOrPath, available: items.map(\.name))
        }
        return match
    }

    /// `~/Library/Application Support/SimpleRAW/<folder>`.
    public static func applicationSupport(_ folder: String, builtIns: [Item]) -> JSONFileStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return JSONFileStore(directory: base.appendingPathComponent("SimpleRAW").appendingPathComponent(folder), builtIns: builtIns)
    }
}
