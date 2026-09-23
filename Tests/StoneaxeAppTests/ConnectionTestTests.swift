import XCTest
import StoneaxeCore
@testable import Stoneaxe

final class ConnectionTestTests: XCTestCase {
    private func job() throws -> MiningJob {
        try MiningJob(params: ["test", String(repeating: "00", count: 32), "", "", [String](), "20000000", "1d00ffff", "495fab29", true], difficulty: 1)
    }
    func testSuccessRequiresAllThreeStages() throws {
        var state = ConnectionTestState(outcome: .running)
        state.receive(.job(try job()))
        XCTAssertEqual(state.outcome, .running)
        state.receive(.transportConnected)
        state.receive(.ready(Data(), 4))
        XCTAssertEqual(state.outcome, .running)
        state.receive(.job(try job()))
        XCTAssertEqual(state.outcome, .passed)
        XCTAssertTrue(state.serverConnected && state.addressAuthorized && state.workReceived)
        state.receive(.disconnected)
        state.timeOut()
        XCTAssertEqual(state.outcome, .passed)
    }
    func testFailurePreservesCompletedSteps() {
        var state = ConnectionTestState(outcome: .running)
        state.receive(.disconnected) // start() clears a previous session first
        XCTAssertEqual(state.outcome, .running)
        state.receive(.transportConnected)
        state.receive(.log("Wallet authorization failed"))
        XCTAssertEqual(state.outcome, .failed)
        XCTAssertTrue(state.serverConnected)
        XCTAssertFalse(state.addressAuthorized)
    }
    func testTimeoutIdentifiesMissingStage() {
        var state = ConnectionTestState(outcome: .running)
        state.receive(.transportConnected)
        state.receive(.ready(Data(), 4))
        state.receive(.log("Pool authorized"))
        state.timeOut()
        XCTAssertEqual(state.message, "Timed out waiting for mining work")
        XCTAssertEqual(state.outcome, .failed)
    }
}
