import FloatBoardConnectors
import FloatBoardCore
import AppKit
import SwiftUI

extension Notification.Name {
    /// Ask the connector runner to sync now (after adding a connector, saving settings, or "Sync now").
    static let floatBoardSyncConnectors = Notification.Name("FloatBoardSyncConnectors")
}

/// What the Connectors tab and the bar say about a connector's health.
@MainActor
enum ConnectorHealth {
    static let unreadableStatus = "Couldn't read this connector's status"
    /// Status texts already reported as unreadable (per connector), so each bad status is logged once.
    private static var reportedUnreadable: [String: String] = [:]

    /// The connector's saved status; nil when it hasn't synced yet or the saved status can't be read (logged once per change).
    static func status(_ info: ConnectorInfo, store: Store) -> ConnectorStatus? {
        guard !info.statusJSON.isEmpty, info.statusJSON != "{}" else { return nil }
        do {
            let s = try JSONDecoder().decode(ConnectorStatus.self, from: Data(info.statusJSON.utf8))
            reportedUnreadable[info.id] = nil
            return s
        } catch {
            if reportedUnreadable[info.id] != info.statusJSON {
                reportedUnreadable[info.id] = info.statusJSON
                store.activity("connector:\(info.id)", .warning, unreadableStatus, detail: "\(error)")
            }
            return nil
        }
    }

    static func statusUnreadable(_ info: ConnectorInfo, store: Store) -> Bool {
        !info.statusJSON.isEmpty && info.statusJSON != "{}" && status(info, store: store) == nil
    }

    static func time(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? Fmt.clock(d) : Fmt.withTime(d)
    }

    static func statusLine(_ info: ConnectorInfo, waiting: Int) -> String {
        if let since = info.unreachableSince {
            return "Unreachable since \(time(since)) — changes are kept and will send when it's back"
        }
        let queued = waiting == 1 ? "1 change waiting to send" : "\(waiting) changes waiting to send"
        guard let ok = info.lastOK else { return "Not synced yet · \(queued)" }
        var line = "Last synced \(time(ok)) · \(queued) · engine using your settings v\(info.engineSettingsVersion)"
        if info.engineSettingsVersion < info.settingsVersion { line += " (v\(info.settingsVersion) waiting to send)" }
        return line
    }
}

/// Adding a connector from a connect link: confirm the address with the user, then save it.
@MainActor
enum ConnectFlow {
    /// Returns true when the connector was added.
    @discardableResult
    static func confirmAndAdd(_ link: URL, store: Store) -> Bool {
        guard let parts = ConnectLink.parse(link) else {
            store.activity("connectors", .warning, "Ignored a connect link that isn't valid",
                           detail: "Needs an https:// address (or http://localhost) and a key.")
            alert("This connect link can't be used",
                  "It needs an https:// address (or http://localhost for one running on this Mac) and a key. Copy it again from the connector's setup page.")
            return false
        }
        let address = Self.address(parts.url)
        let name = parts.name // already reduced to a plain one-line label by ConnectLink.parse
        let id = ConnectLink.id(forName: name)
        let replaced = store.connectors.first {
            $0.id == id && !$0.baseURL.isEmpty && !ConnectorInfo.sameAddress($0.baseURL, parts.url.absoluteString)
        }
        let a = NSAlert()
        a.messageText = "Connect “\(name)”?"
        var info = "Address: \(address)\n\nIt will suggest tasks for your board and hear back what you do with them. Only join addresses you trust."
        let current = store.connectors.filter { !$0.baseURL.isEmpty }.map { "“\($0.name)” (\(Self.address(URL(string: $0.baseURL))))" }
        if !current.isEmpty { info += "\n\nCurrently connected: " + current.joined(separator: ", ") + "." }
        if let replaced {
            info += "\n\nThis REPLACES “\(replaced.name)” at \(Self.address(URL(string: replaced.baseURL))). Its tasks stay on your board."
                + " Unsent changes and your settings (including what FloatBoard has learned about you) will go to the new address."
        }
        a.informativeText = info
        let join = a.addButton(withTitle: "Join")
        let cancel = a.addButton(withTitle: "Cancel")
        if replaced != nil {
            // Return must not confirm a replacement, so Join loses it. Cancel keeps Escape: a button has only one key
            // equivalent, and giving Cancel Return would take Escape away from it.
            join.keyEquivalent = ""
            cancel.keyEquivalent = "\u{1b}"
        }
        NSApp.activate()
        guard a.runModal() == .alertFirstButtonReturn else { return false }
        do {
            try ConnectorAccounts.add(id: id, name: name, baseURL: parts.url, key: parts.key, store: store)
        } catch {
            store.activity("connector:\(id)", .error, "Could not add \(name)", detail: "\(error)")
            alert("Couldn't add \(name)", "\(error)")
            return false
        }
        NotificationCenter.default.post(name: .floatBoardSyncConnectors, object: nil)
        return true
    }

    /// "https://host" or "http://localhost:8787": scheme, host and any port, taken from the URL itself.
    static func address(_ url: URL?) -> String {
        guard let url, let host = url.host else { return url?.absoluteString ?? "" }
        return "\(url.scheme ?? "https")://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    static func alert(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        NSApp.activate()
        a.runModal()
    }
}

