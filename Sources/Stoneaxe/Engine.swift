import Foundation
import CoreGraphics
import IOKit.ps
import StoneaxeCore

struct EngineSnapshot {
    var status = "Starting"
    var connection = "Disconnected"
    var gpu = "Apple GPU"
    var rate = 0.0
    var history: [Double] = []
    var duty = 0.0
    var gpuMilliseconds = 0.0
    var batchSize = 256
    var session = Totals()
    var persisted = Persisted()
    var logs: [LogEntry] = []
    var isMining = false
    var paused = false
    var memoryMB = 0.0
    var fault: String?
    var storageWarning: String?
}

// Mutable mining state is confined to queue. Callbacks are installed before start,
// then invoked on the main queue. URLSession is thread-safe.
final class Engine: @unchecked Sendable {
    let queue = DispatchQueue(label: "app.stoneaxe.engine", qos: .utility)
    var onSnapshot: ((EngineSnapshot) -> Void)?
    var onNotification: ((String, String, String?) -> Void)?
    private var settings: Settings
    private var storage: Storage?
    private var miner: MetalMiner?
    private var snapshot = EngineSnapshot()
    private var timer: DispatchSourceTimer?
    private var nextBatch: DispatchWorkItem?
    private var sleeping = false
    private var running = false
    private var extra1 = Data()
    private var extra2 = Data()
    private var job: MiningJob?
    private var header = Data()
    private var target = Target.difficultyOne
    private var blockTarget = Target.difficultyOne
    private var nextNonce: UInt64 = 0
    private var tickTime = ProcessInfo.processInfo.systemUptime
    private var intervalHashes = 0.0
    private var lastBatchTime = 0.0
    private var thermalRecoveryUntil = 0.0
    private var gpuYieldUntil = 0.0
    private var saveTicks = 0
    private var shareBlocks: [UUID: String] = [:]
    private var monitorBusy = false
    private var lastMonitor = Date.distantPast
    private let web: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 30
        config.urlCache = nil
        return URLSession(configuration: config)
    }()
    private lazy var pool = Stratum(queue: queue) { [weak self] in self?.poolEvent($0) }

    init(settings: Settings) { self.settings = settings }
    func start() {
        queue.async { [self] in
            do {
                storage = try Storage()
                storage?.onError = { [weak self] message in self?.snapshot.storageWarning = message }
                log("info", "Stoneaxe started")
                snapshot.status = "Checking GPU"
                publish()
                miner = try MetalMiner(); try miner?.selfTest()
                snapshot.gpu = miner?.device.name ?? "Apple GPU"
                log("info", "GPU self-test passed")
                running = true
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
                timer.setEventHandler { [weak self] in self?.tick() }; timer.resume(); self.timer = timer
                connectIfNeeded()
            } catch {
                snapshot.fault = error.localizedDescription; snapshot.status = "Mining stopped after error"
                log("error", "GPU initialization failed"); publish()
            }
        }
    }
    func configure(_ value: Settings) {
        queue.async { [self] in
            let reconnect = settings.address != value.address || settings.enabled != value.enabled
            settings = value
            if reconnect { pool.stop(); snapshot.session = Totals(); connectIfNeeded() }
            tick()
        }
    }
    func pause(_ value: Bool) { queue.async { [self] in snapshot.paused = value; tick() } }
    func sleep(_ value: Bool) {
        queue.async { [self] in
            sleeping = value
            if value { pool.stop(); storage?.save() } else { tickTime = ProcessInfo.processInfo.systemUptime; connectIfNeeded() }
            tick()
        }
    }
    func shutdown(completion: @escaping () -> Void) {
        queue.async { [self] in
            running = false; timer?.cancel(); nextBatch?.cancel(); nextBatch = nil
            pool.stop(); web.invalidateAndCancel(); log("info", "Stoneaxe stopped"); storage?.save()
            DispatchQueue.main.async(execute: completion)
        }
    }
    func export(to url: URL, completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(storage?.state ?? Persisted()).write(to: url, options: .atomic)
                DispatchQueue.main.async { completion(true) }
            } catch { DispatchQueue.main.async { completion(false) } }
        }
    }
    private func connectIfNeeded() {
        if settings.enabled && Address.isValid(settings.address) && !sleeping && snapshot.fault == nil { pool.start(address: settings.address) }
    }
    private func poolEvent(_ event: Stratum.Event) {
        switch event {
        case .transportConnected: break
        case .status(let status): snapshot.connection = status
        case .log(let text): log("info", text)
        case .disconnected:
            job = nil; snapshot.connection = "Disconnected"; snapshot.rate = 0; snapshot.isMining = false
            nextBatch?.cancel(); nextBatch = nil
        case .ready(let data, let count):
            extra1 = data; extra2 = Data(repeating: 0, count: count); job = nil
        case .job(let value):
            job = value
            guard advanceExtraNonce() else { return }
            prepareJob(); scheduleBatch(after: 0.01)
        case .share(let id, let accepted, _):
            if accepted == true {
                update { $0.accepted += 1; $0.lastAccepted = Date() }; log("info", "Share accepted")
                if settings.shareNotifications { notify("Share accepted", "Work accepted by CKPool. This is not a block reward.", nil) }
            } else if accepted == false { update { $0.rejected += 1 }; log("warning", "Share rejected") }
            else { update { $0.unknown += 1 }; log("warning", "Share outcome unknown") }
            if let hash = shareBlocks.removeValue(forKey: id), let i = storage?.state.blocks.firstIndex(where: { $0.id == hash }) {
                storage?.state.blocks[i].poolAccepted = accepted; storage?.save()
            }
        }
    }
    private func advanceExtraNonce() -> Bool {
        guard !extra2.isEmpty else { return false }
        for i in extra2.indices.reversed() {
            extra2[i] &+= 1
            if extra2[i] != 0 { return true }
        }
        // Re-subscribe for a new namespace instead of repeating any header.
        pool.start(address: settings.address); return false
    }
    private func prepareJob() {
        guard let job else { return }
        do {
            header = job.header(extraNonce1: extra1, extraNonce2: extra2)
            target = try Target(difficulty: job.difficulty); blockTarget = try Target(compact: job.bits)
            nextNonce = 0
        } catch { fail("Invalid mining work") }
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = max(0, min(2, now-tickTime)); tickTime = now
        let wasMining = snapshot.isMining
        if elapsed > 0 {
            snapshot.rate = intervalHashes / elapsed; intervalHashes = 0
            if wasMining { update { $0.miningSeconds += elapsed } }
            else if settings.enabled {
                let cooling = snapshot.status == "Cooling down"
                update { $0.pausedSeconds += elapsed; if cooling { $0.thermalSeconds += elapsed } }
            }
        }
        var policy = MiningPolicy()
        policy.activeDuty = min(0.10, max(0.01, settings.activePercent / 100))
        policy.idleDuty = min(0.25, max(policy.activeDuty, settings.idlePercent / 100))
        policy.idleThreshold = max(60, settings.idleMinutes * 60)
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        let power = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let source = power.flatMap { IOPSGetProvidingPowerSourceType($0)?.takeUnretainedValue() as String? }
        let battery = source == kIOPSBatteryPowerValue
        let heat = Heat(rawValue: ProcessInfo.processInfo.thermalState.rawValue) ?? .critical
        if heat == .serious || heat == .critical { thermalRecoveryUntil = now + 60 }
        var decision = policy.decision(enabled: settings.enabled && Address.isValid(settings.address), paused: snapshot.paused,
                                       sleeping: sleeping, battery: battery, allowBattery: settings.allowBattery, heat: heat, idleSeconds: idle)
        if decision.duty > 0 && now < thermalRecoveryUntil { decision = (0, "Cooling down") }
        if decision.duty > 0 && now < gpuYieldUntil { decision = (0, "GPU busy · yielding") }
        snapshot.duty = MiningPolicy.ramp(current: snapshot.duty, target: decision.duty)
        let status = snapshot.fault != nil ? "Mining stopped after error" : (decision.duty > 0 && job == nil ? "Waiting for pool work" : decision.reason)
        if status != snapshot.status { snapshot.status = status; log("info", status) }
        snapshot.isMining = snapshot.duty > 0 && job != nil && snapshot.fault == nil && now-lastBatchTime < 3
        snapshot.history.append(snapshot.rate)
        if snapshot.history.count > 60 { snapshot.history.removeFirst(snapshot.history.count-60) }
        if decision.duty == 0 || snapshot.fault != nil { nextBatch?.cancel(); nextBatch = nil; snapshot.isMining = false }
        else { scheduleBatch(after: 0.01) }
        snapshot.memoryMB = memoryFootprint()
        saveTicks += 1
        if saveTicks >= 30 { storage?.save(); saveTicks = 0 }
        checkBlocks()
        publish()
    }
    private func scheduleBatch(after delay: Double) {
        guard running, nextBatch == nil, job != nil, snapshot.duty > 0, snapshot.fault == nil, !sleeping else { return }
        let work = DispatchWorkItem { [weak self] in self?.nextBatch = nil; self?.batch() }
        nextBatch = work; queue.asyncAfter(deadline: .now()+delay, execute: work)
    }
    private func batch() {
        guard running, snapshot.duty > 0, snapshot.fault == nil, let job, let miner, !sleeping else { return }
        let start = ProcessInfo.processInfo.systemUptime
        // Check thermal pressure before every submission, not only the UI tick.
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            thermalRecoveryUntil = start + 60; tick(); return
        }
        do {
            if nextNonce >= 4_294_967_296 {
                guard advanceExtraNonce() else { return }; prepareJob()
            }
            let count = min(snapshot.batchSize, Int(4_294_967_296-nextNonce))
            // Always test against the easier of share and network targets.
            let scanTarget = target.bytes.lexicographicallyPrecedes(blockTarget.bytes) ? blockTarget : target
            let result = try miner.run(header: header, target: scanTarget, nonce: UInt32(nextNonce), count: count)
            guard !result.overflow else { fail("GPU result buffer overflow"); return }
            intervalHashes += Double(count)
            update { $0.hashes += Double(count); $0.gpuSeconds += result.gpuSeconds }
            lastBatchTime = ProcessInfo.processInfo.systemUptime
            var best = 0.0
            for nonce in Set(result.bestNonces + result.shares) {
                var candidate = Data(header.prefix(76)); candidate.appendLE(nonce)
                let digest = candidate.sha256d
                best = max(best, Target.difficulty(of: digest))
            }
            update { $0.bestDifficulty = max($0.bestDifficulty, best) }
            for nonce in result.shares {
                var candidate = Data(header.prefix(76)); candidate.appendLE(nonce)
                let digest = candidate.sha256d
                guard scanTarget.contains(digest: digest) else { fail("GPU/CPU hash mismatch"); return }
                let id = UUID()
                if blockTarget.contains(digest: digest) {
                    let hash = Data(digest.reversed()).hex
                    if storage?.state.blocks.contains(where: { $0.id == hash }) == false {
                        storage?.state.blocks.append(BlockRecord(id: hash, header: candidate.hex, address: settings.address))
                        storage?.save(); log("success", "Block candidate found")
                        if settings.blockNotifications { notify("Block candidate found", "Network confirmation pending. A share acceptance alone does not confirm a block.", hash) }
                    }
                    shareBlocks[id] = hash
                }
                update { $0.submitted += 1 }
                pool.submit(job: job, extra: extra2, nonce: nonce, id: id)
            }
            nextNonce += UInt64(count)
            snapshot.gpuMilliseconds = result.gpuSeconds * 1000
            snapshot.batchSize = MiningPolicy.batchSize(current: count, gpuSeconds: result.gpuSeconds)
            let wall = ProcessInfo.processInfo.systemUptime-start
            if result.gpuSeconds > 0.008 || wall > 0.05 {
                snapshot.batchSize = max(256, min(snapshot.batchSize, count/2/256*256))
                gpuYieldUntil = ProcessInfo.processInfo.systemUptime + 2
                snapshot.duty = 0; tick(); return
            }
            // Duty is a scheduling budget, not a claim about system GPU utilization.
            let delay = max(0.01, result.gpuSeconds / snapshot.duty - wall)
            scheduleBatch(after: delay)
        } catch { fail("GPU execution failed") }
    }
    private func update(_ body: (inout Totals) -> Void) {
        // Do not hold an exclusive inout access to snapshot across a callback:
        // the callback may read another field of the same value-type snapshot.
        var session = snapshot.session
        body(&session)
        snapshot.session = session
        storage?.updateTotals(body)
    }
    private func fail(_ message: String) {
        snapshot.fault = message; snapshot.isMining = false; snapshot.rate = 0; snapshot.duty = 0
        nextBatch?.cancel(); nextBatch = nil; pool.stop(); log("error", message); storage?.save(); publish()
    }
    private func log(_ level: String, _ message: String) {
        let entry = LogEntry(level: level, message: message)
        snapshot.logs.append(entry)
        if snapshot.logs.count > 300 { snapshot.logs.removeFirst(snapshot.logs.count-300) }
        storage?.record(entry)
    }
    private func publish() {
        snapshot.persisted = storage?.state ?? Persisted()
        let value = snapshot
        DispatchQueue.main.async { [weak self] in self?.onSnapshot?(value) }
    }
    private func notify(_ title: String, _ body: String, _ hash: String?) {
        DispatchQueue.main.async { [weak self] in self?.onNotification?(title, body, hash) }
    }
    private func memoryFootprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
    private func checkBlocks() {
        guard settings.verifyBlocks, !sleeping, !monitorBusy, Date().timeIntervalSince(lastMonitor) >= 60,
              let record = storage?.state.blocks.filter({ $0.confirmations < 100 && Date().timeIntervalSince($0.found) < 7*86400 })
                .min(by: { ($0.lastChecked ?? .distantPast) < ($1.lastChecked ?? .distantPast) }) else { return }
        monitorBusy = true; lastMonitor = Date()
        // Only a locally verified block candidate triggers explorer requests.
        let hash = record.id
        Task { [weak self] in
            guard let self else { return }
            var outcome: (String, Int?, Int)?
            do {
                let headerData = try await self.fetch("block/\(hash)/header")
                guard String(data: headerData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == record.header else { throw BitcoinError.invalid("Explorer header mismatch") }
                let statusData = try await self.fetch("block/\(hash)/status")
                let status = try JSONDecoder().decode(ExplorerStatus.self, from: statusData)
                if status.in_best_chain {
                    let blockData = try await self.fetch("block/\(hash)")
                    let info = try JSONDecoder().decode(ExplorerBlock.self, from: blockData)
                    guard info.id == hash, info.height >= 0 else { throw BitcoinError.invalid("Explorer block mismatch") }
                    let height = info.height
                    let tipData = try await self.fetch("blocks/tip/height")
                    guard let string = String(data: tipData, encoding: .utf8), let tip = Int(string.trimmingCharacters(in: .whitespacesAndNewlines)), tip >= height else { throw BitcoinError.invalid("Explorer tip") }
                    outcome = ("In main chain", height, tip-height+1)
                } else { outcome = ("Not in main chain", nil, 0) }
            } catch { /* Temporary API failure/404 is never evidence of a rejected block. */ }
            let final = outcome
            self.queue.async {
                self.monitorBusy = false
                guard let i = self.storage?.state.blocks.firstIndex(where: { $0.id == hash }) else { return }
                self.storage?.state.blocks[i].lastChecked = Date()
                if let (status, height, confirmations) = final {
                    let previous = self.storage!.state.blocks[i]
                    self.storage?.state.blocks[i].status = status
                    self.storage?.state.blocks[i].height = height
                    self.storage?.state.blocks[i].confirmations = confirmations
                    if confirmations > 0 && !previous.includedNotified {
                        self.storage?.state.blocks[i].includedNotified = true
                        self.log("success", "Block included in main chain")
                        if self.settings.blockNotifications { self.notify("Stoneaxe found a block!", "The block is in the main chain. Coinbase rewards require maturity and can be affected by reorganizations.", hash) }
                    } else if confirmations == 0 && previous.confirmations > 0 {
                        self.log("warning", "Block left the main chain")
                        if self.settings.blockNotifications { self.notify("Block left the main chain", "The network reorganized. The block reward is not confirmed.", hash) }
                    }
                    if confirmations >= 100 && !previous.matureNotified {
                        self.storage?.state.blocks[i].matureNotified = true
                        if self.settings.blockNotifications { self.notify("100 block confirmations", "Check the coinbase output in your wallet. Stoneaxe does not verify your spendable balance.", hash) }
                    }
                }
                self.storage?.save(); self.publish()
            }
        }
    }
    private struct ExplorerStatus: Decodable { let in_best_chain: Bool }
    private struct ExplorerBlock: Decodable { let id: String; let height: Int }
    private func fetch(_ path: String) async throws -> Data {
        let url = URL(string: "https://mempool.space/api/" + path)!
        let (data, response) = try await web.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 65536 else { throw BitcoinError.invalid("Explorer unavailable") }
        return data
    }
}
