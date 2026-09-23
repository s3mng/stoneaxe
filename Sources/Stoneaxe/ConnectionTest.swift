import Foundation
import Combine
import StoneaxeCore

struct ConnectionTestState {
    enum Outcome { case idle, running, passed, failed, cancelled }
    var outcome: Outcome = .idle
    var serverConnected = false
    var addressAuthorized = false
    var workReceived = false
    var message = ""

    mutating func receive(_ event: Stratum.Event) {
        guard outcome == .running else { return }
        switch event {
        case .transportConnected: serverConnected = true
        case .ready: addressAuthorized = true
        case .job:
            // Stratum emits jobs only after a successful subscription + authorization.
            guard serverConnected && addressAuthorized else { return }
            workReceived = true; outcome = .passed; message = "Connection test passed"
        case .log(let message):
            if message != "Pool authorized" { self.message = message; outcome = .failed }
        default: break
        }
    }
    mutating func timeOut() {
        guard outcome == .running else { return }
        outcome = .failed
        message = addressAuthorized ? "Timed out waiting for mining work" : serverConnected ? "Timed out waiting for address authorization" : "Timed out connecting to CKPool"
    }
}

/// A short-lived, separate Stratum session. It has no miner and never submits work.
private final class ProbeRun {
    private let queue = DispatchQueue(label: "app.stoneaxe.connection-test", qos: .utility)
    private let publish: (ConnectionTestState) -> Void
    private var state = ConnectionTestState(outcome: .running)
    private var closed = false
    private var timeout: DispatchWorkItem?
    private lazy var pool = Stratum(queue: queue) { [weak self] event in
        // Defer stopping until the Stratum callback returns, avoiding reentrancy.
        self?.queue.async { [weak self] in self?.receive(event) }
    }

    init(publish: @escaping (ConnectionTestState) -> Void) { self.publish = publish }
    func start(_ address: String) {
        queue.async { [self] in
            guard !closed else { return }
            let deadline = DispatchWorkItem { [weak self] in
                guard let self, !self.closed else { return }
                self.state.timeOut(); self.finish()
            }
            timeout = deadline
            queue.asyncAfter(deadline: .now() + 20, execute: deadline)
            pool.start(address: address)
        }
    }
    func cancel() {
        queue.async { [self] in
            guard !closed else { return }
            state.outcome = .cancelled; state.message = "Connection test cancelled"; finish()
        }
    }
    private func receive(_ event: Stratum.Event) {
        guard !closed else { return }
        state.receive(event)
        if state.outcome == .passed || state.outcome == .failed { finish() }
        else { publish(state) }
    }
    private func finish() {
        closed = true; timeout?.cancel(); timeout = nil; pool.stop(); publish(state)
    }
}

@MainActor
final class ConnectionTest: ObservableObject {
    @Published private(set) var state = ConnectionTestState()
    private var run: ProbeRun?
    private var generation = UUID()

    func start(address: String) {
        reset()
        var address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Address.isValid(address) else {
            state = ConnectionTestState(outcome: .failed, message: "Invalid mainnet Bitcoin address")
            return
        }
        if address.lowercased().hasPrefix("bc1") { address = address.lowercased() }
        state = ConnectionTestState(outcome: .running)
        let token = generation
        let run = ProbeRun { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.state = result
                if result.outcome != .running { self.run = nil }
            }
        }
        self.run = run; run.start(address)
    }
    func cancel() {
        guard state.outcome == .running else { return }
        generation = UUID(); run?.cancel(); run = nil
        state.outcome = .cancelled; state.message = "Connection test cancelled"
    }
    func reset() {
        generation = UUID(); run?.cancel(); run = nil; state = ConnectionTestState()
    }
    deinit { run?.cancel() }
}
