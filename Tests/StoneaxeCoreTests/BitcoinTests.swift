import XCTest
@testable import StoneaxeCore

final class BitcoinTests: XCTestCase {
    let genesis = Data(hex: "01000000" + String(repeating: "00", count: 32) + "3ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a" + "29ab5f49ffff001d1dac2b7c")!
    func testGenesisHashAndTarget() throws {
        XCTAssertEqual(Data(genesis.sha256d.reversed()).hex, "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f")
        XCTAssertTrue(try Target(compact: 0x1d00ffff).contains(digest: genesis.sha256d))
        XCTAssertEqual(try Target(difficulty: 1), Target.difficultyOne)
        XCTAssertEqual(try Target(difficulty: 2).bytes, [0,0,0,0,127,255,128] + Array(repeating: 0, count: 25))
        XCTAssertThrowsError(try Target(difficulty: .nan))
        XCTAssertThrowsError(try Target(compact: 0x1d80ffff))
    }
    func testHeaderAndStratumByteOrder() throws {
        // Bitcoin genesis coinbase / Merkle root: independent known mainnet vector.
        let coinbase = "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff4d04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73ffffffff0100f2052a01000000434104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac00000000"
        let params: [Any] = ["genesis", String(repeating:"00",count:32), coinbase, "", [String](), "00000001", "1d00ffff", "495fab29", true]
        let job = try MiningJob(params: params, difficulty: 1)
        let header = job.header(extraNonce1: Data(), extraNonce2: Data())
        XCTAssertEqual(header.prefix(76), genesis.prefix(76))
        var nonzero = params; nonzero[1] = "01020304" + String(repeating: "00", count:28)
        let other = try MiningJob(params: nonzero, difficulty: 1).header(extraNonce1: Data(), extraNonce2: Data())
        XCTAssertEqual(other.subdata(in: 4..<8).hex, "04030201")
    }
    func testAddressChecksums() {
        XCTAssertTrue(Address.isValid("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"))
        XCTAssertTrue(Address.isValid("3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy"))
        XCTAssertFalse(Address.isValid("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNb"))
        XCTAssertFalse(Address.isValid("mipcBbFg9gMiCh81Kj8tqqdgoZub1ZJRfn"))
        XCTAssertFalse(Address.isValid("bc1q"))
        XCTAssertFalse(Address.isValid(String(repeating:"a",count:1000)))
        XCTAssertTrue(Address.isValid("bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh"))
        XCTAssertFalse(Address.isValid("bC1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh"))
    }
    func testMalformedJobsAndHex() {
        XCTAssertNil(Data(hex: "xyz")); XCTAssertNil(Data(hex: "0g"))
        XCTAssertThrowsError(try MiningJob(params: [], difficulty: 1))
    }
    func testAdaptivePolicy() {
        let p = MiningPolicy()
        XCTAssertEqual(p.decision(enabled:true, paused:false, sleeping:false, battery:false, allowBattery:false, heat:.nominal, idleSeconds:0).duty, 0.05)
        XCTAssertEqual(p.decision(enabled:true, paused:false, sleeping:false, battery:false, allowBattery:false, heat:.nominal, idleSeconds:500).duty, 0.20)
        XCTAssertEqual(p.decision(enabled:true, paused:false, sleeping:false, battery:true, allowBattery:false, heat:.nominal, idleSeconds:500).duty, 0)
        XCTAssertEqual(p.decision(enabled:true, paused:false, sleeping:false, battery:false, allowBattery:false, heat:.serious, idleSeconds:500).duty, 0)
        XCTAssertEqual(MiningPolicy.ramp(current:0.2, target:0.05), 0.05)
        XCTAssertEqual(MiningPolicy.ramp(current:0.05, target:0.2), 0.06, accuracy: 0.00001)
        XCTAssertEqual(MiningPolicy.batchSize(current:4096, gpuSeconds:0.008), 1024)
    }
}
