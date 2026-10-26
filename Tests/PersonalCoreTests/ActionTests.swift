import XCTest
@testable import PersonalCore

final class ActionTests: XCTestCase {
    func testReminderDatesRejectNormalizationAndPreserveFloatingDate() throws {
        let date = try EventKitModule.dueComponents(.object(["year": .int(2026), "month": .int(11), "day": .int(10)]))!
        XCTAssertNil(date.hour); XCTAssertNil(date.timeZone)
        for fields: [String: JSON] in [
            ["year": .int(2026), "month": .int(2), "day": .int(30)],
            ["year": .int(2026), "month": .int(3), "day": .int(8), "hour": .int(2), "minute": .int(30), "time_zone": .string("America/New_York")],
            ["year": .int(2026), "month": .int(11), "day": .int(10), "minute": .int(30)],
        ] { XCTAssertThrowsError(try EventKitModule.dueComponents(.object(fields))) }
        XCTAssertNil(try EventKitModule.dueComponents(.object([:])))
    }
    func testPlainNotesNeverDiscardRichFormattingOrAttachments() {
        XCTAssertTrue(NotesModule.isPlainHTML("<div>中文😀 &amp; text<br></div>"))
        for html in ["<div><b>bold</b></div>", "<img src='attachment'>", "<div style='font-size:24px'>x</div>", "<object>audio</object>", "<table><tr><td>x</td></tr></table>"] {
            XCTAssertFalse(NotesModule.isPlainHTML(html))
        }
        XCTAssertEqual(NotesModule.escapeHTML("<b>&\n😀"), "&lt;b&gt;&amp;<br>😀")
    }
    func testMessagesSendNeedsItsOwnGrantAndUsesGlobalOperationIDs() throws {
        let send = MessagesAutomation.tools.first { $0.name == "messages_send" }!
        let without = AgentRecord(id: "a", name: "a", permissions: ["messages.read", "messages.write", "mail.send"], revoked: false)
        XCTAssertFalse(without.allows(send))
        XCTAssertTrue(AgentRecord(id: "a", name: "a", permissions: ["messages.read", "messages.write", "messages.send"], revoked: false).allows(send))
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.sqlite"); let id = UUID().uuidString
        let mail = try OperationStore(url: url, owner: "a")
        try mail.claim(id); try mail.update(id, "unknown")
        let messages = try OperationStore(url: url, owner: "a:messages")
        XCTAssertThrowsError(try messages.claim(id)); XCTAssertThrowsError(try messages.get(id))
        XCTAssertEqual(try OperationStore(url: url, owner: "a").get(id)["status"].string, "unknown")
    }
    func testSendingToNewRecipientRequiresAnExactAddress() {
        for handle in ["+12025550123", "user@example.com"] { XCTAssertTrue(MessagesAutomation.validHandle(handle)) }
        for handle in ["2025550123", "朋友", "+86123", "a@example.com,b@example.com", "Display Name <a@example.com>", "a@example.com\nb@example.com", "a@example.com\n"] { XCTAssertFalse(MessagesAutomation.validHandle(handle)) }
    }
    func testResourceProtocolIsolationPermissionAndExpiryCleanup() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AssetStore(root: root.appendingPathComponent("messages/Exports"), application: "messages")
        let asset = try store.save(Data("中文😀".utf8), filename: "sample.txt", mimeType: "text/plain")
        let agent = AgentRecord(id: "a", name: "a", permissions: ["messages.read"], revoked: false)
        let ext = MCPExtensions(agent: agent, directory: root)
        XCTAssertEqual(try ext.call("resources", [:])["resources"].array?.count, 1)
        XCTAssertNotNil(try ext.call("resource", ["uri": asset["uri"]])["contents"].array?.first?["blob"].string)
        let other = MCPExtensions(agent: agent, directory: root.appendingPathComponent("other"))
        XCTAssertThrowsError(try other.call("resource", ["uri": asset["uri"]]))
        XCTAssertThrowsError(try ext.call("resource", ["uri": .string("apple-personal-mcp://assets/mail/" + asset["asset_id"].string!)]))
        let id = asset["asset_id"].string!
        let sentinel = root.appendingPathComponent("messages/Exports/source.sqlite")
        try Data("must stay".utf8).write(to: sentinel)
        store.cleanupExpired(now: Date().addingTimeInterval(86500))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("messages/Exports/" + id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }
    func testRestartInterruptsUnfinishedJobWithoutRetainingWorkAudio() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString; let dir = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("snapshot".utf8).write(to: dir.appendingPathComponent("input"))
        let record = JSON.object(["id": .string(id), "owner": .string("a"), "kind": .string("transcription"), "recordingID": .string("1"), "status": .string("running"), "locale": .string("zh-CN"), "downloadModels": .bool(false), "created": .number(0)])
        try record.data().write(to: root.appendingPathComponent(id + ".json"))
        let jobs = try VoiceJobs(root: root)
        XCTAssertEqual(try jobs.call("voicememos_job_get", owner: "a", arguments: ["job_id": .string(id)])["status"].string, "interrupted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("input").path))
        XCTAssertThrowsError(try jobs.call("voicememos_job_get", owner: "b", arguments: ["job_id": .string(id)]))
    }
}
