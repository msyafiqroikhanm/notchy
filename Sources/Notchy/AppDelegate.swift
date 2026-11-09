import AppKit
import SwiftUI
import Combine
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let preferences = Preferences()
    let shell = ShellState()
    private lazy var media = MediaController()
    private lazy var lyrics = LyricsController(preferences: preferences)
    private lazy var store = LocalStore()
    private lazy var focus = FocusController(store: store, onReminder: { [weak self] text in
        self?.remind(ShellNotice(kind: .focus, title: text, subtitle: "Fokus", destination: .fokus, duration: 6))
    })
    private lazy var water = WaterController(store: store, preferences: preferences)
    private lazy var tasks = TaskController(store: store)
    private lazy var shelf = ShelfController(store: store)
    private lazy var clipboard = ClipboardController(preferences: preferences)
    private lazy var devices = DeviceMonitor()
    private lazy var prayer = PrayerController(preferences: preferences)
    private var panel: NotchPanel!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var observations = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        media.bind(shell)
        panel = NotchPanel(shell: shell, preferences: preferences, content: AnyView(
            FeatureView(shell: shell, preferences: preferences, store: store,
                        media: media, lyrics: lyrics, focus: focus, water: water,
                        tasks: tasks, shelf: shelf, clipboard: clipboard, prayer: prayer, devices: devices)
        ))
        shell.requestSettings = { [weak self] in self?.openSettings() }
        water.onReminder = { [weak self] text in
            self?.remind(ShellNotice(kind: .water, title: text, subtitle: "Air", destination: .air, duration: 6))
        }
        tasks.onReminder = { [weak self] text in
            self?.remind(ShellNotice(kind: .task, title: text, subtitle: "Tugas", destination: .tugas, duration: 6))
        }
        shelf.onAdded = { [weak self] name in
            self?.panel.showNotice(ShellNotice(kind: .shelf, title: "Ditambahkan ke Shelf", subtitle: name, destination: .shelf, duration: 3))
        }
        panel.onFiles = { [weak self] urls in
            self?.shell.selectedTab = ShellTab.shelf.rawValue
            self?.shelf.add(urls: urls)
        }
        panel.onInvalidDrop = { [weak self] in
            self?.shell.selectedTab = ShellTab.shelf.rawValue
            self?.shelf.rejectNonFileDrop()
        }
        tasks.check()
        panel.onEscape = { [weak self] in self?.shell.cancelTaskEditor() }
        prayer.onReminder = { [weak self] event in
            guard let self else { return }
            self.remind(ShellNotice(kind: .prayer, title: event.prayer.name,
                                    subtitle: event.isPrealert ? "10 menit lagi" : "Waktunya sholat",
                                    trailingText: self.prayer.hm(event.time), destination: .sholat, duration: 6))
        }
        prayer.onPauseMusic = { [weak self] in self?.media.pause() }
        devices.onEvent = { [weak self] event in self?.deviceNotice(event) }
        Publishers.Merge3(devices.objectWillChange, water.objectWillChange, preferences.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateRing() }
            .store(in: &observations)
        updateRing()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Notchy")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu(menu)
        if CommandLine.arguments.contains("--open") { panel.openFromKeyboard() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        preferences.refreshLogin()
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ title: String, _ action: Selector, key: String = "", checked: Bool? = nil) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.target = self
            if let checked { entry.state = checked ? .on : .off }
            menu.addItem(entry)
        }
        item("Buka Notchy", #selector(openPanel), key: "o")
        item("Pengaturan…", #selector(openSettings), key: ",")
        menu.addItem(.separator())
        item("Buka saat login", #selector(toggleLogin), checked: SMAppService.mainApp.status == .enabled)
        item("Maskot", #selector(toggleMascot), checked: preferences.mascot)
        item("Notch minimal", #selector(toggleMinimal), checked: preferences.minimal)
        item("Ring: Baterai", #selector(batteryRing), checked: preferences.ringSource == "battery")
        item("Ring: Air", #selector(waterRing), checked: preferences.ringSource == "water")
        menu.addItem(.separator())
        item("Tentang Notchy", #selector(about))
        item("Keluar dari Notchy", #selector(quit), key: "q")
    }

    @objc private func openPanel() { panel.openFromKeyboard() }
    @objc private func openSettings() {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(preferences: preferences))
            let window = NSWindow(contentViewController: controller)
            window.title = "Pengaturan Notchy"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 560, height: 580))
            window.minSize = NSSize(width: 500, height: 460)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func toggleLogin() {
        preferences.setLogin(enabled: !preferences.loginEnabled)
        if let error = preferences.loginError { showError(error) }
    }
    @objc private func toggleMascot() { preferences.mascot.toggle() }
    @objc private func toggleMinimal() { preferences.minimal.toggle() }
    @objc private func batteryRing() { preferences.ringSource = "battery" }
    @objc private func waterRing() { preferences.ringSource = "water" }
    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Notchy", .applicationVersion: "1.0.0", .credits: NSAttributedString(string: "Companion macOS independen.\nMediaRemote Adapter: BSD-3-Clause.\nJadwal sholat adalah perhitungan, cocokkan dengan masjid setempat.")])
    }
    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Notchy"
        alert.informativeText = message
        alert.addButton(withTitle: "Tutup")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    private func updateRing() {
        if preferences.ringSource == "water" {
            shell.ringProgress = water.progress
            shell.ringLabel = "Air \(water.total) dari \(water.goal) ml"
        } else {
            shell.ringProgress = devices.batteryProgress ?? 0
            shell.ringLabel = devices.batteryProgress == nil ? "Baterai tidak tersedia" : "Baterai \(devices.batteryLabel)"
        }
    }
    private func remind(_ notice: ShellNotice) {
        DispatchQueue.main.async { [weak self] in
            self?.panel?.showNotice(notice)
            NSSound(named: "Glass")?.play()
        }
    }
    /// Built from the event kind plus the monitor's current real battery and IOKit charging flag.
    private func deviceNotice(_ event: DeviceEvent) {
        let percent = devices.batteryProgress.map { _ in DeviceMonitor.batteryText(devices.batteryProgress) }
        let notice: ShellNotice
        switch event {
        case .powerConnected:
            notice = ShellNotice(kind: .charging, title: DeviceMonitor.powerTitle(pluggedIn: true, charging: devices.isCharging),
                                 subtitle: "Adaptor daya tersambung", trailingText: percent, progress: devices.batteryProgress, duration: 3)
        case .powerDisconnected:
            notice = ShellNotice(kind: .disconnected, title: "Pengisi daya dilepas", subtitle: "Memakai baterai",
                                 trailingText: percent, progress: devices.batteryProgress, duration: 3)
        case .bluetooth(let name):
            notice = ShellNotice(kind: .headphones, title: name, subtitle: "Output audio Bluetooth", duration: 3)
        }
        panel.showNotice(notice)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        media.shutdown()
        focus.shutdown()
        water.shutdown()
        tasks.shutdown()
        shelf.shutdown()
        clipboard.shutdown()
        devices.shutdown()
        prayer.shutdown()
        panel?.shutdown()
    }
}
