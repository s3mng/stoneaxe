import Foundation
import Network
import StoneaxeCore

/// Confined to the engine serial queue. No arbitrary server-directed redirects.
final class Stratum {
    enum Event {
        case transportConnected
        case status(String), log(String), ready(Data, Int), job(MiningJob)
        case share(UUID, Bool?, String), disconnected
    }
    private let queue: DispatchQueue
    private let event: (Event) -> Void
    private var connection: NWConnection?
    private var generation = UUID()
    private var pending: [Int: (method: String, share: UUID?, sent: Date)] = [:]
    private var buffer = Data()
    private var nextID = 0
    private var difficulty = 1.0
    private var subscribed = false
    private var authorized = false
    private var username = ""
    private var extra1 = Data()
    private var extraSize = 0
    private var queuedJob: MiningJob?
    private var lastMessage = Date()
    private var retry: DispatchWorkItem?
    private var retrySeconds = 2.0
    private var wanted = false
    private var watchdog: DispatchSourceTimer?

    init(queue: DispatchQueue, event: @escaping (Event) -> Void) { self.queue = queue; self.event = event }
    func start(address: String) {
        stop(); username = address + ".stoneaxe"; wanted = true; retrySeconds = 2; connect()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now()+5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.checkTimeouts() }; timer.resume(); watchdog = timer
    }
    func stop() {
        wanted = false; retry?.cancel(); retry = nil; watchdog?.cancel(); watchdog = nil
        invalidate()
    }
    private func invalidate() {
        generation = UUID(); connection?.cancel(); connection = nil
        for (_, request) in pending { if let share = request.share { event(.share(share, nil, "Connection lost; outcome unknown")) } }
        pending.removeAll(); buffer.removeAll(keepingCapacity: false)
        subscribed = false; authorized = false; queuedJob = nil; difficulty = 1
        event(.disconnected)
    }
    private func connect() {
        guard wanted else { return }
        event(.status("Connecting")); lastMessage = Date()
        let tcp = NWProtocolTCP.Options(); tcp.enableKeepalive = true; tcp.keepaliveIdle = 30
        tcp.keepaliveInterval = 10; tcp.keepaliveCount = 3; tcp.connectionTimeout = 15
        let connection = NWConnection(host: "stratum.ckpool.org", port: 3333, using: NWParameters(tls: nil, tcp: tcp))
        self.connection = connection; let token = generation
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == token else { return }
            switch state {
            case .ready:
                self.event(.transportConnected)
                self.send("mining.subscribe", ["Stoneaxe/0.1.0"])
                self.receive(token)
            case .failed, .waiting: self.reconnect("Pool connection unavailable")
            default: break
            }
        }
        connection.start(queue: queue)
    }
    private func reconnect(_ reason: String) {
        guard wanted else { return }
        invalidate(); retry?.cancel(); event(.log(reason)); event(.status("Reconnecting"))
        let delay = retrySeconds + Double.random(in: 0...1)
        retrySeconds = min(60, retrySeconds * 2)
        let work = DispatchWorkItem { [weak self] in self?.connect() }; retry = work
        queue.asyncAfter(deadline: .now()+delay, execute: work)
    }
    private func receive(_ token: UUID) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, error in
            guard let self, self.generation == token else { return }
            if let data { self.buffer.append(data) }
            guard self.buffer.count <= 262144 else { self.reconnect("Pool message too large"); return }
            while let newline = self.buffer.firstIndex(of: 10) {
                let line = Data(self.buffer.prefix(upTo: newline))
                self.buffer.removeSubrange(...newline)
                do { try self.handle(line) } catch { self.reconnect("Invalid pool message"); return }
                guard self.generation == token else { return }
            }
            if done || error != nil { self.reconnect("Pool connection closed") } else { self.receive(token) }
        }
    }
    private func send(_ method: String, _ params: [Any], share: UUID? = nil) {
        guard let connection else { return }
        guard pending.count < 128 else { reconnect("Too many pending requests"); return }
        nextID += 1
        let object: [String: Any] = ["id": nextID, "method": method, "params": params]
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(10); pending[nextID] = (method, share, Date())
        let token = generation
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, self.generation == token else { return }
            if error != nil { self.reconnect("Pool send failed") }
        })
    }
    func submit(job: MiningJob, extra: Data, nonce: UInt32, id: UUID) {
        guard authorized, subscribed else { event(.share(id, nil, "Not connected; outcome unknown")); return }
        send("mining.submit", [username, job.id, extra.hex, job.time, String(format: "%08x", nonce)], share: id)
    }
    private func handle(_ line: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw BitcoinError.invalid("JSON") }
        lastMessage = Date()
        if let method = json["method"] as? String {
            let params = json["params"] as? [Any] ?? []
            switch method {
            case "mining.set_difficulty":
                guard let n = params.first as? NSNumber, n.doubleValue.isFinite, n.doubleValue >= 1 else { throw BitcoinError.invalid("Difficulty") }
                difficulty = n.doubleValue // Applied to the NEXT job, per Stratum V1.
            case "mining.notify":
                let job = try MiningJob(params: params, difficulty: difficulty)
                queuedJob = job
                if subscribed && authorized { event(.job(job)) }
            case "mining.set_extranonce":
                guard params.count == 2, let s = params[0] as? String, let data = Data(hex: s), data.count <= 32,
                      let n = params[1] as? Int, (1...16).contains(n) else { throw BitcoinError.invalid("Extranonce") }
                extra1 = data; extraSize = n; queuedJob = nil
                if authorized { event(.ready(data, n)) }
            case "client.reconnect": reconnect("Pool requested reconnect")
            case "client.get_version":
                if let id = json["id"], !(id is NSNull), var data = try? JSONSerialization.data(withJSONObject: ["id": id, "result": "Stoneaxe/0.1.0", "error": NSNull()]) {
                    data.append(10); connection?.send(content: data, completion: .idempotent)
                }
            default: break
            }
            return
        }
        guard let id = json["id"] as? Int, let request = pending.removeValue(forKey: id) else { return }
        let hasError = json["error"] != nil && !(json["error"] is NSNull)
        if let share = request.share {
            let accepted = !hasError && (json["result"] as? Bool == true)
            // Avoid persisting pool-provided text, which can contain private identifiers.
            let code = (json["error"] as? [Any])?.first as? Int
            event(.share(share, accepted, accepted ? "Share accepted" : "Share rejected (\(code ?? 0))"))
        } else if request.method == "mining.subscribe" {
            guard !hasError, let result = json["result"] as? [Any], result.count >= 3,
                  let s = result[1] as? String, let data = Data(hex: s), data.count <= 32,
                  let n = result[2] as? Int, (1...16).contains(n) else { throw BitcoinError.invalid("Subscription") }
            subscribed = true; extra1 = data; extraSize = n
            send("mining.authorize", [username, "x"])
        } else if request.method == "mining.authorize" {
            guard !hasError, json["result"] as? Bool == true else { reconnect("Wallet authorization failed"); return }
            authorized = true; retrySeconds = 2
            event(.ready(extra1, extraSize)); event(.status("Connected")); event(.log("Pool authorized"))
            send("mining.suggest_difficulty", [1])
            if let job = queuedJob { event(.job(job)) }
        }
    }
    private func checkTimeouts() {
        guard connection != nil else { return }
        if Date().timeIntervalSince(lastMessage) > 180 { reconnect("Pool timed out"); return }
        let expired = pending.filter { Date().timeIntervalSince($0.value.sent) > 30 }
        for (id, request) in expired {
            pending.removeValue(forKey: id)
            if let share = request.share { event(.share(share, nil, "Share response timed out; outcome unknown")) }
            else if request.method != "mining.suggest_difficulty" { reconnect("Pool handshake timed out"); return }
        }
    }
}
