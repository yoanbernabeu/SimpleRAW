import Foundation

extension Flag: Codable {}
extension ColorLabel: Codable {}

/// What to show. Every criterion narrows the result; an empty filter matches everything.
/// Codable, because a smart album is nothing but a saved filter.
public struct PhotoFilter: Codable, Equatable, Sendable {
    public var minimumRating = 0
    /// `nil` = any flag.
    public var flags: Set<Flag>?
    public var colorLabels: Set<ColorLabel>?
    /// Every one of them must be on the photo.
    public var keywords: [String] = []
    /// Looked for in file names, camera names, keywords, titles and captions.
    public var text: String?
    public var capturedFrom: Date?
    public var capturedTo: Date?
    public var minimumISO: Int?
    public var maximumISO: Int?
    public var cameras: [String]?
    public var isEdited: Bool?
    public var album: Int64?

    public init(
        minimumRating: Int = 0, flags: Set<Flag>? = nil, colorLabels: Set<ColorLabel>? = nil, keywords: [String] = [],
        text: String? = nil, capturedFrom: Date? = nil, capturedTo: Date? = nil, minimumISO: Int? = nil,
        maximumISO: Int? = nil, cameras: [String]? = nil, isEdited: Bool? = nil, album: Int64? = nil
    ) {
        self.minimumRating = minimumRating
        self.flags = flags
        self.colorLabels = colorLabels
        self.keywords = keywords
        self.text = text
        self.capturedFrom = capturedFrom
        self.capturedTo = capturedTo
        self.minimumISO = minimumISO
        self.maximumISO = maximumISO
        self.cameras = cameras
        self.isEdited = isEdited
        self.album = album
    }

    public var isEmpty: Bool { self == PhotoFilter() }

    /// The conditions of a `WHERE` clause, empty for an empty filter, and their bound values.
    /// Nothing the user typed ends up in the SQL.
    func sql() -> (clause: String, bindings: [DatabaseValue]) {
        var conditions: [String] = []
        var bindings: [DatabaseValue] = []
        func add(_ condition: String, _ values: [DatabaseValue]) {
            conditions.append(condition)
            bindings += values
        }
        func placeholders(_ count: Int) -> String {
            Array(repeating: "?", count: count).joined(separator: ", ")
        }

        if minimumRating > 0 { add("rating >= ?", [.int(Int64(minimumRating))]) }
        if let flags {
            // Said in so many words, or SQLite cannot tell that the partial index applies.
            let flagged = flags.contains(.none) ? "" : "flag != 0 AND "
            add("\(flagged)flag IN (\(placeholders(flags.count)))", flags.map { .int(Int64($0.rawValue)) })
        }
        if let colorLabels { add("color_label IN (\(placeholders(colorLabels.count)))", colorLabels.map { .text($0.rawValue) }) }
        for keyword in keywords {
            add("id IN (SELECT photo_id FROM photo_keywords JOIN keywords ON keyword_id = keywords.id WHERE name = ?)", [.text(keyword)])
        }
        if let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            // LIKE wildcards typed by the user are escaped: they are plain characters.
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            let pattern = DatabaseValue.text("%\(escaped)%")
            add(
                """
                (file_name LIKE ? ESCAPE '\\' OR camera LIKE ? ESCAPE '\\'
                    OR title LIKE ? ESCAPE '\\' OR caption LIKE ? ESCAPE '\\' OR id IN (
                    SELECT photo_id FROM photo_keywords JOIN keywords ON keyword_id = keywords.id WHERE name LIKE ? ESCAPE '\\'))
                """,
                [pattern, pattern, pattern, pattern, pattern]
            )
        }
        if let capturedFrom { add("captured_at >= ?", [.double(capturedFrom.timeIntervalSince1970)]) }
        if let capturedTo { add("captured_at < ?", [.double(capturedTo.timeIntervalSince1970)]) }
        if let minimumISO { add("iso >= ?", [.int(Int64(minimumISO))]) }
        if let maximumISO { add("iso <= ?", [.int(Int64(maximumISO))]) }
        if let cameras { add("camera IN (\(placeholders(cameras.count)))", cameras.map(DatabaseValue.text)) }
        // A literal, for the same reason.
        if let isEdited { add(isEdited ? "is_edited = 1" : "is_edited = 0", []) }
        if let album { add("id IN (SELECT photo_id FROM album_photos WHERE album_id = ?)", [.int(album)]) }

        return (conditions.joined(separator: " AND "), bindings)
    }
}

public enum PhotoSort: Hashable, Sendable {
    case captureDate(ascending: Bool)
    case importDate
    case rating
    case fileName

