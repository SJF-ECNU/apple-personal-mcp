import XCTest
import SQLite3
@testable import PersonalCore

final class AgentTests: XCTestCase {
    private var root: URL!
    private var registry: AgentRegistry!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        registry = try AgentRegistry(root: root)
    }
    override func tearDownWithError() throws { registry = nil; try FileManager.default.removeItem(at: root) }
    private func credential(_ record: AgentRecord) throws -> AgentCredential { try .load(registry.credentialURL(record.id)) }
    private func request(_ broker: RequestBroker, _ credential: AgentCredential?, tool: String? = nil, arguments: [String: JSON] = [:], session: AgentSession = AgentSession(), method: String = "call") throws -> Data {
        let done = expectation(description: "reply"); var result = Data()
        broker.request(HostRequest(method: method, tool: tool, arguments: arguments, readOnly: false, credential: credential), session: session) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 5); return result
    }
    private func body(_ data: Data) throws -> JSON { try JSONDecoder().decode(ToolReply.self, from: data).body }
    func testCredentialsPermissionsAndRevocationPersist() throws {
        let agent = try registry.create(name: "reader", permissions: ["mail.read"])
        let c = try credential(agent)
        XCTAssertEqual(Data(base64Encoded: c.secret)?.count, 32)
        XCTAssertEqual(try registry.authenticate(c).id, agent.id)
        XCTAssertThrowsError(try registry.authenticate(nil))
        XCTAssertThrowsError(try registry.authenticate(AgentCredential(agentID: agent.id, secret: "wrong")))
        XCTAssertThrowsError(try registry.create(name: "bad", permissions: ["mail.write"]))
        XCTAssertThrowsError(try registry.create(name: "bad", permissions: ["mail.read", "mail.send"]))
        XCTAssertThrowsError(try registry.update(agent.id, permissions: ["unknown.read"]))
        try registry.update(agent.id, permissions: ["calendar.read"])
        XCTAssertEqual(try AgentRegistry(root: root).authenticate(c).permissions, ["calendar.read"])
        try registry.revoke(agent.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: registry.credentialURL(agent.id).path))
        XCTAssertThrowsError(try AgentRegistry(root: root).authenticate(c))
        XCTAssertThrowsError(try registry.update(agent.id, permissions: ["mail.read"]))
        XCTAssertFalse(registry.configuration(agent).text().contains(c.secret))
    }
    func testCredentialFileRejectsPublicPermissionsAndSymlinks() throws {
        let agent = try registry.create(name: "reader", permissions: [])
        let url = registry.credentialURL(agent.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertThrowsError(try AgentCredential.load(url))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertThrowsError(try AgentCredential.load(link))
    }
    func testCatalogLiveDowngradeAndNoMailLeakInStatus() throws {
        let agent = try registry.create(name: "writer", permissions: ["mail.read", "mail.write"])
        let c = try credential(agent); let broker = RequestBroker(registry: registry, mailRoot: root)
        let session = AgentSession()
        let tools = try JSONDecoder().decode([ToolDefinition].self, from: request(broker, c, session: session, method: "tools"))
        XCTAssertTrue(tools.contains { $0.name == "mail_create_draft" })
        XCTAssertFalse(tools.contains { $0.name == "mail_send_draft" })
        try registry.update(agent.id, permissions: ["calendar.read"])
        let next = try JSONDecoder().decode([ToolDefinition].self, from: request(broker, c, session: session, method: "tools"))
        XCTAssertEqual(Set(next.map(\.name)), ["system_status", "calendar_list", "calendar_search", "calendar_get"])
        let denied = try body(request(broker, c, tool: "mail_get", arguments: ["id": .string("1")], session: session))
        XCTAssertEqual(denied["error"]["code"].string, "permission_denied")
        let status = try body(request(broker, c, tool: "system_status", session: session))
        XCTAssertEqual(status["applications"]["mail"]["state"].string, "permission_denied")
        XCTAssertEqual(status["applications"]["mail"]["messages"], .null)
        XCTAssertEqual(status["automation"], .null)
        let other = try registry.create(name: "other", permissions: [])
        XCTAssertEqual(try body(request(broker, credential(other), session: session))["error"]["code"].string, "identity_changed")
        try registry.revoke(agent.id)
        XCTAssertEqual(try body(request(broker, c, tool: "system_status", session: session))["error"]["code"].string, "invalid_credentials")
        XCTAssertEqual(try body(request(broker, nil, method: "tools"))["error"]["code"].string, "credentials_required")
    }
    func testAgentAssetsAndOperationRecordsAreIsolated() throws {
        let a = try registry.create(name: "a", permissions: ["mail.read"])
        let b = try registry.create(name: "b", permissions: ["mail.read"])
        let directory = root.appendingPathComponent("Agents/\(a.id)/mail")
        let asset = try AssetStore(root: directory.appendingPathComponent("Exports")).save(Data("private-a".utf8), filename: "a", mimeType: "text/plain")
        let op = UUID().uuidString
        let operations = try OperationStore(url: root.appendingPathComponent("state.sqlite"), owner: a.id); try operations.claim(op); try operations.update(op, "unknown")
        XCTAssertThrowsError(try OperationStore(url: root.appendingPathComponent("state.sqlite"), owner: b.id).claim(op))
        let broker = RequestBroker(registry: registry, mailRoot: root)
        let args = ["asset_id": asset["asset_id"]]
        XCTAssertEqual(try body(request(broker, credential(a), tool: "assets_read", arguments: args))["data_base64"].string, Data("private-a".utf8).base64EncodedString())
        XCTAssertEqual(try body(request(broker, credential(b), tool: "assets_read", arguments: args))["error"]["code"].string, "not_found")
        XCTAssertEqual(try body(request(broker, credential(a), tool: "operations_get", arguments: ["operation_id": .string(op)]))["status"].string, "unknown")
        XCTAssertEqual(try body(request(broker, credential(b), tool: "operations_get", arguments: ["operation_id": .string(op)]))["error"]["code"].string, "not_found")
        let log = try String(contentsOf: root.appendingPathComponent("activity.jsonl"), encoding: .utf8)
        XCTAssertFalse(log.contains("private-a")); XCTAssertFalse(log.contains(try credential(a).secret))
        XCTAssertTrue(log.contains(a.id)); XCTAssertTrue(log.contains(b.id))
    }
    func testQueuedRevocationAndDisconnectionPreventExecution() throws {
        for disconnect in [false, true] {
            let agent = try registry.create(name: "queued", permissions: ["mail.read"])
            let c = try credential(agent)
            let scheduler = RequestScheduler(); let release = DispatchSemaphore(value: 0)
            let entered = expectation(description: "blocker entered"); let ended = expectation(description: "blocker ended")
            try scheduler.submit(agentID: "blocker", automationApp: "mail", work: { entered.fulfill(); _ = release.wait(timeout: .now() + 5); return Data() }, reply: { _ in ended.fulfill() })
            wait(for: [entered], timeout: 2)
            let broker = RequestBroker(registry: registry, scheduler: scheduler, mailRoot: root)
            let session = AgentSession(); let denied = expectation(description: "queued denied"); var result = Data()
            broker.request(HostRequest(method: "call", tool: "mail_get_draft", arguments: ["draft_id": .string("1")], readOnly: false, credential: c), session: session) { result = $0; denied.fulfill() }
            if disconnect { session.invalidate() } else { try registry.revoke(agent.id) }
            release.signal(); wait(for: [ended, denied], timeout: 3)
            XCTAssertEqual(try body(result)["error"]["code"].string, disconnect ? "disconnected" : "invalid_credentials")
        }
    }
    func testResourcesRequireTheirOwnApplicationScope() throws {
        let agent = try registry.create(name: "messages reader", permissions: ["messages.read"])
        let c = try credential(agent); let broker = RequestBroker(registry: registry)
        let id = try AssetStore(root: root.appendingPathComponent("Agents/\(agent.id)/messages/Exports")).save(Data("message asset".utf8), filename: "sample", mimeType: "text/plain")["asset_id"]
        XCTAssertEqual(try body(request(broker, c, tool: "assets_read", arguments: ["asset_id": id]))["error"]["code"].string, "permission_denied")
        XCTAssertEqual(try body(request(broker, c, tool: "assets_read", arguments: ["asset_id": id, "application": .string("messages")]))["data_base64"].string, Data("message asset".utf8).base64EncodedString())
        try registry.update(agent.id, permissions: ["mail.read"])
        XCTAssertEqual(try body(request(broker, c, tool: "assets_read", arguments: ["asset_id": id, "application": .string("messages")]))["error"]["code"].string, "permission_denied")
    }
    func testLegacyOperationsRemainGloballyNonRepeatableWithoutLeakingOwnership() throws {
        let url = root.appendingPathComponent("legacy.sqlite"); var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE operations(id TEXT PRIMARY KEY,status TEXT NOT NULL); INSERT INTO operations VALUES('legacy','unknown')", nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        let a = try OperationStore(url: url, owner: "a"); let b = try OperationStore(url: url, owner: "b")
        XCTAssertNil(try a.existing("legacy")); XCTAssertThrowsError(try a.claim("legacy")); XCTAssertThrowsError(try b.claim("legacy"))
        try a.claim("new"); try a.update("new", "unknown")
        XCTAssertNil(try b.existing("new")); XCTAssertThrowsError(try b.claim("new")); XCTAssertThrowsError(try b.update("new", "submitted"))
        XCTAssertEqual(try a.get("new")["status"].string, "unknown")
    }
}
