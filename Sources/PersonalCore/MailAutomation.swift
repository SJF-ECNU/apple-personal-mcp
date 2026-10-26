import AppKit
import Foundation
import MailStore
import SQLite3

/// Official Mail scripting-dictionary events; never SQL writes to Mail.
public final class MailAutomation {
    private static let nativeLock = NSRecursiveLock()
    private let module: MailModule
    private let operationURL: URL
    private let agentName: String
    private let agentID: String
    private let authorize: () throws -> Void
    private var directory: URL { operationURL.deletingLastPathComponent().appendingPathComponent("Agents/\(agentID)/mail") }
    public init(module: MailModule, operationURL: URL = AppIdentity.support.appendingPathComponent("state.sqlite"), agentName: String = "Local", agentID: String = "local", authorize: @escaping () throws -> Void = {}) {
        self.module = module; self.operationURL = operationURL; self.agentName = agentName; self.agentID = agentID; self.authorize = authorize
    }
    public static let tools: [ToolDefinition] = {
        let string = { ToolDefinition.field("string", $0) }
        return [
            ToolDefinition("mail_create_draft", "Create and save a plain-text draft. Never sends.", ["subject": string("Subject"), "body": string("Plain text"), "to": .object(["type": .string("array"), "items": string("Exact recipient address")])], required: ["subject", "body"], readOnly: false),
            ToolDefinition("mail_list_drafts", "List currently script-addressable outgoing draft IDs, bounded to 200; saved messages have separate IDs"),
            ToolDefinition("mail_get_draft", "Read a currently open outgoing draft", ["draft_id": string("Outgoing Mail draft ID")], required: ["draft_id"]),
            ToolDefinition("mail_update_draft", "Update an outgoing draft, without sending", ["draft_id": string("Draft ID"), "subject": string("New subject"), "body": string("New plain text")], required: ["draft_id"], readOnly: false),
            ToolDefinition("mail_upload_attachment", "Upload private attachment bytes: start(filename,size,mime_type), chunk(upload_id,offset,data_base64), finish/status/cancel(upload_id). Chunks <=512KiB, file <=100MiB.", ["action": string("start/chunk/status/finish/cancel"), "filename": string("Basename, no directories"), "size": ToolDefinition.field("integer", "Declared total bytes"), "mime_type": string("Content type"), "upload_id": string("Upload UUID"), "offset": ToolDefinition.field("integer", "Exact returned next_offset"), "data_base64": string("One base64 chunk")], required: ["action"], readOnly: false),
            ToolDefinition("mail_add_attachment", "Add only this Agent's Mail asset to an outgoing draft; does not send", ["draft_id": string("Draft ID"), "asset_id": string("This Agent's mail asset UUID")], required: ["draft_id", "asset_id"], readOnly: false),
            ToolDefinition("mail_send_draft", "Send only after a native human confirmation. Unknown results are never retried.", ["draft_id": string("Draft ID"), "operation_id": string("New UUID; duplicate IDs are not reexecuted")], required: ["draft_id", "operation_id"], readOnly: false),
            ToolDefinition("operations_get", "Inspect this Agent's recorded send operation", ["operation_id": string("Operation UUID"), "application": string("mail (default) or messages")], required: ["operation_id"]),
            ToolDefinition("mail_changes_list", "List this Agent's recorded reversible changes", ["offset": ToolDefinition.field("integer", "Offset"), "limit": ToolDefinition.field("integer", "1...200")]),
            ToolDefinition("mail_undo_change", "Undo one verified move/flag change only if current state still matches; never undoes sending", ["change_id": string("This Agent's change UUID")], required: ["change_id"], readOnly: false),
            ToolDefinition("mail_batch_get", "Inspect this Agent’s batch after cancellation/disconnection; running_or_interrupted is never automatically replayed", ["batch_id": string("Batch UUID")], required: ["batch_id"]),
            ToolDefinition("mail_batch_modify", "Apply 1...20 moves/flags serially, verify each, stop after cancellation/error/unknown; retrying batch_id returns recorded progress", ["batch_id": string("New batch UUID"), "items": .object(["type": .string("array"), "items": .object(["type": .string("object")]), "maxItems": .int(20)])], required: ["batch_id", "items"], readOnly: false),
            ToolDefinition("mail_set_flags", "Set exact read/flag state and read it back. One precise message per call.", ["id": string("Message ID"), "is_read": ToolDefinition.field("boolean", "Explicit read state"), "flagged": ToolDefinition.field("boolean", "Explicit flag state")], required: ["id"], readOnly: false),
            ToolDefinition("mail_move", "Move one uniquely identified message and verify its destination; never permanently delete.", ["id": string("Message ID"), "destination_mailbox_id": string("Exact target mailbox ID")], required: ["id", "destination_mailbox_id"], readOnly: false),
        ]
    }()
    func event(_ cls: String, _ action: String, _ direct: NSAppleEventDescriptor? = nil, _ params: [String: NSAppleEventDescriptor] = [:]) throws -> NSAppleEventDescriptor {
        try authorize()
        let event = AppleEvents.request(bundleID: "com.apple.mail", eventClass: cls, id: action, direct: direct, parameters: params)
        do {
            let reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 20)
            if let code = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value, code != 0 {
                let detail = reply.paramDescriptor(forKeyword: keyErrorString)?.stringValue ?? ""
                throw ServiceError(code == -1743 ? "needs_automation_permission" : "apple_event_failed", "Mail \(cls)/\(action) returned \(code): \(detail)")
            }
            return reply.paramDescriptor(forKeyword: keyDirectObject) ?? .null()
        } catch let error as ServiceError { throw error }
        catch { throw ServiceError("apple_event_failed", String(describing: error)) }
    }
    func get(_ prop: String, _ object: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        do { return try event("core", "getd", AppleEvents.property(prop, object)) }
        catch let error as ServiceError { throw ServiceError(error.code, "Property \(prop): \(error.description)") }
    }
    private func set(_ prop: String, _ object: NSAppleEventDescriptor, _ value: NSAppleEventDescriptor) throws { _ = try event("core", "setd", AppleEvents.property(prop, object), ["data": value]) }
    func officialRead(_ name: String, _ values: [String: JSON]) throws -> JSON {
        Self.nativeLock.lock(); defer { Self.nativeLock.unlock() }
        try authorize(); try ensureRunning()
        guard Self.permissionStatus() == 0 else { throw ServiceError("needs_automation_permission", "Authorize Mail automation in the App for official reading") }
        return try MailOfficialRead(api: self, module: module, authorize: authorize).call(name, values)
    }
    public static func permissionStatus(ask: Bool = false) -> Int32 {
        AppleEvents.permissionStatus(bundleID: "com.apple.mail", ask: ask)
    }
    private func ensureRunning() throws {
        try AppleEvents.ensureRunning(bundleID: "com.apple.mail", name: "Mail")
    }
    private func draft(_ a: Arguments) throws -> NSAppleEventDescriptor {
        let id = try a.id("draft_id")
        guard let n = Int32(exactly: id) else { throw ServiceError("invalid_arguments", "Draft ID out of range") }
        return AppleEvents.object("bcke", "ID  ", NSAppleEventDescriptor(int32: n))
    }
    private func recipients(_ message: NSAppleEventDescriptor, kind: String) throws -> [String] {
        let list = try event("core", "getd", AppleEvents.property("radd", AppleEvents.all(kind, parent: message)))
        return AppleEvents.strings(list)
    }
    static func draftBody(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{fffc}", with: "\n").replacingOccurrences(of: "\n\u{2028}\n", with: "\n\n")
    }
    private func draftJSON(_ message: NSAppleEventDescriptor) throws -> JSON {
        let files = try attachmentFiles(message)
        let attachments = files.count
        return .object(["draft_id": .string(String(try get("ID  ", message).int32Value)), "sender": .string(try get("sndr", message).stringValue ?? ""), "attachment_count": .null, "known_attachment_count": .int(attachments), "attachment_verification": .string("native_mail_review_required"), "attachments": .array(files.map { url in
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            return .object(["filename": .string(url.lastPathComponent), "size": size.map(JSON.int) ?? .null, "available": .bool(FileManager.default.isReadableFile(atPath: url.path))])
        }), "subject": .string(try get("subj", message).stringValue ?? ""), "body": .string(Self.draftBody(try get("ctnt", message).stringValue ?? "")), "to": .array(try recipients(message, kind: "trcp").map(JSON.string)), "cc": .array(try recipients(message, kind: "crcp").map(JSON.string)), "bcc": .array(try recipients(message, kind: "brcp").map(JSON.string)), "sent": .bool(false)])
    }
    public func call(_ name: String, _ values: [String: JSON]) throws -> JSON {
        Self.nativeLock.lock(); defer { Self.nativeLock.unlock() }
        let a = Arguments(values)
        try authorize()
        if name == "operations_get" { return try OperationStore(url: operationURL, owner: agentID).get(a.requiredString("operation_id")) }
        if name == "mail_upload_attachment" { return try AttachmentUpload(root: directory.appendingPathComponent("Uploads"), assets: module.assets).call(values) }
        if name == "mail_changes_list" { return try MailChanges(url: operationURL, owner: agentID).list(offset: a.integer("offset", default: 0, range: 0...Int.max), limit: a.integer("limit", default: 50, range: 1...200)) }
        if name == "mail_batch_get" {
            guard let result = try MailChanges(url: operationURL, owner: agentID).batch(a.requiredString("batch_id")) else { throw ServiceError("not_found", "Batch is not owned by this Agent") }; return result
        }
        try ensureRunning()
        switch name {
        case "mail_add_attachment":
            let message = try draft(a); let id = try a.id("draft_id")
            guard try get("pvis", message).booleanValue else { throw ServiceError("native_review_required", "Open this exact draft in Mail before adding attachments; changing scripted visibility can discard its attachments") }
            let (source, metadata) = try module.assets.resolve(a.requiredString("asset_id"))
            let filename = try AttachmentUpload.filename(metadata["filename"].string ?? "attachment")
            let folder = directory.appendingPathComponent("Drafts/\(id)/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = folder.appendingPathComponent(filename)
            try FileManager.default.copyItem(at: source, to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let before = try attachmentFiles(message)
            let properties = NSAppleEventDescriptor.record(); properties.setDescriptor(NSAppleEventDescriptor(fileURL: file), forKeyword: AppleEvents.code("atfn"))
            let paragraph = AppleEvents.object("cpar", "indx", NSAppleEventDescriptor(int32: -1), AppleEvents.property("ctnt", message))
            let insertion = NSAppleEventDescriptor.record()
            insertion.setDescriptor(paragraph, forKeyword: AppleEvents.code("kobj")); insertion.setDescriptor(NSAppleEventDescriptor(enumCode: AppleEvents.code("afte")), forKeyword: AppleEvents.code("kpos"))
            do { _ = try event("core", "crel", nil, ["kocl": NSAppleEventDescriptor(typeCode: AppleEvents.code("atts")), "insh": insertion.coerce(toDescriptorType: AppleEvents.code("insl"))!, "prdt": properties]) }
            catch { throw ServiceError("effect_unknown", "Attachment insertion did not return a reliable result; inspect this draft in Mail before retrying") }
            // Mail 27 reports zero rich-text attachments even after insertion. Retain
            // our files for byte checks, and require review in the native compose window.
            let manifest = directory.appendingPathComponent("Drafts/\(id)/attachments.json")
            try PrivateFile.writeJSON(JSON.array((before + [file]).map { .string($0.path) }), to: manifest)
            _ = try event("core", "save", message)
            return try draftJSON(message)

        case "mail_create_draft":
            let subject = try a.requiredString("subject")
            let body = try a.requiredString("body")
            let recipients: [JSON]
            if let raw = values["to"] {
                guard let list = raw.array, list.count <= 100, list.allSatisfy({ $0.string != nil && !$0.string!.isEmpty }) else { throw ServiceError("invalid_arguments", "to must be an array of addresses") }
                recipients = list
            } else { recipients = [] }
            let properties = NSAppleEventDescriptor.record()
            properties.setDescriptor(NSAppleEventDescriptor(string: subject), forKeyword: AppleEvents.code("subj"))
            properties.setDescriptor(NSAppleEventDescriptor(string: body), forKeyword: AppleEvents.code("ctnt"))
            // On Mail 27, showing a formerly hidden compose window discards attachments
            // inserted into its saved rich text. Initialize the native editor first.
            properties.setDescriptor(NSAppleEventDescriptor(boolean: true), forKeyword: AppleEvents.code("pvis"))
            let message = try event("core", "crel", nil, ["kocl": NSAppleEventDescriptor(typeCode: AppleEvents.code("bcke")), "prdt": properties])
            for address in recipients {
                    let p = NSAppleEventDescriptor.record(); p.setDescriptor(NSAppleEventDescriptor(string: address.string!), forKeyword: AppleEvents.code("radd"))
                    _ = try event("core", "crel", nil, ["kocl": NSAppleEventDescriptor(typeCode: AppleEvents.code("trcp")), "insh": message, "prdt": p])
            }
            _ = try event("core", "save", message)
            return try draftJSON(message)
        case "mail_list_drafts":
            let ids = try event("core", "getd", AppleEvents.property("ID  ", AppleEvents.all("bcke")))
            guard ids.numberOfItems <= 200 else { throw ServiceError("query_too_large", "Too many open outgoing drafts") }
            return .object(["draft_ids": .array((1...max(1, ids.numberOfItems)).compactMap { ids.atIndex($0).map { .string(String($0.int32Value)) } })])
        case "mail_get_draft": return try draftJSON(draft(a))
        case "mail_update_draft":
            let message = try draft(a)
            if let subject = try a.string("subject") { try set("subj", message, NSAppleEventDescriptor(string: subject)) }
            if let body = try a.string("body") {
                guard try attachmentFiles(message).isEmpty else { throw ServiceError("rich_content", "Replacing the body may remove managed attachments; edit this draft in Mail") }
                try set("ctnt", message, NSAppleEventDescriptor(string: body))
            }
            _ = try event("core", "save", message); return try draftJSON(message)
        case "mail_send_draft":
            let op = try a.requiredString("operation_id")
            guard UUID(uuidString: op) != nil else { throw ServiceError("invalid_arguments", "operation_id must be UUID") }
            let state = try OperationStore(url: operationURL, owner: agentID)
            if let existing = try state.existing(op) { return existing }
            let message = try draft(a); let preview = try draftJSON(message)
            guard !(preview["to"].array ?? []).isEmpty else { throw ServiceError("invalid_arguments", "Draft has no To recipients") }
            let files = try attachmentFiles(message)
            // The public dictionary cannot enumerate every outgoing attachment.
            // Show this exact compose window for human review instead of claiming completeness.
            guard try get("pvis", message).booleanValue else { throw ServiceError("native_review_required", "Open this exact draft in Mail before sending; scripted visibility changes can discard attachments") }
            let windows = try event("core", "getd", AppleEvents.all("cwin"))
            let matching = try (1...max(1, windows.numberOfItems)).compactMap { windows.atIndex($0) }.filter { try get("pnam", $0).stringValue == preview["subject"].string }
            guard matching.count == 1 else { throw ServiceError("ambiguous_window", "Keep exactly one Mail compose window with this subject open for native review") }
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").first?.activate(options: [])
            try set("pidx", matching[0], NSAppleEventDescriptor(int32: 1))
            let snapshots = directory.appendingPathComponent("SendSnapshots/\(op)")
            try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: snapshots) }
            for (index, file) in files.enumerated() {
                let info = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard info.isRegularFile == true, let size = info.fileSize, size <= 104857600 else { throw ServiceError("unsupported_attachment", "Attachments must be local regular files no larger than 100MiB") }
                let copy = snapshots.appendingPathComponent(String(index))
                try FileManager.default.copyItem(at: file, to: copy); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
            }
            try state.claim(op)
            let approved = NativeConfirmation.ask("核对 Mail 原生窗口后发送？", "请在已打开的 Mail 草稿窗口核对全部附件。公开接口无法完整枚举草稿附件；下列列表仅包含此服务添加的文件。\n\nAgent: \(agentName)\nFrom: \(preview["sender"].string ?? "")\nTo: \((preview["to"].array ?? []).compactMap(\.string).joined(separator: ", "))\nCc: \((preview["cc"].array ?? []).compactMap(\.string).joined(separator: ", "))\nBcc: \((preview["bcc"].array ?? []).compactMap(\.string).joined(separator: ", "))\nAttachments: \(preview["attachments"].text())\n\(preview["subject"].string ?? "")\n\n\(preview["body"].string ?? "")")
            guard approved else { try state.update(op, "cancelled"); return try state.get(op) }
            do { try authorize() } catch { try state.update(op, "cancelled"); throw error }
            // Recheck the exact draft after human review. A changed draft needs a new review.
            guard try draftJSON(message) == preview else { try state.update(op, "draft_changed"); throw ServiceError("source_changed", "Draft changed during review; send was not attempted") }
            let fresh = try attachmentFiles(message)
            for (index, file) in fresh.enumerated() {
                guard try Self.sameBytes(file, snapshots.appendingPathComponent(String(index))) else { try state.update(op, "draft_changed"); throw ServiceError("source_changed", "Attachment bytes changed during review; no send was attempted") }
            }
            try state.update(op, "unknown")
            do {
                let accepted = try event("emsg", "send", message)
                if accepted.booleanValue { try state.update(op, "submitted") }
            }
            catch { return try state.get(op) }
            return try state.get(op)
        case "mail_set_flags", "mail_move": return try modifyMessage(name, a)
        case "mail_undo_change": return try undo(a.requiredString("change_id"))
        case "mail_batch_modify":
            let history = try MailChanges(url: operationURL, owner: agentID); let batch = try a.requiredString("batch_id")
            if let existing = try history.batch(batch) { return existing }
            guard let items = values["items"]?.array, !items.isEmpty, items.count <= 20 else { throw ServiceError("invalid_arguments", "Provide 1...20 items") }
            try history.startBatch(batch)
            var results: [JSON] = []
            for (index, item) in items.enumerated() {
                // A crash during the next native call must leave that index uncertain.
                _ = try history.updateBatch(batch, status: "running_or_interrupted", results: results, next: index)
                do {
                    try authorize()
                    guard let fields = item.object, Set(fields.keys).isSubset(of: ["id", "is_read", "flagged", "destination_mailbox_id"]) else { throw ServiceError("invalid_arguments", "Unknown batch item fields") }
                    let moving = fields["destination_mailbox_id"] != nil
                    guard !moving || (fields["is_read"] == nil && fields["flagged"] == nil) else { throw ServiceError("invalid_arguments", "One move OR flags per item") }
                    let result = try modifyMessage(moving ? "mail_move" : "mail_set_flags", Arguments(fields))
                    results.append(.object(["index": .int(index), "result": result]))
                    if result["status"].string == "unknown" || result["verified"].boolean == false {
                        return try history.updateBatch(batch, status: "stopped", results: results, next: index + 1)
                    }
                } catch {
                    results.append(.object(["index": .int(index), "error": ToolReply.failure(error).body["error"]]))
                    return try history.updateBatch(batch, status: "stopped", results: results, next: index + 1)
                }
            }
            return try history.updateBatch(batch, status: "completed", results: results, next: nil)
        default: throw ServiceError("unknown_tool", name)
        }
    }
}

