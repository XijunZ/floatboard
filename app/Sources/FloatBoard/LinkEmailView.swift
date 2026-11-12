import AppKit
import FloatBoardConnectors
import FloatBoardCore
import SwiftUI

/// "Link an email…" in the task editor: type, search the connected Gmail (subject, sender and date only), pick one.
/// Shown in place inside the editor (a separate sheet would close the editor's pop-up when clicked).
struct LinkEmailSearch: View {
    @EnvironmentObject var store: Store
    let cardID: Int64
    /// Called with the stored card after a link was made, or nil when cancelled.
    var done: (Card?) -> Void
    @State private var query = ""
    @State private var hits: [(connector: String, hit: EmailHit)] = []
    @State private var problems: [String] = []
    @State private var searching = false
    @State private var searched = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Link an email").font(.system(size: 12, weight: .semibold))
            HStack(spacing: 6) {
                TextField("Subject, sender or any words", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { Task { await search() } }
                Button("Search") { Task { await search() } }
                    .disabled(searching || query.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { done(nil) }
            }
            if searching { ProgressView().controlSize(.small) }
            ForEach(problems, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if searched && hits.isEmpty && !searching && error == nil { Text("No emails found.").font(.system(size: 11)).foregroundStyle(.secondary) }
            if !hits.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(hits, id: \.hit.id) { row in
                            Button { link(row.connector, row.hit) } label: { HitRow(hit: row.hit) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        .onAppear { focused = true }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !searching else { return }
        searching = true; error = nil; problems = []
        defer { searching = false; searched = true }
        let clients = store.connectors.compactMap { info in ConnectorAccounts.client(for: info, store: store).map { (info.id, $0) } }
        guard !clients.isEmpty else { hits = []; error = "Connect the email engine first (Connectors tab)."; return }
        var found: [(String, EmailHit)] = []
        var failures: [String] = []
        for (id, client) in clients {
            do {
                let r = try await client.searchEmails(q)
                found += r.results.map { (id, $0) }
                failures += r.errors.map { "Couldn't search \($0.account): \($0.error)" }
            } catch {
                let why = (error as? ConnectorError)?.description ?? error.localizedDescription
                failures.append("Couldn't search: \(why)")
                if (error as? ConnectorError) != .noEmailSearch {
                    store.activity("connector:\(id)", .warning, "Email search failed", detail: why)
                }
            }
        }
        hits = found.sorted { ($0.1.sentAt ?? "") > ($1.1.sentAt ?? "") }.map { (connector: $0.0, hit: $0.1) }
        problems = failures
    }

    private func link(_ connector: String, _ hit: EmailHit) {
        do {
            try store.linkEmail(cardID: cardID, connector: connector, email: hit.linked)
            ConnectorRunner.shared?.trigger("email linked")
            done(store.card(cardID))
        } catch {
            self.error = "\(error)"
        }
    }
}

/// One search result: subject, then sender and day.
private struct HitRow: View {
    let hit: EmailHit
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(hit.subject.isEmpty ? "(no subject)" : hit.subject).font(.system(size: 12, weight: .medium)).lineLimit(2)
            Text([sender, day].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Color.accentColor.opacity(0.15) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help(hit.account)
    }

    private var sender: String {
        let f = hit.from.trimmingCharacters(in: .whitespaces)
        guard let lt = f.firstIndex(of: "<") else { return f }
        let name = f[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        return name.isEmpty ? f : name
    }

    private var day: String {
        guard let s = hit.sentAt, let d = PhoneBoard.parseISO(s) else { return "" }
        return Fmt.short(d)
    }
}
