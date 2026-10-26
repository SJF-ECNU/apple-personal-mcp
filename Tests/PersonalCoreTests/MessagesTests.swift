import XCTest
import SQLite3
@testable import PersonalCore

final class MessagesTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data { try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "typedstream", subdirectory: "Fixtures")!) }
    func testNativeArchivesPreserveEmojiMetadataWordsAndLongText() throws {
        XCTAssertEqual(try MessagesModule.decodeAttributedBody(fixture("metadata-words")), "DNS AttributeNS __k text 👩🏽‍💻\n")
        XCTAssertEqual(try MessagesModule.decodeAttributedBody(fixture("emoji")), "👩🏽‍💻🙂\u{FFFC}")
        XCTAssertEqual(try MessagesModule.decodeAttributedBody(fixture("long")), String(repeating: "中文 DNS AttributeNS 👩🏽‍💻\n", count: 4000))
        XCTAssertThrowsError(try MessagesModule.decodeAttributedBody(Data("invalid".utf8)))
        XCTAssertThrowsError(try MessagesModule.decodeAttributedBody(fixture("long").prefix(25)))
    }
    func testWALSearchAttributedBodyAndRetraction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("chat.db").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE message(ROWID INTEGER PRIMARY KEY,guid TEXT,text TEXT,attributedBody BLOB,date INTEGER,date_edited INTEGER DEFAULT 0,date_retracted INTEGER DEFAULT 0,is_from_me INTEGER DEFAULT 0,is_read INTEGER DEFAULT 0,service TEXT,handle_id INTEGER,associated_message_guid TEXT,associated_message_type INTEGER,thread_originator_guid TEXT,reply_to_guid TEXT,item_type INTEGER);
        CREATE TABLE handle(ROWID INTEGER PRIMARY KEY,id TEXT);
        CREATE TABLE chat(ROWID INTEGER PRIMARY KEY,guid TEXT,display_name TEXT,chat_identifier TEXT,service_name TEXT);
        CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER,message_date INTEGER);
        CREATE TABLE chat_handle_join(chat_id INTEGER,handle_id INTEGER);
        CREATE TABLE attachment(ROWID INTEGER PRIMARY KEY,transfer_name TEXT,filename TEXT,mime_type TEXT,total_bytes INTEGER,transfer_state INTEGER);
        CREATE TABLE message_attachment_join(message_id INTEGER,attachment_id INTEGER);
        INSERT INTO handle VALUES(1,'test@example.invalid');
        INSERT INTO chat VALUES(1,'chat-guid','synthetic','synthetic','iMessage');
        INSERT INTO chat_handle_join VALUES(1,1);
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        let module = try MessagesModule(databaseURL: root.appendingPathComponent("chat.db"), attachmentRoot: root.appendingPathComponent("Attachments"), assets: AssetStore(root: root.appendingPathComponent("Exports")))
        var s: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO message(ROWID,guid,attributedBody,date,handle_id,service) VALUES(1,'guid',?,800000000000000000,1,'iMessage')", -1, &s, nil), SQLITE_OK)
        let data = try fixture("metadata-words")
        data.withUnsafeBytes { bytes in _ = sqlite3_bind_blob(s, 1, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        XCTAssertEqual(sqlite3_step(s), SQLITE_DONE); sqlite3_finalize(s)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO chat_message_join VALUES(1,1,800000000000000000)", nil, nil, nil), SQLITE_OK)
        let search = try module.call("messages_search", ["text": .string("AttributeNS")])
        XCTAssertEqual(search["messages"].array?.count, 1)
        XCTAssertEqual(search["messages"].array?.first?["body_source"].string, "typedstream")
        XCTAssertEqual(try module.call("messages_get", ["id": .string("1")])["body"]["text"].string, "DNS AttributeNS __k text 👩🏽‍💻\n")
        XCTAssertEqual(try module.call("messages_list_chats", [:])["chats"].array?.first?["participants"].array, [.string("test@example.invalid")])
        let attachment = root.appendingPathComponent("Attachments/source.bin")
        try FileManager.default.createDirectory(at: attachment.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: attachment)
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO attachment VALUES(1,'test.bin',?,'application/octet-stream',3,0)", -1, &s, nil), SQLITE_OK)
        sqlite3_bind_text(s, 1, attachment.path, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        XCTAssertEqual(sqlite3_step(s), SQLITE_DONE); sqlite3_finalize(s)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO message_attachment_join VALUES(1,1); INSERT INTO attachment VALUES(2,'outside','/etc/hosts','text/plain',3,0); INSERT INTO message_attachment_join VALUES(1,2)", nil, nil, nil), SQLITE_OK)
        let exported = try module.call("messages_get_attachment", ["id": .string("1"), "attachment_id": .string("1")])
        XCTAssertEqual(exported["size"].int, 3)
        XCTAssertEqual(try Data(contentsOf: attachment), Data("abc".utf8))
        XCTAssertThrowsError(try module.call("messages_get_attachment", ["id": .string("1"), "attachment_id": .string("2")]))
        XCTAssertEqual(sqlite3_exec(db, "UPDATE message SET date_retracted=1 WHERE ROWID=1", nil, nil, nil), SQLITE_OK)
        let retracted = try module.call("messages_get", ["id": .string("1")])
        XCTAssertEqual(retracted["unavailable_reason"].string, "retracted"); XCTAssertEqual(retracted["body"], .null)
    }
    func testSQLiteTextPreservesEmbeddedNULAndSourceCannotBeWritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE sample(value TEXT); INSERT INTO sample VALUES('a'||char(0)||'b')", nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        let source = try LocalDatabase(url)
        XCTAssertEqual(try source.query("SELECT value FROM sample").first?.text("value"), "a\0b")
        XCTAssertThrowsError(try source.query("DELETE FROM sample"))
        XCTAssertEqual(try source.query("SELECT count(*) AS count FROM sample").first?.integer("count"), 1)
    }
    func testCopiedOldMediaHasFreshExportLifetime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original"); try Data("old media".utf8).write(to: source)
        let date = Date(timeIntervalSince1970: 0); try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: source.path)
        let assets = AssetStore(root: root.appendingPathComponent("Exports"))
        let exported = try assets.saveFile(source, filename: "original", mimeType: "application/octet-stream")
        XCTAssertEqual(try assets.read(id: exported["asset_id"].string!, offset: 0, length: 20)["data_base64"].string, Data("old media".utf8).base64EncodedString())
        XCTAssertEqual(try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date)
    }
}