extension MailAutomation {
    private func attachmentFiles(_ message: NSAppleEventDescriptor) throws -> [URL] {
        let id = try get("ID  ", message).int32Value
        let root = directory.appendingPathComponent("Drafts/\(id)").resolvingSymlinksInPath()
        let manifest = root.appendingPathComponent("attachments.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return [] }
        let json = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: manifest))
        return try (json.array ?? []).map { value in
            guard let path = value.string else { throw ServiceError("invalid_asset", "Invalid draft attachment record") }
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard url.path.hasPrefix(root.path + "/"), FileManager.default.isReadableFile(atPath: url.path) else { throw ServiceError("not_downloaded", "A managed draft attachment is unavailable") }
            return url
        }
    }
    private func modifyMessage(_ name: String, _ a: Arguments, record: Bool = true, expected: JSON? = nil) throws -> JSON {
        try authorize()
        let db = try module.store(); let item = try db.message(id: a.id())
        guard let n = Int32(exactly: item.id), let mailbox = try db.mailbox(id: item.mailboxID) else { throw ServiceError("source_changed", "Mail identity is no longer representable") }
        let account = AppleEvents.object("mact", "ID  ", NSAppleEventDescriptor(string: mailbox.accountID))
        let box = AppleEvents.object("mbxp", "name", NSAppleEventDescriptor(string: mailbox.path), mailbox.accountID.isEmpty ? nil : account)
        let message = AppleEvents.object("mssg", "ID  ", NSAppleEventDescriptor(int32: n), box)
        guard try get("subj", message).stringValue == item.subject,
              (try get("meid", message).stringValue ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) == (item.messageIDHeader ?? "") else { throw ServiceError("source_changed", "Mail object does not match local identity") }
        let history = try MailChanges(url: operationURL, owner: agentID)
        var target = JSON.object(["id": .string(String(item.id)), "account_id": .string(item.accountID), "mailbox_id": .string(String(item.mailboxID)), "message_id": item.messageIDHeader.map(JSON.string) ?? .null])
        if name == "mail_set_flags" {
            let read = try a.bool("is_read"); let flag = try a.bool("flagged")
            guard read != nil || flag != nil else { throw ServiceError("invalid_arguments", "Provide an explicit flag state") }
            let oldRead = try get("isrd", message).booleanValue; let oldFlag = try get("isfl", message).booleanValue
            let current = JSON.object(["is_read": .bool(oldRead), "flagged": .bool(oldFlag)])
            if let expected { guard (expected.object ?? [:]).allSatisfy({ current[$0.key] == $0.value }) else { throw ServiceError("change_conflict", "Flags changed after this recorded operation") } }
            var before: [String: JSON] = [:]; var after: [String: JSON] = [:]
            if let read, read != oldRead { before["is_read"] = .bool(oldRead); after["is_read"] = .bool(read) }
            if let flag, flag != oldFlag { before["flagged"] = .bool(oldFlag); after["flagged"] = .bool(flag) }
            let change = record && !before.isEmpty ? try history.prepare(kind: "flags", target: target, before: .object(before), after: .object(after)) : nil
            do {
                if let read { try set("isrd", message, NSAppleEventDescriptor(boolean: read)) }
                if let flag { try set("isfl", message, NSAppleEventDescriptor(boolean: flag)) }
                let actualRead = try get("isrd", message).booleanValue; let actualFlag = try get("isfl", message).booleanValue
                let verified = (read == nil || read == actualRead) && (flag == nil || flag == actualFlag)
                if let change { try history.update(change, status: verified ? "applied" : "unknown") }
                return .object(["id": .string(String(item.id)), "is_read": .bool(actualRead), "flagged": .bool(actualFlag), "verified": .bool(verified), "status": .string(verified ? "verified" : "unknown"), "change_id": change.map(JSON.string) ?? .null])
            } catch {
                if let change { try history.update(change, status: "unknown") }
                return .object(["status": .string("unknown"), "change_id": change.map(JSON.string) ?? .null, "error": ToolReply.failure(error).body["error"]])
            }
        }
        if let expected { guard expected["mailbox_id"].string == String(item.mailboxID) else { throw ServiceError("change_conflict", "Message moved after this operation") } }
        guard let header = item.messageIDHeader, !header.isEmpty,
              try db.messages(messageIDHeaders: [header], mailboxIDs: [item.mailboxID]).count == 1,
              let destinationBox = try db.mailbox(id: a.id("destination_mailbox_id")), destinationBox.accountID == item.accountID,
              destinationBox.sourceMailboxID == nil, mailbox.sourceMailboxID == nil else { throw ServiceError("ambiguous_target", "Move requires unique identity and ordinary same-account mailboxes") }
        if destinationBox.id == mailbox.id { return .object(["status": .string("unchanged"), "id": .string(String(item.id))]) }
        guard try db.messages(messageIDHeaders: [header], mailboxIDs: [destinationBox.id]).isEmpty else { throw ServiceError("ambiguous_target", "Destination already contains this Message-ID") }
        let comparison = NSAppleEventDescriptor.record(); let examined = NSAppleEventDescriptor(descriptorType: AppleEvents.code("exmn"), bytes: nil, length: 0)!
        comparison.setDescriptor(NSAppleEventDescriptor(enumCode: AppleEvents.code("=   ")), forKeyword: AppleEvents.code("relo")); comparison.setDescriptor(AppleEvents.property("meid", examined), forKeyword: AppleEvents.code("obj1")); comparison.setDescriptor(NSAppleEventDescriptor(string: header), forKeyword: AppleEvents.code("obj2"))
        let unique = AppleEvents.object("mssg", "test", comparison.coerce(toDescriptorType: AppleEvents.code("cmpd"))!, box)
        let ids = try get("ID  ", unique)
        guard ids.numberOfItems == 1, ids.atIndex(1)?.int32Value == n else { throw ServiceError("ambiguous_target", "Mail cannot resolve the same unique message") }
        let change = record ? try history.prepare(kind: "move", target: target, before: .object(["mailbox_id": .string(String(mailbox.id))]), after: .object(["mailbox_id": .string(String(destinationBox.id))])) : nil
        let destination = AppleEvents.object("mbxp", "name", NSAppleEventDescriptor(string: destinationBox.path), destinationBox.accountID.isEmpty ? nil : account)
        do {
            _ = try event("core", "move", unique, ["insh": destination])
            for _ in 0..<20 {
                let found = try db.messages(messageIDHeaders: [header], mailboxIDs: [destinationBox.id])
                if found.count == 1, try db.messages(messageIDHeaders: [header], mailboxIDs: [mailbox.id]).isEmpty {
                    var fields = target.object!; fields["id"] = .string(String(found[0].id)); fields["mailbox_id"] = .string(String(destinationBox.id)); target = .object(fields)
                    if let change { try history.update(change, status: "applied", target: target) }
                    return .object(["status": .string("verified"), "new_message": MailModule.summary(found[0]), "change_id": change.map(JSON.string) ?? .null])
                }
                try authorize(); Thread.sleep(forTimeInterval: 0.25)
            }
        } catch { /* A native move may already have happened. Do not replay it. */ }
        if let change { try history.update(change, status: "unknown") }
        return .object(["status": .string("unknown"), "change_id": change.map(JSON.string) ?? .null, "message": .string("Inspect actual Mail location before any retry")])
    }
    private func undo(_ id: String) throws -> JSON {
        let history = try MailChanges(url: operationURL, owner: agentID); let row = try history.get(id)
        if row["status"].string == "undone" { return row }
        guard row["status"].string == "applied" else { throw ServiceError("effect_unknown", "Only verified applied changes can be undone") }
        let target = row["target"]; let db = try module.store(); let item = try db.message(id: Arguments(["id": target["id"]]).id())
        guard item.accountID == target["account_id"].string, String(item.mailboxID) == target["mailbox_id"].string, item.messageIDHeader == target["message_id"].string else { throw ServiceError("change_conflict", "Message identity/location changed since this operation") }
        var values = row["before"].object!; values["id"] = target["id"]
        let moving = row["kind"].string == "move"
        if moving { values["destination_mailbox_id"] = values.removeValue(forKey: "mailbox_id") }
        let result = try modifyMessage(moving ? "mail_move" : "mail_set_flags", Arguments(values), record: false, expected: row["after"])
        guard result["status"].string == "verified" || result["status"].string == "unchanged" else { try history.update(id, status: "undo_unknown"); return .object(["change_id": .string(id), "status": .string("undo_unknown"), "result": result]) }
        try history.update(id, status: "undone", result: result); return try history.get(id)
    }
    static func sameBytes(_ a: URL, _ b: URL) throws -> Bool {
        guard try a.resourceValues(forKeys: [.fileSizeKey]).fileSize == b.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        let left = try FileHandle(forReadingFrom: a); defer { try? left.close() }
        let right = try FileHandle(forReadingFrom: b); defer { try? right.close() }
        while true {
            let l = try left.read(upToCount: 65536) ?? Data(); let r = try right.read(upToCount: 65536) ?? Data()
            if l != r { return false }; if l.isEmpty { return true }
        }
    }
}

