import AppKit
import FloatBoardConnectors
import FloatBoardCore
import SwiftUI

/// One engine on the Connectors tab, in three parts with one row style throughout:
/// - header: the engine, its health, and actions on the whole engine (Sync now, ⋯);
/// - Inputs: every source feeding it (Gmail inboxes, Outlook, Fathom, WhatsApp on this Mac), each with a switch and ⋯;
/// - Rules and settings: the engine's settings form.
/// The phone app is not part of the engine's inputs: it has its own card (`PhoneAppCard`).
struct ConnectorCard: View {
    @EnvironmentObject var store: Store
    let info: ConnectorInfo
    @State private var settingsOpen = false
    @State private var archiving = false
    /// Switch positions the engine hasn't confirmed yet (shown at once; the next status replaces them).
    @State private var pendingInputs: [String: Bool] = [:]
    @State private var inputError: String?
    @ObservedObject private var rechecks = RecheckState.shared

    var body: some View {
        let status = ConnectorHealth.status(info, store: store)
        VStack(alignment: .leading, spacing: 10) {
            header(status)
            Divider()
            CardSection(title: "Inputs", help: "Where tasks come from.") {
                ForEach(engineInputs(status)) { inputRow($0) }
                WhatsAppInputRow(info: info, openRules: { settingsOpen = true })
                if let inputError {
                    Label(inputError, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange)
                }
                addInputMenu
            }
            Divider()
            DisclosureGroup(isExpanded: $settingsOpen) {
                ConnectorSettingsForm(info: info, schema: status?.schema ?? []).padding(.top, 6)
            } label: {
                Text("Rules and settings").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .sheet(isPresented: $archiving) { ArchiveSheet(info: info).environmentObject(store) }
    }

    // MARK: Header: the engine and actions on all of it

    private func header(_ status: ConnectorStatus?) -> some View {
        let host = URL(string: info.baseURL)?.host ?? info.baseURL
        let problem = info.unreachableSince != nil
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "server.rack").font(.system(size: 15))
                    .foregroundStyle(problem ? Color.orange : Color.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(info.name) engine").font(.system(size: 13, weight: .semibold))
                    Text(host.isEmpty ? "No address saved" : host).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(rechecks.active.contains(info.id) ? "Re-checking…" : "Sync now") {
                    NotificationCenter.default.post(name: .floatBoardSyncConnectors, object: nil)
                }
                .disabled(rechecks.active.contains(info.id))
                engineMenu
            }
            Text(ConnectorHealth.statusLine(info, waiting: store.waitingCount(connector: info.id))
                 + (status?.dbSizeBytes.map { " · " + EngineArchive.sizeText($0) } ?? ""))
                .font(.system(size: 11)).foregroundStyle(problem ? Color.orange : Color.secondary)
            if let size = status?.dbSizeBytes, EngineArchive.isLarge(size) {
                Label("The engine's database is getting full. Archive old data (⋯).", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            if ConnectorHealth.statusUnreadable(info, store: store) {
                Label(ConnectorHealth.unreadableStatus, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange)
            }
            ForEach(status?.needsAttention ?? [], id: \.self) { m in
                Label(m, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
    }

    /// Actions on the whole engine; the ones that remove data sit at the bottom and ask twice.
    private var engineMenu: some View {
        Menu {
            Menu("Re-check email") {
                ForEach([7, 14, 30], id: \.self) { d in Button("The last \(d) days…") { confirmRecheck(days: d) } }
            }
            .disabled(rechecks.active.contains(info.id))
            Button("Open setup page") { openSetup() }.disabled(info.baseURL.isEmpty)
            Divider()
            Button("Archive old data to this Mac…") { archiving = true }.disabled(info.baseURL.isEmpty)
            Button("Disconnect \(info.name) from this Mac…", role: .destructive) { remove() }
        } label: { Image(systemName: "ellipsis.circle") }
        .menuIndicator(.hidden).fixedSize()
        .help("Re-check email, setup page, archive old data, disconnect this engine")
    }

    // MARK: Inputs

    /// The engine's own inputs; WhatsApp has its own row (it is read on this Mac).
    private func engineInputs(_ status: ConnectorStatus?) -> [EngineSource] {
        (status?.sources ?? []).filter { $0.kind != "whatsapp" }
    }

    private func inputRow(_ s: EngineSource) -> some View {
        let on = pendingInputs[s.id] ?? s.enabled
        let (icon, name, detail): (String, String, String) = switch s.kind {
        case "gmail": ("envelope", "Gmail", s.address)
        case "outlook_web": ("envelope.badge", "Outlook", s.address.isEmpty ? "Chrome extension" : s.address)
        case "fathom": ("video", "Fathom", "Meeting notes")
        default: ("tray", s.kind, s.address)
        }
        let verb = s.kind == "outlook_web" ? "Last report" : s.kind == "fathom" ? "Last notes" : "Read"
        let state: (String, Bool) = !on ? ("Off", false)
            : s.lastError.map { ($0, true) }
            ?? (s.lastRun.flatMap(ConnectorClient.parseISODate).map { ("\(verb) \(ConnectorHealth.time($0))", false) } ?? ("Not read yet", false))
        return SourceRow(icon: icon, name: name, detail: detail, state: state.0, problem: state.1,
                         isOn: Binding(get: { on }, set: { setInput(s, $0) })) {
            Button("Manage on the setup page") { openSetup() }
        }
    }

    private func setInput(_ s: EngineSource, _ on: Bool) {
        guard let client = ConnectorAccounts.client(for: info, store: store) else { return }
        pendingInputs[s.id] = on; inputError = nil
        Task { @MainActor in
            do {
                try await client.setSourceEnabled(id: s.id, on)
                store.activity("connector:\(info.id)", .info, "\(on ? "Turned on" : "Turned off") \(s.address.isEmpty ? s.kind : s.address)")
                NotificationCenter.default.post(name: .floatBoardSyncConnectors, object: nil)
            } catch {
                pendingInputs[s.id] = nil
                inputError = "Couldn't turn \(s.address.isEmpty ? "it" : s.address) \(on ? "on" : "off"): \((error as? ConnectorError)?.description ?? error.localizedDescription)"
            }
        }
    }

    private var addInputMenu: some View {
        Menu {
            Button("Gmail inbox (setup page)…") { openSetup() }
            Button("Outlook (setup page)…") { openSetup() }
            Button("Fathom meeting notes (setup page)…") { openSetup() }
            Divider()
            Button("WhatsApp: use its switch above") {}.disabled(true)
        } label: { Text("Add an input…").font(.system(size: 11)) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(info.baseURL.isEmpty)
    }

    // MARK: Actions

    private func openSetup() {
        if let u = URL(string: info.baseURL)?.appendingPathComponent("setup") { NSWorkspace.shared.open(u) }
    }

    private func confirmRecheck(days: Int) {
        let a = NSAlert()
        a.messageText = "Re-check the last \(days) days of email?"
        a.informativeText = "The engine looks at that email again. Nothing is deleted. Email tasks you haven't touched that no longer need action are hidden (you can restore them from \"Show withdrawn\"). Tasks you changed are left alone. A backup is taken first."
        a.addButton(withTitle: "Re-check"); a.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let id = info.id
        Task { @MainActor in
            let out = await ConnectorRunner.shared?.recheck(connector: id, days: days)
                ?? .init(summary: nil, notice: "FloatBoard isn't ready to sync yet. Try again in a moment.")
            ConnectFlow.alert(out.summary == nil ? "Re-check did not run" : out.problems ? "Re-check finished with problems" : "Re-check finished", out.notice)
        }
    }

    private func remove() {
        let a = NSAlert()
        a.messageText = "Disconnect \(info.name) from this Mac?"
        a.informativeText = "This Mac stops syncing with the \(info.name) engine (\(URL(string: info.baseURL)?.host ?? info.baseURL)) and forgets its key. The engine itself, its setup page and your paired phones are not deleted. Its tasks and their history stay on your board, and your settings for it (rules, group descriptions, lists and learned preferences) are kept: they come back if you connect it again."
        a.addButton(withTitle: "Cancel"); a.addButton(withTitle: "Disconnect…")
        a.buttons[1].hasDestructiveAction = true
        NSApp.activate()
        guard a.runModal() == .alertSecondButtonReturn else { return }
        guard ConnectFlow.confirmTwice("Disconnect \(info.name) now?",
            "New tasks from it stop arriving, and changes made on your phone stop reaching this Mac, until you connect it again.", action: "Disconnect") else { return }
        do { try ConnectorAccounts.remove(id: info.id, store: store) } catch {
            store.activity("connector:\(info.id)", .error, "Could not remove \(info.name)", detail: "\(error)")
            ConnectFlow.alert("Couldn't remove \(info.name)", "\(error)")
        }
    }
}

// MARK: - Shared pieces

/// A titled part of the card.
struct CardSection<Content: View>: View {
    let title: String
    let help: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Text(help).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            content
        }
    }
}

/// The one row style for inputs and phones: icon · name · detail · state · [switch] · ⋯
struct SourceRow<MenuItems: View>: View {
    let icon: String
    let name: String
    let detail: String
    let state: String
    var problem = false
    var isOn: Binding<Bool>?
    @ViewBuilder let menu: MenuItems

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary)
            Text(name).font(.system(size: 12, weight: .medium)).frame(width: 74, alignment: .leading)
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .frame(minWidth: 120, maxWidth: 220, alignment: .leading)
            Text(state).font(.system(size: 11)).foregroundStyle(problem ? Color.orange : Color.secondary)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).help(state)
            if let isOn {
                Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden()
            } else {
                Color.clear.frame(width: 26, height: 1)
            }
            Menu { menu } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - WhatsApp (read on this Mac)

struct WhatsAppInputRow: View {
    @EnvironmentObject var store: Store
    let info: ConnectorInfo
    let openRules: () -> Void
    @State private var on = false
    @State private var st: WhatsAppSync.Status?

    var body: some View {
        SourceRow(icon: "bubble.left.and.bubble.right", name: "WhatsApp", detail: "This Mac (WhatsApp Desktop)",
                  state: state, problem: on && st?.error != nil,
                  isOn: Binding(get: { on }, set: { v in
                      if v, !confirmOn() { return }
                      on = v
                      WhatsAppSync.setOn(v, connector: info.id, store: store)
                      if v { NotificationCenter.default.post(name: .floatBoardWhatsAppNow, object: nil) }
                      st = WhatsAppSync.status[info.id]
                  })) {
            Button("Your WhatsApp rules…") { openRules() }
            Button("Read now") { NotificationCenter.default.post(name: .floatBoardWhatsAppNow, object: nil) }.disabled(!on)
            Button("Full Disk Access settings…") {
                if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(u) }
            }
        }
        .onAppear { on = WhatsAppSync.isOn(connector: info.id, store: store); st = WhatsAppSync.status[info.id] }
        .onReceive(NotificationCenter.default.publisher(for: .floatBoardWhatsAppRead)) { _ in st = WhatsAppSync.status[info.id] }
    }

    private var state: String {
        guard on else { return "Off" }
        if let e = st?.error { return e }
        guard let read = st?.lastRead else { return "Reading…" }
        return (st?.lastSent ?? 0) == 0 ? "Read \(ConnectorHealth.time(read)) · no new messages to check"
            : "Read \(ConnectorHealth.time(read)) · \(st!.lastSent) chat\(st!.lastSent == 1 ? "" : "s") checked for tasks"
    }

    private func confirmOn() -> Bool {
        let a = NSAlert()
        a.messageText = "Screen WhatsApp for tasks?"
        a.informativeText = """
            Every 5 minutes FloatBoard reads WhatsApp Desktop's own copy of your messages on this Mac. It never logs in, \
            never touches WhatsApp itself and never sends anything on WhatsApp.

            Unread messages from chats that aren't archived (muted ones too, judged more strictly) go to your engine \
            (\(URL(string: info.baseURL)?.host ?? "your engine")) and to Claude, which turns the ones that need you into tasks.

            macOS may ask you to allow FloatBoard in Full Disk Access.
            """
        a.addButton(withTitle: "Turn on"); a.addButton(withTitle: "Cancel")
        NSApp.activate()
        return a.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - Phone app

/// The phone app: where the board goes (not a source of tasks), so a card of its own. Served by `info`'s engine at
/// `<engine>/app`; lists the paired phones (each ⋯ › Disconnect) and pairs new ones. Hidden for engines without it.
struct PhoneAppCard: View {
    @EnvironmentObject var store: Store
    let info: ConnectorInfo
    @State private var pairing = false
    @State private var copied = false

    var body: some View {
        if ConnectorSync.phoneSupport[info.id] != false, !info.baseURL.isEmpty {
            let address = (URL(string: info.baseURL)?.host).map { "\($0)/app" } ?? "\(info.baseURL)/app"
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "iphone").font(.system(size: 16)).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Phone app").font(.system(size: 13, weight: .semibold))
                        Text("\(address) · served by the \(info.name) engine").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Pair a phone…") { pairing = true }
                    Menu {
                        Button(copied ? "Address copied" : "Copy the phone app's address") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("https://\(address)/", forType: .string)
                            copied = true
                        }
                        Button("Open it in the browser") { if let u = URL(string: "https://\(address)/") { NSWorkspace.shared.open(u) } }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuIndicator(.hidden).fixedSize()
                }
                Text("Your board on your phone: move, finish and add tasks, open links, and get urgent alerts and due reminders.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Divider()
                CardSection(title: "Paired phones", help: "Signed in to the phone app.") { PhonesList(info: info) }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.06)))
            .sheet(isPresented: $pairing) { PairPhoneSheet(info: info).environmentObject(store) }
        }
    }
}

