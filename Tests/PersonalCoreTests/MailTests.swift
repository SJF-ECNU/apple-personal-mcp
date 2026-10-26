import Foundation
import MailStore
import XCTest
@testable import PersonalCore

final class MailFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("apm-test-" + UUID().uuidString)
    let account = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    let storeID = "11111111-2222-3333-4444-555555555555"
    let db: SQLiteConnection
    init() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("MailData"), withIntermediateDirectories: true)
        db = try SQLiteConnection(path: root.appendingPathComponent("MailData/Envelope Index").path, readOnly: false, create: true)
        try db.execute("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE properties(ROWID INTEGER PRIMARY KEY,key TEXT,value TEXT);
        CREATE TABLE subjects(ROWID INTEGER PRIMARY KEY,subject TEXT);
        CREATE TABLE addresses(ROWID INTEGER PRIMARY KEY,address TEXT,comment TEXT);
        CREATE TABLE summaries(ROWID INTEGER PRIMARY KEY,summary TEXT);
        CREATE TABLE mailboxes(ROWID INTEGER PRIMARY KEY,url TEXT,total_count INTEGER DEFAULT 0,unread_count INTEGER DEFAULT 0,source INTEGER);
        CREATE TABLE message_global_data(ROWID INTEGER PRIMARY KEY,message_id INTEGER,message_id_header TEXT,model_category INTEGER);
        CREATE TABLE messages(ROWID INTEGER PRIMARY KEY,message_id INTEGER,global_message_id INTEGER,sender INTEGER,subject_prefix TEXT,subject INTEGER,summary INTEGER,date_sent INTEGER,date_received INTEGER,mailbox INTEGER,read INTEGER DEFAULT 0,flagged INTEGER DEFAULT 0,deleted INTEGER DEFAULT 0,size INTEGER DEFAULT 0,conversation_id INTEGER DEFAULT 1,flags INTEGER DEFAULT 0,list_id_hash INTEGER,unsubscribe_type INTEGER);
        CREATE INDEX messages_deleted_date_received_index ON messages(deleted,date_received);
        CREATE INDEX messages_mailbox_date_received_index ON messages(mailbox,date_received);
        CREATE TABLE recipients(message INTEGER,address INTEGER,type INTEGER,position INTEGER);
        CREATE TABLE attachments(message INTEGER,attachment_id TEXT,name TEXT);
        CREATE TABLE labels(message_id INTEGER,mailbox_id INTEGER);
        INSERT INTO addresses VALUES(1,'sender@example.invalid','Test Sender');
        INSERT INTO addresses VALUES(2,'recipient@example.invalid','Recipient');
        """)
        try db.run("INSERT INTO mailboxes VALUES(1,?,0,0,NULL)", [.text("imap://\(account)/INBOX")])
        try db.run("INSERT INTO properties VALUES(1,'UUID',?)", [.text(storeID)])
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    @discardableResult func add(_ id: Int, text: String, downloaded: Bool = true, attachment: Bool = false) throws -> URL? {
        try db.run("INSERT INTO subjects VALUES(?,?)", [.int(Int64(id)), .text("Fixture \(id)")])
        try db.run("INSERT INTO summaries VALUES(?,?)", [.int(Int64(id)), .text("Preview \(id)")])
        try db.run("INSERT INTO message_global_data VALUES(?,?,?,NULL)", [.int(Int64(id)), .int(Int64(id)), .text("fixture-\(id)@example.invalid")])
        try db.run("INSERT INTO messages(ROWID,message_id,global_message_id,sender,subject,summary,date_sent,date_received,mailbox) VALUES(?,?,?,1,?,?,1700000000,1700000000,1)", [.int(Int64(id)), .int(Int64(id)), .int(Int64(id)), .int(Int64(id)), .int(Int64(id))])
        try db.run("INSERT INTO recipients VALUES(?,2,0,0)", [.int(Int64(id))])
        try db.run("UPDATE mailboxes SET total_count=total_count+1,unread_count=unread_count+1 WHERE ROWID=1")
        guard downloaded else { return nil }
        var raw = "From: sender@example.invalid\r\nTo: recipient@example.invalid\r\nSubject: Fixture \(id)\r\nMessage-ID: <fixture-\(id)@example.invalid>\r\nMIME-Version: 1.0\r\n"
        if attachment {
            raw += "Content-Type: multipart/mixed; boundary=TESTBOUNDARY\r\n\r\n--TESTBOUNDARY\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n\(text)\r\n--TESTBOUNDARY\r\nContent-Type: text/plain; name=test.txt\r\nContent-Disposition: attachment; filename=test.txt\r\nContent-Transfer-Encoding: base64\r\n\r\nSGVsbG8=\r\n--TESTBOUNDARY--\r\n"
            try db.run("INSERT INTO attachments VALUES(?,'2','test.txt')", [.int(Int64(id))])
        } else { raw += "Content-Type: text/plain; charset=utf-8\r\n\r\n\(text)" }
        let data = Data(raw.utf8)
        let dir = root.appendingPathComponent("\(account)/INBOX.mbox/\(storeID)/Data/Messages")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("\(id).emlx")
        try (Data("\(data.count)\n".utf8) + data + Data("\n<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>".utf8)).write(to: path)
        return path
    }
    func module() -> MailModule { MailModule(root: root, assets: AssetStore(root: root.appendingPathComponent("Exports"))) }
}

final class MailTests: XCTestCase {
    func testWALMetadataAndUnreadState() throws {
        let f = try MailFixture(); try f.add(1, text: "正文")
        let module = f.module()
        XCTAssertEqual(try module.call("mail_search", [:])["messages"].array?.count, 1)
        _ = try module.call("mail_get", ["id": .string("1")])
        XCTAssertEqual(try f.db.scalarInt("SELECT read FROM messages WHERE ROWID=1"), 0)
        try f.add(2, text: "new WAL record")
        XCTAssertEqual(try module.call("mail_search", [:])["messages"].array?.count, 2)
    }
    func testCompleteBodyAndSearchBeyondFortyThousandCharacters() throws {
        let f = try MailFixture()
        let text = String(repeating: "中文👩🏽‍💻 ", count: 12000) + "END-MARKER"
        try f.add(1, text: text)
        let module = f.module(); var output = ""; var offset = 0
        while true {
            let result = try module.call("mail_get", ["id": .string("1"), "body_offset": .int(offset), "max_chars": .int(777)])
            output += result["body"]["text"].string ?? ""
            guard let next = result["body"]["next_offset"].int else { break }; offset = next
        }
        XCTAssertTrue(output.hasSuffix("END-MARKER"))
        XCTAssertEqual(output, text)
        let found = try module.call("mail_search", ["body": .string("END-MARKER")])
        XCTAssertEqual(found["messages"].array?.count, 1)
        XCTAssertEqual(found["search_complete"].boolean, true)
    }
    func testBodyScanReportsUnfinishedAndNotDownloaded() throws {
        let f = try MailFixture(); try f.add(1, text: "first"); try f.add(2, text: "missing", downloaded: false)
        let result = try f.module().call("mail_search", ["body": .string("not-there"), "scan_limit": .int(1)])
        XCTAssertEqual(result["search_complete"].boolean, false)
        XCTAssertNotNil(result["next_scan_offset"].int)
        XCTAssertEqual(try f.module().call("mail_get", ["id": .string("2")])["content_status"].string, "not_downloaded")
    }
    func testMIMEAttachmentExportDoesNotChangeSource() throws {
        let f = try MailFixture(); let path = try f.add(1, text: "附件正文", attachment: true)!
        let original = try Data(contentsOf: path); let module = f.module()
        let detail = try module.call("mail_get", ["id": .string("1")])
        let attachment = try XCTUnwrap(detail["attachments"].array?.first)
        let exported = try module.call("mail_get_attachment", ["id": .string("1"), "part_id": attachment["partID"]])
        let bytes = try module.assets.read(id: exported["asset_id"].string!, offset: 0, length: 100)
        XCTAssertEqual(bytes["data_base64"].string, Data("Hello".utf8).base64EncodedString())
        XCTAssertEqual(try Data(contentsOf: path), original)
    }
    func testBatchBudgetAllowsCompleteContinuation() throws {
        let f = try MailFixture()
        for id in 1...25 {
            try f.add(id, text: "body")
            try f.db.run("UPDATE subjects SET subject=? WHERE ROWID=?", [.text(String(repeating: "长主题", count: 2000)), .int(Int64(id))])
        }
        let module = f.module(); var pending = (1...25).map { JSON.string(String($0)) }; var received: [String] = []
        while !pending.isEmpty {
            let page = try module.call("mail_get_many", ["ids": .array(pending)])
            XCTAssertLessThan(try page.data().count, 262144)
            let messages = page["messages"].array!
            XCTAssertFalse(messages.isEmpty)
            received += messages.compactMap { $0["id"].string }
            pending = page["remaining_ids"].array!
        }
        XCTAssertEqual(Set(received), Set((1...25).map(String.init)))
        XCTAssertEqual(received.count, 25)
    }
}
