import XCTest
@testable import PersonalCore

final class CompletionTests: XCTestCase {
    func testDraftAttachmentPlaceholderRepresentation() {
        XCTAssertEqual(MailAutomation.draftBody("原文 😀 \u{fffc}"), "原文 😀 \n")
        XCTAssertNotEqual(MailAutomation.draftBody("原文\n"), MailAutomation.draftBody("改文\n"))
        XCTAssertNotEqual(MailAutomation.draftBody("a b"), MailAutomation.draftBody("ab"))
        XCTAssertEqual(MailAutomation.draftBody("a\n\u{2028}\nb"), "a\n\nb")
        XCTAssertNotEqual(MailAutomation.draftBody("a\nb"), MailAutomation.draftBody("a\n\nb"))
        XCTAssertEqual(MailAutomation.draftBody("a\u{2028}b"), "a\u{2028}b")
    }
    func testChunkUploadIsRetryableAndIsolatedWithoutOverwriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = AssetStore(root: root.appendingPathComponent("Exports"))
        let uploader = AttachmentUpload(root: root.appendingPathComponent("Uploads"), assets: assets)
        let id = try uploader.call(["action": .string("start"), "filename": .string("中文.txt"), "size": .int(6)])["upload_id"]
        let chunk: [String: JSON] = ["action": .string("chunk"), "upload_id": id, "offset": .int(0), "data_base64": .string(Data("abc".utf8).base64EncodedString())]
        XCTAssertEqual(try uploader.call(chunk)["next_offset"].int, 3)
        XCTAssertEqual(try uploader.call(chunk)["next_offset"].int, 3)
        var conflict = chunk; conflict["data_base64"] = .string(Data("xyz".utf8).base64EncodedString())
        XCTAssertThrowsError(try uploader.call(conflict))
        XCTAssertThrowsError(try uploader.call(["action": .string("finish"), "upload_id": id]))
        XCTAssertThrowsError(try AttachmentUpload(root: root.appendingPathComponent("Other"), assets: assets).call(["action": .string("status"), "upload_id": id]))
        var second = chunk; second["offset"] = .int(3); second["data_base64"] = .string(Data("def".utf8).base64EncodedString())
        _ = try uploader.call(second)
        let result = try uploader.call(["action": .string("finish"), "upload_id": id])
        XCTAssertEqual(try uploader.call(["action": .string("finish"), "upload_id": id]), result)
        XCTAssertEqual(try assets.read(id: result["asset_id"].string!, offset: 0, length: 6)["data_base64"].string, Data("abcdef".utf8).base64EncodedString())
        for name in ["../file", "/etc/hosts", "..", "a\nb", "a\\b"] { XCTAssertThrowsError(try AttachmentUpload.filename(name)) }
    }
    func testAttachmentComparisonDetectsSameSizeSameTimestampEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"); let b = root.appendingPathComponent("b")
        try Data("safe".utf8).write(to: a); try Data("evil".utf8).write(to: b)
        let date = Date(timeIntervalSince1970: 1000)
        for url in [a, b] { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
        XCTAssertFalse(try MailAutomation.sameBytes(a, b))
        try Data("safe".utf8).write(to: b); XCTAssertTrue(try MailAutomation.sameBytes(a, b))
    }
    func testChangeAndBatchHistoryCannotCrossAgentOrBeReexecuted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.sqlite")
        let a = try MailChanges(url: url, owner: "a"); let b = try MailChanges(url: url, owner: "b")
        let id = try a.prepare(kind: "flags", target: .object(["id": .string("1")]), before: .object(["flagged": .bool(false)]), after: .object(["flagged": .bool(true)]))
        XCTAssertEqual(try a.get(id)["status"].string, "pending"); XCTAssertThrowsError(try b.get(id))
        try a.update(id, status: "unknown")
        XCTAssertEqual(try MailChanges(url: url, owner: "a").get(id)["status"].string, "unknown")
        let batch = UUID().uuidString; try a.startBatch(batch)
        _ = try a.updateBatch(batch, status: "stopped", results: [.object(["change_id": .string(id), "status": .string("unknown")])], next: 1)
        XCTAssertThrowsError(try a.startBatch(batch)); XCTAssertThrowsError(try b.startBatch(batch)); XCTAssertNil(try b.batch(batch))
        XCTAssertEqual(try MailChanges(url: url, owner: "a").batch(batch)?["unexecuted_from"].int, 1)
    }
    func testICalendarUnicodeFoldingAndHeaderInjection() throws {
        let event = JSON.object(["uid": .string("synthetic-uid"), "title": .string(String(repeating: "中文😀", count: 100)), "notes": .string("x\r\nATTENDEE:mailto:injected@example.com"), "start": .string("2026-11-10T01:00:00Z"), "end": .string("2026-11-10T02:00:00Z"), "all_day": .bool(false)])
        let data = try ICalendarInvitation.make(event: event, organizer: "owner@example.com", attendees: ["guest@example.com"])
        let raw = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(raw.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 75 })
        XCTAssertEqual(raw.components(separatedBy: "\r\n").filter { $0.hasPrefix("ATTENDEE") }.count, 1)
        XCTAssertTrue(raw.contains("DTSTART:20261110T010000Z"))
        XCTAssertTrue(raw.replacingOccurrences(of: "\r\n ", with: "").contains(String(repeating: "中文😀", count: 100)))
        XCTAssertThrowsError(try ICalendarInvitation.make(event: event, organizer: "owner@example.com\nBcc:bad", attendees: ["guest@example.com"]))
        let noMail = AgentRecord(id: "a", name: "calendar", permissions: ["calendar.read", "calendar.write"], revoked: false)
        XCTAssertTrue(CalendarInvitation.tools.allSatisfy { !noMail.allows($0) })
    }
    func testCancellationBeforeAdmissionAndConnectionOwnership() throws {
        let id = UUID().uuidString; let a = AgentSession(); let b = AgentSession()
        a.cancel(id); try a.begin(id); XCTAssertThrowsError(try a.check(id)); a.end(id)
        let next = UUID().uuidString; try a.begin(next); b.cancel(next)
        XCTAssertNoThrow(try a.check(next)); a.cancel(next); XCTAssertThrowsError(try a.check(next)); a.end(next)
    }
    func testOfficialReferencesPreserveIdentityAndRejectTruncation() throws {
        let ref = OfficialMailReference(account: "a", path: "收件箱/子文件夹", id: Int32.max, header: "id@example.com")
        let decoded = try OfficialMailReference.decode(ref.token)
        XCTAssertEqual(decoded.id, Int32.max); XCTAssertEqual(decoded.path, ref.path); XCTAssertEqual(decoded.header, ref.header)
        XCTAssertThrowsError(try OfficialMailReference.decode("mail-api:not-base64"))
        XCTAssertThrowsError(try OfficialMailReference.decode(OfficialMailReference(account: "a", path: "x", id: -1).token))
    }
}
