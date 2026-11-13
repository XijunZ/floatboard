import AppKit
import FloatBoardConnectors
import FloatBoardCore
import SwiftUI

/// "Archive old data to this Mac…": saves an engine's old change log and old email task records to a file beside the
/// backups, then has the engine remove exactly those rows (EngineArchive).
struct ArchiveSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let info: ConnectorInfo
    @State private var months = EngineArchive.defaultMonths
    @State private var running = false
    @State private var handled = 0
    @State private var outcome: EngineArchive.Outcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Archive old data to this Mac").font(.system(size: 15, weight: .semibold))
            Text("Saves \(info.name)'s old change log and old email task records to a file on this Mac, then removes them from the engine to free space.")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Text("Your board doesn't change. The last 3 months and tasks still open are always kept, so an email never becomes a task twice.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Archive data older than", selection: $months) {
                ForEach(EngineArchive.cutOffChoices, id: \.self) { m in Text(m == 12 ? "1 year" : "\(m) months").tag(m) }
            }
            .pickerStyle(.segmented)
            .disabled(running)
            if running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(handled == 0 ? "Archiving…" : "Archiving… \(EngineArchive.count(handled)) entries").font(.system(size: 12))
                }
            }
            if let outcome {
                Label(outcome.message, systemImage: outcome.problem == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(outcome.problem == nil ? Color.green : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                if let file = shownFile {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
                Spacer()
                Button(outcome == nil ? "Cancel" : "Done") { dismiss() }.disabled(running)
                Button("Archive…") {
                    let span = months == 12 ? "1 year" : "\(months) months"
                    guard ConnectFlow.confirmTwice("Remove data older than \(span) from the engine?",
                        "It is saved to a file on this Mac first, and only removed from the engine once the file checks out. This can't be undone from FloatBoard.",
                        action: "Archive") else { return }
                    Task { await archive() }
                }
                .disabled(running)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    /// The file, when one was written (also after a failure that kept it).
    private var shownFile: URL? {
        guard let dir = LocalData.archives else { return nil }
        let file = outcome?.file ?? EngineArchive.fileURL(dir: dir, connector: info.id, now: Date())
        return outcome != nil && FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    private func archive() async {
        let component = "connector:\(info.id)"
        guard let client = ConnectorAccounts.client(for: info, store: store) else {
            outcome = .init(problem: "This connection has no address or key. Reconnect it first.")
            return
        }
        guard let dir = LocalData.archives else {
            outcome = .init(problem: "There's no folder to archive into on this Mac (FloatBoard is using a test database).")
            return
        }
        running = true; handled = 0; outcome = nil
        let before = EngineArchive.cutOff(months: months, now: Date())
        let out = await EngineArchive.run(client: client, connector: info.id, before: before, dir: dir) { n in
            Task { @MainActor in handled = n }
        }
        running = false
        outcome = out
        if let problem = out.problem {
            store.activity(component, .warning, "Archive of old engine data stopped", detail: out.saved > 0 ? out.message : problem)
        } else if out.saved > 0 {
            store.activity(component, .info, "Archived old engine data to this Mac", detail: out.message)
        }
        NotificationCenter.default.post(name: .floatBoardSyncConnectors, object: nil) // refreshes the database size
    }
}
