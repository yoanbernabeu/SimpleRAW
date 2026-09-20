import Foundation
import RawEngine

/// One development of a photo, kept under a name next to the current one.
public struct PhotoVersion: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let photoID: Int64
    public var name: String
    public let createdAt: Date
    let adjustmentsJSON: String

    /// Decoded when asked for: a list of versions shows names.
    public var adjustments: Adjustments {
        get throws { try JSONDecoder().decode(Adjustments.self, from: Data(adjustmentsJSON.utf8)) }
    }
}

public enum PhotoVersionError: LocalizedError {
    case blankName

    public var errorDescription: String? { "A version needs a name." }
}

extension PhotoCatalog {
    /// Oldest first: the order they were made in.
    public func versions(of photo: Int64) throws -> [PhotoVersion] {
        try database.query("SELECT * FROM photo_versions WHERE photo_id = ? ORDER BY created_at, id", [.int(photo)]) { row in
            PhotoVersion(
                id: Int64(try row.int("id")), photoID: Int64(try row.int("photo_id")), name: try row.string("name"),
                createdAt: Date(timeIntervalSince1970: try row.double("created_at")), adjustmentsJSON: try row.string("adjustments")
            )
        }
    }

    @discardableResult
    public func saveVersion(named name: String, of photo: Int64, adjustments: Adjustments, at date: Date = Date()) throws -> Int64 {
        let name = try Self.versionName(name)
        let json = String(decoding: try adjustments.jsonData(), as: UTF8.self)
        return try database.transaction {
            try database.execute(
                "INSERT INTO photo_versions (photo_id, name, adjustments, created_at) VALUES (?, ?, ?, ?)",
                [.int(photo), .text(name), .text(json), .double(date.timeIntervalSince1970)]
            )
            return try database.query("SELECT last_insert_rowid() AS id") { Int64(try $0.int("id")) }.first ?? 0
        }
    }

    public func renameVersion(_ id: Int64, to name: String) throws {
        try database.execute("UPDATE photo_versions SET name = ? WHERE id = ?", [.text(try Self.versionName(name)), .int(id)])
    }

    public func deleteVersion(_ id: Int64) throws {
        try database.execute("DELETE FROM photo_versions WHERE id = ?", [.int(id)])
    }

    private static func versionName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PhotoVersionError.blankName }
        return trimmed
    }
}
