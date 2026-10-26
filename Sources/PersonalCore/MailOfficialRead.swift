import AppKit
import Foundation
import MailStore

struct OfficialMailReference: Codable {
    var account: String
    var path: String
    var id: Int32?
    var header: String?
    var specifier: Data? = nil
    var token: String { "mail-api:" + ((try? JSONEncoder().encode(self)) ?? Data()).base64EncodedString() }
    static func decode(_ value: String) throws -> Self {
        guard value.hasPrefix("mail-api:"), value.utf8.count <= 32768, let data = Data(base64Encoded: String(value.dropFirst(9))),
              let ref = try? JSONDecoder().decode(Self.self, from: data), !ref.path.isEmpty, ref.id == nil || ref.id! > 0 else { throw ServiceError("invalid_reference", "Use the exact official reference returned by Mail search") }
        return ref
    }
}

/// Bounded official scripting fallback. IDs deliberately cannot be confused with local row IDs.
final class MailOfficialRead {
    let api: MailAutomation
    let module: MailModule
    let authorize: () throws -> Void
    init(api: MailAutomation, module: MailModule, authorize: @escaping () throws -> Void) { self.api = api; self.module = module; self.authorize = authorize }
    static func requested(_ values: [String: JSON]) -> Bool {
        values["backend"]?.string == "official" || [values["id"], values["mailbox_id"]].contains { $0?.string?.hasPrefix("mail-api:") == true } || (values["ids"]?.array ?? []).contains { $0.string?.hasPrefix("mail-api:") == true }
    }
    private func account(_ id: String) -> NSAppleEventDescriptor? { id.isEmpty ? nil : AppleEvents.object("mact", "ID  ", NSAppleEventDescriptor(string: id)) }
    private func box(_ ref: OfficialMailReference) -> NSAppleEventDescriptor {
        if let specifier = ref.specifier, let value = NSAppleEventDescriptor(descriptorType: AppleEvents.code("obj "), data: specifier) { return value }
        return AppleEvents.object("mbxp", "name", NSAppleEventDescriptor(string: ref.path), account(ref.account))
    }
    private func reference(_ value: String) throws -> OfficialMailReference {
        if value.hasPrefix("mail-api:") { return try OfficialMailReference.decode(value) }
        let db = try module.store(); let item = try db.message(id: Arguments(["id": .string(value)]).id())
        guard let id = Int32(exactly: item.id), let mailbox = try db.mailbox(id: item.mailboxID) else { throw ServiceError("unsupported_id", "Native message ID cannot be represented exactly") }
        return OfficialMailReference(account: item.accountID, path: mailbox.path, id: id, header: item.messageIDHeader ?? "")
    }
    private func message(_ ref: OfficialMailReference) throws -> NSAppleEventDescriptor {
        guard let id = ref.id, ref.header != nil else { throw ServiceError("invalid_reference", "A message reference is required") }
        let value = AppleEvents.object("mssg", "ID  ", NSAppleEventDescriptor(int32: id), box(ref))
        guard (try api.get("meid", value).stringValue ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) == ref.header else { throw ServiceError("source_changed", "Official message reference no longer matches") }
        return value
    }
    private func accounts() throws -> [String] { AppleEvents.strings(try api.event("core", "getd", AppleEvents.property("ID  ", AppleEvents.all("mact")))) }
    private func boxes(_ accountID: String?) throws -> [OfficialMailReference] {
        var found: [OfficialMailReference] = []
        func visit(_ parent: NSAppleEventDescriptor?, accountID: String, path: String, depth: Int) throws {
            guard depth < 32, found.count < 1000 else { throw ServiceError("query_too_large", "Narrow official queries to a single mailbox/account") }
            let children = AppleEvents.items(try api.event("core", "getd", AppleEvents.all("mbxp", parent: parent)))
            for child in children {
                let name = try api.get("pnam", child).stringValue ?? ""
                guard !name.isEmpty else { throw ServiceError("unsupported_mailbox", "Mail returned a mailbox without a name") }
                let current = path.isEmpty ? name : path + "/" + name
                found.append(OfficialMailReference(account: accountID, path: current, specifier: child.data))
                try visit(child, accountID: accountID, path: current, depth: depth + 1)
            }
        }
        if let accountID { try visit(account(accountID), accountID: accountID, path: "", depth: 0) }
        else {
            for id in try accounts() { try visit(account(id), accountID: id, path: "", depth: 0) }
            try visit(nil, accountID: "", path: "", depth: 0)
        }
        return found
    }
    private func iso(_ date: Date?) -> JSON { date.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null }
    private func summary(_ ref: OfficialMailReference) throws -> JSON {
        let object = try message(ref)
        return .object(["id": .string(ref.token), "native_id": .string(String(ref.id!)), "message_id": .string(ref.header ?? ""), "account_id": .string(ref.account), "mailbox": .string(ref.path), "mailbox_id": .string(OfficialMailReference(account: ref.account, path: ref.path, specifier: ref.specifier).token), "subject": .string(try api.get("subj", object).stringValue ?? ""), "sender": .string(try api.get("sndr", object).stringValue ?? ""), "received_at": iso(try api.get("rdrc", object).dateValue), "is_read": .bool(try api.get("isrd", object).booleanValue), "flagged": .bool(try api.get("isfl", object).booleanValue), "preview": .string(""), "preview_available": .bool(false)])
    }
    private func body(_ object: NSAppleEventDescriptor) throws -> String {
        let read = try api.get("isrd", object).booleanValue
        let descriptor = try api.get("ctnt", object)
        guard let content = descriptor.stringValue else { throw ServiceError("not_downloaded", "Mail has not provided body text") }
        guard try api.get("isrd", object).booleanValue == read else { throw ServiceError("read_state_changed", "Read status changed during the official query; no automatic flag write was performed") }
        if content.isEmpty, (try api.get("raso", object).stringValue ?? "").isEmpty { throw ServiceError("not_downloaded", "Mail has not provided the downloaded message source") }
        return content
    }
    private func attachmentRefs(_ object: NSAppleEventDescriptor) throws -> [NSAppleEventDescriptor] { AppleEvents.items(try api.event("core", "getd", AppleEvents.all("attc", parent: object))) }
    private func optionalProperty(_ name: String, _ object: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor? {
        do { return try api.get(name, object) }
        catch let error as ServiceError where error.code == "apple_event_failed" { return nil }
    }
    private func attachmentSummary(_ attachment: NSAppleEventDescriptor) throws -> JSON {
        let mime = try optionalProperty("attp", attachment)?.stringValue
        let size = try optionalProperty("atsz", attachment)?.int32Value
        let downloaded = try optionalProperty("atdn", attachment)?.booleanValue
        return .object(["partID": .string(try api.get("ID  ", attachment).stringValue ?? ""), "filename": .string(try api.get("pnam", attachment).stringValue ?? ""), "mimeType": mime.map(JSON.string) ?? .null, "size": size.map { .int(Int($0)) } ?? .null, "isDownloaded": downloaded.map(JSON.bool) ?? .null, "metadata_complete": .bool(mime != nil && size != nil && downloaded != nil)])
    }

    private func search(_ a: Arguments) throws -> JSON {
        let list: [OfficialMailReference]
        if let id = try a.string("mailbox_id") {
            if id.hasPrefix("mail-api:") { list = [try OfficialMailReference.decode(id)] }
            else { let db = try module.store(); guard let b = try db.mailbox(id: Arguments(["id": .string(id)]).id()) else { throw ServiceError("not_found", "Mailbox not found") }; list = [OfficialMailReference(account: b.accountID, path: b.path)] }
        } else { list = try boxes(a.string("account_id")) }
        let offset = try a.integer("scan_offset", default: a.integer("offset", default: 0, range: 0...Int.max), range: 0...Int.max)
        let limit = try a.integer("limit", default: 50, range: 1...200); let budget = try a.integer("scan_limit", default: 100, range: 1...500)
        let from = try a.string("date_from").map(EventKitModule.date); let to = try a.string("date_to").map(EventKitModule.date)
        var skipped = 0; var scanned = 0; var matches: [JSON] = []; var more = false
        let deadline = Date().addingTimeInterval(10)
        outer: for mailbox in list {
            try authorize()
            let parent = box(mailbox)
            let count = Int(try api.event("core", "cnte", parent, ["kocl": NSAppleEventDescriptor(typeCode: AppleEvents.code("mssg"))]).int32Value)
            if skipped + count <= offset { skipped += count; continue }
            let start = max(1, offset - skipped + 1)
            if start > count { skipped += count; continue }
            for index in start...count {
                if scanned >= budget || matches.count >= limit || Date() > deadline { more = true; break outer }
                try authorize(); scanned += 1
                let object = AppleEvents.object("mssg", "indx", NSAppleEventDescriptor(int32: Int32(index)), parent)
                let nativeID = try api.get("ID  ", object)
                guard nativeID.descriptorType == typeSInt32, nativeID.int32Value > 0 else { throw ServiceError("unsupported_id", "Native ID is not an exact positive 32-bit integer") }
                var ref = mailbox; ref.id = nativeID.int32Value; ref.header = (try api.get("meid", object).stringValue ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
                let row = try summary(ref)
                if let unread = try a.bool("unread"), row["is_read"].boolean == unread { continue }
                if try a.bool("include_trash") != true, (try api.get("isdl", object).booleanValue || api.get("isjk", object).booleanValue) { continue }
                if let from, let received = row["received_at"].string.flatMap({ ISO8601DateFormatter().date(from: $0) }), received < from { continue }
                if let to, let received = row["received_at"].string.flatMap({ ISO8601DateFormatter().date(from: $0) }), received >= to { continue }
                if let subject = try a.string("subject"), row["subject"].string?.localizedCaseInsensitiveContains(subject) != true { continue }
                if let sender = try a.string("sender"), row["sender"].string?.localizedCaseInsensitiveContains(sender) != true { continue }
                if let text = try a.string("text"), ((row["subject"].string ?? "") + " " + (row["sender"].string ?? "")).localizedCaseInsensitiveContains(text) == false { continue }
                if let recipient = try a.string("recipient") {
                    let addresses = AppleEvents.strings(try api.event("core", "getd", AppleEvents.property("radd", AppleEvents.all("rcpt", parent: object))))
                    if !addresses.contains(where: { $0.localizedCaseInsensitiveContains(recipient) }) { continue }
                }
                if let text = try a.string("body"), try !body(object).localizedCaseInsensitiveContains(text) { continue }
                matches.append(row)
            }
            skipped += count
        }
        return .object(["messages": .array(matches), "scanned": .int(scanned), "next_scan_offset": more ? .int(offset + scanned) : .null, "next_offset": more ? .int(offset + scanned) : .null, "has_more": .bool(more), "search_complete": .bool(!more), "ordering": .string("account_mailbox_native_order; live_results_can_change")])
    }
    func call(_ name: String, _ values: [String: JSON]) throws -> JSON {
        let a = Arguments(values); let result: JSON
        switch name {
        case "mail_list_accounts":
            result = .object(["accounts": .array(try accounts().map { id in let ref = account(id)!; return .object(["id": .string(id), "name": .string(try api.get("pnam", ref).stringValue ?? ""), "email_addresses": .array(AppleEvents.strings(try api.get("emad", ref)).map(JSON.string))]) })])
        case "mail_list_mailboxes":
            result = .object(["mailboxes": .array(try boxes(a.string("account_id")).map { ref in .object(["id": .string(ref.token), "path": .string(ref.path), "account_id": .string(ref.account), "unread_count": .int(Int(try api.get("mbuc", box(ref)).int32Value))]) })])
        case "mail_search", "mail_overview": result = try search(a)
        case "mail_get", "mail_get_attachment", "mail_get_thread":
            let ref = try reference(a.requiredString("id")); let object = try message(ref)
            if name == "mail_get_thread" {
                result = .object(["messages": .array([try summary(ref)]), "thread_complete": .bool(false), "coverage": .string("anchor_only; Mail_official_dictionary_has_no_conversation_identifier; use_local_backend_for_full_threads")]); break
            }
            let attachments = try attachmentRefs(object)
            if name == "mail_get_attachment" {
                let id = try a.requiredString("part_id")
                let matched = try attachments.filter { try api.get("ID  ", $0).stringValue == id }
                guard matched.count == 1 else { throw ServiceError("not_found", "Native attachment does not belong to this message") }
                let target = matched[0]
                guard try api.get("atdn", target).booleanValue else { throw ServiceError("not_downloaded", "Mail has not downloaded attachment bytes") }
                let filename = try AttachmentUpload.filename(api.get("pnam", target).stringValue ?? "attachment")
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("APM-Mail-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); defer { try? FileManager.default.removeItem(at: directory) }
                let file = directory.appendingPathComponent(filename)
                _ = try api.event("core", "save", target, ["kfil": NSAppleEventDescriptor(fileURL: file)])
                result = try module.assets.saveFile(file, filename: filename, mimeType: optionalProperty("attp", target)?.stringValue ?? "application/octet-stream"); break
            }
            var fields = try summary(ref).object!; var content = try body(object)
            if try a.bool("include_html") == true {
                guard try api.get("msze", object).int32Value <= 33554432 else { throw ServiceError("message_too_large", "Official HTML parsing is limited to 32MiB source") }
                let raw = try api.get("raso", object).stringValue ?? ""
                guard raw.utf8.count <= 33554432 else { throw ServiceError("message_too_large", "Official HTML parsing is limited to 32MiB source; plain text is available separately") }
                let parts = MIME.parse(Data(raw.utf8)).leaves.filter { $0.contentType == "text/html" && !$0.isAttachment }
                guard !parts.isEmpty else { throw ServiceError("no_html_body", "Native source contains no HTML body") }; content = parts.map { $0.text() }.joined(separator: "\n")
            }
            fields["body"] = try BodyPaging.page(content, arguments: a); fields["body_downloaded"] = .bool(true)
            fields["body_view"] = .string(try a.bool("include_html") == true ? "original_mime_html" : "official_plain_text")
            fields["attachments"] = .array(try attachments.map(attachmentSummary))
            result = .object(fields)
        case "mail_get_many":
            guard let ids = values["ids"]?.array, !ids.isEmpty, ids.count <= 200 else { throw ServiceError("invalid_arguments", "Provide 1...200 message IDs") }
            var rows: [JSON] = []; var size = 0; var consumed = 0
            for id in ids {
                guard let value = id.string else { throw ServiceError("invalid_arguments", "IDs must be strings") }
                let row = try summary(reference(value)); let bytes = try row.data().count
                if size + bytes > 250000 { break }; rows.append(row); size += bytes; consumed += 1
            }
            result = .object(["messages": .array(rows), "remaining_ids": .array(Array(ids.dropFirst(consumed))), "has_more": .bool(consumed < ids.count), "bodies_included": .bool(false)])
        default: throw ServiceError("unknown_tool", name)
        }
        var fields = result.object!; fields["source"] = .object(["application": .string("mail"), "backend": .string("official_api")]); fields["observed_at"] = .string(ISO8601DateFormatter().string(from: Date()))
        return .object(fields)
    }
}
