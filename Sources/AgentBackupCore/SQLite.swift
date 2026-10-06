import Foundation
import SQLite3

enum SQLiteError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let m) = self { m } else { nil } }
}

/// Minimal SQLite access for the few statements this app runs against agents' databases.
func sqliteExecute(_ database: URL, _ sql: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
        defer { sqlite3_close(db) }
        throw SQLiteError.failed("Cannot open \(database.lastPathComponent): \(String(cString: sqlite3_errmsg(db)))")
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 5000)
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
        let message = error.map { String(cString: $0) } ?? "unknown error"
        sqlite3_free(error)
        throw SQLiteError.failed("\(database.lastPathComponent): \(message)")
    }
}

/// True if `table` exists in the database.
func sqliteHasTable(_ database: URL, _ table: String) -> Bool {
    var db: OpaquePointer?
    guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        sqlite3_close(db)
        return false
    }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", -1, &statement, nil) == SQLITE_OK else { return false }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, table, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    return sqlite3_step(statement) == SQLITE_ROW
}

extension BackupEngine {
    static func perform(_ action: PostAction) throws {
        switch action {
        case .reindexCodexSessions(let database):
            try sqliteExecute(database, "UPDATE backfill_state SET status = 'pending', last_watermark = NULL")
        }
    }
}
