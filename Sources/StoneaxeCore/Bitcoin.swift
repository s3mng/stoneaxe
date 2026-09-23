import Foundation
import CryptoKit

public enum BitcoinError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let reason): return reason }
    }
}

public extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0, hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let end = hex.index(i, offsetBy: 2)
            guard let value = UInt8(hex[i..<end], radix: 16) else { return nil }
            bytes.append(value); i = end
        }
        self.init(bytes)
    }
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    var sha256d: Data { Data(SHA256.hash(data: Data(SHA256.hash(data: self)))) }
    func wordBE(_ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { ($0 << 8) | UInt32(self[offset + $1]) }
    }
    mutating func appendLE(_ value: UInt32) {
        append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
}

/// Bitcoin targets stored in human-readable, big-endian order.
public struct Target: Equatable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) { precondition(bytes.count == 32); self.bytes = bytes }
    public static let difficultyOne = Target(bytes: [0, 0, 0, 0, 255, 255] + Array(repeating: 0, count: 26))
    public init(compact: UInt32) throws {
        let exponent = Int(compact >> 24), mantissa = compact & 0x007fffff
        guard compact & 0x00800000 == 0, mantissa != 0, exponent <= 32 else {
            throw BitcoinError.invalid("Invalid block target")
        }
        var result = [UInt8](repeating: 0, count: 32)
        if exponent <= 3 {
            let n = mantissa >> (8 * (3 - exponent))
            for i in 0..<4 { result[31-i] = UInt8(truncatingIfNeeded: n >> (8*i)) }
        } else {
            for i in 0..<3 { result[32-exponent+i] = UInt8(truncatingIfNeeded: mantissa >> (8*(2-i))) }
        }
        guard result.contains(where: { $0 != 0 }) else { throw BitcoinError.invalid("Zero block target") }
        bytes = result
    }
    /// Exact floor(diff1 / difficulty) for the supplied IEEE-754 value.
    public init(difficulty: Double) throws {
        guard difficulty.isFinite, difficulty >= 1 else { throw BitcoinError.invalid("Invalid share difficulty") }
        let bits = difficulty.bitPattern
        let divisor = (bits & 0x000fffffffffffff) | (1 << 52)
        let exponent = Int((bits >> 52) & 0x7ff) - 1023 - 52
        var numerator = Self.difficultyOne.bytes.flatMap { byte in (0..<8).reversed().map { (byte >> $0) & 1 } }
        if exponent < 0 { numerator += Array(repeating: 0, count: -exponent) }
        var remainder: UInt64 = 0
        var quotient = [UInt8]()
        for bit in numerator {
            remainder = (remainder << 1) | UInt64(bit)
            if remainder >= divisor { remainder -= divisor; quotient.append(1) } else { quotient.append(0) }
        }
        if exponent > 0 { quotient = exponent >= quotient.count ? [] : Array(quotient.dropLast(exponent)) }
        quotient = Array(repeating: 0, count: max(0, 256 - quotient.count)) + quotient.suffix(256)
        bytes = stride(from: 0, to: 256, by: 8).map { start in
            quotient[start..<start+8].reduce(UInt8(0)) { ($0 << 1) | $1 }
        }
    }
    public func contains(digest: Data) -> Bool {
        let value = Array(digest.reversed())
        return value == bytes || value.lexicographicallyPrecedes(bytes)
    }
    public var words: [UInt32] { let d = Data(bytes); return stride(from: 0, to: 32, by: 4).map { d.wordBE($0) } }
    public static func difficulty(of digest: Data) -> Double {
        let value = digest.reversed().reduce(0.0) { $0 * 256 + Double($1) }
        let base = difficultyOne.bytes.reduce(0.0) { $0 * 256 + Double($1) }
        return value > 0 ? base / value : Double.greatestFiniteMagnitude
    }
}

public struct MiningJob {
    public let id: String
    public let previous: Data
    public let coinbasePrefix: Data
    public let coinbaseSuffix: Data
    public let branches: [Data]
    public let version: UInt32
    public let bits: UInt32
    public let time: String
    public let clean: Bool
    public let difficulty: Double

