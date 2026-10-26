import EventKit
import Foundation

public final class EventKitModule {
    private let store = EKEventStore()
    private let authorize: () throws -> Void
    private let agentName: String
    private let confirm: (String, String) -> Bool
    public init(agentName: String = "Local", authorize: @escaping () throws -> Void = {}, confirm: @escaping (String, String) -> Bool = NativeConfirmation.ask) {
        self.agentName = agentName; self.authorize = authorize; self.confirm = confirm
    }
    private static let field = ToolDefinition.field
    public static let tools: [ToolDefinition] = {
        let id = field("string", "Exact EventKit identifier")
        let paging = ["offset": field("integer", "Result offset"), "limit": field("integer", "1...200, default 50")]
        let body = ["id": id, "body_offset": field("integer", "Notes Unicode scalar offset"), "max_chars": field("integer", "Notes page size 1...16000")]
        return [
            ToolDefinition("calendar_list", "List accessible EventKit calendars"),
            ToolDefinition("calendar_search", "Read event instances in a timezone-qualified range of at most one year", paging.merging(["date_from": field("string", "ISO 8601 with timezone"), "date_to": field("string", "ISO 8601 with timezone"), "calendar_id": id, "text": field("string", "Title/location filter")]) { a, _ in a }, required: ["date_from", "date_to"]),
            ToolDefinition("calendar_get", "Read one EventKit event and paged notes; supply occurrence_start for recurring instances", body.merging(["occurrence_start": field("string", "Exact occurrence_start from search")]) { a, _ in a }, required: ["id"]),
            ToolDefinition("reminders_list_lists", "List accessible EventKit reminder lists"),
            ToolDefinition("reminders_search", "Search local EventKit reminders; original due date components are preserved", paging.merging(["list_id": id, "completed": field("boolean", "Exact completion status"), "text": field("string", "Title/notes filter")]) { a, _ in a }),
            ToolDefinition("reminders_get", "Read one reminder and paged notes", body, required: ["id"]),
        ] + writeTools
    }()
    public static func status(_ app: String) -> JSON {
        let status = EKEventStore.authorizationStatus(for: app == "calendar" ? .event : .reminder)
        return .object(["state": .string(status == .fullAccess ? "ready" : "needs_\(app)_permission"), "authorization_status": .int(status.rawValue), "backend": .string("official_eventkit"), "writes_implemented": .bool(true), "new_attendee_invitations": .bool(false)])
    }
    public static func date(_ value: String) throws -> Date {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let result = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { throw ServiceError("invalid_arguments", "Date must be ISO 8601 including timezone") }
        return result
    }
    public static func range(_ args: Arguments) throws -> (Date, Date) {
        let from = try date(args.requiredString("date_from"))
        let to = try date(args.requiredString("date_to"))
        guard to > from, to.timeIntervalSince(from) <= 366 * 86400 else { throw ServiceError("invalid_arguments", "Event range must be positive and at most 366 days") }
        return (from, to)
    }
    private func calendar(_ id: String?, type: EKEntityType) throws -> [EKCalendar]? {
        guard let id else { return nil }
        guard let calendar = store.calendars(for: type).first(where: { $0.calendarIdentifier == id }) else { throw ServiceError("not_found", "Calendar/list not found") }
        return [calendar]
    }
    private func page(_ values: [JSON], _ args: Arguments) throws -> JSON {
        let offset = try args.integer("offset", default: 0, range: 0...Int.max)
        let limit = try args.integer("limit", default: 50, range: 1...200)
        guard offset <= values.count else { throw ServiceError("invalid_cursor", "Offset exceeds current results") }
        let next = offset + min(limit, values.count - offset)
        return .object(["items": .array(Array(values[offset..<next])), "total": .int(values.count), "next_offset": next < values.count ? .int(next) : .null, "has_more": .bool(next < values.count), "coverage": .string("current_eventkit_store; results may change between pages")])
    }
    private func iso(_ date: Date?) -> JSON {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return date.map { .string(formatter.string(from: $0)) } ?? .null
    }
    private func event(_ event: EKEvent) -> JSON {
        .object(["id": .string(event.eventIdentifier ?? event.calendarItemIdentifier), "calendar_id": .string(event.calendar.calendarIdentifier), "title": .string(event.title ?? ""), "start": iso(event.startDate), "end": iso(event.endDate), "occurrence_start": iso(event.startDate), "all_day": .bool(event.isAllDay), "time_zone": event.timeZone.map { .string($0.identifier) } ?? .null, "location": .string(event.location ?? ""), "recurring": .bool(event.hasRecurrenceRules), "last_modified": iso(event.lastModifiedDate)])
    }
    private func components(_ value: DateComponents?) -> JSON {
        guard let value else { return .null }
        var fields: [String: JSON] = [:]
        for (key, number) in [("year", value.year), ("month", value.month), ("day", value.day), ("hour", value.hour), ("minute", value.minute), ("second", value.second)] { fields[key] = number.map(JSON.int) ?? .null }
        fields["time_zone"] = value.timeZone.map { .string($0.identifier) } ?? .null
        fields["calendar"] = value.calendar.map { .string(String(describing: $0.identifier)) } ?? .null
        return .object(fields)
    }
    private func reminder(_ reminder: EKReminder) -> JSON {
        .object(["id": .string(reminder.calendarItemIdentifier), "list_id": .string(reminder.calendar.calendarIdentifier), "title": .string(reminder.title ?? ""), "completed": .bool(reminder.isCompleted), "priority": .int(reminder.priority), "due_components": components(reminder.dueDateComponents), "start_components": components(reminder.startDateComponents), "completion_date": iso(reminder.completionDate), "last_modified": iso(reminder.lastModifiedDate)])
    }
    public func call(_ name: String, _ values: [String: JSON]) throws -> JSON {
        let app = name.hasPrefix("calendar_") ? "calendar" : "reminders"
        let type: EKEntityType = app == "calendar" ? .event : .reminder
        guard EKEventStore.authorizationStatus(for: type) == .fullAccess else { throw ServiceError("needs_\(app)_permission", "Grant \(app) access in ApplePersonalMCP.app; MCP cannot grant system permissions") }
        let args = Arguments(values)
        let result: JSON
        switch name {
        case "calendar_list", "reminders_list_lists":
            result = .object(["items": .array(store.calendars(for: type).map { .object(["id": .string($0.calendarIdentifier), "title": .string($0.title), "account": .string($0.source.title), "allows_modifications": .bool($0.allowsContentModifications)]) })])
        case "calendar_search":
            let (from, to) = try Self.range(args)
            let calendars = try calendar(args.string("calendar_id"), type: .event)
            let text = try args.string("text")
            let events = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: calendars)).filter {
                guard let text, !text.isEmpty else { return true }
                return (($0.title ?? "") + " " + ($0.location ?? "")).localizedCaseInsensitiveContains(text)
            }.sorted { $0.startDate == $1.startDate ? ($0.eventIdentifier ?? "") < ($1.eventIdentifier ?? "") : $0.startDate < $1.startDate }
            result = try page(events.map(event), args)
        case "calendar_get":
            let id = try args.requiredString("id")
            guard var found = store.event(withIdentifier: id) else { throw ServiceError("not_found", "Event not found; search again after sync") }
            if let occurrence = try args.string("occurrence_start") {
                let start = try Self.date(occurrence)
                let candidates = store.events(matching: store.predicateForEvents(withStart: start, end: start.addingTimeInterval(1), calendars: [found.calendar]))
                let matches = candidates.filter { $0.calendarItemIdentifier == found.calendarItemIdentifier && abs($0.startDate.timeIntervalSince(start)) < 0.001 }
                guard matches.count == 1 else { throw ServiceError("source_changed", "Event occurrence no longer resolves uniquely") }; found = matches[0]
            } else if found.hasRecurrenceRules { throw ServiceError("invalid_arguments", "Recurring events require occurrence_start from search") }
            var fields = event(found).object!
            fields["notes"] = try BodyPaging.page(found.notes ?? "", arguments: args)
            result = .object(fields)
        case "reminders_search":
            let lists = try calendar(args.string("list_id"), type: .reminder)
            let done = DispatchSemaphore(value: 0); let lock = NSLock(); var fetched: [EKReminder]?
            let token = store.fetchReminders(matching: store.predicateForReminders(in: lists)) { values in lock.lock(); fetched = values; lock.unlock(); done.signal() }
            guard done.wait(timeout: .now() + 15) == .success else { store.cancelFetchRequest(token); throw ServiceError("timeout", "EventKit reminder fetch timed out") }
            lock.lock(); let snapshot = fetched; lock.unlock()
            guard let snapshot else { throw ServiceError("eventkit_unavailable", "EventKit did not return reminders") }
            let completed = try args.bool("completed"); let text = try args.string("text")
            let reminders = snapshot.filter { item in
                (completed == nil || completed == item.isCompleted) && (text == nil || text!.isEmpty || ((item.title ?? "") + " " + (item.notes ?? "")).localizedCaseInsensitiveContains(text!))
            }.sorted { $0.calendarItemIdentifier < $1.calendarItemIdentifier }
            result = try page(reminders.map(reminder), args)
        case "reminders_get":
            guard let found = store.calendarItem(withIdentifier: try args.requiredString("id")) as? EKReminder else { throw ServiceError("not_found", "Reminder not found") }
            var fields = reminder(found).object!
            fields["notes"] = try BodyPaging.page(found.notes ?? "", arguments: args); result = .object(fields)
        default:
            guard Self.writeTools.contains(where: { $0.name == name }) else { throw ServiceError("unknown_tool", name) }
            result = try mutate(name, args)
        }
        return .object((result.object ?? [:]).merging(["source": .object(["application": .string(app), "backend": .string("official_eventkit")]), "observed_at": .string(ISO8601DateFormatter().string(from: Date()))]) { a, _ in a })
    }
}

