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
    /// Called after the event is created, e.g. so the edit pop-up can show the new Meet link.
    var onAdded: (String, Google.CreatedEvent) -> Void = { _, _ in }
    @State private var working = false

    var body: some View {
        Menu {
            if !card.gcalAccount.isEmpty, let u = URL(string: card.gcalLink) {
                Button("Open in Google Calendar (\(card.gcalAccount))") { NSWorkspace.shared.open(u) }
                Divider()
            }
            if google.accounts.isEmpty {
                Button("Connect a Google account…") { ui.tab = .connectors }
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
            let icon = working ? "hourglass" : (card.gcalAccount.isEmpty ? "calendar.badge.plus" : "calendar.badge.checkmark")
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
        .disabled(working)
    }

    private func add(_ account: String, meet: Bool) {
        working = true
        Task {
            defer { working = false }
            do {
                let ev = try await google.createEvent(for: card, account: account, addMeet: meet)
                store.markInCalendar(card, account: account, event: ev)
                onAdded(account, ev)
            } catch {
                store.lastError = error.localizedDescription
                store.activity("google", .error, "Could not add the task to Google Calendar", detail: error.localizedDescription)
            }
        }
    }
}

/// Google accounts for adding tasks to Google Calendar, and the one-time Google Cloud set-up (Connectors tab).
struct AccountsView: View {
    @EnvironmentObject var google: Google
    var showAccounts = true
    @State private var clientID = ""
    @State private var secret = ""
    @State private var setupOpen = false

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 12) {
                if showAccounts {
                Text("Google Calendar (optional)").font(.system(size: 13, weight: .semibold))
                Text("Only for adding tasks to your calendar and Meet links. Off until you connect an account.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if google.accounts.isEmpty {
                    Text("No accounts connected yet.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(google.accounts, id: \.self) { email in
                    HStack {
                        Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                        Text(email).font(.system(size: 12))
                        Spacer()
                        Button("Remove") { google.remove(email) }
                    }
                    .frame(maxWidth: 520)
                }
                HStack {
                    Button(google.busy ? "Waiting for sign-in in your browser…" : "Connect Google account…") { google.connect() }
                        .disabled(!google.isConfigured || google.busy)
                    if let s = google.status { Text(s).font(.system(size: 11)).foregroundStyle(.secondary) }
                }

                }

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
                2. APIs & Services → Library → Google Calendar API → Enable.
                3. Google Auth Platform (OAuth consent screen) → Get started: app name FloatBoard, External, your email.
                4. Audience → Test users → add each Google account you'll connect.
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
