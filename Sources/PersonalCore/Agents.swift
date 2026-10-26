import Foundation
import Security
import SQLite3

public struct AgentCredential: Codable, Equatable, Sendable {
    public let agentID: String
    public let secret: String
    public static func load(_ url: URL) throws -> AgentCredential {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard url.resolvingSymlinksInPath().path == url.standardizedFileURL.path,
              attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0,
              (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 4096 else {
            throw ServiceError("invalid_credentials", "Credential file must be a private regular file owned by this user")
        }
        return try JSONDecoder().decode(AgentCredential.self, from: Data(contentsOf: url))
    }
}

public struct AgentRecord: Codable, Sendable {
    public let id: String
    public let name: String
    public let permissions: Set<String>
    public let revoked: Bool
    public func allows(_ tool: ToolDefinition) -> Bool {
        if ["calendar_prepare_invitation", "calendar_send_invitation"].contains(tool.name) {
            guard permissions.contains("mail.read"), permissions.contains("mail.write") else { return false }
            if tool.name == "calendar_send_invitation" && !permissions.contains("mail.send") { return false }
        }
        if tool.name == "system_status" { return true }
        if tool.name == "assets_read" { return ["mail", "messages", "voice_memos", "notes"].contains { permissions.contains("\($0).read") } }
        if tool.name == "operations_get" { return ["mail", "messages"].contains { permissions.contains("\($0).read") } }
        let app = tool.application
        guard permissions.contains("\(app).read") else { return false }
        if !tool.readOnly && !permissions.contains("\(app).write") { return false }
        if ["mail_send_draft", "messages_send"].contains(tool.name) && !permissions.contains("\(app).send") { return false }
        return true
    }
}

/// Per-user MCP authorization, not a sandbox against other processes with full user access.
public final class AgentRegistry {
    public static let applications = ["mail", "calendar", "reminders", "notes", "messages", "voice_memos"]
    public static let permissionNames = Set(applications.flatMap { ["\($0).read", "\($0).write"] } + ["mail.send", "messages.send"])
    public let root: URL
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    public init(root: URL = AppIdentity.support) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = root.appendingPathComponent("agents.sqlite")
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw ServiceError("state_unavailable", "Cannot open Agent registry") }
        sqlite3_busy_timeout(db, 3000)
        guard sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS agents(id TEXT PRIMARY KEY, name TEXT NOT NULL, secret TEXT NOT NULL, permissions TEXT NOT NULL, revoked INTEGER NOT NULL DEFAULT 0)", nil, nil, nil) == SQLITE_OK else { throw ServiceError("state_unavailable", "Cannot create Agent registry") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    deinit { sqlite3_close(db) }
    private func statement(_ sql: String, _ strings: [String] = []) throws -> OpaquePointer {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw ServiceError("state_unavailable", "Cannot prepare Agent query") }
        for (i, value) in strings.enumerated() { sqlite3_bind_text(s, Int32(i + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        return s
    }
    private func text(_ s: OpaquePointer, _ col: Int32) -> String { sqlite3_column_text(s, col).map { String(cString: $0) } ?? "" }
    private func record(_ s: OpaquePointer) throws -> AgentRecord {
        AgentRecord(id: text(s, 0), name: text(s, 1), permissions: try JSONDecoder().decode(Set<String>.self, from: Data(text(s, 2).utf8)), revoked: sqlite3_column_int(s, 3) != 0)
    }
    public static func validate(_ permissions: Set<String>) throws {
        guard permissions.isSubset(of: permissionNames) else { throw ServiceError("invalid_permissions", "Unknown application permission") }
        for app in applications {
            if permissions.contains("\(app).write") && !permissions.contains("\(app).read") { throw ServiceError("invalid_permissions", "Write requires read for \(app)") }
            if permissions.contains("\(app).send") && !permissions.contains("\(app).write") { throw ServiceError("invalid_permissions", "Send requires write for \(app)") }
        }
    }
    public func create(name: String, permissions: Set<String>) throws -> AgentRecord {
        lock.lock(); defer { lock.unlock() }
        try Self.validate(permissions)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw ServiceError("invalid_arguments", "Agent name must contain 1...80 characters") }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ServiceError("credential_failed", "System random generator unavailable") }
        let id = UUID().uuidString
        let credential = AgentCredential(agentID: id, secret: Data(bytes).base64EncodedString())
        let directory = credentialURL(id).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try PrivateFile.writeJSON(credential, to: credentialURL(id))
        do {
            let s = try statement("INSERT INTO agents(id,name,secret,permissions) VALUES(?,?,?,?)", [id, name, credential.secret, String(data: try JSONEncoder().encode(permissions), encoding: .utf8)!]); defer { sqlite3_finalize(s) }
            guard sqlite3_step(s) == SQLITE_DONE else { throw ServiceError("state_unavailable", "Cannot create Agent") }
        } catch { try? FileManager.default.removeItem(at: credentialURL(id)); throw error }
        return AgentRecord(id: id, name: name, permissions: permissions, revoked: false)
    }
    public func list() throws -> [AgentRecord] {
        lock.lock(); defer { lock.unlock() }
        let s = try statement("SELECT id,name,permissions,revoked FROM agents ORDER BY rowid"); defer { sqlite3_finalize(s) }
        var rows: [AgentRecord] = []
        while true {
            let result = sqlite3_step(s)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw ServiceError("state_unavailable", "Cannot list Agents") }
            rows.append(try record(s))
        }
    }
    public func authenticate(_ credential: AgentCredential?) throws -> AgentRecord {
        lock.lock(); defer { lock.unlock() }
        guard let credential else { throw ServiceError("credentials_required", "Create an Agent in ApplePersonalMCP.app and configure --credential-file") }
        let s = try statement("SELECT id,name,permissions,revoked FROM agents WHERE id=? AND secret=? AND revoked=0", [credential.agentID, credential.secret]); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw ServiceError("invalid_credentials", "Agent credentials are invalid or revoked") }
        return try record(s)
    }
    public func update(_ id: String, permissions: Set<String>) throws {
        lock.lock(); defer { lock.unlock() }
        try Self.validate(permissions)
        let s = try statement("UPDATE agents SET permissions=? WHERE id=? AND revoked=0", [String(data: try JSONEncoder().encode(permissions), encoding: .utf8)!, id]); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw ServiceError("not_found", "Active Agent not found") }
    }
    public func revoke(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        let s = try statement("UPDATE agents SET revoked=1 WHERE id=?", [id]); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw ServiceError("not_found", "Agent not found") }
        try? FileManager.default.removeItem(at: credentialURL(id))
    }
    public func credentialURL(_ id: String) -> URL { root.appendingPathComponent("Credentials/\(id).json") }
    public func configuration(_ agent: AgentRecord) -> JSON {
        .object(["mcpServers": .object(["apple-personal": .object(["command": .string("/Applications/ApplePersonalMCP.app/Contents/Helpers/apple-personal-mcp"), "args": .array([.string("--credential-file"), .string(credentialURL(agent.id).path)])])])])
    }
}

extension ToolDefinition {
    public var automationApplication: String { name == "calendar_prepare_invitation" || name == "calendar_send_invitation" ? "mail" : application }
    public var application: String {
        if name == "assets_read" || name == "operations_get" { return "mail" }
        if name.hasPrefix("voicememos_") { return "voice_memos" }
        return AgentRegistry.applications.first { name.hasPrefix($0 + "_") } ?? "system"
    }
    public var usesAutomation: Bool {
        !readOnly || MailAutomation.tools.contains { $0.name == name && name != "operations_get" } || NotesModule.tools.contains { $0.name == name } || MessagesAutomation.tools.contains { $0.name == name }
    }
}
