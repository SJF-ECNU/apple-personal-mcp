import Foundation

public enum ICalendarInvitation {
    public static func email(_ value: String) -> Bool {
        value.range(of: "\\A[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\\z", options: .regularExpression) != nil
    }
    private static func text(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: ",", with: "\\,")
    }
    static func fold(_ value: String) -> String {
        var lines: [String] = []; var line = ""
        for scalar in value.unicodeScalars {
            let character = String(scalar)
            if line.utf8.count + character.utf8.count > 75 { lines.append(line); line = " " }
            line += character
        }
        lines.append(line); return lines.joined(separator: "\r\n")
    }
    public static func make(event: JSON, organizer: String, attendees: [String], now: Date = Date()) throws -> Data {
        guard email(organizer), !attendees.isEmpty, attendees.count <= 100, attendees.allSatisfy(email) else { throw ServiceError("invalid_arguments", "Use exact email addresses for organizer and attendees") }
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0); date.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let start = try EventKitModule.date(event["start"].string ?? ""); let end = try EventKitModule.date(event["end"].string ?? "")
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Apple Personal MCP//Invitation//EN", "CALSCALE:GREGORIAN", "METHOD:REQUEST", "BEGIN:VEVENT", "UID:" + text(event["uid"].string ?? ""), "DTSTAMP:" + date.string(from: now), "SEQUENCE:0"]
        if event["all_day"].boolean == true {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone.current
            date.timeZone = calendar.timeZone; date.dateFormat = "yyyyMMdd"
            let exclusive = calendar.startOfDay(for: end) == end ? end : calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))!
            lines += ["DTSTART;VALUE=DATE:" + date.string(from: start), "DTEND;VALUE=DATE:" + date.string(from: exclusive)]
        } else { lines += ["DTSTART:" + date.string(from: start), "DTEND:" + date.string(from: end)] }
        lines += ["SUMMARY:" + text(event["title"].string ?? ""), "LOCATION:" + text(event["location"].string ?? ""), "DESCRIPTION:" + text(event["notes"].string ?? ""), "ORGANIZER:mailto:" + organizer]
        lines += attendees.map { "ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:" + $0 }
        lines += ["STATUS:CONFIRMED", "END:VEVENT", "END:VCALENDAR"]
        return Data((lines.map(fold).joined(separator: "\r\n") + "\r\n").utf8)
    }
}

