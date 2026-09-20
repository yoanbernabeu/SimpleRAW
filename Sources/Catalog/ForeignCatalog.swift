import Foundation

/// Why a catalog that came from elsewhere is not opened.
public enum ForeignCatalogError: LocalizedError, Equatable {
    /// SQLite's own check found the file inconsistent.
    case damaged(String)
    case newerVersion(Int)
    /// A table, index, trigger or view that the app's migrations do not create, or not that way.
    case unexpectedSchema(String)

    public var errorDescription: String? {
        switch self {
        case .damaged: "This catalog is damaged and cannot be opened."
        case .newerVersion: "This catalog was written by a newer version of SimpleRAW."
        case .unexpectedSchema(let object): "This catalog was not written by SimpleRAW: it contains an unknown \(object)."
        }
    }
}

public struct ForeignCatalogReport: Equatable, Sendable {
    public var photoCount = 0
    /// Photos whose `relative_path` does not stay under the originals. `Library.url(for:)`
    /// never follows them; they are listed so that a restore can say which photos are lost.
    public var escapingPaths: [String] = []
}

extension PhotoCatalog {
    /// Checks a catalog file that the app did not write itself, **before** it is opened for
    /// real: a restore calls this on what it downloaded. The file is opened read-only and left
    /// untouched.
    /// - Throws: `ForeignCatalogError` when the file is damaged, from a newer version, or holds
    ///   anything the migrations do not create: a trigger or a view would run inside the app.
    public static func validateForeignCatalog(at url: URL) throws -> ForeignCatalogReport {
        // What SQLite cannot even open or read is damaged, as far as a restore is concerned: a
        // file that is not a database, or one that needs companion files that did not come.
        let foreign: Database
        let problems: [String]
        do {
            foreign = try Database.readOnly(url: url)
            problems = try foreign.query("PRAGMA quick_check") { try $0.string("quick_check") }
        } catch let error as DatabaseError {
            throw ForeignCatalogError.damaged(error.localizedDescription)
        }
        guard problems == ["ok"] else { throw ForeignCatalogError.damaged(problems.first ?? "") }

        let version = try foreign.userVersion
        guard version <= migrations.count else { throw ForeignCatalogError.newerVersion(version) }
        // What this very version creates, or an older app did: the migrations are append-only.
        let reference = try Database.inMemory()
        try reference.migrate(Array(migrations.prefix(version)))
        let (expected, found) = (try schema(of: reference), try schema(of: foreign))
        for (name, object) in found where expected[name] != object {
            throw ForeignCatalogError.unexpectedSchema("\(object.type) named \(name)")
        }
        for name in expected.keys where found[name] == nil {
            throw ForeignCatalogError.unexpectedSchema("schema, without \(name)")
        }

        var report = ForeignCatalogReport()
        _ = try foreign.query("SELECT relative_path FROM photos") { row in
            report.photoCount += 1
            let path = try row.string("relative_path")
            if !Library.isConfined(relativePath: path) { report.escapingPaths.append(path) }
        }
        return report
    }

    private struct SchemaObject: Equatable {
        let type: String
        let table: String
        let sql: String
    }

    private static func schema(of database: Database) throws -> [String: SchemaObject] {
        let objects = try database.query("SELECT type, name, tbl_name, sql FROM sqlite_master") { row in
            // Compared as text, spacing aside: the same migrations write the same definitions.
            let sql = (try row.optionalString("sql") ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return (try row.string("name"), SchemaObject(type: try row.string("type"), table: try row.string("tbl_name"), sql: sql))
        }
        return Dictionary(objects, uniquingKeysWith: { first, _ in first })
    }
}