extension EventKitModule {
    func invitationDetails(_ values: [String: JSON]) throws -> JSON {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw ServiceError("needs_calendar_permission", "Calendar full access is required") }
        let a = Arguments(values); let item = try resolveEvent(a)
        try checkModified(item, a)
        guard !item.hasRecurrenceRules, !item.isDetached else { throw ServiceError("unsupported_invitation_scope", "Create a one-off event before preparing an iCalendar email invitation") }
        guard let uid = item.calendarItemExternalIdentifier, !uid.isEmpty else { throw ServiceError("source_unavailable", "This provider has no external calendar UID") }
        var fields = event(item).object!; fields["uid"] = .string(uid); fields["notes"] = .string(item.notes ?? "")
        return .object(fields)
    }
    public static let writeTools: [ToolDefinition] = {
        let f = ToolDefinition.field
        let identity = ["id": f("string", "Native item ID"), "expected_modified": f("string", "Exact last_modified from latest read")]
        let eventFields = ["title": f("string", "Title"), "notes": f("string", "Plain notes"), "location": f("string", "Location"), "date_from": f("string", "ISO 8601 start with timezone"), "date_to": f("string", "ISO 8601 end with timezone"), "time_zone": f("string", "IANA timezone identifier"), "all_day": f("boolean", "All-day boundaries must be midnight in time_zone"), "calendar_id": f("string", "Writable calendar ID"), "recurrence": f("object", "frequency daily/weekly/monthly/yearly, interval 1...365, count 1...1000")]
        let occurrence = ["occurrence_start": f("string", "Exact occurrence_start for recurring items"), "scope": f("string", "Required for recurring events: occurrence or future")]
        let reminderFields = ["title": f("string", "Title"), "notes": f("string", "Plain notes"), "list_id": f("string", "Writable reminder list ID"), "priority": f("integer", "0...9"), "due_components": f("object", "year/month/day and optional hour/minute/time_zone; empty object clears due date")]
        return [
            ToolDefinition("calendar_create", "Create an event without adding attendees", eventFields, required: ["title", "date_from", "date_to", "calendar_id"], readOnly: false),
            ToolDefinition("calendar_update", "Update explicit fields; existing attendees require native confirmation", identity.merging(eventFields) { a, _ in a }.merging(occurrence) { a, _ in a }, required: ["id", "expected_modified"], readOnly: false),
            ToolDefinition("calendar_delete", "Delete the specified event/scope only after native confirmation", identity.merging(occurrence) { a, _ in a }, required: ["id", "expected_modified"], readOnly: false),
            ToolDefinition("reminders_create", "Create a reminder in an explicit list", reminderFields, required: ["title", "list_id"], readOnly: false),
            ToolDefinition("reminders_update", "Update specified reminder fields, retaining other properties", identity.merging(reminderFields) { a, _ in a }, required: ["id", "expected_modified"], readOnly: false),
            ToolDefinition("reminders_complete", "Set an explicit completion state; repeated completed=true never toggles", identity.merging(["completed": f("boolean", "Explicit completion state")]) { a, _ in a }, required: ["id", "completed", "expected_modified"], readOnly: false),
            ToolDefinition("reminders_delete", "Delete one reminder only after native confirmation", identity, required: ["id", "expected_modified"], readOnly: false),
        ]
    }()
    public static func dueComponents(_ json: JSON) throws -> DateComponents? {
        guard let fields = json.object, Set(fields.keys).isSubset(of: ["year", "month", "day", "hour", "minute", "time_zone"]) else { throw ServiceError("invalid_arguments", "Unsupported due date components") }
        if fields.isEmpty { return nil }
        let a = Arguments(fields)
        guard fields["year"] != nil, fields["month"] != nil, fields["day"] != nil else { throw ServiceError("invalid_arguments", "Due date needs year, month and day") }
        var components = DateComponents()
        components.year = try a.integer("year", default: 2001, range: 1900...9999); components.month = try a.integer("month", default: 1, range: 1...12); components.day = try a.integer("day", default: 1, range: 1...31)
        if fields["hour"] != nil {
            components.hour = try a.integer("hour", default: 0, range: 0...23); components.minute = try a.integer("minute", default: 0, range: 0...59)
        } else if fields["minute"] != nil { throw ServiceError("invalid_arguments", "Minute requires hour") }
        if let zone = try a.string("time_zone") {
            guard let value = TimeZone(identifier: zone) else { throw ServiceError("invalid_arguments", "Invalid time_zone") }; components.timeZone = value
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = components.timeZone ?? TimeZone(secondsFromGMT: 0)!
        components.calendar = calendar
        guard let date = calendar.date(from: components), calendar.component(.year, from: date) == components.year, calendar.component(.month, from: date) == components.month, calendar.component(.day, from: date) == components.day,
              components.hour == nil || calendar.component(.hour, from: date) == components.hour else { throw ServiceError("invalid_arguments", "Due date is not a valid local calendar date") }
        return components
    }
    private func checkModified(_ item: EKCalendarItem, _ args: Arguments) throws {
        guard let actual = iso(item.lastModifiedDate).string, actual == (try args.string("expected_modified", required: true)) else { throw ServiceError("source_changed", "Item changed; read it again before updating") }
        guard item.calendar.allowsContentModifications else { throw ServiceError("read_only_calendar", "Calendar/list does not allow modifications") }
    }
    private func writableCalendar(_ id: String, _ type: EKEntityType) throws -> EKCalendar {
        guard let value = try calendar(id, type: type)?.first, value.allowsContentModifications else { throw ServiceError("read_only_calendar", "Selected calendar/list is not writable") }; return value
    }
    private func resolveEvent(_ args: Arguments) throws -> EKEvent {
        guard var found = store.event(withIdentifier: try args.requiredString("id")) else { throw ServiceError("not_found", "Event not found") }
        if let occurrence = try args.string("occurrence_start") {
            let start = try Self.date(occurrence)
            let candidates = store.events(matching: store.predicateForEvents(withStart: start, end: start.addingTimeInterval(1), calendars: [found.calendar]))
            let matches = candidates.filter { $0.calendarItemIdentifier == found.calendarItemIdentifier && abs($0.startDate.timeIntervalSince(start)) < 0.001 }
            guard matches.count == 1 else { throw ServiceError("source_changed", "Occurrence no longer resolves uniquely") }; found = matches[0]
        } else if found.hasRecurrenceRules { throw ServiceError("invalid_arguments", "Recurring events require occurrence_start") }
        return found
    }
    private func span(_ event: EKEvent, _ args: Arguments) throws -> EKSpan {
        let scope = try args.string("scope")
        if event.hasRecurrenceRules || scope != nil {
            guard args.values["occurrence_start"] != nil, let scope, ["occurrence", "future"].contains(scope) else { throw ServiceError("invalid_arguments", "Specify occurrence_start and scope occurrence/future") }
            return scope == "future" ? .futureEvents : .thisEvent
        }
        return .thisEvent
    }
    private func mutate(_ name: String, _ a: Arguments) throws -> JSON {
        try authorize()
        if name.hasPrefix("calendar_") {
            let creating = name == "calendar_create"
            var item = try creating ? EKEvent(eventStore: store) : resolveEvent(a)
            let range = creating ? EKSpan.thisEvent : try span(item, a)
            if !creating { try checkModified(item, a) }
            if name == "calendar_delete" || (!creating && !(item.attendees ?? []).isEmpty) {
                let changes = JSON.object(a.values.filter { !["id", "expected_modified"].contains($0.key) }).text()
                let attendees = (item.attendees ?? []).map { $0.url.absoluteString }.joined(separator: "\n")
                let detail = "Agent: \(agentName)\n\(item.title ?? "")\n\(iso(item.startDate).string ?? "")\nScope: \(try a.string("scope") ?? "event")\nID: \(item.eventIdentifier ?? "")\nAttendees:\n\(attendees)\nRequested: \(changes)\n\n已有参与者的修改可能发送通知。"
                guard confirm(name == "calendar_delete" ? "删除这个日程？" : "修改含参与者的日程？", detail) else { return .object(["status": .string("cancelled")]) }
                store.reset(); item = try resolveEvent(a); try checkModified(item, a); try authorize()
            }
            if name == "calendar_delete" {
                try store.remove(item, span: range, commit: true)
                return .object(["status": .string("deleted"), "id": a.values["id"] ?? .null, "scope": .string(try a.string("scope") ?? "event")])
            }
            if creating { item.calendar = try writableCalendar(a.requiredString("calendar_id"), .event) }
            else if let id = try a.string("calendar_id") { item.calendar = try writableCalendar(id, .event) }
            if let title = try a.string("title", required: creating) { item.title = title }
            if let notes = try a.string("notes") { item.notes = notes }
            if let location = try a.string("location") { item.location = location }
            if let zone = try a.string("time_zone") { guard let value = TimeZone(identifier: zone) else { throw ServiceError("invalid_arguments", "Invalid time_zone") }; item.timeZone = value }
            if let start = try a.string("date_from", required: creating) { item.startDate = try Self.date(start) }
            if let end = try a.string("date_to", required: creating) { item.endDate = try Self.date(end) }
            let intendedZone = try a.string("time_zone").flatMap(TimeZone.init(identifier:)) ?? item.timeZone
            let proposedStart = try a.string("date_from").map(Self.date) ?? item.startDate!
            let proposedEnd = try a.string("date_to").map(Self.date) ?? item.endDate!
            if let allDay = try a.bool("all_day") { item.isAllDay = allDay }
            guard item.endDate > item.startDate else { throw ServiceError("invalid_arguments", "Event end must be after start") }
            if item.isAllDay && (creating || !Set(a.values.keys).isDisjoint(with: ["date_from", "date_to", "all_day", "time_zone"])) {
                guard let zone = intendedZone else { throw ServiceError("invalid_arguments", "All-day events require time_zone") }
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
                guard calendar.startOfDay(for: proposedStart) == proposedStart, calendar.startOfDay(for: proposedEnd) == proposedEnd else { throw ServiceError("invalid_arguments", "All-day boundaries must be local midnight") }
            }
            if let raw = a.values["recurrence"] {
                guard let fields = raw.object, Set(fields.keys).isSubset(of: ["frequency", "interval", "count"]) else { throw ServiceError("invalid_arguments", "Unsupported recurrence fields") }
                if fields.isEmpty { item.recurrenceRules = nil }
                else {
                    guard creating || range == .futureEvents else { throw ServiceError("invalid_arguments", "Recurrence changes require future scope") }
                    let r = Arguments(fields); let frequency = try r.string("frequency", required: true)!
                    let frequencies: [String: EKRecurrenceFrequency] = ["daily": .daily, "weekly": .weekly, "monthly": .monthly, "yearly": .yearly]
                    guard let value = frequencies[frequency], fields["count"] != nil else { throw ServiceError("invalid_arguments", "Recurrence needs supported frequency and count") }
                    item.recurrenceRules = [EKRecurrenceRule(recurrenceWith: value, interval: try r.integer("interval", default: 1, range: 1...365), end: EKRecurrenceEnd(occurrenceCount: try r.integer("count", default: 1, range: 1...1000)))]
                }
            }
            try authorize(); try store.save(item, span: range, commit: true)
            return event(item)
        }
        let creating = name == "reminders_create"
        let item: EKReminder
        if creating { item = EKReminder(eventStore: store); item.calendar = try writableCalendar(a.requiredString("list_id"), .reminder) }
        else { guard let found = store.calendarItem(withIdentifier: try a.requiredString("id")) as? EKReminder else { throw ServiceError("not_found", "Reminder not found") }; item = found }
        if name == "reminders_complete", let completed = try a.bool("completed"), completed == item.isCompleted { return reminder(item) }
        if !creating { try checkModified(item, a) }
        if name == "reminders_delete" {
            guard confirm("删除这个提醒事项？", "Agent: \(agentName)\n\(item.title ?? "")\nID: \(item.calendarItemIdentifier)") else { return .object(["status": .string("cancelled")]) }
            let identifier = item.calendarItemIdentifier; store.reset()
            guard let fresh = store.calendarItem(withIdentifier: identifier) as? EKReminder else { throw ServiceError("not_found", "Reminder no longer exists") }
            try checkModified(fresh, a); try authorize(); try store.remove(fresh, commit: true)
            return .object(["status": .string("deleted"), "id": a.values["id"] ?? .null])
        }
        if let title = try a.string("title", required: creating) { item.title = title }
        if let notes = try a.string("notes") { item.notes = notes }
        if let list = try a.string("list_id"), !creating { item.calendar = try writableCalendar(list, .reminder) }
        if a.values["priority"] != nil { item.priority = try a.integer("priority", default: 0, range: 0...9) }
        if let due = a.values["due_components"] { item.dueDateComponents = try Self.dueComponents(due) }
        if name == "reminders_complete" { guard let completed = try a.bool("completed") else { throw ServiceError("invalid_arguments", "completed is required") }; item.isCompleted = completed }
        try authorize(); try store.save(item, commit: true)
        return reminder(item)
    }
}
