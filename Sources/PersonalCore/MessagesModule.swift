import Foundation
import TypedStream

public final class MessagesModule {
    private let database: LocalDatabase
    private let attachmentRoot: URL
    private let assets: AssetStore
    public init(databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db"), attachmentRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/Attachments"), assets: AssetStore) throws {
        database = try LocalDatabase(databaseURL); self.attachmentRoot = attachmentRoot; self.assets = assets
        _ = try database.query("SELECT m.ROWID,m.guid,m.text,m.attributedBody,m.date,m.date_edited,m.date_retracted,m.is_from_me,m.is_read,m.service,m.handle_id,m.associated_message_guid,m.associated_message_type,m.thread_originator_guid,m.reply_to_guid,m.item_type FROM message m LIMIT 0")
    }
    public static let tools: [ToolDefinition] = {
        let field = ToolDefinition.field; let id = field("string", "Positive native decimal ID")
        let paging = ["offset": field("integer", "Result/candidate offset"), "limit": field("integer", "1...200")]
        return [
            ToolDefinition("messages_list_chats", "List locally synchronized chats and participant handles", paging),
            ToolDefinition("messages_search", "Scan local history, including typedstream bodies; reports incomplete scans", paging.merging(["chat_id": id, "text": field("string", "Body contains; scans at most scan_limit candidates"), "scan_limit": field("integer", "1...200, default 100"), "date_from": field("string", "ISO 8601 with timezone"), "date_to": field("string", "ISO 8601 with timezone")]) { a, _ in a }),
            ToolDefinition("messages_get_thread", "Read a chronological page of one local chat; full bodies fetched separately", paging.merging(["chat_id": id]) { a, _ in a }, required: ["chat_id"]),
            ToolDefinition("messages_get", "Read complete plain/typedstream text in pages, plus reply and attachment metadata; retracted text is withheld", ["id": id, "body_offset": field("integer", "Unicode scalar offset"), "max_chars": field("integer", "1...16000")], required: ["id"]),
            ToolDefinition("messages_get_attachment", "Export an already local attachment without changing Messages", ["id": id, "attachment_id": id], required: ["id", "attachment_id"]),
        ]
    }()
    private let select = "SELECT m.ROWID AS id,m.guid,m.text,m.attributedBody,m.date,m.date_edited,m.date_retracted,m.is_from_me,m.is_read,m.service,m.associated_message_guid,m.associated_message_type,m.thread_originator_guid,m.reply_to_guid,m.item_type,h.id AS sender FROM message m LEFT JOIN handle h ON h.ROWID=m.handle_id"
    public static func decodeAttributedBody(_ data: Data) throws -> String {
        // NSString is encoded first by NSAttributedString. Do not use Madrid.stringValue:
        // that convenience accessor filters legitimate messages containing 'NS'/emoji/Attribute.
        let values = try TypedStreamDecoder.decode(data)
        guard let first = values.first, case .object(let kind, let fields) = first,
              ["NSString", "NSMutableString"].contains(kind.name), let value = fields.first,
              case .string(let text) = value else { throw ServiceError("unsupported_format", "Attributed body does not start with a supported NSString payload") }
        return text
    }
    private func body(_ row: [String: LocalCell]) -> (String?, String) {
        if row.integer("date_retracted") > 0 { return (nil, "retracted") }
        if let text = row["text"]?.string, !text.isEmpty { return (text, "text_column") }
        if let archive = row["attributedBody"]?.data, !archive.isEmpty {
            do { return (try Self.decodeAttributedBody(archive), "typedstream") } catch { return (nil, "unsupported_format") }
        }
        return (row["text"]?.string, "no_local_text")
    }
    private func date(_ value: Int64) -> JSON {
        guard value != 0 else { return .null }
        let seconds = abs(value) > 100000000000 ? Double(value) / 1_000_000_000 : Double(value)
        return .string(ISO8601DateFormatter().string(from: Date(timeIntervalSinceReferenceDate: seconds)))
    }
    private func summary(_ row: [String: LocalCell]) -> JSON {
        let (text, source) = body(row)
        return .object(["id": .string(String(row.integer("id"))), "guid": .string(row.text("guid")), "date": date(row.integer("date")), "sender": row.integer("is_from_me") != 0 ? .null : .string(row.text("sender")), "from_me": .bool(row.integer("is_from_me") != 0), "is_read": .bool(row.integer("is_read") != 0), "service": .string(row.text("service")), "preview": text.map { .string(String($0.prefix(300))) } ?? .null, "body_source": .string(source), "content_status": .string(text == nil ? "unavailable" : "preview"), "reply_to_guid": .string(row.text("reply_to_guid")), "thread_originator_guid": .string(row.text("thread_originator_guid")), "associated_message_guid": .string(row.text("associated_message_guid")), "associated_message_type": .int(Int(row.integer("associated_message_type"))), "edited_at": date(row.integer("date_edited")), "retracted_at": date(row.integer("date_retracted")), "item_type": .int(Int(row.integer("item_type")))])
    }
    private func attachmentURL(_ value: String) throws -> URL {
        let url = URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL
        let root = attachmentRoot.resolvingSymlinksInPath().path + "/"
        guard !value.isEmpty, url.resolvingSymlinksInPath().path.hasPrefix(root), FileManager.default.isReadableFile(atPath: url.path) else { throw ServiceError("not_downloaded", "Attachment is not available inside the local Messages attachment directory") }
        return url
    }
    private func attachmentRows(_ id: String) throws -> [[String: LocalCell]] {
        try database.query("SELECT a.ROWID AS id,a.transfer_name,a.filename,a.mime_type,a.total_bytes,a.transfer_state FROM attachment a JOIN message_attachment_join j ON j.attachment_id=a.ROWID WHERE j.message_id=? ORDER BY a.ROWID", [id])
    }
    public func status() throws -> JSON {
        let rows = try database.query("SELECT count(*) AS count,sum(CASE WHEN attributedBody IS NOT NULL THEN 1 ELSE 0 END) AS archives FROM message")
        return .object(["state": .string("ready"), "messages": .int(Int(rows.first?.integer("count") ?? 0)), "archived_bodies": .int(Int(rows.first?.integer("archives") ?? 0)), "backend": .string("local_readonly"), "writes_implemented": .bool(false)])
    }
    public func call(_ name: String, _ values: [String: JSON]) throws -> JSON {
        let args = Arguments(values); let result: JSON
        switch name {
        case "messages_list_chats":
            let offset = try args.integer("offset", default: 0, range: 0...Int.max); let limit = try args.integer("limit", default: 50, range: 1...200)
            let rows = try database.query("SELECT c.ROWID AS id,c.guid,c.display_name,c.chat_identifier,c.service_name,max(j.message_date) AS latest FROM chat c LEFT JOIN chat_message_join j ON j.chat_id=c.ROWID GROUP BY c.ROWID ORDER BY latest DESC,c.ROWID DESC LIMIT ? OFFSET ?", [String(limit + 1), String(offset)])
            let page = try rows.prefix(limit).map { row -> JSON in
                let participants = try database.query("SELECT h.id FROM handle h JOIN chat_handle_join j ON j.handle_id=h.ROWID WHERE j.chat_id=? ORDER BY h.ROWID", [String(row.integer("id"))]).map { JSON.string($0.text("id")) }
                return .object(["id": .string(String(row.integer("id"))), "guid": .string(row.text("guid")), "title": .string(row.text("display_name")), "chat_identifier": .string(row.text("chat_identifier")), "service": .string(row.text("service_name")), "latest_date": date(row.integer("latest")), "participants": .array(participants)])
            }
            result = .object(["chats": .array(page), "has_more": .bool(rows.count > limit), "next_offset": rows.count > limit ? .int(offset + limit) : .null])
        case "messages_search", "messages_get_thread":
            var conditions: [String] = []; var bindings: [String] = []
            if values["chat_id"] != nil || name == "messages_get_thread" {
                conditions.append("EXISTS(SELECT 1 FROM chat_message_join j WHERE j.message_id=m.ROWID AND j.chat_id=?)"); bindings.append(String(try args.id("chat_id")))
            }
            for (key, comparison) in [("date_from", ">="), ("date_to", "<")] {
                if let value = try args.string(key) {
                    let date = try EventKitModule.date(value).timeIntervalSinceReferenceDate * 1_000_000_000
                    guard date >= 0, date < Double(Int64.max) else { throw ServiceError("invalid_arguments", "Date is outside supported Messages range") }
                    conditions.append("m.date \(comparison) ?"); bindings.append(String(Int64(date)))
                }
            }
            let offset = try args.integer("offset", default: 0, range: 0...Int.max); let limit = try args.integer("limit", default: 50, range: 1...200)
            let text = try args.string("text")
            let scan = text != nil ? try args.integer("scan_limit", default: 100, range: 1...200) : limit
            let direction = name == "messages_get_thread" ? "ASC" : "DESC"
            let whereClause = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
            let rows = try database.query(select + whereClause + " ORDER BY m.date \(direction),m.ROWID \(direction) LIMIT ? OFFSET ?", bindings + [String(scan + 1), String(offset)])
            var matches: [JSON] = []; var unavailable = 0; var checked = 0
            for row in rows.prefix(scan) {
                let (body, _) = self.body(row); checked += 1
                if body == nil { unavailable += 1 }
                if text == nil || body?.localizedCaseInsensitiveContains(text!) == true { matches.append(summary(row)) }
                if matches.count == limit { break }
            }
            let more = rows.count > checked
            result = .object(["messages": .array(matches), "has_more": .bool(more), "next_offset": more ? .int(offset + checked) : .null, "scanned": .int(checked), "unavailable_bodies": .int(unavailable), "search_complete": .bool(!more && (text == nil || unavailable == 0))])
        case "messages_get":
            let id = String(try args.id())
            guard let row = try database.query(select + " WHERE m.ROWID=?", [id]).first else { throw ServiceError("not_found", "Local message not found") }
            var fields = summary(row).object!
            let (body, source) = self.body(row)
            if let body {
                fields["body"] = try BodyPaging.page(body, arguments: args); fields["content_status"] = fields["body"]?["content_status"]
            } else { fields["unavailable_reason"] = .string(source) }
            fields["attachments"] = .array(try attachmentRows(id).map { row in
                .object(["id": .string(String(row.integer("id"))), "filename": .string(row.text("transfer_name")), "mime_type": .string(row.text("mime_type")), "size": .int(Int(row.integer("total_bytes"))), "is_downloaded": .bool((try? attachmentURL(row.text("filename"))) != nil)])
            }); result = .object(fields)
        case "messages_get_attachment":
            let id = String(try args.id()); let attachment = try args.id("attachment_id")
            guard let row = try attachmentRows(id).first(where: { $0.integer("id") == attachment }) else { throw ServiceError("not_found", "Attachment does not belong to this message") }
            let url = try attachmentURL(row.text("filename"))
            result = try assets.saveFile(url, filename: row.text("transfer_name"), mimeType: row.text("mime_type").isEmpty ? "application/octet-stream" : row.text("mime_type"))
        default: throw ServiceError("unknown_tool", name)
        }
        return .object((result.object ?? [:]).merging(["source": .object(["application": .string("messages"), "backend": .string("local_readonly")]), "coverage": .string("current_mac_local_history; unavailable bodies are explicit"), "observed_at": .string(ISO8601DateFormatter().string(from: Date()))]) { a, _ in a })
    }
}
