import SwiftUI
import StoneaxeCore

private let copper = Color(red: 0.80, green: 0.48, blue: 0.27)

struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let peak = max(1, values.max() ?? 1)
                for (i, value) in values.enumerated() {
                    let p = CGPoint(x: geometry.size.width * Double(i) / Double(max(1, values.count-1)), y: geometry.size.height * (1-value/peak))
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
            }.stroke(copper, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }.accessibilityHidden(true)
    }
}

struct PopoverView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(nsImage: Pickaxe.image(frame: 0, size: 32)).foregroundStyle(copper)
                Text("Stoneaxe").font(.title3.bold())
                Spacer()
                Circle().fill(model.snapshot.isMining ? Color.green : Color.secondary).frame(width: 7, height: 7)
            }
            Text(model.text(model.snapshot.status)).font(.subheadline).foregroundStyle(.secondary)
            Text(Format.rate(model.snapshot.rate)).font(.system(size: 30, weight: .medium, design: .rounded)).monospacedDigit()
            Sparkline(values: model.snapshot.history).frame(height: 38)
            HStack {
                Label(Format.duration(model.snapshot.session.miningSeconds), systemImage: "clock")
                Spacer(); Text("\(model.snapshot.session.accepted) shares")
            }.font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button(model.text(model.snapshot.paused ? "Resume" : "Pause")) { model.togglePause() }
                    .disabled(!model.settings.enabled)
                Spacer()
                Button(model.text("Open Stoneaxe")) { model.show("Overview") }.buttonStyle(.borderedProminent).tint(copper)
            }
            HStack {
                Button(model.text("Settings")) { model.show("Settings") }
                Spacer()
                Button(model.text("Quit Stoneaxe")) { NSApplication.shared.terminate(nil) }
            }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 320)
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    private let tabs = [("Overview","square.grid.2x2"),("Activity","text.alignleft"),("Blocks","cube"),("Settings","slider.horizontal.3")]
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Image(nsImage: Pickaxe.image(frame: 0, size: 48)).padding(.top, 18)
                Text("Stoneaxe").font(.title2.bold())
                Text(model.text("Small work. Long odds.")).font(.caption).foregroundStyle(.secondary).padding(.bottom, 28)
                ForEach(tabs, id: \.0) { name, icon in
                    Button { model.selectedTab = name; model.banner = "" } label: {
                        Label(model.text(name), systemImage: icon)
                            .font(.system(size: 13, weight: model.selectedTab == name ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(model.selectedTab == name ? copper.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text("CKPool · Bitcoin").font(.caption).foregroundStyle(.secondary)
                Text("v0.1.0 · Apple Silicon").font(.caption2).foregroundStyle(.tertiary)
            }.padding(18).frame(width: 185).background(.quaternary.opacity(0.4))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(model.text(model.selectedTab)).font(.title2.bold())
                    Spacer()
                    Text(model.text(model.snapshot.connection)).font(.caption).foregroundStyle(.secondary)
                }.padding(24)
                if let fault = model.snapshot.fault {
                    notice(model.text(fault) + " · " + model.text("Restart Stoneaxe to retry the GPU"), color: .red)
                }
                if let warning = model.snapshot.storageWarning { notice(model.text(warning), color: .orange) }
                if !model.banner.isEmpty { notice(model.text(model.banner), color: copper) }
                Group {
                    switch model.selectedTab {
                    case "Activity": ActivityView(model: model)
                    case "Blocks": BlocksView(model: model)
                    case "Settings": SettingsView(model: model)
                    default: OverviewView(model: model)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(minWidth: 800, minHeight: 660).tint(copper)
    }
    private func notice(_ text: String, color: Color) -> some View {
        Text(text).font(.caption).foregroundStyle(color).padding(.horizontal,24).padding(.bottom,10).textSelection(.enabled)
    }
}

struct OverviewView: View {
    @ObservedObject var model: AppModel
    @State private var period = "Session"
    private var totals: Totals {
        switch period {
        case "All time": return model.snapshot.persisted.totals
        case "Today":
            let c = Calendar.current.dateComponents([.year,.month,.day], from: Date())
            let key = String(format:"%04d-%02d-%02d", c.year!, c.month!, c.day!)
            return model.snapshot.persisted.days.first(where: { $0.day == key })?.totals ?? Totals()
        default: return model.snapshot.session
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.text(model.snapshot.status)).foregroundStyle(.secondary)
                        Text(Format.rate(model.snapshot.rate)).font(.system(size: 38, weight: .medium, design: .rounded)).monospacedDigit()
                    }
                    Spacer()
                    Button(model.text(model.snapshot.paused ? "Resume" : "Pause")) { model.togglePause() }.disabled(!model.settings.enabled)
                }
                Sparkline(values: model.snapshot.history).frame(height: 65)
                Text(model.text("Last 60 seconds")).font(.caption).foregroundStyle(.secondary)
                if !model.settings.enabled { Button(model.text("Open settings")) { model.show("Settings") }.buttonStyle(.borderedProminent) }
                Picker("", selection: $period) {
                    ForEach(["Session","Today","All time"], id: \.self) { Text(model.text($0)).tag($0) }
                }.pickerStyle(.segmented)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    metric("Mining time", Format.duration(totals.miningSeconds))
                    metric("Average hashrate", Format.rate(totals.miningSeconds > 0 ? totals.hashes/totals.miningSeconds : 0))
                    metric("Total hashes", Format.number(totals.hashes))
                    metric("Best difficulty", Format.number(totals.bestDifficulty))
                    metric("Shares accepted", "\(totals.accepted)")
                    metric("Shares submitted", "\(totals.submitted)")
                }
                Text(model.text("Accepted shares are work reports, not Bitcoin payouts.")).font(.caption).foregroundStyle(.secondary)
                GroupBox {
                    VStack(spacing: 10) {
                        row("Shares rejected", "\(totals.rejected)")
                        row("Unknown outcome", "\(totals.unknown)")
                        row("Last accepted", totals.lastAccepted?.formatted(date: .abbreviated, time: .shortened) ?? model.text("No shares yet"))
                        row("Paused time", Format.duration(totals.pausedSeconds))
                        row("Cooling time", Format.duration(totals.thermalSeconds))
                        row("GPU compute time", Format.duration(totals.gpuSeconds))
                        Divider()
                        row("Scheduling budget", String(format: "%.0f%%", model.snapshot.duty*100))
                        row("Last GPU batch", String(format: "%.2f ms", model.snapshot.gpuMilliseconds))
                        row("Memory footprint", String(format: "%.1f MB", model.snapshot.memoryMB))
                    }.padding(8)
                }
                Text(model.text("Budget controls compute time and rest intervals; it is not total GPU utilization.")).font(.caption).foregroundStyle(.secondary)
                Button(model.text("Export statistics")) { model.exportStats() }
            }.padding(24).padding(.top, -12)
        }
    }
    private func metric(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.text(name)).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit()).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
    private func row(_ name: String, _ value: String) -> some View {
        HStack { Text(model.text(name)).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit() }.font(.caption)
    }
}

