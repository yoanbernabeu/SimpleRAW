import Foundation
import RawEngine

/// The photos of a library and everything said about them: ratings, flags, labels, keywords,
/// albums and adjustments. Thread-safe: the interface and a running import can share it.
public final class PhotoCatalog: Sendable {
    public let database: Database

    public init(url: URL) throws {
        database = try Database(url: url)
        try database.migrate(Self.migrations)
    }

    private init(database: Database) throws {
        self.database = database
        try database.migrate(Self.migrations)
    }

    public static func inMemory() throws -> PhotoCatalog {
        try PhotoCatalog(database: .inMemory())
    }

    /// Append only: a shipped step never changes.
    static let migrations = [
        """
        CREATE TABLE photos (
            id INTEGER PRIMARY KEY,
            relative_path TEXT NOT NULL UNIQUE,
            file_name TEXT NOT NULL,
            content_hash TEXT NOT NULL UNIQUE,
            imported_at REAL NOT NULL,
            captured_at REAL,
            camera TEXT, lens TEXT, iso INTEGER, exposure_time REAL, aperture REAL, focal_length REAL,
            width INTEGER NOT NULL, height INTEGER NOT NULL,
            rating INTEGER NOT NULL DEFAULT 0,
            flag INTEGER NOT NULL DEFAULT 0,
            color_label TEXT,
            adjustments TEXT,
            is_edited INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX photos_captured_at ON photos (captured_at);
        CREATE INDEX photos_rating ON photos (rating);
        CREATE TABLE keywords (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE COLLATE NOCASE);
        CREATE TABLE photo_keywords (
            photo_id INTEGER NOT NULL REFERENCES photos (id) ON DELETE CASCADE,
            keyword_id INTEGER NOT NULL REFERENCES keywords (id) ON DELETE CASCADE,
            PRIMARY KEY (photo_id, keyword_id)
        );
        CREATE TABLE albums (id INTEGER PRIMARY KEY, name TEXT NOT NULL, filter TEXT);
        CREATE TABLE album_photos (
            album_id INTEGER NOT NULL REFERENCES albums (id) ON DELETE CASCADE,
            photo_id INTEGER NOT NULL REFERENCES photos (id) ON DELETE CASCADE,
            PRIMARY KEY (album_id, photo_id)
        )
        """,
        // Edits this version could not read, set aside when new ones were saved over them.
        "ALTER TABLE photos ADD COLUMN unreadable_adjustments TEXT",
        // Names the thumbnail of the edits, so that the grid has nothing to encode or hash.
        // NULL on rows saved before it existed: `Photo` then reads it off the stored JSON.
        "ALTER TABLE photos ADD COLUMN adjustments_fingerprint TEXT",
        // One index per sort of the grid (captured_at has its own already), in the order the
        // sort reads it; partial ones for the states few photos are in; and the two lookups
        // that removing a photo and forgetting unused keywords do on every row otherwise.
        """
        DROP INDEX photos_rating;
        CREATE INDEX photos_rating_captured_at ON photos (rating DESC, captured_at, id);
        CREATE INDEX photos_imported_at ON photos (imported_at, id);
        CREATE INDEX photos_file_name ON photos (file_name COLLATE NOCASE, id);
        CREATE INDEX photos_flag ON photos (flag) WHERE flag != 0;
        CREATE INDEX photos_color_label ON photos (color_label) WHERE color_label IS NOT NULL;
        CREATE INDEX photos_is_edited ON photos (is_edited) WHERE is_edited = 1;
        CREATE INDEX album_photos_photo ON album_photos (photo_id);
        CREATE INDEX photo_keywords_keyword ON photo_keywords (keyword_id);
        """,
        // A counter that every change moves, whoever makes it: what a backup compares instead
        // of copying and hashing the whole catalog to find out that nothing happened. Triggers
        // rather than a line in every method, which the next method would forget. They are
        // part of the schema `validateForeignCatalog` expects.
        """
        CREATE TABLE meta (id INTEGER PRIMARY KEY CHECK (id = 1), revision INTEGER NOT NULL);
        INSERT INTO meta (id, revision) VALUES (1, 0);
        """ + ["photos", "keywords", "photo_keywords", "albums", "album_photos"].flatMap { table in
            ["INSERT", "UPDATE", "DELETE"].map { event in
                "CREATE TRIGGER \(table)_\(event.lowercased())_revision AFTER \(event) ON \(table) BEGIN UPDATE meta SET revision = revision + 1; END;"
            }
        }.joined(separator: "\n"),
        // Several developments of one photo, each under a name: the color one and the black and
        // white one. They go with their photo, and move the revision like everything else.
        """
        CREATE TABLE photo_versions (
            id INTEGER PRIMARY KEY,
            photo_id INTEGER NOT NULL REFERENCES photos (id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            adjustments TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE INDEX photo_versions_photo ON photo_versions (photo_id);
        """ + ["INSERT", "UPDATE", "DELETE"].map { event in
            "CREATE TRIGGER photo_versions_\(event.lowercased())_revision AFTER \(event) ON photo_versions BEGIN UPDATE meta SET revision = revision + 1; END;"
        }.joined(separator: "\n"),
        // What is said about a picture rather than read off the camera. The keywords already
        // have their own tables, because they are shared and counted; these four belong to one
        // photo each, so they are columns. NULL, never an empty string: blank is nothing.
        """
        ALTER TABLE photos ADD COLUMN title TEXT;
        ALTER TABLE photos ADD COLUMN caption TEXT;
        ALTER TABLE photos ADD COLUMN author TEXT;
        ALTER TABLE photos ADD COLUMN copyright TEXT;
        """,
    ]