    public init(params: [Any], difficulty: Double) throws {
        guard params.count == 9,
              let id = params[0] as? String, !id.isEmpty, id.count <= 256,
              let prev = params[1] as? String, let previous = Data(hex: prev), previous.count == 32,
              let prefix = params[2] as? String, prefix.count <= 100_000, let cb1 = Data(hex: prefix),
              let suffix = params[3] as? String, suffix.count <= 100_000, let cb2 = Data(hex: suffix),
              let branchStrings = params[4] as? [String], branchStrings.count <= 32,
              let ver = params[5] as? String, ver.count == 8, let version = UInt32(ver, radix: 16),
              let bitsString = params[6] as? String, bitsString.count == 8, let bits = UInt32(bitsString, radix: 16),
              let time = params[7] as? String, time.count == 8, UInt32(time, radix: 16) != nil,
              let clean = params[8] as? Bool else { throw BitcoinError.invalid("Malformed mining job") }
        let branches = branchStrings.compactMap { Data(hex: $0) }
        guard branches.count == branchStrings.count, branches.allSatisfy({ $0.count == 32 }) else { throw BitcoinError.invalid("Invalid Merkle branch") }
        _ = try Target(compact: bits); _ = try Target(difficulty: difficulty)
        self.id = id; self.previous = previous; coinbasePrefix = cb1; coinbaseSuffix = cb2
        self.branches = branches; self.version = version; self.bits = bits
        self.time = time; self.clean = clean; self.difficulty = difficulty
    }
    public func header(extraNonce1: Data, extraNonce2: Data) -> Data {
        var root = (coinbasePrefix + extraNonce1 + extraNonce2 + coinbaseSuffix).sha256d
        for branch in branches { root = (root + branch).sha256d }
        var result = Data(); result.appendLE(version)
        // Stratum V1 previous hash is encoded as big-endian 32-bit words.
        for offset in stride(from: 0, to: 32, by: 4) { result.appendLE(previous.wordBE(offset)) }
        result.append(root)
        result.appendLE(UInt32(time, radix: 16)!); result.appendLE(bits); result.appendLE(0)
        return result
    }
}

public enum Address {
    /// Mainnet Base58Check and native SegWit (Bech32 / Bech32m), including Taproot.
    public static func isValid(_ address: String) -> Bool {
        guard address.count <= 90, !address.isEmpty else { return false }
        if address.lowercased().hasPrefix("bc1") { return validSegwit(address) }
        let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        var decoded = [UInt8](repeating: 0, count: 25)
        for c in address {
            guard let n = alphabet.firstIndex(of: c) else { return false }
            var carry = n
            for i in decoded.indices.reversed() { carry += Int(decoded[i]) * 58; decoded[i] = UInt8(carry & 255); carry >>= 8 }
            if carry != 0 { return false }
        }
        guard (26...35).contains(address.count), decoded[0] == 0 || decoded[0] == 5 else { return false }
        let leading = address.prefix(while: { $0 == "1" }).count
        guard decoded.prefix(while: { $0 == 0 }).count == leading else { return false }
        return Data(decoded.prefix(21)).sha256d.prefix(4) == Data(decoded.suffix(4))
    }
    private static func validSegwit(_ original: String) -> Bool {
        guard original == original.lowercased() || original == original.uppercased() else { return false }
        let s = original.lowercased()
        let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
        let chars = s.dropFirst(3)
        let data = chars.compactMap { alphabet.firstIndex(of: $0).map(UInt32.init) }
        guard data.count == chars.count, data.count >= 7 else { return false }
        var checksum: UInt32 = 1
        let generators: [UInt32] = [0x3b6a57b2,0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3]
        for value in [UInt32(3),3,0,2,3] + data {
            let top = checksum >> 25; checksum = ((checksum & 0x1ffffff) << 5) ^ value
            for j in 0..<5 where (top >> j) & 1 != 0 { checksum ^= generators[j] }
        }
        let version = data[0]
        guard version <= 16, checksum == (version == 0 ? 1 : 0x2bc830a3) else { return false }
        var accumulator: UInt32 = 0, bits = 0, program = [UInt8]()
        for value in data.dropFirst().dropLast(6) {
            accumulator = ((accumulator << 5) | value) & 0xfff; bits += 5
            while bits >= 8 { bits -= 8; program.append(UInt8((accumulator >> bits) & 255)) }
        }
        guard bits < 5, ((accumulator << (8-bits)) & 255) == 0, (2...40).contains(program.count) else { return false }
        return version != 0 || program.count == 20 || program.count == 32
    }
}