struct ActivityView: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var warningsOnly = false
    private var entries: [LogEntry] {
        model.snapshot.logs.reversed().filter {
            (!warningsOnly || $0.level == "warning" || $0.level == "error") &&
            (query.isEmpty || model.text($0.message).localizedCaseInsensitiveContains(query) || $0.message.localizedCaseInsensitiveContains(query))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(model.text("Search logs"), text: $query)
                Toggle(model.text("Errors & warnings"), isOn: $warningsOnly).toggleStyle(.checkbox)
            }
            List(entries) { entry in
                HStack(alignment: .top, spacing: 12) {
                    Text(entry.date.formatted(date: .omitted, time: .standard)).font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 85, alignment: .leading)
                    Circle().fill(entry.level == "error" ? .red : entry.level == "warning" ? .orange : copper).frame(width: 5, height: 5).padding(.top, 5)
                    Text(model.text(entry.message)).font(.callout).textSelection(.enabled)
                }.padding(.vertical, 5)
            }.overlay { if entries.isEmpty { Text(model.text("No activity yet")).foregroundStyle(.secondary) } }
            Text(model.text("Recent 300 events. Rotating files retain up to 4 MB. Disk logs use English for diagnostics.")).font(.caption).foregroundStyle(.secondary)
            Button(model.text("Show log files")) { NSWorkspace.shared.open(AppPaths.logs) }
        }.padding([.horizontal,.bottom],24)
    }
}

