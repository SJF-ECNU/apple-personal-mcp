import AppKit

/// Stateless descriptor construction; authorization and error handling stay in each adapter.
enum AppleEvents {
    static func code(_ value: String) -> FourCharCode { value.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    static func object(_ kind: String, _ form: String, _ selection: NSAppleEventDescriptor, _ parent: NSAppleEventDescriptor? = nil) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        for (key, value) in [("want", NSAppleEventDescriptor(typeCode: code(kind))), ("form", NSAppleEventDescriptor(enumCode: code(form))), ("seld", selection), ("from", parent ?? .null())] {
            record.setDescriptor(value, forKeyword: code(key))
        }
        return record.coerce(toDescriptorType: code("obj "))!
    }

    static func property(_ name: String, _ parent: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        object("prop", "prop", NSAppleEventDescriptor(typeCode: code(name)), parent)
    }

    static func all(_ kind: String, parent: NSAppleEventDescriptor? = nil) -> NSAppleEventDescriptor {
        var ordinal = code("all ")
        return object(kind, "indx", NSAppleEventDescriptor(descriptorType: code("abso"), bytes: &ordinal, length: 4)!, parent)
    }

    static func items(_ value: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
        guard value.numberOfItems > 0 else { return [] }
        return (1...value.numberOfItems).compactMap { value.atIndex($0) }
    }

    static func strings(_ value: NSAppleEventDescriptor) -> [String] {
        if value.numberOfItems == 0 { return value.stringValue.map { [$0] } ?? [] }
        return items(value).compactMap(\.stringValue)
    }

    static func request(bundleID: String, eventClass: String, id: String, direct: NSAppleEventDescriptor?, parameters: [String: NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor.appleEvent(withEventClass: code(eventClass), eventID: code(id), targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: bundleID), returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let direct { event.setParam(direct, forKeyword: keyDirectObject) }
        for (key, value) in parameters { event.setParam(value, forKeyword: code(key)) }
        return event
    }

    static func permissionStatus(bundleID: String, ask: Bool) -> Int32 {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let descriptor = target.aeDesc else { return -1 }
        return AEDeterminePermissionToAutomateTarget(descriptor, typeWildCard, typeWildCard, ask)
    }

    static func ensureRunning(bundleID: String, name: String) throws {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { throw ServiceError("app_unavailable", "\(name).app not found") }
        let done = DispatchSemaphore(value: 0)
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in done.signal() }
        guard done.wait(timeout: .now() + 15) == .success else { throw ServiceError("app_unavailable", "\(name) did not start") }
    }
}
