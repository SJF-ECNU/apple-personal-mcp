import Foundation
import SQLite3

/// Private history of reversible Mail changes; never an undo promise for sending.
public final class MailChanges {
    private var db: OpaquePointer?
    private let owner: String
    public init(url: URL, owner: String) throws {
        self.owner = owner
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw ServiceError("state_unavailable", "Cannot open change history") }
        sqlite3_busy_timeout(db, 3000)
        guard sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS mail_changes(id TEXT PRIMARY KEY,owner TEXT NOT NULL,payload TEXT NOT NULL); CREATE TABLE IF NOT EXISTS mail_batches(id TEXT PRIMARY KEY,owner TEXT NOT NULL,payload TEXT NOT NULL)", nil, nil, nil) == SQLITE_OK else { throw ServiceError("state_unavailable", "Cannot create change history") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    deinit { sqlite3_close(db) }
    private func statement(_ sql: String, _ fields: [String]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ServiceError("state_unavailable", "Cannot prepare change query") }
        for (index, value) in fields.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        return statement
    }
    public func prepare(kind: String, target: JSON, before: JSON, after: JSON) throws -> String {
        let id = UUID().uuidString
        let row = JSON.object(["change_id": .string(id), "kind": .string(kind), "target": target, "before": before, "after": after, "status": .string("pending"), "created_at": .string(ISO8601DateFormatter().string(from: Date()))])
        let statement = try statement("INSERT INTO mail_changes(id,owner,payload) VALUES(?,?,?)", [id, owner, row.text()]); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ServiceError("state_unavailable", "Cannot record change before execution") }
        return id
    }
    public func get(_ id: String) throws -> JSON {
        let statement = try statement("SELECT payload FROM mail_changes WHERE id=? AND owner=?", [id, owner]); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw ServiceError("not_found", "Change is not owned by this Agent") }
        return try JSONDecoder().decode(JSON.self, from: Data(String(cString: text).utf8))
    }
    public func update(_ id: String, status: String, target: JSON? = nil, result: JSON? = nil) throws {
        var fields = try get(id).object!; fields["status"] = .string(status)
        if let target { fields["target"] = target }
        if let result { fields["result"] = result }
        let statement = try statement("UPDATE mail_changes SET payload=? WHERE id=? AND owner=?", [JSON.object(fields).text(), id, owner]); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw ServiceError("state_unavailable", "Cannot record change result") }
    }
    public func batch(_ id: String) throws -> JSON? {
        let statement = try statement("SELECT payload FROM mail_batches WHERE id=? AND owner=?", [id, owner]); defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw ServiceError("state_unavailable", "Cannot read batch") }
        return try JSONDecoder().decode(JSON.self, from: Data(String(cString: text).utf8))
    }
    public func startBatch(_ id: String) throws {
        guard UUID(uuidString: id) != nil else { throw ServiceError("invalid_arguments", "batch_id must be a UUID") }
        let value = JSON.object(["batch_id": .string(id), "status": .string("prepared"), "results": .array([]), "unexecuted_from": .int(0)])
        let statement = try statement("INSERT INTO mail_batches(id,owner,payload) VALUES(?,?,?)", [id, owner, value.text()]); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ServiceError("duplicate_batch", "Batch ID is already reserved; inspect mail_batch_get, never blindly replay") }
    }
    public func updateBatch(_ id: String, status: String, results: [JSON], next: Int?) throws -> JSON {
        let value = JSON.object(["batch_id": .string(id), "status": .string(status), "results": .array(results), "unexecuted_from": next.map { .int(status == "running_or_interrupted" ? $0 + 1 : $0) } ?? .null, "uncertain_index": status == "running_or_interrupted" ? next.map(JSON.int) ?? .null : .null])
        let statement = try statement("UPDATE mail_batches SET payload=? WHERE id=? AND owner=?", [value.text(), id, owner]); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw ServiceError("state_unavailable", "Cannot record batch result") }
        return value
    }
    public func list(offset: Int, limit: Int) throws -> JSON {
        let statement = try statement("SELECT payload FROM mail_changes WHERE owner=? ORDER BY rowid DESC LIMIT ? OFFSET ?", [owner, String(limit + 1), String(offset)]); defer { sqlite3_finalize(statement) }
        var rows: [JSON] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw ServiceError("state_unavailable", "Cannot read change history") }
            rows.append(try JSONDecoder().decode(JSON.self, from: Data(String(cString: text).utf8)))
        }
        return .object(["changes": .array(Array(rows.prefix(limit))), "next_offset": rows.count > limit ? .int(offset + limit) : .null])
    }
}