/// Connectors tab: the online services that suggest tasks, plus Google Calendar.
struct ConnectorsView: View {
    @EnvironmentObject var store: Store
    @State private var pasted = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connectors").font(.system(size: 13, weight: .semibold))
                    Text("A connector suggests tasks for your board and hears back what you did with them. The board works on its own without any.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if store.connectors.isEmpty {
                        Text("No connectors yet.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(store.connectors) { ConnectorCard(info: $0) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add a connector").font(.system(size: 13, weight: .semibold))
                    HStack {
                        TextField("Paste a connect link (floatboard://connect?…)", text: $pasted)
                            .textFieldStyle(.roundedBorder).frame(width: 420)
                        Button("Add…") {
                            let link = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                            if let u = URL(string: link), ConnectFlow.confirmAndAdd(u, store: store) { pasted = "" }
                            else if URL(string: link) == nil { ConnectFlow.alert("That isn't a link", "Copy the connect link from the connector's setup page.") }
                        }
                        .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("The connector's setup page gives you this link; its “Connect to FloatBoard” button opens it directly.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Copy diagnostics") { DiagnosticsCopy.copy(store: store) }
                    Text("Copies a support summary (no keys, email text or task titles) to paste to whoever is helping.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Divider()
                WithdrawnList()
                Divider()
                AccountsView()
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.bottom, 20)
        }
    }
}

/// One connector: status, actions and its settings.
struct ConnectorCard: View {
    @EnvironmentObject var store: Store
    let info: ConnectorInfo
    @State private var settingsOpen = false
    @State private var pairing = false
    @ObservedObject private var rechecks = RecheckState.shared

    private var recheckMenu: some View {
        Menu {
            ForEach([7, 14, 30], id: \.self) { d in
                Button("Re-check the last \(d) days…") { confirmRecheck(days: d) }
            }
        } label: { Text(rechecks.active.contains(info.id) ? "Re-checking…" : "Re-check") }
        .disabled(rechecks.active.contains(info.id))
        .fixedSize()
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

    var body: some View {
        let status = ConnectorHealth.status(info, store: store)
        let host = URL(string: info.baseURL)?.host ?? info.baseURL
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: info.unreachableSince == nil ? "bolt.horizontal.circle" : "bolt.horizontal.circle.fill")
                    .foregroundStyle(info.unreachableSince == nil ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.name).font(.system(size: 12, weight: .semibold))
                    Text(host.isEmpty ? "No address saved" : host).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open setup page") {
                    if let u = URL(string: info.baseURL)?.appendingPathComponent("setup") { NSWorkspace.shared.open(u) }
                }
                .disabled(info.baseURL.isEmpty)
                Button("Pair a phone…") { pairing = true }
                    .disabled(info.baseURL.isEmpty)
                Button("Sync now") { NotificationCenter.default.post(name: .floatBoardSyncConnectors, object: nil) }
                recheckMenu
                Button("Remove…", role: .destructive) { remove() }
            }
            Text(ConnectorHealth.statusLine(info, waiting: store.waitingCount(connector: info.id)))
                .font(.system(size: 11))
                .foregroundStyle(info.unreachableSince == nil ? Color.secondary : Color.orange)
            if ConnectorHealth.statusUnreadable(info, store: store) {
                Label(ConnectorHealth.unreadableStatus, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            ForEach(status?.needsAttention ?? [], id: \.self) { m in
                Label(m, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            DisclosureGroup("Settings", isExpanded: $settingsOpen) {
                ConnectorSettingsForm(info: info, schema: status?.schema ?? [])
                    .padding(.top, 6)
            }
            .font(.system(size: 12))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .sheet(isPresented: $pairing) { PairPhoneSheet(info: info).environmentObject(store) }
    }

    private func remove() {
        let a = NSAlert()
        a.messageText = "Remove \(info.name)?"
        a.informativeText = "FloatBoard stops syncing with it and forgets its key. Its tasks and their history stay on your board, and your settings for it (rules, group descriptions, lists and learned preferences) are kept: they come back if you connect it again."
        a.addButton(withTitle: "Remove"); a.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do { try ConnectorAccounts.remove(id: info.id, store: store) } catch {
            store.activity("connector:\(info.id)", .error, "Could not remove \(info.name)", detail: "\(error)")
            ConnectFlow.alert("Couldn't remove \(info.name)", "\(error)")
        }
    }
}

/// Every card an engine took off the board, whatever connector it came from (even a removed one), each restorable.
struct WithdrawnList: View {
    @EnvironmentObject var store: Store
    @State private var open = false
    var body: some View {
        let withdrawn = store.withdrawnCards
        if !withdrawn.isEmpty {
            DisclosureGroup("Show withdrawn (\(withdrawn.count))", isExpanded: $open) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(withdrawn) { c in
                        HStack {
                            Text(c.title).font(.system(size: 11)).lineLimit(1)
                            Spacer()
                            Button("Restore") { store.restoreWithdrawn(c.id) }
                        }
                    }
                }
                .padding(.top, 4)
            }
            .font(.system(size: 12))
        }
    }
}
