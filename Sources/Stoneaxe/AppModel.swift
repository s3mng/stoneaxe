import AppKit
import SwiftUI
import UserNotifications
import ServiceManagement
import StoneaxeCore

final class AppModel: ObservableObject {
    @Published var settings = Settings.load()
    @Published var snapshot = EngineSnapshot()
    @Published var selectedTab = "Overview"
    @Published var notificationAllowed = false
    @Published var banner = ""
    private(set) var engine: Engine!
    var openWindow: (() -> Void)?
    var closePopover: (() -> Void)?
    var statusChanged: (() -> Void)?
    init() {
        engine = Engine(settings: settings)
        engine.onSnapshot = { [weak self] value in self?.snapshot = value; self?.statusChanged?() }
        engine.onNotification = { [weak self] title, body, hash in self?.notify(title, body, hash) }
    }
    func text(_ key: String) -> String { Texts.get(key, settings.language) }
    func save(_ value: Settings) -> Bool {
        var value = value
        value.address = value.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!value.enabled && value.address.isEmpty) || Address.isValid(value.address) else { banner = "Invalid mainnet Bitcoin address"; return false }
        if value.address.lowercased().hasPrefix("bc1") { value.address = value.address.lowercased() }
        guard value.idlePercent >= value.activePercent else { banner = "Idle budget must be at least the active budget"; return false }
        settings = value; value.save(); engine.configure(value); banner = "Saved"
        if value.enabled && (value.blockNotifications || value.shareNotifications) { requestNotifications() }
        return true
    }
    func show(_ tab: String) { selectedTab = tab; closePopover?(); openWindow?() }
    func togglePause() { engine.pause(!snapshot.paused) }
    func refreshNotifications() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] value in
            DispatchQueue.main.async { self?.notificationAllowed = value.authorizationStatus == .authorized || value.authorizationStatus == .provisional }
        }
    }
    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in self?.refreshNotifications() }
    }
    private func notify(_ title: String, _ body: String, _ hash: String?) {
        let content = UNMutableNotificationContent()
        content.title = text(title); content.body = text(body); content.sound = .default
        if let hash { content.userInfo["block"] = hash }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
    func exportStats() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "stoneaxe-statistics.json"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.engine.export(to: url) { success in self?.banner = success ? "Exported" : "Export failed" }
        }
    }
    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    func setLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            objectWillChange.send()
        } catch { banner = "Could not update login item" }
    }
}

enum Format {
    static func rate(_ value: Double) -> String {
        if value >= 1e9 { return String(format: "%.2f GH/s", value/1e9) }
        if value >= 1e6 { return String(format: "%.2f MH/s", value/1e6) }
        if value >= 1e3 { return String(format: "%.1f kH/s", value/1e3) }
        return String(format: "%.0f H/s", value)
    }
    static func duration(_ value: Double) -> String {
        let seconds = max(0, Int(value)); let hours = seconds / 3600
        return String(format: "%02d:%02d:%02d", hours, (seconds/60)%60, seconds%60)
    }
    static func number(_ value: Double) -> String { value.formatted(.number.precision(.significantDigits(1...5))) }
}
