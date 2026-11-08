import FloatBoardConnectors
import FloatBoardCore
import AppKit
import Carbon
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: Store!
    private let ui = UIState()
    private let google = Google()
    private var panel: PanelController!
    private var statusItem: NSStatusItem!
    private var avoider: WindowAvoider!
    private var clickMonitor: Any?
    private var modeWatch: AnyCancellable?
    private var pendingLinks: [URL] = []
    private var connectors: ConnectorRunner!
    private var backupTimer: Timer?
    private var activityWindow: NSWindow?
    private var localClickMonitor: Any?
    private var lastResign = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before migration touches the real file: snapshot it, but only if it exists and needs migrating.
        var preMigrateError: Error?
        var preMigrateNote: String?
        let backups = Backups.forEnvironment()
        if let backups {
            let check = Backups.migrationCheck(DB.defaultURL())
            if check.needed {
                var failure: Error?
                for _ in 0..<2 {
                    do { try backups.snapshot(reason: "pre-migrate"); failure = nil; break } catch { failure = error }
                }
                if let failure {
                    preMigrateError = failure
                    let scratch = LocalData.isScratchDatabase
                        || CommandLine.arguments.contains("--snapshot")
                    if !scratch {
                        let a = NSAlert()
                        a.messageText = "FloatBoard couldn't back up your board before updating it"
                        a.informativeText = "\(failure)"
                        a.addButton(withTitle: "Quit"); a.addButton(withTitle: "Continue without a backup")
                        NSApp.activate()
                        if a.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil); return }
                    }
                }
            }
            if let p = check.problem { preMigrateNote = p }
        }
        do {
            store = Store(db: try DB())
            google.attach(store: store)
            if let preMigrateError { store.activity("backup", .error, "Backup (pre-migrate) failed", detail: "\(preMigrateError)") }
            if let preMigrateNote { store.activity("backup", .warning, "Could not read schema version; backed up as a precaution", detail: preMigrateNote) }
        } catch {
            let a = NSAlert()
            a.messageText = "FloatBoard couldn't open its database"
            a.informativeText = "\(error)"
            a.runModal()
            NSApp.terminate(nil)
            return
        }
        let args = CommandLine.arguments
        // `FloatBoard --import-google-client <file.json>`: save the OAuth client to the credentials file and exit.
        if let i = args.firstIndex(of: "--import-google-client"), i + 1 < args.count {
            let ok = google.importClientJSON(at: URL(fileURLWithPath: args[i + 1]))
            print(ok ? "Imported Google OAuth client (\(google.clientID.prefix(14))…)" : (google.status ?? "Import failed"))
            NSApp.terminate(nil)
            return
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshot.run(dir: args[i + 1], store: store, google: google)
            NSApp.terminate(nil)
            return
        }
        if let backups {
            store.dailyBackup(backups)
            backupTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { if let s = self?.store { s.dailyBackup(backups) } }
            }
        }
        panel = PanelController(store: store, ui: ui, google: google)
        setupMainMenu()
        setupStatusItem()
        // Collapse only when a click is what takes you out of FloatBoard: the board (unless pinned)
        // collapses and quick add closes. If you ⌘-Tab away first, later clicks in that app don't count.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastResign = Date() }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // FloatBoard was in front when this click happened (it's deactivating because of it).
                let clickedAway = NSApp.isActive || Date().timeIntervalSince(self.lastResign) < 0.5
                guard clickedAway else { return }
                if self.ui.quickAdding { self.ui.quickAdding = false }
                if self.ui.mode == .expanded && !self.ui.pinned { self.ui.mode = .banner }
            }
        }
        // Clicking the board brings FloatBoard to the front again (the panel doesn't do that by itself),
        // so the next click elsewhere counts as clicking away.
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, self.ui.mode == .expanded || self.ui.quickAdding, !NSApp.isActive { NSApp.activate() }
            }
            return event
        }
        connectors = ConnectorRunner(store: store)
        connectors.start()
        NotificationCenter.default.addObserver(forName: .floatBoardShowActivity, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { if n.object as? String == "open" { self?.showActivity() } }
        }
        NotificationCenter.default.addObserver(forName: .floatBoardSyncConnectors, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.connectors.trigger("asked") }
        }
        modeWatch = ui.$mode.removeDuplicates().sink { [weak self] m in
            guard m == .expanded else { return }
            self?.connectors.boardOpened()
        }
        // A connect link opened before launch finished is handled now.
        for link in pendingLinks { handleConnectLink(link) }
        pendingLinks = []
        DragHandle.makeMenu = { [weak self] in
            let m = NSMenu()
            self?.menuNeedsUpdate(m)
            return m
        }
        avoider = WindowAvoider { [weak self] in self?.panel.reservedFrame }
        avoider.store = store

        let ctrlOpt = controlKey | optionKey
        HotKeys.register(id: 1, keyCode: kVK_ANSI_B, modifiers: ctrlOpt) { [weak self] in self?.toggleVisible() }
        HotKeys.register(id: 2, keyCode: kVK_ANSI_N, modifiers: ctrlOpt) { [weak self] in self?.ui.openAdd() }

        // Dev aid: FLOATBOARD_START_MODE=expanded|minimized to check layout without clicking.
        switch ProcessInfo.processInfo.environment["FLOATBOARD_START_MODE"] {
        case "expanded": ui.mode = .expanded
        case "minimized": ui.mode = .minimized
        default: panel.apply(ui.mode)
        }
    }

    /// `floatboard://connect?url=…&key=…&name=…` (from a connector's setup page) adds that connector after you confirm.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "floatboard" {
            if store == nil || panel == nil { pendingLinks.append(url) } else { handleConnectLink(url) }
        }
    }

    private func handleConnectLink(_ url: URL) {
        guard ConnectFlow.confirmAndAdd(url, store: store) else { return }
        ui.tab = .connectors
        expand()
    }

    /// Clicking the Dock icon: bring the bar back if it's hidden/minimised, otherwise open the full board.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if ui.mode == .hidden || ui.mode == .minimized { ui.mode = .banner } else { expand() }
        return false
    }

    // MARK: Main menu

    private func setupMainMenu() {
        let main = NSMenu()
        func sub(_ title: String, _ build: (NSMenu) -> Void) -> NSMenu {
            let item = NSMenuItem(); let m = NSMenu(title: title); build(m); item.submenu = m; main.addItem(item); return m
        }
        func add(_ m: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                 _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            if let target { i.target = target }
            m.addItem(i)
        }

        _ = sub("FloatBoard") { m in
            add(m, "About FloatBoard", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
            m.addItem(.separator())
            add(m, "Settings…", #selector(barSettings), ",", target: self)
            add(m, "Connectors…", #selector(showConnectors), target: self)
            add(m, "Groups…", #selector(manageGroups), target: self)
            m.addItem(.separator())
            add(m, "Hide FloatBoard", #selector(NSApplication.hide(_:)), "h")
            add(m, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
            add(m, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
            m.addItem(.separator())
            add(m, "Quit FloatBoard", #selector(NSApplication.terminate(_:)), "q")
        }
        _ = sub("File") { m in
            add(m, "New Task", #selector(newTask), "n", target: self)
            m.addItem(.separator())
            add(m, "Export Tasks to CSV…", #selector(export), "e", [.command, .shift], target: self)
            m.addItem(.separator())
            add(m, "Close", #selector(NSWindow.performClose(_:)), "w")
        }
        _ = sub("Edit") { m in
            add(m, "Undo", Selector(("undo:")), "z")
            add(m, "Redo", Selector(("redo:")), "z", [.command, .shift])
            m.addItem(.separator())
            add(m, "Cut", #selector(NSText.cut(_:)), "x")
            add(m, "Copy", #selector(NSText.copy(_:)), "c")
            add(m, "Paste", #selector(NSText.paste(_:)), "v")
            add(m, "Select All", #selector(NSText.selectAll(_:)), "a")
            m.addItem(.separator())
            add(m, "Find…", #selector(findInBoard), "f", target: self)
        }
        _ = sub("View") { m in
            add(m, "Show Board", #selector(expand), "1", target: self)
            add(m, "Show/Hide Bar", #selector(toggleVisible), "b", [.control, .option], target: self)
            add(m, "Shrink Bar to Pill", #selector(minimize), target: self)
            m.addItem(.separator())
            add(m, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        }
        let window = sub("Window") { m in
            add(m, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
            add(m, "Zoom", #selector(NSWindow.performZoom(_:)))
            add(m, "Put Board Back Above the Bar", #selector(resetBoard), target: self)
            m.addItem(.separator())
            add(m, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        }
        let help = sub("Help") { m in
            add(m, "FloatBoard Guide", #selector(showGuide), "?", target: self)
            add(m, "Activity…", #selector(showActivity), "a", [.command, .option], target: self)
            m.addItem(.separator())
            add(m, "Restore from backup…", #selector(restoreBackup), target: self)
        }
        NSApp.mainMenu = main
        NSApp.windowsMenu = window // macOS adds its tiling / Move & Resize items here
        NSApp.helpMenu = help
    }

    /// Restore replaces the database file under the running app, so after it the app relaunches
    /// (reopening the connection in place would leave views and modules holding stale state).
    @objc func restoreBackup() {
        guard let backups = Backups.forEnvironment() else {
            let a = NSAlert(); a.messageText = "Backups are off for this test database"; a.runModal(); return
        }
        let all = backups.restorable()
        NSApp.activate()
        guard !all.isEmpty else {
            let a = NSAlert(); a.messageText = "No backups yet"
            a.informativeText = "A backup is made once a day while FloatBoard runs."; a.runModal(); return
        }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        let pick = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        for b in all { pick.addItem(withTitle: "\(f.string(from: b.date)) · \(b.reason)") }
        let a = NSAlert()
        a.messageText = "Restore from backup"
        a.informativeText = "Your current board is saved as a \"pre-restore\" backup first, then replaced with the one you pick. FloatBoard relaunches afterwards."
        a.accessoryView = pick
        a.addButton(withTitle: "Restore and relaunch"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let chosen = all[pick.indexOfSelectedItem]
        do { try backups.restore(chosen.url) } catch {
            store.activity("backup", .error, "Restore failed", detail: "\(chosen.url.lastPathComponent): \(error)")
            showError("Restore failed", error)
            return
        }
        store.activity("backup", .info, "Restored \(chosen.url.lastPathComponent)")
        let cfg = NSWorkspace.OpenConfiguration(); cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    @objc func findInBoard() {
        ui.tab = .board
        expand()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: .floatBoardFocusSearch, object: nil)
        }
    }

    @objc func showActivity() {
        if activityWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "FloatBoard Activity"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: ActivityView().environmentObject(store))
            w.center()
            activityWindow = w
        }
        NSApp.activate()
        activityWindow?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .floatBoardShowActivity, object: nil)
    }

    @objc func showGuide() {
        expand()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .floatBoardShowGuide, object: nil)
        }
    }

    // MARK: Menu bar icon

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "FloatBoard")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "", state: Bool = false) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        if !key.isEmpty { i.keyEquivalentModifierMask = [.control, .option] }
        i.state = state ? .on : .off
        return i
    }

    @objc func toggleVisible() {
        ui.mode = (ui.mode == .hidden || ui.mode == .minimized) ? .banner : .hidden
    }
    @objc func showBanner() { ui.mode = .banner }
    /// Open the board — also when it's already "open" but minimised to the Dock.
    @objc func expand() {
        if ui.mode == .expanded { panel.apply(.expanded) } else { ui.mode = .expanded }
    }
    @objc func minimize() { ui.mode = .minimized }
    @objc func newTask() { ui.openAdd() }

    @objc func export() {
        do {
            let url = try store.exportCSV()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { showError("Export failed", error) }
    }

    @objc func revealDB() {
        NSWorkspace.shared.activateFileViewerSelecting([store.db.url])
    }

    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch { showError("Couldn't change 'Open at login'", error) }
    }

    @objc func quit() { NSApp.terminate(nil) }
    @objc func toggleAvoid() {
        if avoider.enabled && !avoider.trusted {
            avoider.requestPermission()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        } else {
            avoider.enabled.toggle()
        }
    }
    @objc func toggleSplitCount() { ui.bar.splitCount = !(ui.bar.splitCount ?? false) }
    @objc func resetBoard() { panel.resetBoard() }
    @objc func syncConnectors() { connectors.trigger("menu") }
    @objc func barSettings() { ui.tab = .bar; ui.quickAdding = false; expand() }
    @objc func showConnectors() { ui.tab = .connectors; ui.quickAdding = false; expand() }
    @objc func manageGroups() { ui.tab = .groups; ui.quickAdding = false; expand() }

    private func showError(_ title: String, _ error: Error) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = error.localizedDescription
        NSApp.activate()
        a.runModal()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let showing = ui.mode != .hidden && ui.mode != .minimized

        menu.addItem(.sectionHeader(title: "Tasks"))
        menu.addItem(item("New task…", #selector(newTask), "n"))
        menu.addItem(item(showing ? "Hide bar" : "Show bar", #selector(toggleVisible), "b"))
        if ui.mode == .expanded {
            menu.addItem(item("Put board back above the bar", #selector(resetBoard)))
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Set up"))
        menu.addItem(item("Bar…", #selector(barSettings)))
        menu.addItem(item("Groups…", #selector(manageGroups)))
        menu.addItem(item("Connectors…", #selector(showConnectors)))
        if store.connectors.contains(where: { !$0.baseURL.isEmpty }) { menu.addItem(item("Sync connectors now", #selector(syncConnectors))) }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Settings"))
        let avoidTitle = avoider.enabled && !avoider.trusted
            ? "Push other windows above the bar (needs permission…)"
            : "Push other windows above the bar"
        menu.addItem(item(avoidTitle, #selector(toggleAvoid), state: avoider.enabled && avoider.trusted))
        menu.addItem(item("Start when I log in", #selector(toggleLogin), state: SMAppService.mainApp.status == .enabled))
        menu.addItem(item("Split count: Doing · To do", #selector(toggleSplitCount), state: ui.bar.splitCount ?? false))

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Your data"))
        menu.addItem(item("Export tasks to spreadsheet (CSV)", #selector(export)))
        menu.addItem(item("Show data folder", #selector(revealDB)))

        menu.addItem(.separator())
        menu.addItem(item("Quit FloatBoard", #selector(quit), ""))
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular) // normal app: Dock icon, ⌘-Tab, ⌘Q
    app.run()
}
