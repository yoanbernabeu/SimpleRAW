import Foundation
import Testing
@testable import Catalog

@Suite struct DatabaseTests {
    let database: Database

    init() throws {
        database = try Database.inMemory()
        try database.execute("CREATE TABLE photos (id INTEGER PRIMARY KEY, name TEXT NOT NULL, rating INTEGER, iso REAL)")
    }

    @Test func insertsAndReadsBackEveryKindOfValue() throws {
        try database.execute(
            "INSERT INTO photos (name, rating, iso) VALUES (?, ?, ?)",
            ["R0001.DNG", 4, 400.5]
        )
        let rows = try database.query("SELECT * FROM photos") { row in
            (try row.string("name"), try row.int("rating"), try row.double("iso"))
        }
        #expect(rows.count == 1)
        #expect(rows[0].0 == "R0001.DNG" && rows[0].1 == 4 && rows[0].2 == 400.5)
        #expect(database.lastInsertedRowID == 1)
    }

    @Test func nullIsReadAsNil() throws {
        try database.execute("INSERT INTO photos (name, rating) VALUES (?, ?)", ["a", .null])
        let ratings = try database.query("SELECT rating, iso FROM photos") { (try $0.optionalInt("rating"), try $0.optionalDouble("iso")) }
        #expect(ratings.count == 1 && ratings[0].0 == nil && ratings[0].1 == nil)
    }

    /// Regression: a typo in the name of an optional column read as a silent `nil`.
    @Test func aMissingOptionalColumnIsAnErrorToo() throws {
        try database.execute("INSERT INTO photos (name) VALUES (?)", ["a"])
        #expect(throws: DatabaseError.self) { try database.query("SELECT name FROM photos") { try $0.optionalInt("ratting") } }
        #expect(throws: DatabaseError.self) { try database.query("SELECT name FROM photos") { try $0.optionalDouble("izo") } }
    }

    /// What the user reads says what went wrong; the statement is for whoever debugs.
    @Test func anErrorKeepsItsSQLForTheDebugger() {
        do {
            try database.execute("INSERT INTO nowhere VALUES (1)")
            Issue.record("should have thrown")
        } catch {
            #expect(error.localizedDescription.contains("nowhere") && !error.localizedDescription.contains("INSERT"))
            #expect(!"\(error)".contains("INSERT"))
            #expect(String(reflecting: error).contains("INSERT INTO nowhere"))
        }
    }

    @Test func aFullDiskOrADamagedFileIsSaidInPlainWords() {
        #expect(DatabaseError(message: "database or disk is full", code: 13).localizedDescription.contains("disk is full"))
        #expect(DatabaseError(message: "file is not a database", code: 26).localizedDescription.contains("damaged"))
    }

    /// Parameters are bound, never pasted into the SQL: a quote is just a character.
    @Test func valuesAreBoundNotInterpolated() throws {
        let hostile = "x'); DROP TABLE photos; --"
        try database.execute("INSERT INTO photos (name) VALUES (?)", [.text(hostile)])
        #expect(try database.query("SELECT name FROM photos") { try $0.string("name") } == [hostile])
    }

