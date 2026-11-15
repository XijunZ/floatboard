import AppKit
import FloatBoardConnectors
import FloatBoardCore
import SwiftUI

/// The sections of Settings (docs/architecture.md, Edition 2): what the product is, in the order you set it up.
enum SettingsSection: String, CaseIterable, Identifiable {
    case mode, inputs, outputs, rules, keys
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mode: "Mode"
        case .inputs: "Inputs"
        case .outputs: "Outputs"
        case .rules: "Rules & learning"
        case .keys: "Keys"
        }
    }
    var icon: String {
        switch self {
        case .mode: "server.rack"
        case .inputs: "tray.and.arrow.down"
        case .outputs: "tray.and.arrow.up"
        case .rules: "text.book.closed"
        case .keys: "key"
        }
    }
    var blurb: String {
        switch self {
        case .mode: "Where screening runs."
        case .inputs: "Where tasks come from."
        case .outputs: "Where tasks and alerts go."
        case .rules: "What FloatBoard follows, and what it has learned."
        case .keys: "Every key, kept in this Mac's Keychain."
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
                        Label(s.title, systemImage: s.icon)
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
                    case .inputs: InputsSection()
                    case .outputs: OutputsSection()
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

    var body: some View {
        let connected = !engines(store).isEmpty
        HStack(alignment: .top, spacing: 10) {
            choice("Always on", "Your own engine screens email, meeting notes and chats every 5 minutes, even when this Mac is off. Needed for the phone app.",
                   icon: "cloud", selected: connected, enabled: true, note: connected ? "In use" : "Connect an engine below")
            choice("Mac only", "Screening runs on this Mac while it's awake, with no online service. Your board always stays on this Mac either way.",
                   icon: "laptopcomputer", selected: false, enabled: false, note: "Coming soon")
        }
        ForEach(engines(store)) { EngineCard(info: $0) }
        SettingsBlock(title: connected ? "Connect another engine" : "Connect your engine",
                      help: "Your engine's setup page has a “Connect to FloatBoard” button that opens this automatically. Or paste its connect link here.") {
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
        HStack {
            Button("Copy diagnostics") { DiagnosticsCopy.copy(store: store) }
            Text("A support summary (no keys, email text or task titles) to paste to whoever is helping.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func choice(_ title: String, _ text: String, icon: String, selected: Bool, enabled: Bool, note: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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
        .opacity(enabled ? 1 : 0.6)
    }
}

// MARK: - Inputs

struct InputsSection: View {
    @EnvironmentObject var store: Store
    var body: some View {
        if engines(store).isEmpty { NoEngineYet(what: "Inputs") }
        ForEach(engines(store)) { EngineInputsCard(info: $0) }
        WithdrawnList()
    }
}

/// A short, numbered guide for adding one kind of input. The engine's setup page does the signing in.
struct InputGuide: View {
    enum Kind: String, Identifiable { case gmail, outlook, fathom; var id: String { rawValue } }
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let kind: Kind
    let info: ConnectorInfo

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
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                Button("Open the setup page") {
                    if let u = URL(string: info.baseURL)?.appendingPathComponent("setup") { NSWorkspace.shared.open(u) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
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
            let keys = ConnectorHealth.status(info, store: store)?.keys
            return [
                keys?.googleClientID == nil
                    ? "First set up your Google client: Settings › Keys › Google client for Gmail (one time only)."
                    : "Your Google client is set ✓",
                "Press “Open the setup page” below and sign in with your engine key if it asks.",
                "Under “Gmail accounts”, press “Connect a Gmail account” and pick the inbox.",
                "Google says the app is unverified: that's your own app. Press Advanced, then Continue.",
                "Back here, the inbox appears under Inputs within a minute. Its switch turns it on and off.",
            ]
        case .outlook:
            return [
                "On the computer where you use Outlook on the web, open Chrome.",
                "Press “Open the setup page” below and find “Outlook (Chrome extension)”. It shows a code and how to load the extension.",
                "Load the extension, paste the code into it, and keep an Outlook tab open.",
                "Outlook appears under Inputs after its first report.",
            ]
        case .fathom:
            return [
                "Press “Open the setup page” below and find “Fathom meeting recaps”. It shows your private webhook address.",
                "In Fathom, open Settings › API access › Webhooks, add a webhook, and paste that address.",
                "Optional: paste a Fathom API key on the setup page too, so missed meetings are caught up every hour.",
                "Fathom appears under Inputs after the next meeting.",
            ]
        }
    }
}

// MARK: - Outputs

struct OutputsSection: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var google: Google

    var body: some View {
        SettingsBlock(title: "Board", help: "Every new task lands on your board. It is always on.") {
            ForEach(engines(store)) { form($0, ["default_group", "auto_add"]) }
        }
        ForEach(engines(store)) { PhoneAppCard(info: $0) }
        SettingsBlock(title: "Phone alerts", help: "Urgent tasks and due reminders on your phone (through the phone app; ntfy is set up on the engine's setup page).") {
            if engines(store).isEmpty { NoEngineYet(what: "Phone alerts") }
            ForEach(engines(store)) { form($0, ["alerts_on", "critical_hours"]) }
        }
        SettingsBlock(title: "Email", help: "What happens in Gmail. Reply drafts appear as a Draft reply button on email tasks; drafts are saved in Gmail and never sent.") {
            if engines(store).isEmpty { NoEngineYet(what: "Email actions") }
            ForEach(engines(store)) { form($0, ["mark_read_on_done", "ai_footer"]) }
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
        ForEach(engines(store)) { info in
            Rulebooks(info: info)
            ConnectorSettingsForm(info: info, schema: ConnectorHealth.status(info, store: store)?.schema ?? [],
                                  keys: ["my_rules", "chat_rules", "group_notes", "ignore_senders", "allow_senders", "unread_only",
                                         "learned", "learn_at", "*"])
        }
    }
}

/// The shared rulebooks the engine follows (read-only): part 1 of your instructions.
struct Rulebooks: View {
    @EnvironmentObject var store: Store
    let info: ConnectorInfo
    @State private var books: [Rulebook] = []
    @State private var error: String?

    var body: some View {
        SettingsBlock(title: "Shared rules", help: "The rulebooks every FloatBoard engine follows. Read-only: your own rules below override them.") {
            ForEach(books) { b in
                DisclosureGroup(b.name) {
                    ScrollView {
                        Text(b.text).font(.system(size: 11)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                }
                .font(.system(size: 12))
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
        }
        .task { await load() }
    }

    private func load() async {
        guard let client = ConnectorAccounts.client(for: info, store: store) else { return }
        do { books = try await client.rulebooks(); error = nil } catch {
            self.error = "Couldn't load the shared rules: \((error as? ConnectorError)?.description ?? error.localizedDescription)"
        }
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
        SettingsBlock(title: "Google client for Gmail",
                      help: "Lets your engine read the Gmail inboxes you connect. One-time set-up in Google Cloud; the steps are below.") {
            state(mac: Keys.value(Keys.gmailClientID, store: store) != nil, engine: engineKeys.map { $0.googleClientID != nil },
                  waiting: waiting.contains(.googleClient), detail: engineKeys?.googleClientID.map { "client ID \($0.prefix(18))…" })
            HStack {
                TextField("Client ID", text: $gid).textFieldStyle(.roundedBorder).frame(width: 300)
                SecureField("Client secret", text: $gsecret).textFieldStyle(.roundedBorder).frame(width: 200)
                Button("Save") { save { try Keys.setGmailClient(id: gid, secret: gsecret, store: store); gid = ""; gsecret = "" } }
                    .disabled(gid.trimmingCharacters(in: .whitespaces).isEmpty || gsecret.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            GmailClientSteps()
        }
        Divider()
        SettingsBlock(title: "Gmail sign-ins", help: "Each inbox you connect. Connect or reconnect them from Inputs › Add an input › Gmail.") {
            ForEach(engines(store)) { info in
                ForEach((ConnectorHealth.status(info, store: store)?.sources ?? []).filter { $0.kind == "gmail" }) { s in
                    Label(s.address + (s.lastError.map { " · \($0)" } ?? " · signed in"), systemImage: "envelope")
                        .font(.system(size: 11)).foregroundStyle(s.lastError == nil ? Color.secondary : Color.orange)
                }
            }
        }
        Divider()
        SettingsBlock(title: "Google Calendar client", help: "Separate from Gmail: lets this Mac add tasks to your calendar. Accounts are under Outputs › Calendar.") {
            AccountsView(showAccounts: false)
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
             ? "Keys are kept in a private file on this Mac (this build isn't signed with a certificate, so the Keychain would ask again after every update)."
             : "Keys are kept in this Mac's Keychain. Your engine gets only the ones it needs, and never sends them back.")
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

/// The one-time Google Cloud steps for the Gmail client, with the engine's own redirect address to copy.
private struct GmailClientSteps: View {
    @EnvironmentObject var store: Store
    @State private var open = false
    var body: some View {
        let redirect = engines(store).first.flatMap { URL(string: $0.baseURL)?.appendingPathComponent("setup/google/callback").absoluteString }
        DisclosureGroup("How to make the Google client (about 5 minutes, once)", isExpanded: $open) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array([
                    "Open console.cloud.google.com and create a project (any name, e.g. FloatBoard).",
                    "APIs & Services › Library: enable the Gmail API.",
                    "Google Auth Platform › Get started: app name FloatBoard, External, your email.",
                    "Audience: press Publish app, so it says In production (otherwise Gmail sign-ins expire every 7 days).",
                    "Clients › Create client › Web application. Under Authorized redirect URIs add the address below.",
                    "Copy the Client ID and Client secret into the boxes above and press Save.",
                ].enumerated()), id: \.offset) { i, s in
                    Text("\(i + 1). \(s)").font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                }
                if let redirect {
                    HStack {
                        Text(redirect).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(redirect, forType: .string) }
                            .controlSize(.small)
                    }
                }
                Button("Open Google Cloud Console") {
                    if let u = URL(string: "https://console.cloud.google.com/apis/credentials") { NSWorkspace.shared.open(u) }
                }
                .controlSize(.small)
            }
            .padding(.top, 4)
        }
        .font(.system(size: 11))
    }
}
