import FloatBoardCore
import SwiftUI

/// The calendar button on a task: add it to a connected Google account's calendar (with or without
/// Google Meet), open it if it's already there, or fall back to a pre-filled page in the browser.
struct CalendarMenu: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var google: Google
    @EnvironmentObject var ui: UIState
    let card: Card
    /// Show "Add to Google Calendar" text next to the icon (used in the edit pop-up).
    var labeled = false
    /// Called after the event is queued for Google, e.g. so the edit pop-up can show the task is on the calendar.
    var onAdded: (String) -> Void = { _ in }

    var body: some View {
        Menu {
            if !card.gcalAccount.isEmpty, let u = URL(string: card.gcalLink) {
                Button("Open in Google Calendar (\(card.gcalAccount))") { NSWorkspace.shared.open(u) }
                Divider()
            }
            if google.accounts.isEmpty {
                Button("Connect a Google account…") { ui.tab = .settings; ui.settingsSection = .connections }
            } else {
                ForEach(google.accounts, id: \.self) { acct in
                    Menu("Add to \(acct)") {
                        // Default: timed tasks get a Meet call, date-only tasks don't.
                        if card.dueHasTime {
                            Button("With Google Meet") { add(acct, meet: true) }
                            Button("Without Google Meet") { add(acct, meet: false) }
                        } else {
                            Button("Without Google Meet") { add(acct, meet: false) }
                            Button("With Google Meet") { add(acct, meet: true) }
                        }
                    }
                }
            }
            Divider()
            if let url = card.googleCalendarURL {
                Button("Open pre-filled in browser instead") { NSWorkspace.shared.open(url) }
            }
        } label: {
            let icon = (card.gcalAccount.isEmpty ? "calendar.badge.plus" : "calendar.badge.checkmark")
            if labeled {
                Label(card.gcalAccount.isEmpty ? "Add to Google Calendar" : "In Google Calendar", systemImage: icon)
            } else {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(card.gcalAccount.isEmpty ? "Add to Google Calendar" : "In \(card.gcalAccount)'s calendar")
    }

    /// One path for every way of putting a task on the calendar: a change waits in the calendar outbox and is sent at once
    /// when online (the scheduler is nudged), kept and retried when not. Problems are written to Activity.
    private func add(_ account: String, meet: Bool) {
        guard store.addToCalendar(card, account: account, addMeet: meet) else { return }
        onAdded(account)
        NotificationCenter.default.post(name: .floatBoardCalendarNow, object: nil)
    }
}

/// Google accounts for adding tasks to Google Calendar, and the one-time Google Cloud set-up (Settings).
struct AccountsView: View {
    @EnvironmentObject var google: Google
    var showAccounts = true
    /// The one-time Google Cloud client set-up (shown under Settings › Keys).
    var showSetup = true
    @State private var clientID = ""
    @State private var secret = ""
    @State private var setupOpen = false

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 12) {
                if showAccounts {
                    CalendarSettingsView()
                }

                if showSetup {
                DisclosureGroup(isExpanded: Binding(get: { setupOpen || !google.isConfigured }, set: { setupOpen = $0 })) {
                VStack(alignment: .leading, spacing: 10) {
                Text(google.isConfigured
                     ? "Saved on this Mac (client ID \(google.clientID.prefix(14))…). Paste new values below to replace it."
                     : "Not set up yet. Create the client in Google Cloud Console, then paste its ID and secret here.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("Client ID", text: $clientID).textFieldStyle(.roundedBorder).frame(width: 340)
                    SecureField("Client secret", text: $secret).textFieldStyle(.roundedBorder).frame(width: 220)
                    Button("Save") {
                        google.saveClient(id: clientID, secret: secret)
                        clientID = ""; secret = ""
                    }
                    .disabled(clientID.isEmpty || secret.isEmpty)
                    Text("or").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Import JSON file…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.json]
                        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                        NSApp.activate()
                        if panel.runModal() == .OK, let u = panel.url { google.importClientJSON(at: u) }
                    }
                }
                Text("""
                Steps (console.cloud.google.com):
                1. Create a new project (any name, e.g. "FloatBoard").
                2. APIs & Services → Library → enable the Gmail API and the Google Calendar API.
                3. Google Auth Platform (OAuth consent screen) → Get started: app name FloatBoard, External, your email.
                4. Audience → Publish app, so it says In production (otherwise sign-ins expire after 7 days).
                5. Clients → Create client → Application type: Desktop app → Create. Copy the client ID and secret here.
                """)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                }
                .padding(.top, 6)
                } label: {
                    Text("Google Cloud set-up (one-time)").font(.system(size: 13, weight: .semibold))
                }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Settings › Outputs › Calendar: the connected Google accounts, which account new events go to, and a switch for every calendar.
struct CalendarSettingsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var google: Google
    /// Pictures only: pretend these accounts are connected.
    var accounts: [String]? = nil
    /// Bumped after a change so the lists are read again.
    @State private var tick = 0
    /// Pictures can't draw system controls (pickers, switches, link buttons), so they get plain stand-ins.
    @Environment(\.calendarSnapshot) private var snapshot

    private var connected: [String] { accounts ?? google.accounts }

    var body: some View {
        let _ = tick
        let all = CalendarCache(store: store).calendars()
        let effective = CalendarSettings.effectiveDefault(saved: store.savedDefaultCalendarAccount(), connected: connected)
        VStack(alignment: .leading, spacing: 14) {
            if connected.isEmpty {
                Text("No Google account connected yet. Connect one to see your calendars here and to put tasks on them.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if connected.count > 1, let effective {
                HStack {
                    Text("New events go to").font(.system(size: 12))
                    if snapshot {
                        Text(effective + " ⌄").font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                    } else {
                        Picker("Default account", selection: Binding(get: { effective }, set: {
                            if store.setDefaultCalendarAccount($0) { tick += 1 }
                        })) {
                            ForEach(connected, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
            }
            ForEach(connected, id: \.self) { email in account(email, all: all) }
            HStack {
                Button(google.busy ? "Waiting for sign-in in your browser…" : "Connect Google account…") { google.connect() }
                    .disabled(!google.isConfigured || google.busy)
                if let s = google.status { Text(s).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private func account(_ email: String, all: [CalCalendar]) -> some View {
        let mine = CalendarSettings.calendars(of: email, in: all)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                Text(email).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Remove…") {
                    if ConnectFlow.confirmTwice("Remove \(email)?",
                        "FloatBoard stops adding tasks to this calendar and making Meet links with it. Events already made stay.",
                        action: "Remove") { google.remove(email); tick += 1 }
                }
            }
            if CalendarSettings.needsReconnect(account: email, calendars: all) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 11))
                    if snapshot {
                        Text("Reconnect to show your calendars").font(.system(size: 12)).foregroundStyle(Color.accentColor)
                    } else {
                        Button("Reconnect to show your calendars") { google.connect(loginHint: email) }
                            .buttonStyle(.link).font(.system(size: 12))
                            .disabled(!google.isConfigured || google.busy)
                    }
                }
                .padding(.leading, 22)
            }
            ForEach(mine, id: \.calendarID) { c in
                HStack(spacing: 8) {
                    Circle().fill(Color(hex: c.color)).frame(width: 9, height: 9)
                    Text(c.name).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    if snapshot {
                        Capsule().fill(c.shown ? Color.accentColor : Color.primary.opacity(0.2)).frame(width: 26, height: 14)
                            .overlay(Circle().fill(.white).padding(2), alignment: c.shown ? .trailing : .leading)
                    } else {
                        Toggle(c.name, isOn: Binding(get: { c.shown }, set: { on in
                            if CalendarCache(store: store).setShown(account: email, calendarID: c.calendarID, on) {
                                tick += 1
                                NotificationCenter.default.post(name: .floatBoardCalendarNow, object: nil)
                            }
                        }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                }
                .padding(.leading, 22)
            }
        }
    }
}