    @Test func aFailedTransactionLeavesNothingBehind() throws {
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try database.transaction {
                try database.execute("INSERT INTO photos (name) VALUES (?)", ["kept?"])
                throw Boom()
            }
        }
        #expect(try database.query("SELECT COUNT(*) AS n FROM photos") { try $0.int("n") } == [0])
    }

    @Test func aSuccessfulTransactionCommits() throws {
        try database.transaction {
            try database.execute("INSERT INTO photos (name) VALUES (?)", ["a"])
            try database.execute("INSERT INTO photos (name) VALUES (?)", ["b"])
        }
        #expect(try database.query("SELECT COUNT(*) AS n FROM photos") { try $0.int("n") } == [2])
    }

    @Test func invalidSQLIsAnErrorThatSaysWhy() {
        #expect(throws: DatabaseError.self) { try database.execute("SELEC nonsense") }
        do {
            try database.execute("INSERT INTO nowhere VALUES (1)")
        } catch {
            #expect("\(error)".contains("nowhere"))
        }
    }

    /// A catalog can come from a stranger: see `ForeignCatalogTests`.
    @Test func everyConnectionIsHardened() throws {
        #expect(try database.query("PRAGMA trusted_schema") { try $0.int("trusted_schema") } == [0])
        #expect(try database.query("PRAGMA cell_size_check") { try $0.int("cell_size_check") } == [1])
        #expect(try database.query("PRAGMA busy_timeout") { try $0.int("timeout") } == [Int(Database.busyTimeout)])
        // Nothing to switch off: the system SQLite cannot load extensions at all.
        #expect(throws: DatabaseError.self) { try database.execute("SELECT load_extension('anything')") }
    }

    /// Defensive mode, which the system SQLite turns on by itself: no statement, however it
    /// got there, can rewrite the schema by hand. If this fails, `Database` needs a C shim.
    @Test func theSchemaCannotBeEditedBehindSQLitesBack() throws {
        try database.execute("PRAGMA writable_schema = ON")
        #expect(throws: DatabaseError.self) {
            try database.execute("UPDATE sqlite_master SET sql = 'CREATE TABLE photos (id)' WHERE name = 'photos'")
        }
    }

    @Test func aMissingColumnIsAnError() throws {
        try database.execute("INSERT INTO photos (name) VALUES (?)", ["a"])
        #expect(throws: DatabaseError.self) {
            try database.query("SELECT name FROM photos") { try $0.string("nope") }
        }
    }
}

@Suite struct MigrationTests {
    let steps = [
        "CREATE TABLE a (id INTEGER PRIMARY KEY)",
        "ALTER TABLE a ADD COLUMN name TEXT",
    ]

    @Test func migrationsRunOnceAndInOrder() throws {
        let database = try Database.inMemory()
        try database.migrate(steps)
        #expect(try database.userVersion == 2)
        try database.execute("INSERT INTO a (name) VALUES (?)", ["x"])
        // Running again must not try to recreate anything.
        try database.migrate(steps)
        #expect(try database.query("SELECT name FROM a") { try $0.string("name") } == ["x"])
    }

    @Test func anOlderDatabaseOnlyGetsWhatItMisses() throws {
        let database = try Database.inMemory()
        try database.migrate(Array(steps.prefix(1)))
        try database.migrate(steps)
        #expect(try database.userVersion == 2)
        try database.execute("INSERT INTO a (name) VALUES (?)", ["x"])
    }

    /// Regression: steps were cut at every ";\n", which a trigger's body is full of.
    @Test func aStepIsAWholeScript() throws {
        let database = try Database.inMemory()
        try database.migrate(steps + [
            """
            CREATE TABLE log (note TEXT);
            CREATE TRIGGER a_log AFTER INSERT ON a BEGIN
                INSERT INTO log VALUES ('one;
            two');
                INSERT INTO log VALUES (new.name);
            END;
            """,
        ])
        try database.execute("INSERT INTO a (name) VALUES (?)", ["x"])
        #expect(try database.query("SELECT note FROM log ORDER BY rowid") { try $0.string("note") } == ["one;\ntwo", "x"])
    }

    @Test func aStepThatFailsLeavesTheDatabaseAtThePreviousVersion() throws {
        let database = try Database.inMemory()
        #expect(throws: DatabaseError.self) { try database.migrate(steps + ["CREATE TABLE b (id INTEGER); CREATE TABLE nonsense ("]) }
        #expect(try database.userVersion == 2)
        #expect(try database.query("SELECT name FROM sqlite_master WHERE name = 'b'") { try $0.string("name") }.isEmpty)
    }

