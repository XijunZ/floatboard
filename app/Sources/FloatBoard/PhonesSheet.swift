import FloatBoardConnectors
import FloatBoardCore
import SwiftUI

/// "Paired phones…": the phones signed in to this engine's phone app, each with Disconnect (signs it out and stops its
/// notifications; the setup page's Remove does the same).
struct PhonesSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let info: ConnectorInfo
    @State private var phones: [ConnectorClient.PairedPhone] = []
    @State private var loading = false
    @State private var error: String?
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paired phones").font(.system(size: 15, weight: .semibold))
            Text("Phones signed in to \(info.name)'s phone app. Disconnect signs a phone out and stops its notifications; pair it again to use it.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if loading && phones.isEmpty {
                ProgressView().controlSize(.small)
            } else if phones.isEmpty && error == nil {
                Text("No phones paired.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(phones) { p in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "iphone").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).font(.system(size: 12, weight: .medium))
                        Text(detail(p)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Disconnect…") { disconnect(p) }.disabled(loading)
                }
            }
            if let notice { Label(notice, systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green) }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 420)
        .task { await load() }
    }

    private func detail(_ p: ConnectorClient.PairedPhone) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        var s = p.lastSeen.map { "Last used \(f.string(from: $0))" } ?? "Not used yet"
        if p.sharesPasskey > 0 { s += " · shares its passkey with \(p.sharesPasskey) other device\(p.sharesPasskey == 1 ? "" : "s")" }
        return s
    }

    private func load() async {
        loading = true; defer { loading = false }
        guard let client = ConnectorAccounts.client(for: info, store: store) else {
            error = "This connection has no address or key. Reconnect it first."; return
        }
        do { phones = try await client.phones(); error = nil } catch {
            self.error = "Couldn't get the list of phones. \((error as? ConnectorError)?.description ?? error.localizedDescription)"
        }
    }

    private func disconnect(_ p: ConnectorClient.PairedPhone) {
        guard ConnectFlow.confirmTwice("Disconnect \(p.name)?",
            "It is signed out of the FloatBoard phone app and gets no more notifications. Your board doesn't change. To use it again, pair it from this Mac.",
            action: "Disconnect") else { return }
        Task {
            loading = true; defer { loading = false }
            guard let client = ConnectorAccounts.client(for: info, store: store) else { return }
            do {
                let name = try await client.removePhone(id: p.id)
                notice = "\(name) disconnected."; error = nil
                store.activity("connector:\(info.id)", .info, "Disconnected phone \(name)")
                phones = (try? await client.phones()) ?? phones.filter { $0.id != p.id } // try?-ok: the list just refreshes less
            } catch {
                self.error = "Couldn't disconnect \(p.name). \((error as? ConnectorError)?.description ?? error.localizedDescription)"
            }
        }
    }
}
