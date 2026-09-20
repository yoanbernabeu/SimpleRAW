import CryptoKit
import Foundation
import SQLite3

/// What SQLite refused, in two voices: `localizedDescription` (and `"\(error)"`) is for the
/// person in front of the app, `debugDescription` adds the statement for whoever debugs.
public struct DatabaseError: LocalizedError, CustomStringConvertible, CustomDebugStringConvertible, Equatable {
    /// SQLite's own words.
    public let message: String
    /// SQLite's primary result code.
    public let code: Int32
    public let sql: String?

    public init(message: String, code: Int32 = SQLITE_ERROR, sql: String? = nil) {
        self.message = message
        self.code = code
        self.sql = sql
    }

    public var errorDescription: String? {
        switch code {
        case SQLITE_FULL: "The disk is full: the catalog could not be saved."
        case SQLITE_BUSY, SQLITE_LOCKED: "The catalog is in use by another program. Try again in a moment."
        case SQLITE_CORRUPT, SQLITE_NOTADB: "The catalog is damaged (\(message))."
        case SQLITE_READONLY, SQLITE_PERM, SQLITE_CANTOPEN, SQLITE_IOERR:
            "The catalog cannot be read or written (\(message)). Check the disk and the permissions of the library."
        case SQLITE_CONSTRAINT: "The catalog refused this change (\(message))."
        default: "The catalog reported an error: \(message)."
        }
    }

    public var description: String { errorDescription ?? message }
    public var debugDescription: String { "SQLite error \(code): \(message)" + (sql.map { " — in: \($0)" } ?? "") }
}

/// A value bound to a `?` of a statement. Literals work as is: `[4, "name", 1.5]`.
public enum DatabaseValue: Equatable, Sendable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
}

extension DatabaseValue: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByNilLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .text(value) }
    public init(nilLiteral: ()) { self = .null }

    public init(_ value: Int?) { self = value.map { .int(Int64($0)) } ?? .null }
    public init(_ value: Double?) { self = value.map(DatabaseValue.double) ?? .null }
    public init(_ value: String?) { self = value.map(DatabaseValue.text) ?? .null }
}

/// A thin layer over the SQLite that ships with macOS: bound parameters, typed rows,
/// transactions, migrations. One connection, serialized by SQLite itself and by a lock, so
/// that an import running in the background and the interface can share it.
public final class Database: @unchecked Sendable {
    private let handle: OpaquePointer
    /// `nil` for a database in memory, which no other connection can reach.
    private let path: String?
    private let lock = NSRecursiveLock()
    /// Guarded by `lock`. For tests: told of every statement this connection runs.
    private var statementObserver: (() -> Void)?
    /// Guarded by `lock`. Compiled statements that are not running, by their text: compiling
    /// one costs more than running it for the small queries the interface makes all day.
    private var idleStatements: [String: OpaquePointer] = [:]
    /// Guarded by `lock`. How many statements were compiled, for tests.
    private(set) var compilations = 0
    static let keptStatementsLimit = 32
    var keptStatements: Int { lock.withLock { idleStatements.count } }
    /// Guarded by `lock`.
    private var transactionDepth = 0