struct BlocksView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if model.snapshot.persisted.blocks.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "cube.transparent").font(.system(size: 45, weight: .ultraLight)).foregroundStyle(copper)
                        Text(model.text("No blocks found yet")).font(.title3)
                        Text(model.text("Every hash is another try. Keep your expectations small and your pickaxe moving.")).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical,60)
                }
                ForEach(model.snapshot.persisted.blocks.reversed()) { block in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { Text(model.text(block.status)).font(.headline); Spacer(); Text("\(model.text("Confirmations")): \(block.confirmations)") }
                            Text(block.found.formatted()).font(.caption).foregroundStyle(.secondary)
                            Text(block.id).font(.caption.monospaced()).textSelection(.enabled)
                            Text("\(model.text("Payout address")): \(block.address)").font(.caption).textSelection(.enabled)
                            Text("\(model.text("Pool accepted")): \(model.text(block.poolAccepted.map { $0 ? "Yes" : "No" } ?? "Pending"))").font(.caption)
                            HStack {
                                Link(model.text("View block"), destination: URL(string: "https://mempool.space/block/\(block.id)")!)
                                Spacer()
                                Button(model.text("Copy hash")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(block.id, forType: .string) }
                            }
                        }.padding(10)
                    }
                }
                Text(model.text("Block candidates are verified against mempool.space. Verification runs while Stoneaxe is open, for up to 7 days or 100 confirmations. Explorer failures leave the result pending.")).font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var draft = Settings()
    @StateObject private var connectionTest = ConnectionTest()
    private func t(_ key: String) -> String { Texts.get(key, draft.language) }
    var body: some View {
        Form {
            Section {
                Picker(t("Language"), selection: $draft.language) { Text("한국어").tag("ko"); Text("English").tag("en") }
                HStack {
                    TextField(t("Bitcoin receiving address"), text: $draft.address, prompt: Text("bc1q… / bc1p… / 1… / 3…"))
                        .font(.system(.body, design: .monospaced))
                    Button(t("Paste")) {
                        if let address = NSPasteboard.general.string(forType: .string) {
                            draft.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                }
                Text(t("Only a public mainnet receiving address. Never enter a seed phrase or private key.")).font(.caption).foregroundStyle(.secondary)
                Toggle(t("Enable automatic mining"), isOn: $draft.enabled)
            }
            Section(t("CKPool connection test")) {
                HStack {
                    Button(t("Test connection")) { connectionTest.start(address: draft.address) }
                        .disabled(connectionTest.state.outcome == .running)
                    if connectionTest.state.outcome == .running {
                        ProgressView().controlSize(.small)
                        Button(t("Cancel")) { connectionTest.cancel() }
                    }
                }
                if connectionTest.state.outcome != .idle {
                    testStep("Server connection", complete: connectionTest.state.serverConnected)
                    testStep("Address authorization", complete: connectionTest.state.addressAuthorized)
                    testStep("Mining work received", complete: connectionTest.state.workReceived)
                    if !connectionTest.state.message.isEmpty {
                        Text(t(connectionTest.state.message)).font(.caption)
                            .foregroundStyle(connectionTest.state.outcome == .failed ? Color.red : connectionTest.state.outcome == .passed ? Color.green : Color.secondary)
                    }
                }
                Text(t("Tests the address above without saving or mining. Existing mining continues. Your public address is sent to CKPool; the test closes within 20 seconds. Share acceptance is not tested."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(t("Behaviour")) {
                Toggle(t("Allow mining on battery"), isOn: $draft.allowBattery)
                Toggle(t("Launch at login"), isOn: Binding(get: { model.launchAtLogin }, set: { model.setLogin($0) }))
                Stepper("\(t("Consider away after")): \(Int(draft.idleMinutes)) \(t("minutes"))", value: $draft.idleMinutes, in: 1...30)
                slider("While using your Mac", value: $draft.activePercent, range: 1...10)
                slider("While away", value: $draft.idlePercent, range: 5...25)
                Text(t("Budget controls compute time and rest intervals; it is not total GPU utilization.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(t("Notifications")) {
                Toggle(t("Block discoveries & confirmations"), isOn: $draft.blockNotifications)
                Toggle(t("Accepted shares (not rewards)"), isOn: $draft.shareNotifications)
                HStack {
                    Text(t(model.notificationAllowed ? "Notifications allowed" : "Notifications not allowed")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(t("Allow notifications")) { model.requestNotifications() }
                }
                Button(t("Open notification settings")) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) }
            }
            Section(t("Network verification")) {
                Toggle(t("Verify block candidates with mempool.space"), isOn: $draft.verifyBlocks)
                Text(t("Only when a block candidate is found, its hash and your IP are sent to mempool.space. Your seed and keys are never needed. CKPool receives your payout address over Stratum V1 (unencrypted).")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(t("Save & apply")) { if model.save(draft) { draft = model.settings } }.buttonStyle(.borderedProminent)
            }
        }.formStyle(.grouped).onAppear { draft = model.settings; model.refreshNotifications() }
            .onChange(of: draft.address) { _, address in
                connectionTest.reset()
                if model.settings.address.isEmpty && Address.isValid(address.trimmingCharacters(in: .whitespacesAndNewlines)) { draft.enabled = true }
            }
            .onDisappear { connectionTest.cancel() }
    }
    private func testStep(_ name: String, complete: Bool) -> some View {
        Label(t(name), systemImage: complete ? "checkmark.circle.fill" : "circle")
            .font(.caption).foregroundStyle(complete ? Color.green : Color.secondary)
    }
    private func slider(_ name: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) {
            HStack { Text(t(name)); Spacer(); Text("\(Int(value.wrappedValue))%").monospacedDigit() }
            Slider(value: value, in: range, step: 1)
        }
    }
}
