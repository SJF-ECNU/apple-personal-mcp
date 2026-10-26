import Foundation
import SQLite3

enum LocalCell {
    case text(String), integer(Int64), real(Double), blob(Data), null
    var string: String? { if case .text(let v) = self { return v }; return nil }
    var integer: Int64 { if case .integer(let v) = self { return v }; return 0 }
    var data: Data? { if case .blob(let v) = self { return v }; return nil }
    var double: Double { switch self { case .real(let v): return v; case .integer(let v): return Double(v); default: return 0 } }
}

/// One request owns one connection. Never immutable-mode on a live WAL database.
final class LocalDatabase {
    private var db: OpaquePointer?
    init(_ url: URL) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); db = nil; throw ServiceError("needs_permission", "Cannot open local source; check App Full Disk Access and local synchronization")
        }
        sqlite3_busy_timeout(db, 3000)
        guard sqlite3_exec(db, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK else { throw ServiceError("source_unavailable", "Cannot enable read-only source connection") }
    }
    deinit { sqlite3_close(db) }
    func query(_ sql: String, _ strings: [String] = []) throws -> [[String: LocalCell]] {
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, let s = raw else { throw ServiceError("unsupported_schema", "Local source does not support this query") }
        defer { sqlite3_finalize(s) }
        for (i, value) in strings.enumerated() { sqlite3_bind_text(s, Int32(i + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        var result: [[String: LocalCell]] = []
        while true {
            let status = sqlite3_step(s)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw ServiceError("source_unavailable", "Local source query failed; retry a new read") }
            var row: [String: LocalCell] = [:]
            for col in 0..<sqlite3_column_count(s) {
                let name = String(cString: sqlite3_column_name(s, col)); let cell: LocalCell
                switch sqlite3_column_type(s, col) {
                case SQLITE_INTEGER: cell = .integer(sqlite3_column_int64(s, col))
                case SQLITE_FLOAT: cell = .real(sqlite3_column_double(s, col))
                case SQLITE_TEXT:
                    let length = Int(sqlite3_column_bytes(s, col))
                    cell = .text(String(decoding: UnsafeBufferPointer(start: sqlite3_column_text(s, col), count: length), as: UTF8.self))
                case SQLITE_BLOB:
                    let length = Int(sqlite3_column_bytes(s, col)); cell = .blob(sqlite3_column_blob(s, col).map { Data(bytes: $0, count: length) } ?? Data())
                default: cell = .null
                }
                row[name] = cell
            }
            result.append(row)
        }
    }
}

extension Dictionary where Key == String, Value == LocalCell {
    func text(_ key: String) -> String { self[key]?.string ?? "" }
    func integer(_ key: String) -> Int64 { self[key]?.integer ?? 0 }
}
