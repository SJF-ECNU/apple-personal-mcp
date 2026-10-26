import AppKit
import XCTest
@testable import PersonalCore

final class SharedUtilitiesTests: XCTestCase {
    func testDescriptorsKeepObjectIdentityAndListSemantics() throws {
        let box = AppleEvents.object("mbxp", "name", NSAppleEventDescriptor(string: "Inbox/Work"))
        let message = AppleEvents.object("mssg", "ID  ", NSAppleEventDescriptor(int32: 42), box)
        let record = try XCTUnwrap(message.coerce(toDescriptorType: typeAERecord))
        XCTAssertEqual(record.forKeyword( AppleEvents.code("want"))?.typeCodeValue, AppleEvents.code("mssg"))
        XCTAssertEqual(record.forKeyword( AppleEvents.code("seld"))?.int32Value, 42)
        XCTAssertEqual(record.forKeyword( AppleEvents.code("from"))?.data, box.data)
        let property = try XCTUnwrap(AppleEvents.property("isrd", message).coerce(toDescriptorType: typeAERecord))
        XCTAssertEqual(property.forKeyword( AppleEvents.code("form"))?.enumCodeValue, AppleEvents.code("prop"))
        XCTAssertEqual(property.forKeyword( AppleEvents.code("from"))?.data, message.data)
        let all = try XCTUnwrap(AppleEvents.all("attc", parent: message).coerce(toDescriptorType: typeAERecord))
        XCTAssertEqual(all.forKeyword( AppleEvents.code("form"))?.enumCodeValue, AppleEvents.code("indx"))
        XCTAssertEqual(all.forKeyword( AppleEvents.code("from"))?.data, message.data)
        let list = NSAppleEventDescriptor.list()
        XCTAssertEqual(AppleEvents.strings(list), [])
        XCTAssertEqual(AppleEvents.items(NSAppleEventDescriptor(string: "scalar")), [])
        list.insert(NSAppleEventDescriptor(string: "中文😀"), at: 1)
        list.insert(NSAppleEventDescriptor(string: "second"), at: 2)
        XCTAssertEqual(AppleEvents.strings(list), ["中文😀", "second"])
        XCTAssertEqual(AppleEvents.strings(NSAppleEventDescriptor(string: "scalar")), ["scalar"])
    }

    func testRequestKeepsApplicationAndEventClassWithoutSending() throws {
        for (bundle, cls, action) in [("com.apple.mail", "core", "getd"), ("com.apple.Notes", "core", "save"), ("com.apple.MobileSMS", "icht", "send")] {
            let recipient = AppleEvents.object("pres", "ID  ", NSAppleEventDescriptor(string: "synthetic-recipient"))
            let request = AppleEvents.request(bundleID: bundle, eventClass: cls, id: action, direct: NSAppleEventDescriptor(string: "synthetic"), parameters: ["TO  ": recipient])
            XCTAssertEqual(request.attributeDescriptor(forKeyword: keyAddressAttr)?.data, NSAppleEventDescriptor(bundleIdentifier: bundle).data)
            XCTAssertEqual(request.attributeDescriptor(forKeyword: keyEventClassAttr)?.typeCodeValue, AppleEvents.code(cls))
            XCTAssertEqual(request.attributeDescriptor(forKeyword: keyEventIDAttr)?.typeCodeValue, AppleEvents.code(action))
            XCTAssertEqual(request.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, "synthetic")
            XCTAssertEqual(request.paramDescriptor(forKeyword: AppleEvents.code("TO  "))?.data, recipient.data)
        }
    }

    func testPrivateReplacementKeepsPermissionsAndEncodingFailureKeepsPriorData() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("state.json")
        try PrivateFile.write(Data([0, 255, 1]), to: file)
        XCTAssertEqual(try Data(contentsOf: file), Data([0, 255, 1]))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let value = JSON.object(["text": .string("中文😀\0"), "optional": .null])
        try PrivateFile.writeJSON(value, to: file)
        XCTAssertEqual(try JSONDecoder().decode(JSON.self, from: Data(contentsOf: file)), value)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        struct Invalid: Encodable {
            func encode(to encoder: Encoder) throws { throw ServiceError("synthetic", "encoding failed") }
        }
        let prior = try Data(contentsOf: file)
        XCTAssertThrowsError(try PrivateFile.writeJSON(Invalid(), to: file))
        XCTAssertEqual(try Data(contentsOf: file), prior)
        XCTAssertThrowsError(try PrivateFile.writeJSON(value, to: folder.appendingPathComponent("missing/state.json")))
    }

    func testSharedArgumentReadersKeepValidationAndUnicodeCursors() throws {
        XCTAssertEqual(try Arguments(["value": .string("  text  ")]).requiredString("value"), "  text  ")
        for value in [JSON.null, .string("  "), .int(4)] {
            XCTAssertThrowsError(try Arguments(["value": value]).requiredString("value")) { XCTAssertEqual(($0 as? ServiceError)?.code, "invalid_arguments") }
        }
        XCTAssertThrowsError(try Arguments([:]).requiredString("value"))
        let page = try BodyPaging.page("A😀B", arguments: Arguments(["body_offset": .int(1), "max_chars": .int(1)]))
        XCTAssertEqual(page["text"].string, "😀")
        XCTAssertEqual(page["next_offset"].int, 2)
        for value in [JSON.int(0), .int(16001), .number(1.5), .null] {
            XCTAssertThrowsError(try BodyPaging.page("text", arguments: Arguments(["max_chars": value]))) { XCTAssertEqual(($0 as? ServiceError)?.code, "invalid_arguments") }
        }
        XCTAssertThrowsError(try BodyPaging.page("text", arguments: Arguments(["body_offset": .int(10)]))) { XCTAssertEqual(($0 as? ServiceError)?.code, "invalid_cursor") }
    }
}
