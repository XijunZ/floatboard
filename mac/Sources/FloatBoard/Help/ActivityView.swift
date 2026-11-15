import AppKit
import FloatBoardCore
import SwiftUI

extension Notification.Name {
    /// Open the Activity window (Help menu, bar warning).
    static let floatBoardShowActivity = Notification.Name("FloatBoardShowActivity")
}

/// Copies a support dump to the clipboard (Connectors tab and Activity window).
@MainActor
enum DiagnosticsCopy {
    static func copy(store: Store) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let text = Diagnostics.json(store: store, backups: Backups.forEnvironment(), appVersion: version)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        store.activity("diagnostics", .info, "Copied diagnostics to the clipboard")
    }
}

/// Help → Activity…: everything the app did and every problem it hit, newest first.
struct ActivityView: View {
    @EnvironmentObject var store: Store
    @State private var rows: [ActivityEntry] = []
    @State private var level: ActivityLevel?
    @State private var component = "All"
    @State private var selected: Int?
    @State private var tracing = false

    private var components: [String] { ["All"] + Array(Set(rows.map(\.component))).sorted() }
    private var shown: [(Int, ActivityEntry)] {
        rows.enumerated().filter { _, e in
            (level == nil || e.level == level) && (component == "All" || e.component == component)
        }.map { ($0.offset, $0.element) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !store.healthProblems.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Needs attention").font(.system(size: 12, weight: .semibold))
                    ForEach(store.healthProblems, id: \.id) { p in
                        HStack {
                            Label(p.message, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange)
                            Spacer()
                            Button("Dismiss") { Health.acknowledge(p.id, store: store) }
                                .controlSize(.small).help("Hide this from the bar until it changes or goes away")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                Divider()
            }
            HStack(spacing: 10) {
                Picker("Show", selection: $level) {
                    Text("All levels").tag(ActivityLevel?.none)
                    Text("Problems").tag(ActivityLevel?.some(.error))
                    Text("Warnings").tag(ActivityLevel?.some(.warning))
                    Text("Info").tag(ActivityLevel?.some(.info))
                }.frame(width: 150)
                Picker("From", selection: $component) { ForEach(components, id: \.self) { Text($0).tag($0) } }.frame(width: 190)
                Spacer()
                Button("Show trace") { tracing = true }.disabled(pickedRow?.trace == nil)
                Button("Copy row") { copyRow() }.disabled(pickedRow == nil)
                Button("Copy diagnostics") { DiagnosticsCopy.copy(store: store); reload() }
            }
            .padding(10)
            Divider()
            List(selection: $selected) {
                ForEach(shown, id: \.0) { idx, e in row(e).tag(idx) }
            }
            .listStyle(.plain)
            if shown.isEmpty { Text("Nothing here.").foregroundStyle(.secondary).padding() }
        }
        .frame(minWidth: 720, minHeight: 420)
        .onAppear { open() }
        .onReceive(NotificationCenter.default.publisher(for: .floatBoardShowActivity)) { _ in open() }
        .sheet(isPresented: $tracing) { TraceSheet(entries: pickedRow?.trace.map { store.trace($0) } ?? []) }
    }

    private var pickedRow: Optional<ActivityEntry> { selected.flatMap { $0 < rows.count ? rows[$0] : nil } }

    private func open() {
        reload()
        store.markActivitySeen(upTo: Date())
        _ = Health.refresh(store: store, backups: Backups.forEnvironment())   // errors just seen no longer count
    }

    private func reload() { rows = store.recentActivity(limit: 500) }

    private func copyRow() {
        guard let e = pickedRow else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ActivityView.text(e), forType: .string)
    }

    static func text(_ e: ActivityEntry) -> String {
        var s = "\(Fmt.withTime(e.at))  \(label(e.level))  \(e.component)  \(e.message)"
        if let d = e.detail { s += "\n\(d)" }
        if let t = e.trace { s += "\ntrace: \(t)" }
        return s
    }

    static func label(_ l: ActivityLevel) -> String { l == .error ? "problem" : l == .warning ? "warning" : "info" }

    private func row(_ e: ActivityEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: e.level == .error ? "xmark.octagon.fill" : e.level == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(e.level == .error ? Color.red : e.level == .warning ? Color.orange : Color.secondary)
                Text(Fmt.withTime(e.at)).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(e.component).font(.system(size: 11, weight: .medium))
                if !e.seen { Circle().fill(Color.blue).frame(width: 6, height: 6) }
            }
            Text(e.message).font(.system(size: 12))
            if let d = e.detail { Text(d).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3) }
        }
        .padding(.vertical, 2)
    }
}

/// All rows that share one trace id (a change followed from the board to the engine and back).
private struct TraceSheet: View {
    let entries: [ActivityEntry]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Everything with this trace, oldest first").font(.system(size: 13, weight: .semibold))
            List(Array(entries.enumerated()), id: \.offset) { _, e in
                Text(ActivityView.text(e)).font(.system(size: 11)).textSelection(.enabled)
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(14).frame(width: 620, height: 360)
    }
}