public final class OperationStore {
    private var db: OpaquePointer?
    private let owner: String
    public init(url: URL = AppIdentity.support.appendingPathComponent("state.sqlite"), owner: String = "local") throws {
        self.owner = owner
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw ServiceError("state_unavailable", "Cannot open operation state") }
        sqlite3_busy_timeout(db, 3000)
        guard sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS operations(id TEXT PRIMARY KEY, status TEXT NOT NULL)", nil, nil, nil) == SQLITE_OK else { throw ServiceError("state_unavailable", "Cannot create operation table") }
        if try !hasOwnerColumn() {
            guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw ServiceError("state_unavailable", "Cannot migrate operation ownership") }
            do {
                if try !hasOwnerColumn() {
                    guard sqlite3_exec(db, "ALTER TABLE operations ADD COLUMN owner TEXT", nil, nil, nil) == SQLITE_OK else { throw ServiceError("state_unavailable", "Cannot add operation ownership") }
                }
                guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw ServiceError("state_unavailable", "Cannot commit operation ownership") }
            } catch { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); throw error }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    deinit { sqlite3_close(db) }
    private func hasOwnerColumn() throws -> Bool {
        let s = try statement("PRAGMA table_info(operations)", []); defer { sqlite3_finalize(s) }
        while sqlite3_step(s) == SQLITE_ROW { if let name = sqlite3_column_text(s, 1), String(cString: name) == "owner" { return true } }
        return false
    }
    private func statement(_ sql: String, _ strings: [String]) throws -> OpaquePointer {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw ServiceError("state_unavailable", "Cannot prepare operation") }
        for (i, v) in strings.enumerated() { sqlite3_bind_text(s, Int32(i + 1), v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        return s
    }
    public func claim(_ id: String) throws {
        let s = try statement("INSERT INTO operations(id,status,owner) VALUES (?, 'prepared', ?)", [id, owner]); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw ServiceError("operation_exists", "Operation already exists; query it instead") }
    }
    public func update(_ id: String, _ status: String) throws {
        let s = try statement("UPDATE operations SET status=? WHERE id=? AND owner=?", [status, id, owner]); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw ServiceError("not_found", "Operation is not owned by this Agent") }
    }
    public func existing(_ id: String) throws -> JSON? {
        let s = try statement("SELECT status FROM operations WHERE id=? AND owner=?", [id, owner]); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW, let text = sqlite3_column_text(s, 0) else { return nil }
        return .object(["operation_id": .string(id), "status": .string(String(cString: text)), "reexecuted": .bool(false), "delivered": .null])
    }
    public func get(_ id: String) throws -> JSON { guard let v = try existing(id) else { throw ServiceError("not_found", "Unknown operation") }; return v }
}
