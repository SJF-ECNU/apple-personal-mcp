import Foundation
import MailStore

public final class MailModule {
    private let root: URL?
    public let assets: AssetStore
    private var cached: MailStore?
    public init(root: URL? = nil, assets: AssetStore = AssetStore()) { self.root = root; self.assets = assets }
    public func store() throws -> MailStore {
        if let cached { return cached }
        do {
            let location = try root.map { MailLocation(root: $0) } ?? MailLocation.discover()
            let value = try MailStore(location: location); cached = value; return value
        } catch let e as MailStoreError { throw ServiceError("unsupported_schema", e.description) }
        catch { throw ServiceError("needs_permission", "Mail local data cannot be opened. Grant Full Disk Access to ApplePersonalMCP.app, then restart its service. \(error)") }
    }
    private static let field = ToolDefinition.field
    public static let tools: [ToolDefinition] = {
        let id = field("string", "Positive native ID as decimal string")
        let paging: [String: JSON] = ["offset": field("integer", "Result offset, default 0"), "limit": field("integer", "Page size 1...200")]
        let body: [String: JSON] = ["id": id, "body_offset": field("integer", "Unicode scalar offset"), "max_chars": field("integer", "Body page size 1...16000"), "include_html": field("boolean", "Return an HTML page instead of plain text")]
        var search = paging
        for k in ["text", "subject", "sender", "recipient", "account_id", "mailbox_id", "date_from", "date_to", "body"] { search[k] = field("string", k) }
        search["unread"] = field("boolean", "Unread only when true")
        search["include_trash"] = field("boolean", "Include Trash and Junk")
        search["scan_offset"] = field("integer", "Candidate offset for body search")
        search["scan_limit"] = field("integer", "Body candidates per call, 1...500")
        let definitions = [
            ToolDefinition("mail_list_accounts", "Read local Mail accounts without starting Mail"),
            ToolDefinition("mail_list_mailboxes", "Read mailboxes and unread counts", ["account_id": field("string", "Exact account ID")]),
            ToolDefinition("mail_overview", "Unread counts and latest message previews"),
            ToolDefinition("mail_search", "Search metadata or complete downloaded MIME bodies. Body searches report unfinished candidate scans.", search),
            ToolDefinition("mail_get", "Read a complete message through bounded body pages", body, required: ["id"]),
            ToolDefinition("mail_get_many", "Read up to 200 message summaries under one response budget", ["ids": .object(["type": .string("array"), "items": id, "maxItems": .int(200)])], required: ["ids"]),
            ToolDefinition("mail_get_thread", "Read ordered conversation summaries; fetch full bodies separately", ["id": id].merging(paging) { a, _ in a }, required: ["id"]),
            ToolDefinition("mail_get_attachment", "Export a downloaded attachment into app-owned storage", ["id": id, "part_id": field("string", "MIME part ID from mail_get")], required: ["id", "part_id"]),
        ]
        return definitions.map { d in
            ToolDefinition(d.name, d.description, (d.inputSchema["properties"].object ?? [:]).merging(["backend": field("string", "auto (default), local, or official; official references remain qualified")]) { a, _ in a }, required: d.inputSchema["required"].array?.compactMap(\.string) ?? [])
        }
    }()
    public func call(_ name: String, _ values: [String: JSON]) throws -> JSON {
        let args = Arguments(values)
        let db = try store()
        let result: JSON
        switch name {
        case "mail_list_accounts": result = .object(["accounts": try .encoded(db.accounts())])
        case "mail_list_mailboxes": result = .object(["mailboxes": try .encoded(db.mailboxes(accountID: args.string("account_id")))])
        case "mail_overview":
            var q = MessageQuery(); q.limit = 10
            let boxes = try db.mailboxes()
            result = .object(["unread_by_mailbox": .array(boxes.filter { $0.unreadCount > 0 }.map { .object(["mailbox_id": .string(String($0.id)), "account_id": .string($0.accountID), "path": .string($0.path), "unread": .int($0.unreadCount)]) }), "latest": .array(try db.search(q).messages.map(Self.summary))])
        case "mail_search": result = try search(args, db)
        case "mail_get": result = try detail(args, db)
        case "mail_get_many":
            guard let ids = values["ids"]?.array, !ids.isEmpty, ids.count <= 200 else { throw ServiceError("invalid_arguments", "ids must contain 1...200 decimal ID strings") }
            let numbers = try ids.map { v -> Int64 in guard let s = v.string, let n = Int64(s), n > 0 else { throw ServiceError("invalid_arguments", "Invalid message ID") }; return n }
            let found = Dictionary(uniqueKeysWithValues: try db.messages(ids: numbers).map { ($0.id, $0) })
            var summaries: [JSON] = []; var usedBytes = 0; var remaining: [JSON] = []; var exhausted = false
            for (index, id) in numbers.enumerated() {
                guard let item = found[id] else { continue }
                let value = Self.summary(item); let size = try value.data().count
                if usedBytes + size > 250000 {
                    guard !summaries.isEmpty else { throw ServiceError("metadata_too_large", "Use mail_get for this single unusually large summary") }
                    remaining = Array(ids[index...]); exhausted = true; break
                }
                usedBytes += size; summaries.append(value)
            }
            result = .object(["messages": .array(summaries), "remaining_ids": .array(remaining), "has_more": .bool(exhausted), "bodies_included": .bool(false)])
        case "mail_get_thread":
            let item = try db.message(id: args.id())
            var q = MessageQuery(); q.conversationID = item.conversationID; q.accountIDs = [item.accountID]; q.includeTrashAndJunk = true; q.sortAscending = true
            q.limit = try args.integer("limit", default: 50, range: 1...200); q.offset = try args.integer("offset", default: 0, range: 0...Int.max)
            if item.conversationID == 0 { q.ids = [item.id]; q.conversationID = nil }
            result = try page(db.search(q), offset: q.offset)
        case "mail_get_attachment":
            let found = try db.attachmentData(messageID: args.id(), attachment: args.requiredString("part_id"))
            guard found.info.isDownloaded else { throw ServiceError("not_downloaded", "Mail has not downloaded this attachment") }
            result = try assets.save(found.data, filename: found.info.filename, mimeType: found.info.mimeType)
        default: throw ServiceError("unknown_tool", name)
        }
        var fields = result.object ?? [:]
        fields["source"] = .object(["application": .string("mail"), "backend": .string("local_readonly")])
        fields["observed_at"] = .string(ISO8601DateFormatter().string(from: Date()))
        fields["coverage"] = .string("current_mac_local_data")
        return .object(fields)
    }
    private func query(_ a: Arguments) throws -> MessageQuery {
        var q = MessageQuery()
        q.text = try a.string("text"); q.sender = try a.string("sender"); q.recipient = try a.string("recipient")
        if let s = try a.string("subject") { q.subjectTerms = [s] }
        if let s = try a.string("account_id") { q.accountIDs = [s] }
        if a.values["mailbox_id"] != nil { q.mailboxIDs = [try a.id("mailbox_id")] }
        if let unread = try a.bool("unread") { q.isRead = !unread }
        q.includeTrashAndJunk = try a.bool("include_trash") ?? false
        for k in ["date_from", "date_to"] {
            if let value = try a.string(k) {
                let f = ISO8601DateFormatter()
                guard let date = f.date(from: value) else { throw ServiceError("invalid_arguments", "\(k) requires ISO 8601 including timezone") }
                if k == "date_from" { q.dateFrom = date } else { q.dateTo = date }
            }
        }
        q.limit = try a.integer("limit", default: 50, range: 1...200)
        q.offset = try a.integer("offset", default: 0, range: 0...Int.max)
        return q
    }
    private func search(_ a: Arguments, _ db: MailStore) throws -> JSON {
        var q = try query(a)
        guard let body = try a.string("body"), !body.isEmpty else { return try page(db.search(q), offset: q.offset) }
        let start = try a.integer("scan_offset", default: 0, range: 0...Int.max)
        let budget = try a.integer("scan_limit", default: 100, range: 1...500)
        q.offset = start; q.limit = budget
        let candidates = try db.search(q)
        var matches: [JSON] = []; var unavailable = 0; var scanned = 0
        for item in candidates.messages {
            let detail = try db.detail(id: item.id)
            scanned += 1
            if !detail.bodyAvailable { unavailable += 1; continue }
            if (detail.textBody ?? "").range(of: body, options: [.caseInsensitive, .diacriticInsensitive]) != nil { matches.append(Self.summary(item)) }
        }
        return .object(["messages": .array(matches), "scanned": .int(scanned), "unavailable_bodies": .int(unavailable), "search_complete": .bool(!candidates.hasMore && unavailable == 0), "next_scan_offset": candidates.hasMore ? .int(start + scanned) : .null, "has_more": .bool(candidates.hasMore), "query_scope": .string("decoded_downloaded_bodies")])
    }
    private func page(_ p: SearchPage, offset: Int) throws -> JSON {
        .object(["messages": .array(p.messages.map(Self.summary)), "total": p.total.map(JSON.int) ?? .null, "has_more": .bool(p.hasMore), "next_offset": p.hasMore ? .int(offset + p.messages.count) : .null, "search_complete": .bool(true)])
    }
    private func detail(_ a: Arguments, _ db: MailStore) throws -> JSON {
        let value = try db.detail(id: a.id())
        var fields = Self.summary(value.summary).object!
        fields["to"] = try .encoded(value.to); fields["cc"] = try .encoded(value.cc)
        fields["attachments"] = try .encoded(value.attachments)
        fields["body_downloaded"] = .bool(value.bodyAvailable)
        if value.bodyAvailable {
            let html = try a.bool("include_html") ?? false
            fields["body_view"] = .string(html ? "html" : "original_text")
            fields["body"] = try BodyPaging.page(html ? value.htmlBody ?? "" : value.textBody ?? "", arguments: a)
        } else { fields["content_status"] = .string("not_downloaded") }
        return .object(fields)
    }
    public static func summary(_ m: MessageSummary) -> JSON {
        .object(["id": .string(String(m.id)), "account_id": .string(m.accountID), "mailbox_id": .string(String(m.mailboxID)), "mailbox": .string(m.mailboxPath), "subject": .string(m.subject), "sender": .string(m.sender.formatted), "received_at": .string(ISO8601DateFormatter().string(from: m.dateReceived)), "is_read": .bool(m.isRead), "flagged": .bool(m.isFlagged), "preview": .string(String((m.preview ?? "").prefix(300))), "message_id": m.messageIDHeader.map(JSON.string) ?? .null, "conversation_id": .string(String(m.conversationID)), "open_url": m.mailLink.map(JSON.string) ?? .null])
    }
}
