import XCTest
import SQLite3
@testable import PersonalCore

final class VoiceMemosTests: XCTestCase {
    private func word(_ n: UInt32) -> Data { withUnsafeBytes(of: n.bigEndian) { Data($0) } }
    private func atom(_ name: String, _ payload: Data) -> Data { atom(word(name.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }), payload) }
    private func atom(_ type: Data, _ payload: Data) -> Data { word(UInt32(payload.count + 8)) + type + payload }
    private var transcript: JSON { .object(["locale": .object(["identifier": .string("zh_CN")]), "attributedString": .object(["runs": .array([.string("我们"), .int(0), .string("讨论 DNS AttributeNS 👩🏽‍💻。"), .int(0)]), "attributeTable": .array([.object(["timeRange": .array([.number(0), .number(1.25)])])])])]) }
    private func media(_ qta: Bool) throws -> Data {
        let json = try transcript.data()
        if !qta { return atom("moov", atom("trak", atom("udta", atom("tsrp", json)))) }
        let key = Data("com.apple.VoiceMemos.tsrp".utf8)
        let keys = atom("keys", Data(repeating: 0, count: 4) + word(1) + word(UInt32(key.count + 8)) + Data("mdta".utf8) + key)
        let item = atom(word(1), atom("data", Data(repeating: 0, count: 8) + json))
        return atom("moov", atom("meta", Data(repeating: 0, count: 4) + keys + atom("ilst", item)))
    }
    func testDirectAndKeyedTranscriptsPreserveAllOriginalRuns() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        for qta in [false, true] {
            try media(qta).write(to: url)
            let parsed = try OriginalTranscript(url: url).read()
            XCTAssertEqual(parsed, [transcript])
            XCTAssertEqual(try OriginalTranscript.text(parsed[0]), "我们讨论 DNS AttributeNS 👩🏽‍💻。")
        }
        try atom("mdat", transcript.data()).write(to: url)
        XCTAssertTrue(try OriginalTranscript(url: url).read().isEmpty, "JSON in audio bytes must not be mistaken for transcript metadata")
        try (word(4) + Data("moov".utf8)).write(to: url)
        XCTAssertThrowsError(try OriginalTranscript(url: url).read())
        var invalid = transcript.object!; invalid["attributedString"] = .object(["runs": .array([.string("text"), .int(9)]), "attributeTable": .array([])])
        XCTAssertThrowsError(try OriginalTranscript.text(.object(invalid)))
    }
    func testSyntheticRecordingExportAndFullTextPages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(root.appendingPathComponent("CloudRecordings.db").path, &db), SQLITE_OK)
        let sql = "CREATE TABLE ZCLOUDRECORDING(Z_PK INTEGER PRIMARY KEY,ZUNIQUEID TEXT,ZENCRYPTEDTITLE TEXT,ZCUSTOMLABELFORSORTING TEXT,ZDATE REAL,ZDURATION REAL,ZPATH TEXT,ZFLAGS INTEGER); INSERT INTO ZCLOUDRECORDING VALUES(1,'uuid','synthetic','synthetic',800000000,1.25,'sample.qta',8); INSERT INTO ZCLOUDRECORDING VALUES(2,'missing','missing','missing',800000001,0,'missing.m4a',0)"
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        let bytes = try media(true); try bytes.write(to: root.appendingPathComponent("sample.qta"))
        let assets = AssetStore(root: root.appendingPathComponent("Exports")); let module = try VoiceMemosModule(root: root, assets: assets)
        XCTAssertEqual(try module.status()["downloaded_media"].int, 1)
        XCTAssertEqual(try module.call("voicememos_get", ["id": .string("2")])["audio_downloaded"].boolean, false)
        XCTAssertThrowsError(try module.call("voicememos_get_transcript", ["id": .string("2")]))
        var text = ""; var offset = 0
        while true {
            let result = try module.call("voicememos_get_transcript", ["id": .string("1"), "body_offset": .int(offset), "max_chars": .int(3)])
            XCTAssertEqual(result["transcript_source"].string, "apple_original_embedded")
            text += result["body"]["text"].string!
            guard let next = result["body"]["next_offset"].int else { break }; offset = next
        }
        XCTAssertEqual(text, try OriginalTranscript.text(transcript))
        let asset = try module.call("voicememos_get_audio", ["id": .string("1")])
        XCTAssertTrue(asset["filename"].string!.hasSuffix(".qta"))
        XCTAssertEqual(try assets.read(id: asset["asset_id"].string!, offset: 0, length: 524288)["data_base64"].string, bytes.base64EncodedString())
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("sample.qta")), bytes)
    }
}
