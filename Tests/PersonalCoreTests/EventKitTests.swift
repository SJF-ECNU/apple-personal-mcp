import XCTest
@testable import PersonalCore

final class EventKitTests: XCTestCase {
    func testTimezoneAndRangeBoundaries() throws {
        let valid = Arguments(["date_from": .string("2026-10-26T00:00:00+08:00"), "date_to": .string("2026-10-27T00:00:00+08:00")])
        let range = try EventKitModule.range(valid)
        XCTAssertEqual(range.1.timeIntervalSince(range.0), 86400)
        XCTAssertEqual(try EventKitModule.date("2026-10-26T00:00:00.125+08:00").timeIntervalSince(EventKitModule.date("2026-10-26T00:00:00+08:00")), 0.125, accuracy: 0.001)
        for (from, to) in [("2026-10-26", "2026-10-27"), ("2026-10-27T00:00:00Z", "2026-10-26T00:00:00Z"), ("2026-01-01T00:00:00Z", "2028-01-01T00:00:00Z")] {
            XCTAssertThrowsError(try EventKitModule.range(Arguments(["date_from": .string(from), "date_to": .string(to)])))
        }
    }
    func testScopesDoNotCrossApplications() {
        let agent = AgentRecord(id: UUID().uuidString, name: "calendar", permissions: ["calendar.read"], revoked: false)
        XCTAssertTrue(EventKitModule.tools.filter { agent.allows($0) }.allSatisfy { $0.name.hasPrefix("calendar_") })
        XCTAssertEqual(EventKitModule.tools.filter { agent.allows($0) }.count, 3)
    }
}
