import AppKit
import FloatBoardConnectors
import FloatBoardCore
import SwiftUI

/// The sections of Settings (docs/architecture.md, Edition 2): what the product is, in the order you set it up.
enum SettingsSection: String, CaseIterable, Identifiable {
    case mode, connections, rules, keys
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mode: "Mode"
        case .connections: "Connections"
        case .rules: "Rules & learning"
        case .keys: "Keys"
        }
    }
    var icon: String {
        switch self {
        case .mode: "server.rack"
        case .connections: "point.3.connected.trianglepath.dotted"
        case .rules: "text.book.closed"
        case .keys: "key"
        }
    }
    var blurb: String {
        switch self {
        case .mode: "Where screening runs."
        case .connections: "Where tasks come from, your phone, and where tasks and alerts go."
        case .rules: "What FloatBoard follows, and what it has learned."
        case .keys: "Every key, kept privately on this Mac."
        }
    }
}

/// The Settings tab: a list of sections on the left, the chosen one on the right.
struct SettingsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var ui: UIState

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsSection.allCases) { s in
                    Button { ui.settingsSection = s } label: {
                        HStack(spacing: 8) {
                            // Fixed-width icon column, so every title starts at the same place.
                            Image(systemName: s.icon).frame(width: 20, alignment: .center)
                            Text(s.title)
                        }
                            .font(.system(size: 12, weight: ui.settingsSection == s ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5).padding(.horizontal, 8)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(ui.settingsSection == s ? Color.accentColor.opacity(0.15) : Color.clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .frame(width: 170)
            .padding(.trailing, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ui.settingsSection.title).font(.system(size: 15, weight: .semibold))
                        Text(ui.settingsSection.blurb).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    switch ui.settingsSection {
                    case .mode: ModeSection()
                    case .connections: ConnectionsSection()
                    case .rules: RulesSection()
                    case .keys: KeysSection()
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.leading, 14).padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A titled block inside a section.
struct SettingsBlock<Content: View>: View {
    let title: String
    var help: String = ""
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if !help.isEmpty { Text(help).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            content
        }
    }
}

/// Engines with an address (the ones this Mac can talk to).
@MainActor private func engines(_ store: Store) -> [ConnectorInfo] { store.connectors.filter { !$0.baseURL.isEmpty } }

/// The engine that screens: its settings are the ones in use (the other engine gets a copy), so they are edited once.
@MainActor private func screening(_ store: Store) -> [ConnectorInfo] {
    LocalMode.isOn(store: store) ? engines(store).filter { $0.id == LocalMode.connectorID } : Array(engines(store).prefix(1))
}

/// Shown in sections that need an engine when there is none yet.
private struct NoEngineYet: View {
    @EnvironmentObject var ui: UIState
    let what: String
    var body: some View {
        HStack(spacing: 6) {
            Text("\(what) need\(what.hasSuffix("s") ? "" : "s") an engine.").font(.system(size: 12)).foregroundStyle(.secondary)
            Button("Set one up in Mode") { ui.settingsSection = .mode }.buttonStyle(.link).font(.system(size: 12))
        }
    }
}

// MARK: - Mode

struct ModeSection: View {
    @EnvironmentObject var store: Store
    @State private var pasted = ""
    @State private var switching = false
    @State private var problem: String?
    /// The mode picked but not yet confirmed: the panel below says what will happen.
    @State private var pending: String?

    var body: some View {
        let local = LocalMode.isOn(store: store)
        let online = engines(store).filter { $0.id != LocalMode.connectorID }
        HStack(alignment: .top, spacing: 10) {
            choice("Always on", "Your online engine screens email, meeting notes and chats every 5 minutes, even when this Mac is off.",
                   icon: "cloud", selected: !local && !online.isEmpty, enabled: !switching,
                   note: !local && !online.isEmpty ? "In use" : online.isEmpty ? "Connect an engine below" : "Switch back…") {
                if local { pending = online.isEmpty ? nil : "always"; problem = online.isEmpty ? "Connect an online engine first (below)." : nil }
            }
            choice("Mac only", "Screening runs on this Mac while it's awake, with your Claude key and no online service.",
                   icon: "laptopcomputer", selected: local, enabled: !switching, note: local ? "In use" : "Switch…") {
                if !local { pending = "mac"; problem = nil }
            }
        }
        if let pending { confirmPanel(pending, online: online) }
        if switching { ProgressView().controlSize(.small) }
        if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange) }
        ForEach(engines(store)) { EngineCard(info: $0) }
        SettingsBlock(title: online.isEmpty ? "Connect an online engine" : "Connect another engine",
                      help: "For Always on. Your engine's setup page has a “Connect to FloatBoard” button that opens this automatically. Or paste its connect link here.") {
            HStack {
                TextField("floatboard://connect?…", text: $pasted).textFieldStyle(.roundedBorder).frame(width: 420)
                Button("Connect…") {
                    let link = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let u = URL(string: link), ConnectFlow.confirmAndAdd(u, store: store) { pasted = "" }
                    else if URL(string: link) == nil { ConnectFlow.alert("That isn't a link", "Copy the connect link from the engine's setup page.") }
                }
                .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        UpdatesBlock()
        HStack {
            Button("Copy diagnostics") { DiagnosticsCopy.copy(store: store) }
            Text("A support summary (no keys, email text or task titles) to paste to whoever is helping.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    /// What switching does, and the buttons that do it. Nothing changes until Switch is pressed.
    private func confirmPanel(_ to: String, online: [ConnectorInfo]) -> some View {
        let toMac = to == "mac"
        let engineName = online.first?.name ?? "your online engine"
        let lines: [String] = toMac ? [
            LocalMode.isSetUp() ? "This Mac's engine picks up from where \(engineName) is now (it has been kept in step)."
                : online.isEmpty ? "This Mac's engine is set up (first time only)." : "This Mac's engine is set up (first time only) and gets everything from \(engineName).",
            "Moves here: your rules, groups and what was learned; Gmail and Fathom with their sign-ins and how far they were read; what was already judged (so nothing is judged twice); WhatsApp screening.",
            online.isEmpty ? "Add Gmail afterwards in Connections › Inputs." : "\(engineName) stays connected (phone app, Outlook, phone alerts) and stops reading Gmail and Fathom while this Mac does.",
            "Screening only runs while this Mac is awake. Tasks on your board don't change.",
        ] : [
            "\(engineName) picks up from where this Mac is now: everything set up here moves back, including inboxes you connected on this Mac and how far they were read.",
            "Gmail and Fathom turn back on there; WhatsApp screening moves with them.",
            "This Mac's engine goes on standby and is kept in step, so switching back later is instant. Tasks on your board don't change.",
        ]
        return VStack(alignment: .leading, spacing: 8) {
            Text(toMac ? "Switch to Mac only?" : "Switch back to Always on?").font(.system(size: 13, weight: .semibold))
            ForEach(lines, id: \.self) { l in
                Label(l, systemImage: "arrow.right.circle").font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            }
            Text("Nothing you set up is lost either way.").font(.system(size: 11, weight: .medium))
            HStack {
                Button("Cancel") { pending = nil }
                Button(toMac ? "Switch to Mac only" : "Switch to Always on") {
                    pending = nil
                    run { toMac ? try await LocalMode.enable(store: store) : try await LocalMode.disable(store: store) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(maxWidth: 580, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
    }

    private func run(_ work: @escaping () async throws -> Void) {
        switching = true; problem = nil
        Task { @MainActor in
            defer { switching = false }
            do {
                try await work()
                NotificationCenter.default.post(name: .floatBoardSyncConnectors, object: nil)
            } catch {
                problem = "Couldn't switch: \(error). Nothing was lost; try again."
                store.activity("connector:\(LocalMode.connectorID)", .error, "Could not switch mode", detail: "\(error)")
            }
        }
    }

    private func choice(_ title: String, _ text: String, icon: String, selected: Bool, enabled: Bool, note: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) { VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).font(.system(size: 16))
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(note).font(.system(size: 10, weight: .medium)).foregroundStyle(selected ? Color.accentColor : .secondary)
        }
        .padding(12)
        .frame(width: 280, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle()) }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.6)
    }
}

// MARK: - Inputs

struct ConnectionsSection: View {
    @EnvironmentObject var store: Store
    var body: some View {
        SettingsBlock(title: "Inputs", help: "Where tasks come from. Each has a switch; Add an input connects another.") {
            if engines(store).isEmpty { NoEngineYet(what: "Inputs") }
            ForEach(engines(store)) { EngineInputsCard(info: $0) }
            WithdrawnList()
        }
        let phones = engines(store).filter { $0.id != LocalMode.connectorID }
        SettingsBlock(title: "Phone", help: phones.isEmpty ? "The phone app needs Always on (Settings › Mode)." : "Your board on your phone, served by your online engine.") {
            ForEach(phones) { PhoneAppCard(info: $0) }
        }
        OutputsBlock()
    }
}

/// A short, numbered guide for adding one kind of input, with the action itself where the app can do it: Gmail signs
/// in from this Mac with your Google client; Fathom takes its API key here. Online engines also keep their setup page.
struct InputGuide: View {
    enum Kind: String, Identifiable { case gmail, outlook, fathom; var id: String { rawValue } }
    @EnvironmentObject var store: Store
    @EnvironmentObject var google: Google
    @EnvironmentObject var ui: UIState
    @Environment(\.dismiss) private var dismiss
    let kind: Kind
    let info: ConnectorInfo
    @State private var fathomKey = ""
    @State private var message: String?
    @State private var working = false

    private var local: Bool { info.id == LocalMode.connectorID }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 15, weight: .semibold))
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(i + 1)").font(.system(size: 12, weight: .bold)).frame(width: 22, height: 22)
                        .background(Circle().fill(Color.accentColor.opacity(0.18)))
                    Text(step).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
            }
            if kind == .fathom {
                HStack {
                    SecureField("Fathom API key", text: $fathomKey).textFieldStyle(.roundedBorder).frame(width: 300)
                    Button("Save key") { saveFathom() }.disabled(fathomKey.trimmingCharacters(in: .whitespaces).count < 10 || working)
                }
            }
            if let message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                if kind == .gmail {
                    if google.isConfigured {
                        Button(google.busy ? "Waiting for Google…" : "Sign in with Google") { signInGmail() }
                            .keyboardShortcut(.defaultAction).disabled(google.busy)
                    } else {
                        Button("Set up the Google client") { dismiss(); ui.settingsSection = .keys }.keyboardShortcut(.defaultAction)
                    }
                }
                if !local && kind != .gmail {
                    Button("Open the setup page") {
                        if let u = URL(string: info.baseURL)?.appendingPathComponent("setup") { NSWorkspace.shared.open(u) }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private var title: String {
        switch kind {
        case .gmail: "Add a Gmail inbox"
        case .outlook: "Add Outlook on the web"
        case .fathom: "Add Fathom meeting notes"
        }
    }

    private var steps: [String] {
        switch kind {
        case .gmail:
            return [
                google.isConfigured ? "Your Google client is set ✓" : "First set up your Google client (once): Settings › Keys › Google client.",
                "Press “Sign in with Google” and pick the inbox. Google says the app is unverified: that's your own app. Press Advanced, then Continue.",
                "The inbox appears under Inputs within a minute. Its switch turns it on and off.",
            ]
        case .outlook:
            return local ? ["Outlook needs Always on: the extension runs on another computer and sends to your online engine. Switch in Settings › Mode."] : [
                "On the computer where you use Outlook on the web, open Chrome.",
                "Press “Open the setup page” below and find “Outlook (Chrome extension)”. It shows a code and how to load the extension.",
                "Load the extension, paste the code into it, and keep an Outlook tab open.",
                "Outlook appears under Inputs after its first report.",
            ]
        case .fathom:
            return local ? [
                "In Fathom, open Settings › API access and create an API key.",
                "Paste it below and press Save key. This Mac asks Fathom for new meetings every hour while it's awake.",
            ] : [
                "Press “Open the setup page” below and find “Fathom meeting recaps”. It shows your private webhook address.",
                "In Fathom, open Settings › API access › Webhooks, add a webhook, and paste that address.",
                "Optional: paste a Fathom API key below too, so missed meetings are caught up every hour.",
            ]
        }
    }

    private func signInGmail() {
        guard let client = ConnectorAccounts.client(for: info, store: store), let secret = google.clientSecret else { return }
        let id = google.clientID
        google.connectGmail { email, refresh in
            try await client.addGmail(address: email, refreshToken: refresh, clientID: id, clientSecret: secret)
            store.activity("connector:\(info.id)", .info, "Gmail connected from this Mac: \(email)")
            message = "\(email) connected ✓"
            NotificationCenter.default.post(name: .floatBoardSyncConnectors, object: nil)
        }
    }

    private func saveFathom() {
        guard let client = ConnectorAccounts.client(for: info, store: store) else { return }
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                try await client.setFathomKey(fathomKey.trimmingCharacters(in: .whitespaces))
                fathomKey = ""; message = "Fathom key saved ✓"
                NotificationCenter.default.post(name: .floatBoardSyncConnectors, object: nil)
            } catch { message = "Couldn't save it: \((error as? ConnectorError)?.description ?? "\(error)")" }
        }
    }
}

// MARK: - Outputs

/// Where tasks and alerts go.
struct OutputsBlock: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var google: Google

    var body: some View {
        Text("Outputs").font(.system(size: 15, weight: .semibold)).padding(.top, 6)
        SettingsBlock(title: "Board", help: "Every new task lands on your board. It is always on.") {
            ForEach(screening(store)) { form($0, ["default_group", "auto_add"]) }
        }
        SettingsBlock(title: "Phone alerts", help: "Urgent tasks and due reminders on your phone, through the phone app (or ntfy, set up on the engine's setup page).") {
            if engines(store).isEmpty { NoEngineYet(what: "Phone alerts") }
            ForEach(engines(store).filter { $0.id != LocalMode.connectorID }.prefix(1)) { form($0, ["alerts_on", "critical_hours"]) }
        }
        SettingsBlock(title: "Email", help: "What happens in Gmail. Reply drafts appear as a Draft reply button on email tasks; drafts are saved in Gmail and never sent.") {
            if engines(store).isEmpty { NoEngineYet(what: "Email actions") }
            ForEach(screening(store)) { form($0, ["mark_read_on_done", "ai_footer"]) }
        }
        SettingsBlock(title: "Calendar") {
            AccountsView(showSetup: false)
        }
        SettingsBlock(title: "Mac notifications",
                      help: "Due reminders and Watch chase reminders appear as notifications on this Mac. Always on; turn them off in System Settings › Notifications › FloatBoard.") {
            EmptyView()
        }
    }

    private func form(_ info: ConnectorInfo, _ keys: [String]) -> some View {
        ConnectorSettingsForm(info: info, schema: ConnectorHealth.status(info, store: store)?.schema ?? [], keys: keys)
    }
}

// MARK: - Rules & learning

struct RulesSection: View {
    @EnvironmentObject var store: Store

    var body: some View {
        if engines(store).isEmpty { NoEngineYet(what: "Rules") }
        ForEach(screening(store)) { info in
            let has = { (k: String) in !((info.settings[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            Rulebooks(info: info)
            // "Your rules" and the old WhatsApp rules only show while they hold something (the rulebooks replace them).
            ConnectorSettingsForm(info: info, schema: ConnectorHealth.status(info, store: store)?.schema ?? [],
                                  keys: (has("my_rules") ? ["my_rules"] : []) + (has("chat_rules") ? ["chat_rules"] : [])
                                      + ["group_notes", "ignore_senders", "allow_senders", "unread_only", "learned", "learn_at", "*"])
            AIModelBlock(info: info)
        }
    }
}

/// Which Claude model each job uses, with what it cost over the last 30 days and what the other model would have cost.
struct AIModelBlock: View {
    @EnvironmentObject var store: Store
    let info: ConnectorInfo
    var body: some View {
        let status = ConnectorHealth.status(info, store: store)
        SettingsBlock(title: "AI model", help: "You choose, and you pay Anthropic directly with your Claude key. Estimates use the last 30 days and Anthropic's list prices.") {
            let cost = status?.aiCost ?? [:]
            if cost.isEmpty {
                Text("No Claude use recorded yet.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(["judge", "recap", "learn", "reply"], id: \.self) { job in
                    if let c = cost[job] {
                        Text("\(Self.label(job)): \(c.calls) call\(c.calls == 1 ? "" : "s"), \(Self.money(c.usd)) a month"
                             + (c.usdIf.filter { abs($0.value - c.usd) > 0.004 }.map { " · with \($0.key.capitalized): \(Self.money($0.value))" }.sorted().joined()))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            ConnectorSettingsForm(info: info, schema: status?.schema ?? [], keys: ["model_judge", "model_recap", "model_reply"])
            if info.id == LocalMode.connectorID && OnDeviceModel.isAvailable { OnDeviceCompare(info: info) }
        }
    }
    static func label(_ job: String) -> String {
        switch job { case "judge": "Judging"; case "recap": "Meeting summaries"; case "learn": "Learning"; default: "Reply drafts" }
    }
    static func money(_ usd: Double) -> String { usd < 0.01 ? "under $0.01" : String(format: "about $%.2f", usd) }
}

/// "Compare with Haiku": before choosing On this Mac, see how often it agrees with Haiku on your latest chats.
struct OnDeviceCompare: View {
    @EnvironmentObject var store: Store
    let info: ConnectorInfo
    @State private var result: String?
    @State private var running = false
    private let metaKey = "ondevice.agreement"

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Button(running ? "Comparing…" : "Compare On this Mac with Haiku…") { compare() }.disabled(running).controlSize(.small)
            Text(result ?? saved ?? "Judges your latest WhatsApp chats with both and shows how often they agree.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var saved: String? {
        try? store.db.query("SELECT value FROM meta WHERE key=?", [metaKey]) { DB.text($0, 0) }.first // try?-ok: nothing saved yet
    }

    private func compare() {
        guard ConnectFlow.confirmTwice("Compare with Haiku?", "Your latest 10 WhatsApp chats are judged by both. That is up to 10 Haiku calls (well under $0.01); Apple's model is free.", action: "Compare") else { return }
        guard let client = ConnectorAccounts.client(for: info, store: store) else { return }
        running = true
        Task { @MainActor in
            defer { running = false }
            do {
                let c = try await client.compareModels(limit: 10)
                let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "d MMM"
                let text = c.n == 0 ? (c.note ?? "No chats to compare yet.")
                    : "Agreed with Haiku on \(c.agree) of \(c.n) chats (\(f.string(from: Date())))" + ((c.unusable ?? 0) > 0 ? "; \(c.unusable!) answers unusable" : "")
                result = text
                try store.db.run("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", [metaKey, text])
            } catch { result = "Couldn't compare: \((error as? ConnectorError)?.description ?? "\(error)")" }
        }
    }
}

/// The rulebooks FloatBoard follows (email, chats): yours to edit. Each starts as the built-in one; every change is a
/// version you can restore, and Reset goes back to the built-in one. A newer built-in rulebook is merged in without
/// touching what you changed (RulebookSync).
struct Rulebooks: View {
    @EnvironmentObject var store: Store
    let info: ConnectorInfo
    @State private var books: [Rulebook] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(books) { b in RulebookEditor(info: info, book: b) }
            if books.isEmpty && error == nil { Text("Loading the rulebooks…").font(.system(size: 11)).foregroundStyle(.secondary) }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            Text("Always applied on top, and not editable: security or fraud alerts about your own accounts always need you.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .task { await load() }
    }

    private func load() async {
        guard let client = ConnectorAccounts.client(for: info, store: store) else { return }
        do {
            books = try await client.rulebooks(); error = nil
            RulebookSync.refresh(connector: info.id, store: store, books: books)
        } catch {
            self.error = "Couldn't load the rulebooks: \((error as? ConnectorError)?.description ?? error.localizedDescription)"
        }
    }
}

struct RulebookEditor: View {
    @EnvironmentObject var store: Store
    let info: ConnectorInfo
    let book: Rulebook
    @State private var text = ""
    @State private var loaded = false
    @State private var message: String?

    private var key: String { RulebookSync.keys[book.key] ?? "rulebook_\(book.key)" }
    private var stored: String { (store.connectors.first { $0.id == info.id }?.settings[key] as? String ?? "") }
    private var current: String { stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? book.text : stored }
    private var isBuiltIn: Bool { stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        SettingsBlock(title: "\(book.name) rulebook",
                      help: isBuiltIn ? "The built-in rulebook. Edit it to make it yours; you can always reset it."
                                      : "Your own copy. Updates to the built-in rulebook are merged in; lines you changed stay yours.") {
            TextEditor(text: $text)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 220)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15)))
            HStack {
                Button("Save") { save(text) }.disabled(text == current)
                Button("Undo changes") { text = current }.buttonStyle(.borderless).disabled(text == current)
                Spacer()
                Button("Reset to built-in…") { reset() }.disabled(isBuiltIn)
                if let message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            InstructionsHistory(info: info, part: key, emptyMeans: book.text)
        }
        .onAppear { if !loaded { text = current; loaded = true } }
        .onChange(of: stored) { _, _ in text = current } // a restore, a reset or a merged update
    }

    private func save(_ t: String) {
        // Saving text identical to the built-in one means "follow the built-in rulebook".
        let value = t.trimmingCharacters(in: .whitespacesAndNewlines) == book.text.trimmingCharacters(in: .whitespacesAndNewlines) ? "" : t
        do {
            try store.saveConnectorSettings(connector: info.id, values: [key: value])
            RulebookSync.setBase(book.text, info.id, key, store: store)
            message = "Saved. It is used from the next check."
            NotificationCenter.default.post(name: .floatBoardSyncConnectors, object: nil)
        } catch { message = "Couldn't save: \(error)" }
    }

    private func reset() {
        guard ConnectFlow.confirmTwice("Reset the \(book.name.lowercased()) rulebook?",
            "It goes back to the built-in rulebook. Your version stays in the history, so you can restore it.", action: "Reset") else { return }
        do {
            try store.saveConnectorSettings(connector: info.id, values: [key: ""], source: .restore, note: "reset to the built-in rulebook")
            text = book.text
            message = "Back to the built-in rulebook."
            NotificationCenter.default.post(name: .floatBoardSyncConnectors, object: nil)
        } catch { message = "Couldn't reset: \(error)" }
    }
}

// MARK: - Keys

struct KeysSection: View {
    @EnvironmentObject var store: Store
    @State private var claude = ""
    @State private var gid = ""
    @State private var gsecret = ""
    @State private var message: String?
    @State private var refresh = 0

    var body: some View {
        let _ = refresh
        let engineKeys = engines(store).compactMap { ConnectorHealth.status($0, store: store)?.keys }.first
        let waiting = engines(store).flatMap { Keys.pending(connector: $0.id, store: store) }
        SettingsBlock(title: "Claude key", help: "Used to judge messages, write meeting recaps and reply drafts. Get one at console.anthropic.com › API keys.") {
            state(mac: Keys.value(Keys.claude, store: store) != nil, engine: engineKeys?.claude, waiting: waiting.contains(.claude))
            HStack {
                SecureField(Keys.value(Keys.claude, store: store) == nil ? "sk-ant-…" : "Paste a new key to replace it", text: $claude)
                    .textFieldStyle(.roundedBorder).frame(width: 360)
                Button("Save") { save { try Keys.setClaude(claude, store: store); claude = "" } }
                    .disabled(claude.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Remove…") {
                    guard ConnectFlow.confirmTwice("Remove the Claude key?", "It is removed from this Mac and from your engine. Screening stops until you add one again.", action: "Remove") else { return }
                    save { try Keys.setClaude("", store: store) }
                }
                .disabled(Keys.value(Keys.claude, store: store) == nil && engineKeys?.claude != true)
            }
        }
        Divider()
        SettingsBlock(title: "Google client", help: "One client for Gmail and Calendar: this Mac signs in with it and hands Gmail sign-ins to the engine that screens.") {
            AccountsView(showAccounts: false)
        }
        Divider()
        SettingsBlock(title: "Gmail sign-ins", help: "Each inbox you connect. Connect or reconnect them in Connections › Inputs › Add an input › Gmail inbox.") {
            ForEach(engines(store)) { info in
                ForEach((ConnectorHealth.status(info, store: store)?.sources ?? []).filter { $0.kind == "gmail" }) { s in
                    Label(s.address + (s.lastError.map { " · \($0)" } ?? " · signed in"), systemImage: "envelope")
                        .font(.system(size: 11)).foregroundStyle(s.lastError == nil ? Color.secondary : Color.orange)
                }
            }
        }
        Divider()
        SettingsBlock(title: "Engine connection", help: "The key this Mac uses to talk to your engine. Disconnect it in Mode.") {
            ForEach(engines(store)) { info in
                Label("\(URL(string: info.baseURL)?.host ?? info.baseURL) · key saved on this Mac", systemImage: "server.rack")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if engines(store).isEmpty { Text("No engine connected.").font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        Text(Credentials.usesFile
             ? "Keys are kept in a private file on this Mac that only your account can read (builds without an Apple Developer ID would otherwise make the Keychain ask for your password after every update)."
             : "Keys are kept in this Mac's Keychain. Your engines get only the ones they need.")
            .font(.system(size: 10)).foregroundStyle(.secondary)
        if let message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary) }
    }

    private func state(mac: Bool, engine: Bool?, waiting: Bool, detail: String? = nil) -> some View {
        HStack(spacing: 12) {
            Label(mac ? "On this Mac" : "Not on this Mac", systemImage: mac ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(mac ? Color.green : Color.secondary)
            if let engine {
                Label(waiting ? "Waiting to send to the engine" : engine ? "On your engine" : "Not on your engine",
                      systemImage: waiting ? "clock" : engine ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(waiting ? Color.orange : engine ? Color.green : Color.orange)
            }
            if let detail { Text(detail).foregroundStyle(.secondary) }
        }
        .font(.system(size: 11))
    }

    private func save(_ work: () throws -> Void) {
        do {
            try work()
            message = "Saved on this Mac. Sending to your engine…"
            refresh += 1
            NotificationCenter.default.post(name: .floatBoardSyncConnectors, object: nil)
        } catch {
            message = "Couldn't save: \(error)"
        }
    }
}

/// Updates: this build's version, what GitHub has, and the buttons (Settings › Mode).
struct UpdatesBlock: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        SettingsBlock(title: "Updates", help: "FloatBoard checks GitHub when it starts and once a day. Updating pulls the code, updates your online engine (if this Mac deploys it) and rebuilds the app, which then reopens.") {
            HStack(spacing: 8) {
                Text("This version: \(updater.built.isEmpty ? "unknown" : String(updater.built.prefix(7)))").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(stateText).font(.system(size: 11)).foregroundStyle(stateIsProblem ? Color.orange : Color.secondary)
            }
            if case .available(let a) = updater.state {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(a.messages, id: \.self) { Text("• " + $0).font(.system(size: 11)).lineLimit(1) }
                }
            }
            HStack {
                Button("Check now") { Task { await updater.check() } }.disabled(isBusy)
                // Only when GitHub has something newer than this version.
                if case .available = updater.state { Button("Update now") { updater.update() }.keyboardShortcut(.defaultAction).disabled(isBusy) }
                Toggle("Install updates automatically when FloatBoard starts", isOn: Binding(get: { updater.autoInstall }, set: { updater.autoInstall = $0 }))
                    .toggleStyle(.checkbox).font(.system(size: 11))
            }
        }
    }

    private var isBusy: Bool { if case .updating = updater.state { return true }; return updater.state == .checking }
    private var stateIsProblem: Bool { if case .failed = updater.state { return true }; if case .unknown = updater.state { return true }; return false }
    private var stateText: String {
        switch updater.state {
        case .idle: return updater.lastChecked == nil ? "Checking shortly…" : ""
        case .checking: return "Checking…"
        case .upToDate: return "Up to date" + (updater.lastChecked.map { " (checked \(Fmt.clock($0)))" } ?? "")
        case .available(let a): return "\(a.count) change\(a.count == 1 ? "" : "s") available"
        case .updating(let m): return m
        case .failed(let why): return "Didn't update: \(why)"
        case .unknown(let why): return why
        }
    }
}

