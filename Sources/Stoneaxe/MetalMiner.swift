import Foundation
import Metal
import StoneaxeCore

struct BatchResult {
    let shares: [UInt32]
    let bestNonces: [UInt32]
    let gpuSeconds: Double
    let overflow: Bool
}

/// One in-flight command buffer, bounded and reused shared buffers. Only called on the mining queue.
final class MetalMiner {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let input: MTLBuffer
    private let output: MTLBuffer
    private var unavailable = false

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.hasUnifiedMemory,
              let queue = device.makeCommandQueue(maxCommandBufferCount: 1),
              let input = device.makeBuffer(length: 30 * 4, options: .storageModeShared),
              let output = device.makeBuffer(length: (65 + 1024) * 4, options: .storageModeShared),
              let url = Bundle.module.url(forResource: "Mining", withExtension: "metal") else {
            throw BitcoinError.invalid("GPU initialization failed")
        }
        let library = try device.makeLibrary(source: String(contentsOf: url), options: nil)
        guard let function = library.makeFunction(name: "mine") else { throw BitcoinError.invalid("Metal kernel missing") }
        pipeline = try device.makeComputePipelineState(function: function)
        guard pipeline.maxTotalThreadsPerThreadgroup >= 256 else { throw BitcoinError.invalid("Unsupported GPU threadgroup size") }
        self.device = device; self.queue = queue; self.input = input; self.output = output
    }
    func run(header: Data, target: Target, nonce: UInt32, count: Int) throws -> BatchResult {
        guard !unavailable else { throw BitcoinError.invalid("Restart Stoneaxe to retry the GPU") }
        guard header.count == 80, count >= 256, count <= 262144, count % 256 == 0,
              UInt64(nonce) + UInt64(count) <= UInt64(UInt32.max) + 1 else { throw BitcoinError.invalid("Invalid GPU batch") }
        let words = stride(from: 0, to: 80, by: 4).map { header.wordBE($0) } + target.words + [nonce, UInt32(count)]
        words.withUnsafeBytes { input.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        output.contents().storeBytes(of: UInt32(0), as: UInt32.self)
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw BitcoinError.invalid("GPU execution failed")
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(input, offset: 0, index: 0); encoder.setBuffer(output, offset: 0, index: 1)
        encoder.dispatchThreadgroups(MTLSize(width: count/256, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        let finished = DispatchSemaphore(value: 0)
        command.addCompletedHandler { _ in finished.signal() }
        encoder.endEncoding(); command.commit()
        // A stalled driver must not wedge the engine queue or app termination.
        // A timed-out command is never followed by another GPU submission.
        guard finished.wait(timeout: .now() + 3) == .success else {
            unavailable = true
            throw BitcoinError.invalid("GPU response timed out")
        }
        guard command.status == .completed else { unavailable = true; throw command.error ?? BitcoinError.invalid("GPU execution failed") }
        let data = output.contents().bindMemory(to: UInt32.self, capacity: 1089)
        let found = Int(data[0])
        return BatchResult(shares: Array(UnsafeBufferPointer(start: data+1, count: min(found,64))),
                           bestNonces: Array(UnsafeBufferPointer(start: data+65, count: count/256)),
                           gpuSeconds: max(0.000001, command.gpuEndTime-command.gpuStartTime), overflow: found > 64)
    }
    /// Real Bitcoin genesis header; independently rehash every GPU-reported candidate.
    func selfTest() throws {
        let header = Data(hex: "01000000" + String(repeating: "00", count: 32) + "3ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a" + "29ab5f49ffff001d1dac2b7c")!
        let nonce: UInt32 = 2083236893
        let target = try Target(compact: 0x1d00ffff)
        let result = try run(header: header, target: target, nonce: nonce-128, count: 256)
        guard result.shares.contains(nonce), !result.overflow else { throw BitcoinError.invalid("GPU/CPU hash mismatch") }
        for n in result.shares {
            var candidate = Data(header.prefix(76)); candidate.appendLE(n)
            guard target.contains(digest: candidate.sha256d) else { throw BitcoinError.invalid("GPU/CPU hash mismatch") }
        }
        // Differential test at an easy synthetic target: verify both false positives
        // and missed results across altered headers and nonce boundaries, offline.
        let easy = Target(bytes: [15] + Array(repeating: 255, count: 31))
        for base: UInt32 in [0, 0x12345600, 0xffffff00] {
            var changed = header
            changed[0] ^= UInt8(truncatingIfNeeded: base >> 24)
            changed[45] ^= 0xa5
            let output = try run(header: changed, target: easy, nonce: base, count: 256)
            var expected = Set<UInt32>()
            var bestNonce = base
            var bestHash = Data(repeating: 255, count: 32)
            for offset in 0..<256 {
                let n = base + UInt32(offset)
                var candidate = Data(changed.prefix(76)); candidate.appendLE(n)
                let digest = candidate.sha256d
                if easy.contains(digest: digest) { expected.insert(n) }
                let comparable = Data(digest.reversed())
                if comparable.lexicographicallyPrecedes(bestHash) { bestHash = comparable; bestNonce = n }
            }
            guard !output.overflow, Set(output.shares) == expected, output.bestNonces == [bestNonce] else {
                throw BitcoinError.invalid("GPU/CPU hash mismatch")
            }
        }
    }
}