/// Paired phones, each with ⋯ › Disconnect (signs it out and stops its notifications).
struct PhonesList: View {
    @EnvironmentObject var store: Store
    let info: ConnectorInfo
    @State private var phones: [ConnectorClient.PairedPhone] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if loaded && phones.isEmpty && error == nil {
                Text("No phones paired.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(phones) { p in
                SourceRow(icon: "iphone", name: p.name, detail: (p.created.map { "Paired \($0.formatted(.dateTime.day().month(.abbreviated)))" } ?? "Paired")
                            + (p.sharesPasskey > 0 ? " · shares a passkey" : ""),
                          state: p.lastSeen.map { "Last used \(ConnectorHealth.time($0))" } ?? "Not used yet") {
                    Button("Disconnect \(p.name)…", role: .destructive) { disconnect(p) }
                }
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .floatBoardSyncConnectors)) { _ in Task { await load() } }
    }

    private func load() async {
        guard let client = ConnectorAccounts.client(for: info, store: store) else { return }
        do { phones = try await client.phones(); error = nil } catch ConnectorError.noPhoneApp {
            phones = []; error = nil
        } catch {
            self.error = "Couldn't list phones. \((error as? ConnectorError)?.description ?? error.localizedDescription)"
        }
        loaded = true
    }

    private func disconnect(_ p: ConnectorClient.PairedPhone) {
        guard ConnectFlow.confirmTwice("Disconnect \(p.name)?",
            "It is signed out of the FloatBoard phone app and gets no more notifications. Your board doesn't change. To use it again, pair it from this Mac.",
            action: "Disconnect") else { return }
        Task { @MainActor in
            guard let client = ConnectorAccounts.client(for: info, store: store) else { return }
            do {
                let name = try await client.removePhone(id: p.id)
                store.activity("connector:\(info.id)", .info, "Disconnected phone \(name)")
                await load()
            } catch {
                self.error = "Couldn't disconnect \(p.name). \((error as? ConnectorError)?.description ?? error.localizedDescription)"
            }
        }
    }
}
