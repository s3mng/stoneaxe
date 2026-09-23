import AppKit
import SwiftUI
import UserNotifications

enum Pickaxe {
    static func image(frame: Int, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { bounds in
            let p = bounds.width / 18
            NSColor.labelColor.setFill()
            let transform = NSAffineTransform()
            transform.translateX(by: size/2, yBy: size/2)
            let angles: [CGFloat] = [-24,-18,-8,12,28,12,-8,-20]
            transform.rotate(byDegrees: angles[frame % angles.count])
            transform.translateX(by: -size/2, yBy: -size/2)
            transform.concat()
            // Pixel handle, pick head, and metal tips. Drawn natively at Retina resolution.
            for i in 0..<8 { NSRect(x: CGFloat(4+i)*p, y: CGFloat(3+i)*p, width: 2*p, height: 2*p).fill() }
            let head = [(6,13),(7,14),(8,14),(9,14),(10,13),(11,12),(12,11),(13,10),(14,9),(14,8),(14,7)]
            for (x,y) in head { NSRect(x: CGFloat(x)*p, y: CGFloat(y)*p, width: 2*p, height: 2*p).fill() }
            transform.invert(); transform.concat()
            if frame == 4 || frame == 5 {
                NSRect(x: 14*p, y: 2*p, width: p, height: p).fill()
                NSRect(x: 16*p, y: 4*p, width: p, height: p).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSWindowDelegate {
    private var model: AppModel!
    private var item: NSStatusItem!
    private var popover: NSPopover!
    private var window: NSWindow?
    private var animation: Timer?
    private var frame = 0
    private var images: [NSImage] = []
    private var observers: [NSObjectProtocol] = []
    private var terminating = false
    private var menuLanguage = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "app.stoneaxe.mac")
        if others.count > 1 { NSApp.terminate(nil); return }
        model = AppModel(); images = (0..<8).map { Pickaxe.image(frame: $0) }
        installApplicationMenu()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = images[0]; item.button?.target = self; item.button?.action = #selector(togglePopover)
        item.button?.setAccessibilityLabel("Stoneaxe")
        popover = NSPopover(); popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverView(model: model))
        model.openWindow = { [weak self] in self?.showWindow() }
        model.closePopover = { [weak self] in self?.popover.performClose(nil) }
        model.statusChanged = { [weak self] in self?.updateStatus() }
        UNUserNotificationCenter.current().delegate = self
        model.refreshNotifications()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.model.engine.sleep(true) })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.model.engine.sleep(false) })
        model.engine.start()
        if model.settings.address.isEmpty { model.selectedTab = "Settings"; showWindow() }
    }
    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY); NSApp.activate(ignoringOtherApps: true) }
    }
    private func showWindow() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 740), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
            window.title = "Stoneaxe"; window.titlebarAppearsTransparent = true
            window.contentViewController = NSHostingController(rootView: MainView(model: model))
            window.isReleasedWhenClosed = false; window.delegate = self; window.center(); self.window = window
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func updateStatus() {
        if menuLanguage != model.settings.language { installApplicationMenu() }
        item.button?.toolTip = "Stoneaxe · \(model.text(model.snapshot.status)) · \(Format.rate(model.snapshot.rate))"
        if model.snapshot.isMining && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            if animation == nil {
                let timer = Timer(timeInterval: 0.14, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.frame = (self.frame+1) % 8; self.item.button?.image = self.images[self.frame]
                }
                timer.tolerance = 0.025; RunLoop.main.add(timer, forMode: .common); animation = timer
            }
        } else { animation?.invalidate(); animation = nil; item.button?.image = images[0] }
    }
    private func installApplicationMenu() {
        menuLanguage = model.settings.language
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Stoneaxe")
        appMenu.addItem(withTitle: model.text("Quit Stoneaxe"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // AppKit routes these standard actions to the focused text field's field
        // editor. A manually bootstrapped accessory app has no default Edit menu.
        let editItem = NSMenuItem()
        let edit = NSMenu(title: model.text("Edit"))
        edit.addItem(withTitle: model.text("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: model.text("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: model.text("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: model.text("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: model.text("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: model.text("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model != nil, !terminating else { return .terminateNow }
        terminating = true; animation?.invalidate()
        model.engine.shutdown { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner,.sound,.list])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in self?.model.show("Blocks") }
        completionHandler()
    }
}

@main
enum StoneaxeApp {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            do { let miner = try MetalMiner(); try miner.selfTest(); print("PASS: Metal SHA-256d matches Bitcoin genesis and CPU verification on \(miner.device.name)"); exit(0) }
            catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        let app = NSApplication.shared
        let delegate = AppDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
