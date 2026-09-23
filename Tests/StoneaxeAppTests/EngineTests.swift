import XCTest
@testable import Stoneaxe

final class EngineTests: XCTestCase {
    func testEnabledEngineAccountsWaitingTimeWithoutExclusiveAccessCrash() {
        // The former crash occurred on the first waiting tick after saving an
        // enabled configuration, before any pool work or GPU batch was needed.
        // No valid address, start(), or disk store: entirely offline and isolated.
        var settings = Settings()
        settings.enabled = true
        settings.address = ""
        let engine = Engine(settings: settings)
        let received = expectation(description: "Enabled waiting tick remains alive")
        engine.onSnapshot = { state in
            XCTAssertGreaterThan(state.session.pausedSeconds, 0)
            XCTAssertFalse(state.isMining)
            XCTAssertNil(state.fault)
            received.fulfill()
        }
        engine.configure(settings)
        wait(for: [received], timeout: 5)
    }

    func testRepeatedPauseAndResumeTicksDoNotCrash() {
        var settings = Settings()
        settings.enabled = true
        settings.address = ""
        let engine = Engine(settings: settings)
        let received = expectation(description: "Repeated state updates")
        received.expectedFulfillmentCount = 20
        engine.onSnapshot = { state in
            XCTAssertGreaterThanOrEqual(state.session.pausedSeconds, 0)
            XCTAssertNil(state.fault)
            received.fulfill()
        }
        for i in 0..<20 { engine.pause(i % 2 == 0) }
        wait(for: [received], timeout: 5)
    }
}
