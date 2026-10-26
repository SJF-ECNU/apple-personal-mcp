import Foundation
import UniformTypeIdentifiers

/// Uses Notes' shipped scripting dictionary, never its private database.
public final class NotesModule {
    private let authorize: () throws -> Void
    private let agentName: String
    private let confirm: (String, String) -> Bool
    private let assets: AssetStore?
    public init(agentName: String = "Local", authorize: @escaping () throws -> Void = {}, confirm: @escaping (String, String) -> Bool = NativeConfirmation.ask, assets: AssetStore? = nil) {
        self.agentName = agentName; self.authorize = authorize; self.confirm = confirm
        self.assets = assets
    }
    public static let tools: [ToolDefinition] = {
        let field = ToolDefinition.field
        return [
            ToolDefinition("notes_list_accounts", "List official Notes accounts"),
            ToolDefinition("notes_list_folders", "List Notes folders through official Apple Events"),
            ToolDefinition("notes_search", "Page note metadata; text filters titles, not full bodies", ["text": field("string", "Title contains"), "folder_id": field("string", "Exact folder ID"), "offset": field("integer", "Result offset"), "limit": field("integer", "1...200")]),
            ToolDefinition("notes_get", "Read full plain text or original HTML through pages; protected notes are refused", ["id": field("string", "Native Notes ID"), "include_html": field("boolean", "Return original HTML instead of plain text"), "body_offset": field("integer", "Unicode scalar offset"), "max_chars": field("integer", "1...16000")], required: ["id"]),
            ToolDefinition("notes_list_attachments", "Read the official attachment directory for one unprotected note", ["id": field("string", "Note ID"), "offset": field("integer", "Attachment offset"), "limit": field("integer", "1...200")], required: ["id"]),
            ToolDefinition("notes_get_attachment", "Export one attachment through Notes' official save command into this Agent's resources", ["id": field("string", "Note ID"), "attachment_id": field("string", "Exact attachment ID from notes_list_attachments")], required: ["id", "attachment_id"]),
        ] + writeTools
    }()
    public static func permissionStatus(ask: Bool = false) -> Int32 {
        AppleEvents.permissionStatus(bundleID: "com.apple.Notes", ask: ask)
    }
    public static func status() -> JSON {
        let permission = permissionStatus()
        return .object(["state": .string(permission == 0 ? "ready" : "needs_notes_automation_permission"), "automation_status": .int(Int(permission)), "backend": .string("official_apple_events"), "writes_implemented": .bool(true)])
    }
    public static func ensureRunning() throws {
        try AppleEvents.ensureRunning(bundleID: "com.apple.Notes", name: "Notes")
    }
    private func get(_ object: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try event("getd", object)
    }
    private func event(_ action: String, _ direct: NSAppleEventDescriptor? = nil, _ parameters: [String: NSAppleEventDescriptor] = [:]) throws -> NSAppleEventDescriptor {
        try authorize()
        let event = AppleEvents.request(bundleID: "com.apple.Notes", eventClass: "core", id: action, direct: direct, parameters: parameters)
        do {
            let reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 20)
            if let code = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value, code != 0 { throw ServiceError(code == -1743 ? "needs_notes_automation_permission" : code == -1728 ? "not_found" : "apple_event_failed", "Notes returned \(code)") }
            return reply.paramDescriptor(forKeyword: keyDirectObject) ?? .null()
        } catch let error as ServiceError { throw error }
        catch {
            let unknown = action != "getd" && [-1712, -609].contains((error as NSError).code)
            throw ServiceError(unknown ? "effect_unknown" : "apple_event_failed", unknown ? "Notes may have applied the operation. Read it back before retrying." : String(describing: error))
        }
    }
    private func string(_ property: String, _ target: NSAppleEventDescriptor) throws -> String { try get(AppleEvents.property(property, target)).stringValue ?? "" }
    private func note(_ id: String) -> NSAppleEventDescriptor { AppleEvents.object("note", "ID  ", NSAppleEventDescriptor(string: id)) }
    private func summary(_ id: String) throws -> JSON {
        let target = note(id)
        let protected = try get(AppleEvents.property("pwpr", target)).booleanValue
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let modified = try get(AppleEvents.property("asmo", target)).dateValue
        return .object(["id": .string(id), "title": .string(try string("pnam", target)), "password_protected": .bool(protected), "folder_id": .string(try string("ID  ", get(AppleEvents.property("cntr", target)))), "last_modified": modified.map { .string(formatter.string(from: $0)) } ?? .null])
    }
    public func call(_ name: String, _ values: [String: JSON]) throws -> JSON {
        try Self.ensureRunning()
        guard Self.permissionStatus() == 0 else { throw ServiceError("needs_notes_automation_permission", "Use the App to authorize Notes automation") }
        let args = Arguments(values)
        let result: JSON
        switch name {
        case "notes_list_accounts":
            result = .object(["accounts": .array(try AppleEvents.strings(get(AppleEvents.property("ID  ", AppleEvents.all("acct")))).map { id in .object(["id": .string(id), "name": .string(try string("pnam", AppleEvents.object("acct", "ID  ", NSAppleEventDescriptor(string: id))))]) })])
        case "notes_list_folders":
            let ids = AppleEvents.strings(try get(AppleEvents.property("ID  ", AppleEvents.all("cfol"))))
            result = .object(["folders": .array(try ids.map { id in .object(["id": .string(id), "name": .string(try string("pnam", AppleEvents.object("cfol", "ID  ", NSAppleEventDescriptor(string: id))))]) })])
        case "notes_search":
            let parent = try args.string("folder_id").map { AppleEvents.object("cfol", "ID  ", NSAppleEventDescriptor(string: $0)) }
            var selector = AppleEvents.all("note", parent: parent)
            if let text = try args.string("text"), !text.isEmpty {
                let comparison = NSAppleEventDescriptor.record()
                let examined = NSAppleEventDescriptor(descriptorType: AppleEvents.code("exmn"), bytes: nil, length: 0)!
                comparison.setDescriptor(NSAppleEventDescriptor(enumCode: AppleEvents.code("cont")), forKeyword: AppleEvents.code("relo"))
                comparison.setDescriptor(AppleEvents.property("pnam", examined), forKeyword: AppleEvents.code("obj1"))
                comparison.setDescriptor(NSAppleEventDescriptor(string: text), forKeyword: AppleEvents.code("obj2"))
                selector = AppleEvents.object("note", "test", comparison.coerce(toDescriptorType: AppleEvents.code("cmpd"))!, parent)
            }
            let ids = AppleEvents.strings(try get(AppleEvents.property("ID  ", selector))).sorted()
            let offset = try args.integer("offset", default: 0, range: 0...Int.max); let limit = try args.integer("limit", default: 50, range: 1...200)
            guard offset <= ids.count else { throw ServiceError("invalid_cursor", "Offset exceeds current Notes results") }
            let next = offset + min(limit, ids.count - offset)
            result = .object(["notes": .array(try ids[offset..<next].map(summary)), "total": .int(ids.count), "next_offset": next < ids.count ? .int(next) : .null, "has_more": .bool(next < ids.count), "search_scope": .string("titles")])
        case "notes_get":
            let id = try args.requiredString("id")
            var fields = try summary(id).object!
            guard fields["password_protected"]?.boolean == false else { throw ServiceError("locked", "Protected notes are not read by this adapter") }
            let html = try args.bool("include_html") ?? false
            let content = try string(html ? "body" : "text", note(id))
            fields["body_view"] = .string(html ? "original_html" : "plain_text")
            fields["body"] = try BodyPaging.page(content, arguments: args)
            fields["attachments"] = try attachmentPage(id, offset: 0, limit: 50)
            fields["rich_content"] = .string(html ? "original_HTML; attachments_are_separate; layout_not_guaranteed" : "plain_text_does_not_preserve_tables_drawings_or_attachment_content")
            result = .object(fields)
        case "notes_list_attachments":
            let id = try args.requiredString("id")
            guard try summary(id)["password_protected"].boolean == false else { throw ServiceError("locked", "Protected note attachments are not read") }
            result = try attachmentPage(id, offset: args.integer("offset", default: 0, range: 0...Int.max), limit: args.integer("limit", default: 50, range: 1...200))
        case "notes_get_attachment":
            guard let assets else { throw ServiceError("state_unavailable", "Agent resource storage is unavailable") }
            let id = try args.requiredString("id"); let attachmentID = try args.requiredString("attachment_id")
            guard try summary(id)["password_protected"].boolean == false else { throw ServiceError("locked", "Protected note attachments are not exported") }
            let ids = AppleEvents.strings(try get(AppleEvents.property("ID  ", AppleEvents.all("atts", parent: note(id)))))
            guard ids.contains(attachmentID) else { throw ServiceError("not_found", "Attachment does not belong to this note") }
            let attachment = AppleEvents.object("atts", "ID  ", NSAppleEventDescriptor(string: attachmentID), note(id))
            let filename = try AttachmentUpload.filename(string("pnam", attachment))
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("APM-Notes-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            let output = folder.appendingPathComponent(filename)
            _ = try event("save", attachment, ["kfil": NSAppleEventDescriptor(fileURL: output)])
            guard let size = try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { throw ServiceError("not_downloaded", "Notes did not export local attachment bytes") }
            try authorize()
            result = try assets.saveFile(output, filename: filename, mimeType: UTType(filenameExtension: output.pathExtension)?.preferredMIMEType ?? "application/octet-stream")
        default:
            guard Self.writeTools.contains(where: { $0.name == name }) else { throw ServiceError("unknown_tool", name) }
            result = try mutate(name, args)
        }
        return .object((result.object ?? [:]).merging(["source": .object(["application": .string("notes"), "backend": .string("official_apple_events")]), "coverage": .string("current_mac_visible_notes"), "observed_at": .string(ISO8601DateFormatter().string(from: Date()))]) { a, _ in a })
    }
    private func attachmentPage(_ id: String, offset: Int, limit: Int) throws -> JSON {
        let ids = AppleEvents.strings(try get(AppleEvents.property("ID  ", AppleEvents.all("atts", parent: note(id)))))
        guard offset <= ids.count else { throw ServiceError("invalid_cursor", "Attachment directory changed; restart listing") }
        let end = offset + min(limit, ids.count - offset)
        let rows = try ids[offset..<end].map { attachmentID -> JSON in
            let target = AppleEvents.object("atts", "ID  ", NSAppleEventDescriptor(string: attachmentID), note(id))
            return .object(["attachment_id": .string(attachmentID), "filename": .string(try string("pnam", target)), "content_identifier": .string(try string("cid ", target)), "url": .string(try string("URL ", target)), "export_availability": .string("not_attempted")])
        }
        return .object(["items": .array(rows), "total": .int(ids.count), "next_offset": end < ids.count ? .int(end) : .null])
    }
}