    // MARK: - Backup

    /// A consistent copy of the catalog in a new file, even while it is in use.
    public func snapshot(to url: URL) throws {
        try database.snapshot(to: url)
    }

    /// Moves with every change to the catalog, and is kept in it: reading it costs one row. A
    /// backup that remembers the revision it last sent knows whether there is anything new
    /// without taking a snapshot.
    public var revision: Int64 {
        get throws { try Self.revision(of: database) }
    }

    /// The revision of a catalog file, read without touching it: what a backup records is the
    /// revision of the snapshot it uploaded, the live catalog may have moved on already.
    public static func revision(ofCatalogAt url: URL) throws -> Int64 {
        try revision(of: .readOnly(url: url))
    }

    private static func revision(of database: Database) throws -> Int64 {
        Int64(try database.query("SELECT revision FROM meta") { try $0.int("revision") }.first ?? 0)
    }

    /// A short value that changes whenever the catalog's content does, and only then.
    public func contentFingerprint() throws -> String {
        try database.contentFingerprint()
    }

    /// The fingerprint of a catalog file, read without touching it: what a backup computes on
    /// the very snapshot it uploads, so that the two can never disagree.
    public static func contentFingerprint(ofCatalogAt url: URL) throws -> String {
        try Database.readOnly(url: url).contentFingerprint()
    }

    // MARK: - Photos