    /// Regression: an unreadable file read as version 0, which would run the first migration on it.
    @Test func theVersionOfAnUnreadableFileIsAnErrorNotZero() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-db-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 0x41, count: 8192).write(to: file)
        #expect(throws: DatabaseError.self) { try Database.readOnly(url: file).userVersion }
    }

    @Test func aDatabaseFromANewerAppIsRefused() throws {
        let database = try Database.inMemory()
        try database.migrate(steps)
        #expect(throws: DatabaseError.self) { try database.migrate(Array(steps.prefix(1))) }
    }

    @Test func aDatabaseOnDiskSurvivesBeingReopened() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-db-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            let database = try Database(url: file)
            try database.migrate(steps)
            try database.execute("INSERT INTO a (name) VALUES (?)", ["persisted"])
        }
        let reopened = try Database(url: file)
        #expect(try reopened.query("SELECT name FROM a") { try $0.string("name") } == ["persisted"])
    }
}

@Suite struct ContentFingerprintTests {
    private func database(_ statements: String...) throws -> Database {
        let database = try Database.inMemory()
        for statement in statements { try database.execute(statement) }
        return database
    }

    /// Table names are read from the file, which may be forged: a quote is just a character.
    @Test func aTableNamedWithAQuoteIsReadLikeAnyOther() throws {
        let database = try database("CREATE TABLE \"we\"\"ird; --\" (id INTEGER PRIMARY KEY, name TEXT)")
        let empty = try database.contentFingerprint()
        try database.execute("INSERT INTO \"we\"\"ird; --\" (name) VALUES ('a')")
        #expect(try database.contentFingerprint() != empty)
    }

    @Test func aTableWithASingleColumnIsFine() throws {
        let database = try database("CREATE TABLE tags (name TEXT)", "INSERT INTO tags VALUES ('a')")
        #expect(try database.contentFingerprint().count == 64)
    }

    /// Regression: values were joined with commas, so they could slide from one column to the next.
    @Test func aValueCannotPassForTwo() throws {
        let schema = "CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT, b TEXT)"
        let one = try database(schema, "INSERT INTO t (a, b) VALUES ('x,y', 'z')")
        let other = try database(schema, "INSERT INTO t (a, b) VALUES ('x', 'y,z')")
        #expect(try one.contentFingerprint() != other.contentFingerprint())
    }

    @Test func nullIsNotAText() throws {
        let schema = "CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT)"
        let null = try database(schema, "INSERT INTO t (a) VALUES (NULL)")
        let text = try database(schema, "INSERT INTO t (a) VALUES ('∅')")
        let number = try database(schema, "INSERT INTO t (a) VALUES (1)")
        let digit = try database(schema, "INSERT INTO t (a) VALUES ('1')")
        #expect(try null.contentFingerprint() != text.contentFingerprint())
        #expect(try number.contentFingerprint() == digit.contentFingerprint(), "a TEXT column stores 1 as '1'")
    }

    /// The app stores no blob, a file that is not the app's may: it still counts as content.
    @Test func aBlobIsContentToo() throws {
        let schema = "CREATE TABLE t (id INTEGER PRIMARY KEY, payload BLOB)"
        let one = try database(schema, "INSERT INTO t (payload) VALUES (x'0102')")
        let other = try database(schema, "INSERT INTO t (payload) VALUES (x'0103')")
        #expect(try one.contentFingerprint() != other.contentFingerprint())
    }

    /// The order rows were written in is not content: tables without an integer key get new
    /// row ids when a snapshot is taken.
    @Test func theSameContentHasTheSameFingerprint() throws {
        let schema = "CREATE TABLE pairs (a INTEGER NOT NULL, b INTEGER NOT NULL, PRIMARY KEY (a, b))"
        let one = try database(schema, "INSERT INTO pairs VALUES (1, 2)", "INSERT INTO pairs VALUES (1, 1)")
        let other = try database(schema, "INSERT INTO pairs VALUES (1, 1)", "INSERT INTO pairs VALUES (1, 2)")
        #expect(try one.contentFingerprint() == other.contentFingerprint())
        try other.execute("DELETE FROM pairs WHERE b = 2")
        #expect(try one.contentFingerprint() != other.contentFingerprint())
    }
}

