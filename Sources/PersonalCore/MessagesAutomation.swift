import Foundation

public final class MessagesAutomation {
    private let authorize: () throws -> Void
    private let agentName: String
    private let state: OperationStore
    private let confirm: (String, String) -> Bool
    public init(operationURL: URL, agentID: String, agentName: String, authorize: @escaping () throws -> Void, confirm: @escaping (String, String) -> Bool = NativeConfirmation.ask) throws {
        self.authorize = authorize; self.agentName = agentName; self.confirm = confirm
        state = try OperationStore(url: operationURL, owner: agentID + ":messages")
    }
    public static let tools: [ToolDefinition] = {
        let f = ToolDefinition.field
        return [
            ToolDefinition("messages_list_targets", "List official sending chat IDs and participants; these differ from local numeric chat IDs", ["offset": f("integer", "Offset"), "limit": f("integer", "1...100")]),
            ToolDefinition("messages_list_accounts", "List official account IDs, services and connection states"),
            ToolDefinition("messages_preview_recipient", "Resolve one exact E.164 phone/email on an explicit official account without sending", ["account_id": f("string", "Official account ID"), "handle": f("string", "E.164 phone including country code, or exact email")], required: ["account_id", "handle"]),
            ToolDefinition("messages_send", "Send plain text after native confirmation: choose chat_id OR account_id plus exact handle. Unknown is never retried", ["chat_id": f("string", "Official ID from messages_list_targets"), "account_id": f("string", "Official account ID for an exact recipient"), "handle": f("string", "E.164 phone/email, with account_id"), "text": f("string", "Full message text"), "operation_id": f("string", "New globally unique UUID")], required: ["text", "operation_id"], readOnly: false),
        ]
    }()
    public static func permissionStatus(ask: Bool = false) -> Int32 {
        AppleEvents.permissionStatus(bundleID: "com.apple.MobileSMS", ask: ask)
    }
    public static func ensureRunning() throws {
        try AppleEvents.ensureRunning(bundleID: "com.apple.MobileSMS", name: "Messages")
    }
    private func event(_ action: String, _ direct: NSAppleEventDescriptor, _ params: [String: NSAppleEventDescriptor] = [:]) throws -> NSAppleEventDescriptor {
        try authorize()
        let event = AppleEvents.request(bundleID: "com.apple.MobileSMS", eventClass: action == "send" ? "icht" : "core", id: action, direct: direct, parameters: params)
        let reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 20)
        if let code = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value, code != 0 { throw ServiceError(code == -1743 ? "needs_messages_automation_permission" : "apple_event_failed", "Messages returned \(code)") }
        return reply.paramDescriptor(forKeyword: keyDirectObject) ?? .null()
    }
    private func get(_ key: String, _ target: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        do { return try event("getd", AppleEvents.property(key, target)) }
        catch let error as ServiceError { throw ServiceError(error.code, "Official Messages property \(key): \(error.description)") }
    }
    private func chat(_ id: String) -> NSAppleEventDescriptor { AppleEvents.object("imct", "ID  ", NSAppleEventDescriptor(string: id)) }
    private func account(_ id: String) throws -> NSAppleEventDescriptor {
        let list = try event("getd", AppleEvents.all("icsv"))
        let references = AppleEvents.items(list)
        let matches = try references.filter { try get("ID  ", $0).stringValue == id }
        guard matches.count == 1 else { throw ServiceError("ambiguous_target", "Official account does not resolve uniquely") }
        return matches[0]
    }
    private func accountInfo(_ id: String) throws -> JSON {
        let account = try account(id)
        guard try get("ID  ", account).stringValue == id else { throw ServiceError("ambiguous_target", "Official account identity did not match") }
        let names: [UInt32: String] = [AppleEvents.code("sims"): "iMessage", AppleEvents.code("ssms"): "SMS", AppleEvents.code("srcs"): "RCS"]
        return .object(["account_id": .string(id), "service": .string(names[try get("styp", account).enumCodeValue] ?? "unsupported"), "connected": .bool(try get("ssta", account).enumCodeValue == AppleEvents.code("conn")), "enabled": .bool(try get("enbl", account).booleanValue)])
    }
    public static func validHandle(_ value: String) -> Bool {
        value.range(of: "\\A\\+[1-9][0-9]{6,14}\\z", options: .regularExpression) != nil || value.range(of: "\\A[^\\s<>@,;:]+@[^\\s<>@,;:]+\\z", options: .regularExpression) != nil
    }
    private func participant(_ id: String, _ handle: String) throws -> NSAppleEventDescriptor { AppleEvents.object("pres", "name", NSAppleEventDescriptor(string: handle), try account(id)) }
    private func recipient(_ id: String, _ handle: String) throws -> JSON {
        guard Self.validHandle(handle) else { throw ServiceError("invalid_arguments", "Use a single E.164 phone or exact email, not a contact name") }
        var fields = try accountInfo(id).object!
        let target = try participant(id, handle)
        let observed = try get("hndl", target).stringValue ?? ""
        guard observed.caseInsensitiveCompare(handle) == .orderedSame, try get("ID  ", get("icsv", target)).stringValue == id else { throw ServiceError("ambiguous_target", "Native participant did not resolve to the exact handle and account") }
        fields["participant_id"] = .string(try get("ID  ", target).stringValue ?? ""); fields["participants"] = .array([.string(observed)])
        return .object(fields)
    }
    private func target(_ id: String) throws -> JSON {
        let target = chat(id)
        guard try get("ID  ", target).stringValue == id else { throw ServiceError("ambiguous_target", "Official chat identity did not match") }
        let account = try get("icsv", target)
        let names: [UInt32: String] = [AppleEvents.code("sims"): "iMessage", AppleEvents.code("ssms"): "SMS", AppleEvents.code("srcs"): "RCS"]
        return .object(["chat_id": .string(id), "name": .string(try get("pnam", target).stringValue ?? ""), "participants": .array(AppleEvents.strings(try event("getd", AppleEvents.property("hndl", AppleEvents.all("pres", parent: target)))).map(JSON.string)), "account_id": .string(try get("ID  ", account).stringValue ?? ""), "service": .string(names[try get("styp", account).enumCodeValue] ?? "unsupported"), "connected": .bool(try get("ssta", account).enumCodeValue == AppleEvents.code("conn"))])
    }
    public func call(_ name: String, _ values: [String: JSON]) throws -> JSON {
        try authorize(); try Self.ensureRunning()
        guard Self.permissionStatus() == 0 else { throw ServiceError("needs_messages_automation_permission", "Authorize Messages through the App owner settings") }
        let a = Arguments(values)
        if name == "messages_list_accounts" {
            let ids = AppleEvents.strings(try event("getd", AppleEvents.property("ID  ", AppleEvents.all("icsv"))))
            let rows = try ids.map { id -> JSON in
                do { return try accountInfo(id) }
                catch let error as ServiceError where error.code == "apple_event_failed" {
                    return .object(["account_id": .string(id), "state": .string("native_account_unavailable"), "error": .string(error.description)])
                }
            }
            return .object(["accounts": .array(rows)])
        }
        if name == "messages_preview_recipient" { return try recipient(a.requiredString("account_id"), a.requiredString("handle")) }
        if name == "messages_list_targets" {
            let ids = AppleEvents.strings(try event("getd", AppleEvents.property("ID  ", AppleEvents.all("imct")))).sorted()
            let offset = try a.integer("offset", default: 0, range: 0...Int.max); let limit = try a.integer("limit", default: 20, range: 1...100)
            guard offset <= ids.count else { throw ServiceError("invalid_cursor", "Offset exceeds current official targets") }
            let next = offset + min(limit, ids.count - offset)
            return .object(["targets": .array(try ids[offset..<next].map(target)), "next_offset": next < ids.count ? .int(next) : .null, "has_more": .bool(next < ids.count)])
        }
        guard name == "messages_send" else { throw ServiceError("unknown_tool", name) }
        let op = try a.requiredString("operation_id")
        guard UUID(uuidString: op) != nil else { throw ServiceError("invalid_arguments", "operation_id must be UUID") }
        if let previous = try state.existing(op) { return previous }
        let chatID = try a.string("chat_id"); let accountID = try a.string("account_id"); let handle = try a.string("handle")
        guard (chatID != nil && accountID == nil && handle == nil) || (chatID == nil && accountID != nil && handle != nil) else { throw ServiceError("invalid_arguments", "Choose chat_id OR account_id plus handle") }
        let text = try a.requiredString("text")
        func resolve() throws -> JSON { if let chatID { return try target(chatID) }; return try recipient(accountID!, handle!) }
        let preview = try resolve()
        guard preview["connected"].boolean == true, preview["service"].string != "unsupported", !(preview["participants"].array ?? []).isEmpty else { throw ServiceError("app_unavailable", "Chat has no supported connected account or participants") }
        try state.claim(op)
        let description = "Agent: \(agentName)\nService: \(preview["service"].string ?? "")\nAccount: \(preview["account_id"].string ?? "")\nTo: \((preview["participants"].array ?? []).compactMap(\.string).joined(separator: ", "))\nTarget ID: \(chatID ?? preview["participant_id"].string ?? "")\n\n\(text)"
        guard confirm("发送这条信息？", description) else { try state.update(op, "cancelled"); return try state.get(op) }
        do { try authorize(); guard try resolve() == preview else { throw ServiceError("source_changed", "Target or account changed during confirmation") } }
        catch { try state.update(op, "cancelled"); throw error }
        try state.update(op, "unknown")
        do {
            let destination: NSAppleEventDescriptor
            if let chatID { destination = chat(chatID) } else { destination = try participant(accountID!, handle!) }
            _ = try event("send", NSAppleEventDescriptor(string: text), ["TO  ": destination]); try state.update(op, "submitted")
        }
        catch { return try state.get(op) }
        return try state.get(op)
    }
}