    /// - Throws: if a photo with the same path or the same content is already there.
    @discardableResult
    public func add(_ photo: NewPhoto, importDate: Date = Date()) throws -> Int64 {
        try database.transaction {
            try database.execute(
                """
                INSERT INTO photos (relative_path, file_name, content_hash, imported_at, captured_at, camera, lens, iso,
                                    exposure_time, aperture, focal_length, width, height)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(photo.relativePath), .text(photo.fileName), .text(photo.contentHash),
                    .double(importDate.timeIntervalSince1970), DatabaseValue(photo.captureDate?.timeIntervalSince1970),
                    DatabaseValue(photo.camera), DatabaseValue(photo.lens), DatabaseValue(photo.iso),
                    DatabaseValue(photo.exposureTime), DatabaseValue(photo.aperture), DatabaseValue(photo.focalLength),
                    .int(Int64(photo.width)), .int(Int64(photo.height)),
                ]
            )
            return database.lastInsertedRowID
        }
    }

    public func photo(_ id: Int64) throws -> Photo? {
        try database.query("SELECT * FROM photos WHERE id = ?", [.int(id)], map: Self.photo(from:)).first
    }

    public func photoID(withContentHash hash: String) throws -> Int64? {
        try database.query("SELECT id FROM photos WHERE content_hash = ?", [.text(hash)]) { Int64(try $0.int("id")) }.first
    }

    public func remove(_ ids: [Int64]) throws {
        try database.transaction {
            try update(ids, set: nil, sql: "DELETE FROM photos WHERE id IN")
            try forgetUnusedKeywords()
        }
    }

    public func setRating(_ rating: Int, for ids: [Int64]) throws {
        try update(ids, set: .int(Int64(min(max(rating, 0), 5))), sql: "UPDATE photos SET rating = ? WHERE id IN")
    }

    public func setFlag(_ flag: Flag, for ids: [Int64]) throws {
        try update(ids, set: .int(Int64(flag.rawValue)), sql: "UPDATE photos SET flag = ? WHERE id IN")
    }

    public func setColorLabel(_ label: ColorLabel?, for ids: [Int64]) throws {
        try update(ids, set: DatabaseValue(label?.rawValue), sql: "UPDATE photos SET color_label = ? WHERE id IN")
    }

    /// Neutral adjustments are stored as none at all. Edits that could not be read are set
    /// aside in their own column first: saving never destroys what it did not understand.
    public func setAdjustments(_ adjustments: Adjustments, for id: Int64) throws {
        let isEdited = adjustments != Adjustments()
        let json = isEdited ? try adjustments.jsonData() : nil
        try database.transaction {
            let stored = try database.query("SELECT adjustments FROM photos WHERE id = ?", [.int(id)]) { try $0.optionalString("adjustments") }.first ?? nil
            if let stored, StoredAdjustments.decode(stored) == nil {
                try database.execute("UPDATE photos SET unreadable_adjustments = ? WHERE id = ?", [.text(stored), .int(id)])
            }
            try database.execute(
                "UPDATE photos SET adjustments = ?, adjustments_fingerprint = ?, is_edited = ? WHERE id = ?",
                [
                    DatabaseValue(json.map { String(decoding: $0, as: UTF8.self) }),
                    DatabaseValue(json.map(AdjustmentsFingerprint.of(json:))), .int(isEdited ? 1 : 0), .int(id),
                ]
            )
        }
    }

    /// The edits of a whole selection (a look, a paste, an undo): all saved, or none.
    public func setAdjustments(_ adjustments: [Int64: Adjustments]) throws {
        try database.transaction {
            for (id, adjustments) in adjustments { try setAdjustments(adjustments, for: id) }
        }
    }

    // MARK: - Credits

    /// What is said about one photo, keywords included: the value an export writes into the
    /// file that leaves. One query for the row, one for the keywords.
    public func credits(for id: Int64) throws -> PhotoCredits {
        guard var credits = try photo(id)?.credits else { return PhotoCredits() }
        credits.keywords = try keywords(for: id)
        return credits
    }

    /// Replaces the title, caption, author and copyright of every photo given. Blank clears a
    /// field; the keywords of `credits` are not written here — they have `setKeywords`.
    public func setCredits(_ credits: PhotoCredits, for ids: [Int64]) throws {
        try forEachBatch(of: ids) { placeholders, ids in
            try database.execute(
                "UPDATE photos SET title = ?, caption = ?, author = ?, copyright = ? WHERE id IN (\(placeholders))",
                [DatabaseValue(credits.title), DatabaseValue(credits.caption), DatabaseValue(credits.author), DatabaseValue(credits.copyright)] + ids
            )
        }
    }

    /// Signs a whole shoot: only who made the picture and who owns it, leaving each photo the
    /// title and the caption it has of its own.
    public func setSignature(author: String?, copyright: String?, for ids: [Int64]) throws {
        try forEachBatch(of: ids) { placeholders, ids in
            try database.execute(
                "UPDATE photos SET author = ?, copyright = ? WHERE id IN (\(placeholders))",
                [DatabaseValue(PhotoCredits.nonBlank(author)), DatabaseValue(PhotoCredits.nonBlank(copyright))] + ids
            )
        }
    }

    public func unreadableAdjustments(for id: Int64) throws -> String? {
        try database.query("SELECT unreadable_adjustments FROM photos WHERE id = ?", [.int(id)]) { try $0.optionalString("unreadable_adjustments") }.first ?? nil
    }

    /// `sql` ends right before the list of ids, which is generated as bound parameters.
    private func update(_ ids: [Int64], set value: DatabaseValue?, sql: String) throws {
        try forEachBatch(of: ids) { placeholders, ids in
            try database.execute("\(sql) (\(placeholders))", (value.map { [$0] } ?? []) + ids)
        }
    }

    /// SQLite only takes so many parameters in one statement, and "select all" on a large
    /// library has more ids than that.
    static let batchSize = 500

    /// Hands `body` the ids a few hundred at a time, with as many `?` as there are, all in one
    /// transaction: the change applies to the whole selection or not at all.
    func forEachBatch(of ids: [Int64], _ body: (_ placeholders: String, _ ids: [DatabaseValue]) throws -> Void) throws {
        guard !ids.isEmpty else { return }
        try database.transaction {
            for start in stride(from: 0, to: ids.count, by: Self.batchSize) {
                let batch = ids[start..<min(start + Self.batchSize, ids.count)]
                try body(Array(repeating: "?", count: batch.count).joined(separator: ", "), batch.map(DatabaseValue.int))
            }
        }
    }

    static func photo(from row: Row) throws -> Photo {
        let metadata = FileMetadata(
            captureDate: try row.optionalDouble("captured_at").map(Date.init(timeIntervalSince1970:)),
            camera: try row.optionalString("camera"),
            lens: try row.optionalString("lens"),
            iso: try row.optionalInt("iso"),
            exposureTime: try row.optionalDouble("exposure_time"),
            aperture: try row.optionalDouble("aperture"),
            focalLength: try row.optionalDouble("focal_length"),
            width: try row.int("width"),
            height: try row.int("height")
        )
        let file = NewPhoto(
            relativePath: try row.string("relative_path"), fileName: try row.string("file_name"),
            contentHash: try row.string("content_hash"), metadata: metadata
        )
        // The edits stay as stored: `Photo` decodes them when asked, and one row that cannot
        // be decoded never makes a whole query fail.
        return Photo(
            id: Int64(try row.int("id")),
            file: file,
            importDate: Date(timeIntervalSince1970: try row.double("imported_at")),
            rating: try row.int("rating"),
            flag: Flag(rawValue: try row.int("flag")) ?? .none,
            colorLabel: try row.optionalString("color_label").flatMap(ColorLabel.init(rawValue:)),
            credits: PhotoCredits(
                title: try row.optionalString("title"), caption: try row.optionalString("caption"),
                author: try row.optionalString("author"), copyright: try row.optionalString("copyright")
            ),
            storedAdjustments: try row.optionalString("adjustments"),
            isEdited: try row.int("is_edited") == 1,
            fingerprint: try row.optionalString("adjustments_fingerprint")
        )
    }

    // MARK: - Keywords

    /// Replaces the keywords of a photo. Blank and duplicate entries are dropped.
    public func setKeywords(_ keywords: [String], for id: Int64) throws {
        try setKeywords(keywords, for: [id])
    }

    /// Replaces the keywords of every photo of a selection. To change some and keep the ones
    /// each photo has of its own, see `addKeywords` and `removeKeywords`.
    public func setKeywords(_ keywords: [String], for ids: [Int64]) throws {
        try database.transaction {
            try forEachBatch(of: ids) { placeholders, ids in
                try database.execute("DELETE FROM photo_keywords WHERE photo_id IN (\(placeholders))", ids)
            }
            try link(keywords, to: ids)
            try forgetUnusedKeywords()
        }
    }

    public func addKeywords(_ keywords: [String], to ids: [Int64]) throws {
        try database.transaction { try link(keywords, to: ids) }
    }

    public func removeKeywords(_ keywords: [String], from ids: [Int64]) throws {
        try database.transaction {
            for keyword in Self.cleaned(keywords) {
                try forEachBatch(of: ids) { placeholders, ids in
                    try database.execute(
                        "DELETE FROM photo_keywords WHERE keyword_id IN (SELECT id FROM keywords WHERE name = ?) AND photo_id IN (\(placeholders))",
                        [.text(keyword)] + ids
                    )
                }
            }
            try forgetUnusedKeywords()
        }
    }

    /// The keywords that every photo of the selection has, in a query per few hundred photos
    /// rather than one per photo.
    public func commonKeywords(of ids: [Int64]) throws -> [String] {
        let selection = Array(Set(ids))
        var photosPerKeyword: [Int64: Int] = [:]
        try forEachBatch(of: selection) { placeholders, ids in
            let counts = try database.query(
                "SELECT keyword_id, COUNT(*) AS n FROM photo_keywords WHERE photo_id IN (\(placeholders)) GROUP BY keyword_id", ids
            ) { (Int64(try $0.int("keyword_id")), try $0.int("n")) }
            for (keyword, count) in counts { photosPerKeyword[keyword, default: 0] += count }
        }
        var names: [String] = []
        try forEachBatch(of: photosPerKeyword.filter { $0.value == selection.count }.map(\.key)) { placeholders, ids in
            names += try database.query("SELECT name FROM keywords WHERE id IN (\(placeholders))", ids) { try $0.string("name") }
        }
        return names.sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Two spellings of a keyword are one keyword: the one the catalog already has, if any.
    private func link(_ keywords: [String], to ids: [Int64]) throws {
        for keyword in Self.cleaned(keywords) {
            try database.execute("INSERT OR IGNORE INTO keywords (name) VALUES (?)", [.text(keyword)])
            try forEachBatch(of: ids) { placeholders, ids in
                try database.execute(
                    """
                    INSERT OR IGNORE INTO photo_keywords (photo_id, keyword_id)
                    SELECT photos.id, keywords.id FROM photos, keywords WHERE keywords.name = ? AND photos.id IN (\(placeholders))
                    """,
                    [.text(keyword)] + ids
                )
            }
        }
    }

    private static func cleaned(_ keywords: [String]) -> Set<String> {
        Set(keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    public func keywords(for id: Int64) throws -> [String] {
        try database.query(
            """
            SELECT name FROM keywords JOIN photo_keywords ON keyword_id = keywords.id
            WHERE photo_id = ? ORDER BY name COLLATE NOCASE
            """,
            [.int(id)]
        ) { try $0.string("name") }
    }

    public func allKeywords() throws -> [KeywordCount] {
        try database.query(
            """
            SELECT name, COUNT(photo_id) AS n FROM keywords JOIN photo_keywords ON keyword_id = keywords.id
            GROUP BY keywords.id ORDER BY name COLLATE NOCASE
            """
        ) { KeywordCount(name: try $0.string("name"), count: try $0.int("n")) }
    }

    private func forgetUnusedKeywords() throws {
        try database.execute("DELETE FROM keywords WHERE id NOT IN (SELECT keyword_id FROM photo_keywords)")
    }

    // MARK: - Albums

    @discardableResult
    public func createAlbum(named name: String) throws -> Int64 {
        try database.transaction {
            try database.execute("INSERT INTO albums (name) VALUES (?)", [.text(name)])
            return database.lastInsertedRowID
        }
    }

    public func albums() throws -> [Album] {
        try database.query("SELECT id, name FROM albums WHERE filter IS NULL ORDER BY name COLLATE NOCASE") {
            Album(id: Int64(try $0.int("id")), name: try $0.string("name"))
        }
    }

    public func renameAlbum(_ id: Int64, to name: String) throws {
        try database.execute("UPDATE albums SET name = ? WHERE id = ?", [.text(name), .int(id)])
    }

    public func deleteAlbum(_ id: Int64) throws {
        try database.execute("DELETE FROM albums WHERE id = ?", [.int(id)])
    }

    public func add(_ photos: [Int64], toAlbum album: Int64) throws {
        try forEachBatch(of: photos) { placeholders, ids in
            try database.execute(
                "INSERT OR IGNORE INTO album_photos (album_id, photo_id) SELECT ?, id FROM photos WHERE id IN (\(placeholders))",
                [.int(album)] + ids
            )
        }
    }

    public func remove(_ photos: [Int64], fromAlbum album: Int64) throws {
        try forEachBatch(of: photos) { placeholders, ids in
            try database.execute("DELETE FROM album_photos WHERE album_id = ? AND photo_id IN (\(placeholders))", [.int(album)] + ids)
        }
    }

    public func photoCount(inAlbum album: Int64) throws -> Int {
        try database.query("SELECT COUNT(*) AS n FROM album_photos WHERE album_id = ?", [.int(album)]) { try $0.int("n") }.first ?? 0
    }
}