extension NotesModule {
    public static let writeTools: [ToolDefinition] = {
        let f = ToolDefinition.field
        let target = ["id": f("string", "Exact Notes ID"), "expected_modified": f("string", "last_modified from latest notes_get")]
        return [
            ToolDefinition("notes_create_folder", "Create a folder inside an explicit Notes account", ["account_id": f("string", "Account ID from notes_list_accounts"), "name": f("string", "New folder name")], required: ["account_id", "name"], readOnly: false),
            ToolDefinition("notes_delete_folder", "Delete only an empty folder after native confirmation and a second emptiness check", ["folder_id": f("string", "Exact folder ID"), "expected_name": f("string", "Exact current folder name")], required: ["folder_id", "expected_name"], readOnly: false),
            ToolDefinition("notes_create", "Create a plain note in an explicit folder", ["folder_id": f("string", "Folder ID"), "title": f("string", "Title"), "text": f("string", "Plain body text")], required: ["folder_id", "title", "text"], readOnly: false),
            ToolDefinition("notes_update", "One operation: title, append_text or text replacement. Body changes require current HTML and refuse rich/attached notes.", target.merging(["title": f("string", "New title"), "append_text": f("string", "Append plain text"), "text": f("string", "Replace plain text, retaining the title"), "expected_body_html": f("string", "Exact complete HTML from latest notes_get(include_html=true)")]) { a, _ in a }, required: ["id", "expected_modified"], readOnly: false),
            ToolDefinition("notes_move", "Move a note within the same account and read back its folder", target.merging(["folder_id": f("string", "Destination folder ID")]) { a, _ in a }, required: ["id", "folder_id", "expected_modified"], readOnly: false),
            ToolDefinition("notes_delete", "Move a note to Notes' deletion flow after native human confirmation", target, required: ["id", "expected_modified"], readOnly: false),
        ]
    }()
    public static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;").replacingOccurrences(of: "\n", with: "<br>")
    }
    public static func isPlainHTML(_ html: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "<\\s*/?\\s*([A-Za-z0-9]+)([^>]*)>") else { return false }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).allSatisfy { match in
            guard let name = Range(match.range(at: 1), in: html), let attributes = Range(match.range(at: 2), in: html) else { return false }
            return ["div", "p", "br", "h1", "html", "body"].contains(html[name].lowercased()) && html[attributes].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "").isEmpty
        }
    }
    private func check(_ id: String, _ a: Arguments) throws -> JSON {
        let current = try summary(id)
        guard current["password_protected"].boolean == false else { throw ServiceError("locked", "Protected notes cannot be modified by this adapter") }
        guard current["last_modified"].string == (try a.string("expected_modified", required: true)) else { throw ServiceError("source_changed", "Note changed; read it again") }
        return current
    }
    private func accountID(_ folder: NSAppleEventDescriptor) throws -> String {
        let accounts = Set(AppleEvents.strings(try get(AppleEvents.property("ID  ", AppleEvents.all("acct")))))
        var container = folder
        for _ in 0..<32 {
            let id = try string("ID  ", container)
            if accounts.contains(id) { return id }
            container = try get(AppleEvents.property("cntr", container))
        }
        throw ServiceError("unsupported_folder", "Folder hierarchy exceeds supported depth")
    }
    private func mutate(_ name: String, _ a: Arguments) throws -> JSON {
        if name == "notes_delete_folder" {
            let id = try a.requiredString("folder_id"); let expected = try a.requiredString("expected_name")
            let target = AppleEvents.object("cfol", "ID  ", NSAppleEventDescriptor(string: id))
            func checkEmpty() throws {
                guard try string("pnam", target) == expected else { throw ServiceError("source_changed", "Folder name changed") }
                guard try get(AppleEvents.all("note", parent: target)).numberOfItems == 0, try get(AppleEvents.all("cfol", parent: target)).numberOfItems == 0 else { throw ServiceError("folder_not_empty", "Only empty folders may be deleted") }
            }
            try checkEmpty()
            guard confirm("删除空的备忘录文件夹？", "Agent: \(agentName)\n\(expected)\nID: \(id)") else { return .object(["status": .string("cancelled")]) }
            try checkEmpty(); try authorize(); _ = try event("delo", target)
            return .object(["status": .string("deleted"), "id": .string(id)])
        }
        if name == "notes_create_folder" {
            let account = AppleEvents.object("acct", "ID  ", NSAppleEventDescriptor(string: try a.requiredString("account_id")))
            let properties = NSAppleEventDescriptor.record(); let title = try a.requiredString("name")
            properties.setDescriptor(NSAppleEventDescriptor(string: title), forKeyword: AppleEvents.code("pnam"))
            let folder = try event("crel", nil, ["kocl": NSAppleEventDescriptor(typeCode: AppleEvents.code("cfol")), "insh": account, "prdt": properties])
            return .object(["id": .string(try string("ID  ", folder)), "name": .string(try string("pnam", folder))])
        }
        if name == "notes_create" {
            let folder = AppleEvents.object("cfol", "ID  ", NSAppleEventDescriptor(string: try a.requiredString("folder_id")))
            let title = try a.requiredString("title"); let text = try a.requiredString("text")
            let properties = NSAppleEventDescriptor.record()
            properties.setDescriptor(NSAppleEventDescriptor(string: "<div>\(Self.escapeHTML(title))</div><div>\(Self.escapeHTML(text))</div>"), forKeyword: AppleEvents.code("body"))
            let created = try event("crel", nil, ["kocl": NSAppleEventDescriptor(typeCode: AppleEvents.code("note")), "insh": folder, "prdt": properties])
            return try summary(string("ID  ", created))
        }
        let id = try a.requiredString("id"); let current = try check(id, a); let target = note(id)
        switch name {
        case "notes_update":
            let keys = ["title", "append_text", "text"].filter { a.values[$0] != nil }
            guard keys.count == 1 else { throw ServiceError("invalid_arguments", "Specify exactly one of title, append_text or text") }
            let key = keys[0]; let value = try a.string(key, required: key == "title")!
            if key == "title" { _ = try event("setd", AppleEvents.property("pnam", target), ["data": NSAppleEventDescriptor(string: value)]) }
            else {
                let old = try string("body", target)
                guard try get(AppleEvents.all("atts", parent: target)).numberOfItems == 0, Self.isPlainHTML(old) else { throw ServiceError("unsupported_rich_content", "Body changes refuse attachments or rich HTML; title-only updates remain available") }
                guard old == (try a.string("expected_body_html", required: true)) else { throw ServiceError("source_changed", "Body changed, including within the native timestamp resolution") }
                let html = key == "text" ? "<div>\(Self.escapeHTML(current["title"].string ?? ""))</div><div>\(Self.escapeHTML(value))</div>" : old + "<div>\(Self.escapeHTML(value))</div>"
                _ = try event("setd", AppleEvents.property("body", target), ["data": NSAppleEventDescriptor(string: html)])
            }
            return try summary(id)
        case "notes_move":
            let destination = try a.requiredString("folder_id")
            if destination == current["folder_id"].string { return current }
            let folder = AppleEvents.object("cfol", "ID  ", NSAppleEventDescriptor(string: destination))
            let original = try get(AppleEvents.property("cntr", target))
            guard try accountID(original) == accountID(folder) else { throw ServiceError("unsupported_move", "Cross-account moves are refused to avoid copy/delete ambiguity") }
            let moved = try event("move", target, ["insh": folder])
            let newID = (try? string("ID  ", moved)) ?? id
            let observed = try summary(newID)
            guard observed["folder_id"].string == destination else { throw ServiceError("effect_unknown", "Move was submitted but destination is not yet verified; do not automatically repeat") }
            return observed
        case "notes_delete":
            guard confirm("删除这个备忘录？", "Agent: \(agentName)\n\(current["title"].string ?? "")\nID: \(id)") else { return .object(["status": .string("cancelled")]) }
            _ = try check(id, a); try authorize(); _ = try event("delo", target)
            return .object(["status": .string("deleted"), "id": .string(id)])
        default: throw ServiceError("unknown_tool", name)
        }
    }
}
