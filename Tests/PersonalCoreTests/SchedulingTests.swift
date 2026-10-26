import XCTest
@testable import PersonalCore

final class SchedulingTests: XCTestCase {
    func testReadersOverlapAndDoNotWaitForAutomation() throws {
        let scheduler = RequestScheduler(); let release = DispatchSemaphore(value: 0)
        let write = expectation(description: "automation running")
        let finished = expectation(description: "all completed"); finished.expectedFulfillmentCount = 3
        try scheduler.submit(agentID: "writer", automationApp: "mail", work: { write.fulfill(); _ = release.wait(timeout: .now() + 5); return Data() }, reply: { _ in finished.fulfill() })
        wait(for: [write], timeout: 2)
        let readers = expectation(description: "both readers running before either completes"); readers.expectedFulfillmentCount = 2
        for id in ["a", "b"] {
            try scheduler.submit(agentID: id, automationApp: nil, work: { readers.fulfill(); _ = release.wait(timeout: .now() + 5); return Data() }, reply: { _ in finished.fulfill() })
        }
        wait(for: [readers], timeout: 2)
        for _ in 0..<3 { release.signal() }; wait(for: [finished], timeout: 3)
    }
    func testMailAutomationDoesNotOverlapAcrossAgents() throws {
        let scheduler = RequestScheduler(); let release = DispatchSemaphore(value: 0); let lock = NSLock(); let secondEntered = DispatchSemaphore(value: 0)
        var active = 0; var maximum = 0
        let entered = expectation(description: "first entered"); let ended = expectation(description: "completed"); ended.expectedFulfillmentCount = 2
        for i in 0..<2 {
            try scheduler.submit(agentID: String(i), automationApp: "mail", work: {
                lock.lock(); active += 1; maximum = max(maximum, active); lock.unlock()
                if i == 0 { entered.fulfill(); _ = release.wait(timeout: .now() + 5) }
                else { secondEntered.signal() }
                lock.lock(); active -= 1; lock.unlock(); return Data()
            }, reply: { _ in ended.fulfill() })
            if i == 0 { wait(for: [entered], timeout: 2) }
        }
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 0.1), .timedOut)
        release.signal(); wait(for: [ended], timeout: 3); XCTAssertEqual(maximum, 1)
    }
    func testReadPoolAndAdmissionAreBounded() throws {
        let scheduler = RequestScheduler(); let release = DispatchSemaphore(value: 0); let lock = NSLock()
        var active = 0; var maximum = 0; var enteredCount = 0
        let entered = expectation(description: "four readers running"); entered.expectedFulfillmentCount = 4
        let ended = expectation(description: "all completed"); ended.expectedFulfillmentCount = 16
        for _ in 0..<16 {
            try scheduler.submit(agentID: "a", automationApp: nil, work: {
                lock.lock(); active += 1; maximum = max(maximum, active); enteredCount += 1; let firstFour = enteredCount <= 4; lock.unlock()
                if firstFour { entered.fulfill() }
                _ = release.wait(timeout: .now() + 5)
                lock.lock(); active -= 1; lock.unlock(); return Data()
            }, reply: { _ in ended.fulfill() })
        }
        wait(for: [entered], timeout: 2)
        XCTAssertThrowsError(try scheduler.submit(agentID: "a", automationApp: nil, work: { Data() }, reply: { _ in XCTFail("Over-limit work ran") }))
        for _ in 0..<16 { release.signal() }; wait(for: [ended], timeout: 3); XCTAssertEqual(maximum, 4)
    }
}
