import XCTest
@testable import PersonalCore

final class CoreTests: XCTestCase {
    func testUnicodePagingReassemblesWithoutDroppingScalars() throws {
        let text = String(repeating: "中文👩🏽‍💻é\n", count: 100)
        var offset = 0; var output = ""
        while true {
            let page = try BodyPaging.page(text, offset: offset, limit: 7)
            output += page["text"].string!
            guard let next = page["next_offset"].int else { break }; offset = next
        }
        XCTAssertEqual(output, text)
        XCTAssertThrowsError(try BodyPaging.page(text, offset: -1, limit: 10))
    }
    func testReadOnlyDeniesCachedMutationBeforeOpeningMail() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let agent = AgentRecord(id: UUID().uuidString, name: "test", permissions: ["mail.read", "mail.write"], revoked: false)
        let service = PersonalService(mail: MailModule(root: base), agent: agent, operationURL: base.appendingPathComponent("state.sqlite"), agentDirectory: base, activity: ActivityLog(url: base.appendingPathComponent("activity"), agentID: agent.id), validate: {})
        let data = service.handle(HostRequest(method: "call", tool: "mail_create_draft", arguments: ["subject": .string("test"), "body": .string("secret-body")], readOnly: true))
        let reply = try JSONDecoder().decode(ToolReply.self, from: data)
        XCTAssertTrue(reply.isError); XCTAssertEqual(reply.body["error"]["code"].string, "read_only")
        XCTAssertFalse(try String(contentsOf: base.appendingPathComponent("activity"), encoding: .utf8).contains("secret-body"))
    }
    func testAssetRangesAndSymlinkRefusal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AssetStore(root: root)
        let metadata = try store.save(Data("abcdef".utf8), filename: "test.txt", mimeType: "text/plain")
        let id = metadata["asset_id"].string!
        XCTAssertEqual(try store.read(id: id, offset: 2, length: 2)["data_base64"].string, Data("cd".utf8).base64EncodedString())
        XCTAssertThrowsError(try store.read(id: "../secret", offset: 0, length: 2))
        try FileManager.default.removeItem(at: root.appendingPathComponent(id))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(id), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertThrowsError(try store.read(id: id, offset: 0, length: 2))
    }
    func testOperationUniquenessAndUnknownSurvivesReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.sqlite"); let id = UUID().uuidString
        do { let store = try OperationStore(url: url); try store.claim(id); try store.update(id, "unknown"); XCTAssertThrowsError(try store.claim(id)) }
        XCTAssertEqual(try OperationStore(url: url).get(id)["status"].string, "unknown")
    }
}