    public convenience init(url: URL) throws {
        try FileManager.default.createPrivateDirectory(at: url.deletingLastPathComponent())
        // Private to its user (0600) before SQLite opens it: the journal files it creates
        // next to a database copy its permissions.
        if !Self.createPrivateFile(atPath: url.path) {
            for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path + suffix)
            }
        }
        try self.init(path: url.path)
    }

    /// - Returns: whether the file was created; `false` leaves the one that is there untouched.
    private static func createPrivateFile(atPath path: String) -> Bool {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    public static func inMemory() throws -> Database {
        try Database(path: ":memory:")
    }

    /// Opens a file to look at it, and changes nothing in it: no journal mode, no schema.
    public static func readOnly(url: URL) throws -> Database {
        try Database(path: url.path, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, configure: false)
    }

    private init(path: String, flags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, configure: Bool = true) throws {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path, &connection, flags, nil) == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(connection)
            throw DatabaseError(message: message, code: SQLITE_CANTOPEN)
        }
        handle = connection
        self.path = path == ":memory:" ? nil : path
        try harden()
        guard configure else { return }
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
        // Said rather than left to the build's default, and FULL on purpose: NORMAL would be
        // faster and safe against a crash of the app, but a power cut could then lose the last
        // edits, and "no data loss" is a requirement of this app where speed of commit is not.
        try execute("PRAGMA synchronous = FULL")
    }

    /// How long a statement waits for another connection's lock before giving up.
    static let busyTimeout: Int32 = 5000

    /// A catalog file may have been written by a stranger (a restore, a shared disk), and
    /// forged SQLite files are a classic way in: every connection, read-only ones included,
    /// distrusts what the schema asks it to run and checks the pages it reads. Two more
    /// protections need no switch, and could not get one from Swift anyway (`sqlite3_db_config`
    /// is variadic): the SQLite of macOS opens every connection in defensive mode and is built
    /// without extension loading. Tests pin both, should a system ever ship otherwise.
    private func harden() throws {
        sqlite3_busy_timeout(handle, Self.busyTimeout)
        try execute("PRAGMA trusted_schema = OFF")
        try execute("PRAGMA cell_size_check = ON")
    }

    deinit {
        // A connection does not close while it has statements.
        for statement in idleStatements.values { sqlite3_finalize(statement) }
        sqlite3_close(handle)
    }

    // MARK: - Statements

    public func execute(_ sql: String, _ bindings: [DatabaseValue] = []) throws {
        try lock.withLock {
            let statement = try prepare(sql, bindings)
            defer { release(statement, sql) }
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW { status = sqlite3_step(statement) }
            guard status == SQLITE_DONE else { throw lastError(sql) }
        }
    }

    public func query<T>(_ sql: String, _ bindings: [DatabaseValue] = [], map: (Row) throws -> T) throws -> [T] {
        try lock.withLock {
            let statement = try prepare(sql, bindings)
            defer { release(statement, sql) }
            var results: [T] = []
            var row: Row?
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    // Columns are named once per query, and only now: a kept statement is compiled
                    // again by its first step if the schema changed, and `*` may have grown.
                    let current = row ?? Row(statement: statement)
                    row = current
                    results.append(try map(current))
                case SQLITE_DONE: return results
                default: throw lastError(sql)
                }
            }
        }
    }

    public var lastInsertedRowID: Int64 {
        lock.withLock { sqlite3_last_insert_rowid(handle) }
    }

    /// Everything in `body` is kept, or nothing is. Transactions nest: an inner one is a
    /// savepoint, so that an operation made of smaller atomic ones is atomic as a whole.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            let depth = transactionDepth
            let (begin, commit, rollback) = depth == 0
                ? ("BEGIN IMMEDIATE", "COMMIT", "ROLLBACK")
                : ("SAVEPOINT nested_\(depth)", "RELEASE nested_\(depth)", "ROLLBACK TO nested_\(depth)")
            try execute(begin)
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            do {
                let result = try body()
                try execute(commit)
                return result
            } catch {
                try? execute(rollback)
                if depth > 0 { try? execute("RELEASE nested_\(depth)") }
                throw error
            }
        }
    }

    /// A consistent copy of the whole database in a new file, even while it is in use. Made
    /// on a connection of its own, open for that long only: copying a large catalog takes a
    /// second, during which this one's lock stays free for the interface. In WAL mode a reader
    /// never blocks the writer either.
    public func snapshot(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let source = try path.map { try Database(path: $0, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, configure: false) } ?? self
        try source.execute("VACUUM INTO ?", [.text(url.path)])
    }

    /// For tests: runs `body`, reporting every statement that goes through this connection.
    func countingStatements<T>(_ observer: @escaping () -> Void, _ body: () throws -> T) rethrows -> T {
        lock.withLock { statementObserver = observer }
        defer { lock.withLock { statementObserver = nil } }
        return try body()
    }

    /// Changes whenever the content does, and only then: SQLite's own data version counter
    /// would not survive a reopen, a snapshot's bytes are not stable either. Hashed row by
    /// row, never held in memory as a whole, every value with its type and its length, so
    /// that no two contents read the same.
    public func contentFingerprint() throws -> String {
        try lock.withLock {
            var hasher = SHA256()
            let tables = try query("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name") { try $0.string("name") }
            for table in tables {
                // Both names come from the file, which may not be ours: quoted, never pasted.
                let columns = try query("PRAGMA table_info(\(Self.quoted(table)))") { try $0.string("name") }
                hasher.update(field: .table, Data(table.utf8))
                hasher.update(field: .integer, withUnsafeBytes(of: Int64(columns.count).littleEndian) { Data($0) })
                // By every column: row ids are not content, a snapshot renumbers them.
                let order = columns.map(Self.quoted).joined(separator: ", ")
                _ = try query("SELECT * FROM \(Self.quoted(table)) ORDER BY \(order)") { $0.feed(&hasher) }
            }
            return ContentHash.hex(hasher.finalize())
        }
    }

    /// An identifier as SQL reads it literally, whatever it contains.
    static func quoted(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Migrations

    /// SQLite's own slot for a schema version.
    public var userVersion: Int {
        get throws {
            // Never a silent 0: that would run the first migration on a file that cannot be read.
            guard let version = try query("PRAGMA user_version", map: { try $0.int("user_version") }).first else {
                throw DatabaseError(message: "the schema version cannot be read")
            }
            return version
        }
    }

    /// Runs the steps this database has not seen yet, in order, each in its own transaction.
    /// A database written by a newer app, with more steps than this one knows, is refused
    /// rather than misread.
    public func migrate(_ steps: [String]) throws {
        let current = try userVersion
        guard current <= steps.count else {
            throw DatabaseError(message: "database is at version \(current), this app only knows \(steps.count)")
        }
        for (index, step) in steps.enumerated().dropFirst(current) {
            try transaction {
                try run(script: step)
                try execute("PRAGMA user_version = \(index + 1)")
            }
        }
    }

    /// Several statements at once, split by SQLite itself: only it knows where one ends.
    private func run(script: String) throws {
        guard sqlite3_exec(handle, script, nil, nil, nil) == SQLITE_OK else { throw lastError(script) }
    }

    // MARK: - Internals

    /// SQLite must copy the bytes it is given: they do not outlive the call.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ bindings: [DatabaseValue]) throws -> OpaquePointer {
        statementObserver?()
        let statement = try idleStatement(sql) ?? compile(sql)
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32 = switch value {
            case .null: sqlite3_bind_null(statement, index)
            case .int(let value): sqlite3_bind_int64(statement, index, value)
            case .double(let value): sqlite3_bind_double(statement, index, value)
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, Self.transient)
            }
            guard status == SQLITE_OK else {
                let error = lastError(sql)
                sqlite3_finalize(statement)
                throw error
            }
        }
        return statement
    }

    private func compile(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError(sql)
        }
        compilations += 1
        return statement
    }

    /// Taken out while it runs: the same text asked for again meanwhile (a query inside a
    /// query) compiles its own, and never finds a statement half way through its rows.
    private func idleStatement(_ sql: String) -> OpaquePointer? {
        idleStatements.removeValue(forKey: sql)
    }

    /// Reset, so that it holds no lock and no row, and without its values, so that none
    /// outlives the call that bound it. SQLite compiles it again by itself if the schema changes.
    private func release(_ statement: OpaquePointer, _ sql: String) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        // Lists of ids come in every length: start over rather than grow without end.
        if idleStatements.count >= Self.keptStatementsLimit {
            for statement in idleStatements.values { sqlite3_finalize(statement) }
            idleStatements.removeAll(keepingCapacity: true)
        }
        if let other = idleStatements.updateValue(statement, forKey: sql) { sqlite3_finalize(other) }
    }

    private func lastError(_ sql: String) -> DatabaseError {
        DatabaseError(message: String(cString: sqlite3_errmsg(handle)), code: sqlite3_errcode(handle), sql: sql)
    }
}