    var sql: String {
        switch self {
        case .captureDate(let ascending): "ORDER BY captured_at \(ascending ? "ASC" : "DESC"), id \(ascending ? "ASC" : "DESC")"
        case .importDate: "ORDER BY imported_at DESC, id DESC"
        case .rating: "ORDER BY rating DESC, captured_at ASC, id ASC"
        case .fileName: "ORDER BY file_name COLLATE NOCASE ASC, id ASC"
        }
    }
}

public struct SmartAlbum: Identifiable, Equatable, Sendable {
    public let id: Int64
    public var name: String
    public var filter: PhotoFilter
}

extension PhotoCatalog {
    public func photos(matching filter: PhotoFilter, sort: PhotoSort = .captureDate(ascending: false)) throws -> [Photo] {
        try photos(matching: [filter], sort: sort)
    }

    /// The photos that match every one of `filters`: how the filter bar narrows a smart
    /// album. Merging two filters into one would need a rule per criterion, and two searches
    /// have no merged form at all; two clauses joined by AND are exact by construction.
    public func photos(matching filters: [PhotoFilter], sort: PhotoSort = .captureDate(ascending: false)) throws -> [Photo] {
        let (sql, bindings) = Self.select("*", matching: filters, sort: sort)
        return try database.query(sql, bindings, map: Self.photo(from:))
    }

    public func count(matching filter: PhotoFilter) throws -> Int {
        try count(matching: [filter])
    }

    public func count(matching filters: [PhotoFilter]) throws -> Int {
        let (sql, bindings) = Self.select("COUNT(*) AS n", matching: filters, sort: nil)
        return try database.query(sql, bindings) { try $0.int("n") }.first ?? 0
    }

    static func select(_ columns: String, matching filters: [PhotoFilter], sort: PhotoSort?) -> (sql: String, bindings: [DatabaseValue]) {
        let parts = filters.map { $0.sql() }.filter { !$0.clause.isEmpty }
        let clause = parts.isEmpty ? "" : " WHERE " + parts.map { "(\($0.clause))" }.joined(separator: " AND ")
        return ("SELECT \(columns) FROM photos\(clause)\(sort.map { " " + $0.sql } ?? "")", parts.flatMap(\.bindings))
    }

    /// The cameras present in the library, for the filter bar.
    public func cameras() throws -> [String] {
        try database.query("SELECT DISTINCT camera FROM photos WHERE camera IS NOT NULL ORDER BY camera") { try $0.string("camera") }
    }

    /// One month of shooting, as the sidebar lists it.
    public struct CaptureMonth: Equatable, Sendable, Identifiable {
        public let year: Int
        public let month: Int
        public let count: Int

        public var id: Int { year * 100 + month }
    }

    /// The shape of the library in time, newest first: at twenty thousand photos, albums and
    /// keywords no longer say where anything is. One pass over the index on `captured_at`;
    /// photos without a capture date belong to no month.
    ///
    /// Grouped by SQLite, in UTC, exactly as the folders of `Originals` are named: a shoot
    /// sits in the same month in the sidebar and on disk.
    public func captureMonths() throws -> [CaptureMonth] {
        try database.query("""
            SELECT CAST(strftime('%Y', captured_at, 'unixepoch') AS INTEGER) AS year,
                   CAST(strftime('%m', captured_at, 'unixepoch') AS INTEGER) AS month,
                   COUNT(*) AS count
            FROM photos WHERE captured_at IS NOT NULL
            GROUP BY year, month ORDER BY year DESC, month DESC
            """) {
            CaptureMonth(year: try $0.int("year"), month: try $0.int("month"), count: try $0.int("count"))
        }
    }

    // MARK: - Smart albums

    @discardableResult
    public func createSmartAlbum(named name: String, filter: PhotoFilter) throws -> Int64 {
        try database.transaction {
            try database.execute("INSERT INTO albums (name, filter) VALUES (?, ?)", [.text(name), .text(try Self.json(filter))])
            return database.lastInsertedRowID
        }
    }

    public func updateSmartAlbum(_ id: Int64, filter: PhotoFilter) throws {
        try database.execute("UPDATE albums SET filter = ? WHERE id = ?", [.text(try Self.json(filter)), .int(id)])
    }

    public func smartAlbums() throws -> [SmartAlbum] {
        try database.query("SELECT id, name, filter FROM albums WHERE filter IS NOT NULL ORDER BY name COLLATE NOCASE") { row in
            SmartAlbum(
                id: Int64(try row.int("id")),
                name: try row.string("name"),
                filter: try JSONDecoder().decode(PhotoFilter.self, from: Data(try row.string("filter").utf8))
            )
        }
    }

    private static func json(_ filter: PhotoFilter) throws -> String {
        String(decoding: try JSONEncoder().encode(filter), as: UTF8.self)
    }
}
