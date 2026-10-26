import Foundation
import SQLite3

/// Fixed, content-free owner diagnostics for compatibility work; no arbitrary SQL/path input.
public enum SourceInspection {
    public static func run() -> JSON {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let group = home.appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared")
        let candidates = [group, home.appendingPathComponent("Library/Application Support/com.apple.voicememos"), home.appendingPathComponent("Library/Containers/com.apple.VoiceMemos/Data/Library/Application Support/com.apple.voicememos")]
        var enumerationErrors: [JSON] = []
        let files = candidates.flatMap { root in (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, errorHandler: { _, error in enumerationErrors.append(.string(String(describing: error))); return true })?.allObjects as? [URL]) ?? [] }
        let voiceDB = files.first { $0.lastPathComponent == "CloudRecordings.db" }
        let voiceRoot = voiceDB?.deletingLastPathComponent() ?? group.appendingPathComponent("Recordings")
        var result: [String: JSON] = [:]
        result["voice_database_found"] = .bool(voiceDB != nil)
        if let voiceDB, let db = try? LocalDatabase(voiceDB) {
            if let rows = try? db.query("SELECT ZPATH,ZCUSTOMLABEL,ZENCRYPTEDTITLE,ZAUDIOFUTURE,ZVERSIONEDAUDIOFUTURE FROM ZCLOUDRECORDING LIMIT 2") {
                result["voice_value_shapes"] = .array(rows.map { row in
                    .object(row.mapValues { cell in
                        switch cell {
                        case .text(let s): return .object(["type": .string("text"), "length": .int(s.count), "path_extension": .string((s as NSString).pathExtension), "is_absolute": .bool(s.hasPrefix("/")), "components": .int(s.split(separator: "/").count)])
                        case .blob(let data): return .object(["type": .string("blob"), "length": .int(data.count), "plist": .bool((try? PropertyListSerialization.propertyList(from: data, format: nil)) != nil)])
                        default: return .object(["type": .string("null_or_number")])
                        }
                    })
                })
            }
        }
        result["voice_enumeration_errors"] = .array(enumerationErrors)
        result["voice_database_names"] = .array(files.filter { ["db", "sqlite"].contains($0.pathExtension) }.map { .string($0.lastPathComponent) })
        result["voice_all_extensions"] = .object(Dictionary(grouping: files, by: { $0.pathExtension }).mapValues { .int($0.count) })
        result["voice_known_root_entries"] = .array(candidates.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] }.map(JSON.string))
        for (name, url) in [("messages", home.appendingPathComponent("Library/Messages/chat.db")), ("voice_memos", voiceRoot.appendingPathComponent("CloudRecordings.db"))] {
            do { result[name] = try schema(url) }
            catch { result[name] = .object(["error": .string(String(describing: error))]) }
        }
        if let db = try? LocalDatabase(home.appendingPathComponent("Library/Messages/chat.db")),
           let rows = try? db.query("SELECT text,attributedBody FROM message WHERE attributedBody IS NOT NULL AND coalesce(date_retracted,0)=0 ORDER BY ROWID DESC LIMIT 500") {
            var decoded = 0; var compared = 0; var identical = 0; var failures = 0; var differences: [JSON] = []
            for row in rows {
                guard let archive = row["attributedBody"]?.data else { continue }
                do {
                    let text = try MessagesModule.decodeAttributedBody(archive); decoded += 1
                    if let original = row["text"]?.string, !original.isEmpty {
                        compared += 1
                        if original == text { identical += 1 }
                        else {
                            let trim: (String) -> String = { $0.replacingOccurrences(of: "\u{FFFC}", with: "").replacingOccurrences(of: "\u{FFFD}", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
                            differences.append(.object(["plain_scalars": .int(original.unicodeScalars.count), "archive_scalars": .int(text.unicodeScalars.count), "equal_after_removing_placeholders_and_edge_whitespace": .bool(trim(original) == trim(text))]))
                        }
                    }
                } catch { failures += 1 }
            }
            result["messages_archive_validation"] = .object(["sampled": .int(rows.count), "decoded": .int(decoded), "decode_failures": .int(failures), "compared_to_nonempty_text_column": .int(compared), "identical_to_nonempty_text_column": .int(identical), "difference_shapes": .array(differences)])
        }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: voiceRoot, includingPropertiesForKeys: nil)
            result["voice_file_extensions"] = .object(Dictionary(grouping: files, by: { $0.pathExtension }).mapValues { .int($0.count) })
        } catch { result["voice_files_error"] = .string(String(describing: error)) }
        return .object(result)
    }
    private static func schema(_ url: URL) throws -> JSON {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { sqlite3_close(db); throw ServiceError("needs_permission", "Cannot open known source database") }
        defer { sqlite3_close(db) }
        var tables: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name", -1, &tables, nil) == SQLITE_OK else { throw ServiceError("unsupported_schema", "Cannot inspect source schema") }
        defer { sqlite3_finalize(tables) }
        var result: [String: JSON] = [:]
        while sqlite3_step(tables) == SQLITE_ROW {
            let table = String(cString: sqlite3_column_text(tables, 0))
            let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(quoted))", -1, &statement, nil) == SQLITE_OK else { continue }
            var columns: [JSON] = []
            while sqlite3_step(statement) == SQLITE_ROW { columns.append(.string(String(cString: sqlite3_column_text(statement, 1)))) }
            sqlite3_finalize(statement)
            result[table] = .array(columns)
        }
        return .object(result)
    }
}