/// Public iCalendar email workflow; it does not pretend EventKit attendees are writable.
public final class CalendarInvitation {
    private let directory: URL
    private let mail: MailModule
    private let agent: AgentRecord
    private let operationURL: URL
    private let authorize: () throws -> Void
    public init(directory: URL, mail: MailModule, agent: AgentRecord, operationURL: URL, authorize: @escaping () throws -> Void) {
        self.directory = directory; self.mail = mail; self.agent = agent; self.operationURL = operationURL; self.authorize = authorize
    }
    public static let tools: [ToolDefinition] = {
        let f = ToolDefinition.field
        return [
            ToolDefinition("calendar_prepare_invitation", "Prepare an unsent standard iCalendar email for an existing one-off event; requires calendar.write and mail.write. Provider attendees remain unmanaged.", ["id": f("string", "EventKit event ID"), "expected_modified": f("string", "Latest last_modified"), "attendees": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "maxItems": .int(100)])], required: ["id", "expected_modified", "attendees"], readOnly: false),
            ToolDefinition("calendar_send_invitation", "Send a prepared iCalendar email after native human confirmation; additionally requires mail.send. Rechecks event and draft, delivery remains unknown.", ["invitation_id": f("string", "Prepared invitation UUID"), "operation_id": f("string", "Globally unique send UUID")], required: ["invitation_id", "operation_id"], readOnly: false),
        ]
    }()
    private func file(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw ServiceError("invalid_arguments", "Invalid invitation UUID") }
        return directory.appendingPathComponent(id + ".json")
    }
    private func save(_ row: JSON, _ id: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try PrivateFile.writeJSON(row, to: file(id))
    }
    public func call(_ name: String, _ values: [String: JSON]) throws -> JSON {
        try authorize(); let a = Arguments(values)
        let automation = MailAutomation(module: mail, operationURL: operationURL, agentName: agent.name, agentID: agent.id, authorize: authorize)
        if name == "calendar_prepare_invitation" {
            guard let recipients = values["attendees"]?.array, !recipients.isEmpty, recipients.count <= 100, recipients.allSatisfy({ $0.string.map(ICalendarInvitation.email) == true }) else { throw ServiceError("invalid_arguments", "Provide 1...100 exact attendee email addresses") }
            let attendees = Array(Set(recipients.compactMap(\.string))).sorted()
            let event = try EventKitModule(authorize: authorize).invitationDetails(values)
            let body = "日程邀请：\(event["title"].string ?? "")\n开始：\(event["start"].string ?? "")\n结束：\(event["end"].string ?? "")\n地点：\(event["location"].string ?? "")\n\n\(event["notes"].string ?? "")\n\n标准 iCalendar 附件；本服务不管理日历提供方的参与者状态。"
            let draft = try automation.call("mail_create_draft", ["subject": .string("邀请：" + (event["title"].string ?? "")), "body": .string(body), "to": .array(attendees.map(JSON.string))])
            let sender = draft["sender"].string ?? ""
            let organizer = sender.range(of: "<([^<>]+)>", options: .regularExpression).map { String(sender[$0].dropFirst().dropLast()) } ?? sender
            guard ICalendarInvitation.email(organizer) else { throw ServiceError("unsupported_sender", "Cannot parse the native From address; unsent draft \(draft["draft_id"].string ?? "") remains for review") }
            let ics = try ICalendarInvitation.make(event: event, organizer: organizer, attendees: attendees)
            let asset = try mail.assets.save(ics, filename: "invitation.ics", mimeType: "text/calendar; method=REQUEST; charset=utf-8")
            let observed = try automation.call("mail_add_attachment", ["draft_id": draft["draft_id"], "asset_id": asset["asset_id"]])
            let id = UUID().uuidString
            try save(.object(["invitation_id": .string(id), "event_arguments": .object(["id": values["id"]!, "expected_modified": values["expected_modified"]!]), "event": event, "draft": observed]), id)
            return .object(["invitation_id": .string(id), "draft": observed, "icalendar": asset, "status": .string("prepared_unsent"), "provider_attendees_managed": .bool(false)])
        }
        let id = try a.requiredString("invitation_id")
        guard let data = try? Data(contentsOf: file(id)) else { throw ServiceError("not_found", "Invitation is not owned by this Agent") }
        let record = try JSONDecoder().decode(JSON.self, from: data); let eventArgs = record["event_arguments"].object!
        let validate = {
            try self.authorize()
            guard try EventKitModule(authorize: self.authorize).invitationDetails(eventArgs) == record["event"] else { throw ServiceError("source_changed", "Calendar event changed since invitation preparation") }
        }
        let op = try a.requiredString("operation_id")
        if let previous = try OperationStore(url: operationURL, owner: agent.id).existing(op) { return previous }
        try validate()
        let guarded = MailAutomation(module: mail, operationURL: operationURL, agentName: agent.name, agentID: agent.id, authorize: validate)
        var expected = record["draft"].object!
        expected["body"] = .string(MailAutomation.draftBody(expected["body"]?.string ?? ""))
        guard try guarded.call("mail_get_draft", ["draft_id": record["draft"]["draft_id"]]) == .object(expected) else { throw ServiceError("source_changed", "Invitation draft changed; prepare a new invitation") }
        return try guarded.call("mail_send_draft", ["draft_id": record["draft"]["draft_id"], "operation_id": .string(op)])
    }
}
