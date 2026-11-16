import FloatBoardConnectors
import FloatBoardCore
import SwiftUI

/// The change log of one versioned part (your rules, WhatsApp rules, learned): newest first, what changed, who changed
/// it, and Restore. Restoring adds a new version; nothing is deleted.
struct InstructionsHistory: View {
    @EnvironmentObject var store: Store
    let info: ConnectorInfo
    let part: String
    /// For a rulebook: what an empty version means (the built-in text), so its changes read sensibly.
    var emptyMeans: String = ""
    @State private var open = false

    var body: some View {
        let versions = store.instructionVersions(connector: info.id, part: part)
        if versions.count > 0 {
            DisclosureGroup("History (\(versions.count) version\(versions.count == 1 ? "" : "s"))", isExpanded: $open) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(versions.enumerated()), id: \.element.id) { i, v in
                        let previous = i + 1 < versions.count ? versions[i + 1].text : ""
                        let (before, now) = (previous.isEmpty ? emptyMeans : previous, v.text.isEmpty ? emptyMeans : v.text)
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(Self.when(v.at)) · \(Self.who(v))" + (v.note.isEmpty ? "" : " · \(v.note)"))
                                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                                Text(v.source == .start ? "The text you had: \(Instructions.lines(now).count) line(s)"
                                     : v.text.isEmpty && !emptyMeans.isEmpty ? "Back to the built-in rulebook"
                                     : Instructions.summary(before, now))
                                    .font(.system(size: 11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            if i > 0 {
                                Button("Restore") { restore(v) }.controlSize(.small)
                            } else {
                                Text("Current").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                        if i + 1 < versions.count { Divider() }
                    }
                }
                .padding(.top, 4)
                .frame(maxWidth: 520, alignment: .leading)
            }
            .font(.system(size: 11))
        }
    }

    static func who(_ v: Instructions.Version) -> String {
        switch v.source {
        case .start: "before history was kept"
        case .you: "you"
        case .learning: "learned from your corrections"
        case .restore: "you restored"
        case .builtin: "built-in rulebook updated"
        }
    }

    static func when(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "d MMM yyyy, HH:mm"
        return f.string(from: d)
    }

    private func restore(_ v: Instructions.Version) {
        guard ConnectFlow.confirmTwice("Restore the version from \(Self.when(v.at))?",
                                       "It becomes the current text and is sent to the engine at the next sync. The current text stays in the history.",
                                       action: "Restore") else { return }
        do {
            try store.restoreInstructions(connector: info.id, version: v)
            NotificationCenter.default.post(name: .floatBoardSyncConnectors, object: nil)
        } catch {
            store.activity("instructions", .error, "Could not restore an earlier version", detail: "\(error)")
            ConnectFlow.alert("Couldn't restore it", "\(error)")
        }
    }
}