/// Hot statements are compiled once and kept. Everything here must hold with or without
/// that: a kept statement is only ever an optimization.
@Suite struct StatementReuseTests {
    let database: Database

    init() throws {
        database = try Database.inMemory()
        try database.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT UNIQUE)")
        for name in ["a", "b", "c"] { try database.execute("INSERT INTO t (name) VALUES (?)", [.text(name)]) }
    }

    private func name(_ id: Int64) throws -> String? {
        try database.query("SELECT name FROM t WHERE id = ?", [.int(id)]) { try $0.string("name") }.first
    }

    @Test func theSameStatementIsCompiledOnce() throws {
        let before = database.compilations
        for id in [1, 2, 3, 2, 1] as [Int64] { _ = try name(id) }
        #expect(database.compilations == before + 1)
    }

    @Test func aStatementRunAgainForgetsItsPreviousValues() throws {
        #expect(try name(1) == "a" && name(3) == "c" && name(9) == nil && name(1) == "a")
        try database.execute("UPDATE t SET name = ? WHERE id = ?", [.null, 1])
        try database.execute("UPDATE t SET name = ? WHERE id = ?", ["z", 2])
        #expect(try name(1) == "" && name(2) == "z")
    }

    /// The statement is in use when the same text is asked for again: the inner call gets its own.
    @Test func aQueryCanRunInsideTheSameQuery() throws {
        let sql = "SELECT id FROM t ORDER BY id"
        let pairs = try database.query(sql) { row in
            (try row.int("id"), try database.query(sql) { try $0.int("id") }.count)
        }
        #expect(pairs.map(\.0) == [1, 2, 3] && pairs.allSatisfy { $0.1 == 3 })
        #expect(try database.query(sql) { try $0.int("id") } == [1, 2, 3])
    }

    @Test func aStatementThatFailedRunsAgain() throws {
        let insert = "INSERT INTO t (name) VALUES (?)"
        #expect(throws: DatabaseError.self) { try database.execute(insert, ["a"]) }
        try database.execute(insert, ["d"])
        #expect(try name(4) == "d")
        // A reader that gives up half way leaves nothing locked either.
        struct Stop: Error {}
        #expect(throws: Stop.self) { try database.query("SELECT id FROM t") { _ in throw Stop() } }
        try database.execute("DROP TABLE t")
    }

    @Test func aKeptStatementSeesAChangeOfSchema() throws {
        #expect(try database.query("SELECT * FROM t WHERE id = 1") { try? $0.string("note") } == [nil])
        try database.execute("ALTER TABLE t ADD COLUMN note TEXT DEFAULT 'new'")
        #expect(try database.query("SELECT * FROM t WHERE id = 1") { try $0.string("note") } == ["new"])
    }

    /// Lists of ids come in every length: texts that differ must not pile up for ever.
    @Test func theNumberOfKeptStatementsIsBounded() throws {
        for count in 1...(Database.keptStatementsLimit * 3) {
            let placeholders = Array(repeating: "?", count: count).joined(separator: ", ")
            _ = try database.query("SELECT id FROM t WHERE id IN (\(placeholders))", (1...count).map { .int(Int64($0)) }) { try $0.int("id") }
        }
        #expect(database.keptStatements <= Database.keptStatementsLimit)
        #expect(try name(2) == "b")
    }

    @Test func transactionsAndSnapshotsStillWork() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-db-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: file) }
        for round in 0..<3 {
            try database.transaction {
                try database.execute("INSERT INTO t (name) VALUES (?)", [.text("round \(round)")])
                try database.transaction { try database.execute("UPDATE t SET name = name || '!' WHERE id = ?", [.int(Int64(4 + round))]) }
            }
            try database.snapshot(to: file)
        }
        #expect(try Database.readOnly(url: file).query("SELECT name FROM t WHERE id = 6") { try $0.string("name") } == ["round 2!"])
    }
}
