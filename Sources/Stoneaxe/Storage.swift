import Foundation

enum AppPaths {
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Stoneaxe", isDirectory: true)
    static let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Stoneaxe", isDirectory: true)
}
struct Settings: Codable, Equatable {
    var address = ""
    var enabled = false
    var allowBattery = false
    var blockNotifications = true
    var shareNotifications = false
    var verifyBlocks = true
    var language = Locale.preferredLanguages.first?.hasPrefix("ko") == true ? "ko" : "en"
    var idleMinutes = 5.0
    var activePercent = 5.0
    var idlePercent = 20.0
    static func load() -> Settings {
        guard let data = UserDefaults.standard.data(forKey: "settings"), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Settings() }
        return value
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "settings") } }
}
struct Totals: Codable {
    var hashes: Double = 0
    var miningSeconds: Double = 0
    var pausedSeconds: Double = 0
    var thermalSeconds: Double = 0
    var gpuSeconds: Double = 0
    var submitted = 0
    var accepted = 0
    var rejected = 0
    var unknown = 0
    var bestDifficulty: Double = 0
    var lastAccepted: Date?
}
struct Daily: Codable, Identifiable {
    var day: String
    var totals = Totals()
    var id: String { day }
}
struct BlockRecord: Codable, Identifiable {
    var id: String // Block hash; computed locally, not trusted from pool text.
    var header: String
    var address: String
    var found = Date()
    var poolAccepted: Bool?
    var status = "Candidate"
    var height: Int?
    var confirmations = 0
    var lastChecked: Date?
    var includedNotified = false
    var matureNotified = false
}
struct Persisted: Codable {
    var totals = Totals()
    var days: [Daily] = []
    var blocks: [BlockRecord] = []
}
struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let level: String
    let message: String
}
/// File operations live on the engine queue, never the UI thread.
final class Storage {
    var state = Persisted()
    private let encoder = JSONEncoder()
    private let statsURL = AppPaths.support.appendingPathComponent("statistics.json")
    private var logHandle: FileHandle?
    private var logBytes = 0
    var onError: ((String) -> Void)?
    init() throws {
        try FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: AppPaths.logs, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: AppPaths.support.path)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if FileManager.default.fileExists(atPath: statsURL.path) {
            do { state = try JSONDecoder().decode(Persisted.self, from: Data(contentsOf: statsURL)) }
            catch {
                let backup = AppPaths.support.appendingPathComponent("statistics-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try FileManager.default.copyItem(at: statsURL, to: backup)
            }
        }
        try openLog()
    }
    func save() {
        do {
            let data = try encoder.encode(state)
            try data.write(to: statsURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: statsURL.path)
        } catch { onError?("Could not save statistics") }
    }
    func record(_ entry: LogEntry) {
        let text = "\(ISO8601DateFormatter().string(from: entry.date)) [\(entry.level)] \(entry.message)\n"
        guard let data = text.data(using: .utf8) else { return }
        do {
            if logBytes + data.count > 1_048_576 { try rotate() }
            try logHandle?.write(contentsOf: data); logBytes += data.count
        } catch { onError?("Could not write log") }
    }
    func updateTotals(_ body: (inout Totals) -> Void) {
        body(&state.totals)
        let parts = Calendar.current.dateComponents([.year,.month,.day], from: Date())
        let key = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        if state.days.last?.day != key { state.days.append(Daily(day: key)) }
        body(&state.days[state.days.count-1].totals)
        if state.days.count > 90 { state.days.removeFirst(state.days.count-90) }
    }
    private func openLog() throws {
        let url = AppPaths.logs.appendingPathComponent("stoneaxe.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        logHandle = try FileHandle(forWritingTo: url); logBytes = Int(try logHandle!.seekToEnd())
    }
    private func rotate() throws {
        try logHandle?.close(); logHandle = nil
        let fm = FileManager.default
        for n in stride(from: 3, through: 1, by: -1) {
            let from = AppPaths.logs.appendingPathComponent(n == 1 ? "stoneaxe.log" : "stoneaxe.\(n-1).log")
            let to = AppPaths.logs.appendingPathComponent("stoneaxe.\(n).log")
            if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
            if fm.fileExists(atPath: from.path) { try fm.moveItem(at: from, to: to) }
        }
        try openLog()
    }
    deinit { try? logHandle?.close() }
}