private enum FingerprintField: UInt8 {
    case null, integer, real, text, blob, table
}

extension SHA256 {
    /// Kind, length, bytes: two different sequences of fields never hash the same bytes.
    fileprivate mutating func update(field: FingerprintField, _ bytes: Data) {
        update(data: [field.rawValue])
        withUnsafeBytes(of: Int64(bytes.count).littleEndian) { update(bufferPointer: $0) }
        update(data: bytes)
    }
}

/// The current row of a query. Only valid inside the `map` closure it is handed to.
public struct Row {
    fileprivate let statement: OpaquePointer
    /// Resolved once per query: looking a name up again for every value of every row was most
    /// of what reading a large library cost.
    private let columns: [String: Int32]

    fileprivate init(statement: OpaquePointer) {
        self.statement = statement
        var columns: [String: Int32] = [:]
        for index in (0..<sqlite3_column_count(statement)).reversed() {
            // Reversed, so that the first of two columns of the same name wins.
            columns[String(cString: sqlite3_column_name(statement, index))] = index
        }
        self.columns = columns
    }

    public func int(_ column: String) throws -> Int {
        Int(sqlite3_column_int64(statement, try index(of: column)))
    }

    public func double(_ column: String) throws -> Double {
        sqlite3_column_double(statement, try index(of: column))
    }

    public func string(_ column: String) throws -> String {
        try optionalString(column) ?? ""
    }

    public func optionalInt(_ column: String) throws -> Int? {
        let index = try index(of: column)
        return sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, index))
    }

    public func optionalDouble(_ column: String) throws -> Double? {
        let index = try index(of: column)
        return sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
    }

    public func optionalString(_ column: String) throws -> String? {
        let index = try index(of: column)
        return sqlite3_column_text(statement, index).map { String(cString: $0) }
    }

    /// Every value of the row, as stored.
    fileprivate func feed(_ hasher: inout SHA256) {
        for index in 0..<sqlite3_column_count(statement) {
            switch sqlite3_column_type(statement, index) {
            case SQLITE_NULL:
                hasher.update(field: .null, Data())
            case SQLITE_INTEGER:
                hasher.update(field: .integer, withUnsafeBytes(of: sqlite3_column_int64(statement, index).littleEndian) { Data($0) })
            case SQLITE_FLOAT:
                hasher.update(field: .real, withUnsafeBytes(of: sqlite3_column_double(statement, index).bitPattern.littleEndian) { Data($0) })
            case SQLITE_TEXT:
                let bytes = sqlite3_column_text(statement, index)
                hasher.update(field: .text, bytes.map { Data(bytes: $0, count: Int(sqlite3_column_bytes(statement, index))) } ?? Data())
            default:
                let bytes = sqlite3_column_blob(statement, index)
                hasher.update(field: .blob, bytes.map { Data(bytes: $0, count: Int(sqlite3_column_bytes(statement, index))) } ?? Data())
            }
        }
    }

    private func index(of column: String) throws -> Int32 {
        guard let index = columns[column] else { throw DatabaseError(message: "no column named \(column)") }
        return index
    }
}
