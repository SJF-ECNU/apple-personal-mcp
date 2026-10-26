import Foundation
import UniformTypeIdentifiers

public final class VoiceMemosModule {
    private let root: URL
    private let database: LocalDatabase
    private let assets: AssetStore
    public init(root: URL? = nil, assets: AssetStore) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"), home.appendingPathComponent("Library/Application Support/com.apple.voicememos/Recordings")]
        guard let selected = root ?? candidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("CloudRecordings.db").path) }) else { throw ServiceError("source_unavailable", "Voice Memos has no readable local database; open the app and allow iCloud synchronization") }
        self.root = selected; self.assets = assets; database = try LocalDatabase(selected.appendingPathComponent("CloudRecordings.db"))
        _ = try database.query("SELECT Z_PK,ZUNIQUEID,ZENCRYPTEDTITLE,ZCUSTOMLABELFORSORTING,ZDATE,ZDURATION,ZPATH,ZFLAGS FROM ZCLOUDRECORDING LIMIT 0")
    }
    public static let tools: [ToolDefinition] = {
        let field = ToolDefinition.field; let id = field("string", "Exact local recording ID")
        return [
            ToolDefinition("voicememos_list", "List local recording metadata; audio may still be downloading", ["text": field("string", "Title contains"), "offset": field("integer", "Result offset"), "limit": field("integer", "1...200")]),
            ToolDefinition("voicememos_get", "Read one recording's metadata and exact referenced media availability", ["id": id], required: ["id"]),
            ToolDefinition("voicememos_get_audio", "Export the exact original local media; preserves qta/m4a format", ["id": id], required: ["id"]),
            ToolDefinition("voicememos_get_transcript", "Read Apple's original embedded transcript through complete text pages; never generates replacement text", ["id": id, "track_index": field("integer", "Transcript index, default 0; available_tracks lists alternatives"), "body_offset": field("integer", "Unicode scalar offset"), "max_chars": field("integer", "1...16000"), "include_raw": field("boolean", "Also export original JSON including word timings")], required: ["id"]),
        ]
    }()
    private func audio(_ row: [String: LocalCell]) throws -> URL {
        let path = row.text("ZPATH")
        guard !path.isEmpty else { throw ServiceError("not_downloaded", "Original recording has no local path yet") }
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)).standardizedFileURL
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
              let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), attributes.isRegularFile == true, (attributes.fileSize ?? 0) > 0,
              FileManager.default.isReadableFile(atPath: url.path) else { throw ServiceError("not_downloaded", "The exact referenced media is not downloaded. Open Voice Memos to synchronize; no revision is guessed by filename.") }
        return url
    }
    private func summary(_ row: [String: LocalCell]) -> JSON {
        let title = row["ZENCRYPTEDTITLE"]?.string ?? row.text("ZCUSTOMLABELFORSORTING")
        return .object(["id": .string(String(row.integer("Z_PK"))), "uuid": .string(row.text("ZUNIQUEID")), "title": .string(title), "created_at": .string(ISO8601DateFormatter().string(from: Date(timeIntervalSinceReferenceDate: row["ZDATE"]?.double ?? 0))), "duration_seconds": .number(row["ZDURATION"]?.double ?? 0), "audio_downloaded": .bool((try? audio(row)) != nil), "native_extension": .string((row.text("ZPATH") as NSString).pathExtension), "native_flags": .int(Int(row.integer("ZFLAGS"))), "deletion_state": .string("native_flags_not_interpreted")])
    }
    private func recording(_ args: Arguments) throws -> [String: LocalCell] {
        guard let row = try database.query("SELECT * FROM ZCLOUDRECORDING WHERE Z_PK=?", [String(try args.id())]).first else { throw ServiceError("not_found", "Local recording not found") }; return row
    }
    func localAudio(id: String) throws -> URL { try audio(recording(Arguments(["id": .string(id)]))) }
    public func status() throws -> JSON {
        let rows = try database.query("SELECT ZPATH FROM ZCLOUDRECORDING")
        return .object(["state": .string("ready"), "recordings": .int(rows.count), "downloaded_media": .int(rows.filter { (try? audio($0)) != nil }.count), "backend": .string("local_readonly"), "writes_implemented": .bool(false)])
    }
    public func call(_ name: String, _ values: [String: JSON]) throws -> JSON {
        let args = Arguments(values); let result: JSON
        switch name {
        case "voicememos_list":
            let offset = try args.integer("offset", default: 0, range: 0...Int.max); let limit = try args.integer("limit", default: 50, range: 1...200)
            let text = try args.string("text"); let filter = text == nil ? "" : " WHERE instr(lower(coalesce(ZENCRYPTEDTITLE,ZCUSTOMLABELFORSORTING,'')),lower(?))>0"
            let rows = try database.query("SELECT * FROM ZCLOUDRECORDING" + filter + " ORDER BY ZDATE DESC,Z_PK DESC LIMIT ? OFFSET ?", (text.map { [$0] } ?? []) + [String(limit + 1), String(offset)])
            result = .object(["recordings": .array(rows.prefix(limit).map(summary)), "has_more": .bool(rows.count > limit), "next_offset": rows.count > limit ? .int(offset + limit) : .null, "visibility": .string("all_local_database_rows; native deletion flags not interpreted")])
        case "voicememos_get": result = summary(try recording(args))
        case "voicememos_get_audio":
            let row = try recording(args); let url = try audio(row)
            result = try assets.saveFile(url, filename: url.lastPathComponent, mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream")
        case "voicememos_get_transcript":
            let row = try recording(args); let url = try audio(row)
            let before = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
            let transcripts = try OriginalTranscript(url: url).read()
            let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
            guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate,
                  String(describing: before.fileResourceIdentifier) == String(describing: after.fileResourceIdentifier) else { throw ServiceError("source_changed", "Media changed during transcript extraction") }
            guard !transcripts.isEmpty else { throw ServiceError("no_original_transcript", "No supported original transcript is embedded in the local recording; no new transcript was generated") }
            let index = try args.integer("track_index", default: 0, range: 0...transcripts.count - 1)
            let selected = transcripts[index]; let text = try OriginalTranscript.text(selected)
            var fields: [String: JSON] = ["id": .string(String(row.integer("Z_PK"))), "transcript_source": .string("apple_original_embedded"), "media_extension": .string(url.pathExtension), "audio_revision_alignment": .string("embedded_metadata; alignment_after_edits_not_verified"), "track_index": .int(index), "available_tracks": .array(transcripts.enumerated().map { .object(["index": .int($0.offset), "locale": $0.element["locale"]]) }), "body": try BodyPaging.page(text, arguments: args)]
            if try args.bool("include_raw") == true { fields["raw_json"] = try assets.save(selected.data(), filename: "original-transcript.json", mimeType: "application/json") }
            result = .object(fields)
        default: throw ServiceError("unknown_tool", name)
        }
        return .object((result.object ?? [:]).merging(["source": .object(["application": .string("voice_memos"), "backend": .string("local_readonly")]), "coverage": .string("current_mac_local_data"), "observed_at": .string(ISO8601DateFormatter().string(from: Date()))]) { a, _ in a })
    }
}
