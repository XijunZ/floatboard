import AppKit
import FloatBoardCore
import SwiftUI

/// Settings › Areas › Jots: the daily nudge (on, time) and the daily files (on, folder).
struct JotsSettings: View {
    @EnvironmentObject var store: Store
    @State private var nudge = JotNudgeSettings()
    @State private var files = DailyFilesSettings()
    @State private var loaded = false

    var body: some View {
        SettingsBlock(title: "Jots", help: "A daily nudge to jot something (skipped on days you already wrote one; on your phone when this Mac didn't show it), and a Markdown copy of each day's jots in a folder.") {
            HStack(spacing: 8) {
                Toggle("Daily nudge at", isOn: $nudge.on).toggleStyle(.checkbox)
                Picker("", selection: Binding(get: { nudge.minutes / 60 }, set: { nudge.minutes = $0 * 60 + nudge.minutes % 60 })) {
                    ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }.labelsHidden().frame(width: 64).disabled(!nudge.on)
                Text(":")
                Picker("", selection: Binding(get: { nudge.minutes % 60 }, set: { nudge.minutes = nudge.minutes / 60 * 60 + $0 })) {
                    ForEach([0, 15, 30, 45], id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }.labelsHidden().frame(width: 64).disabled(!nudge.on)
            }
            HStack(spacing: 8) {
                Toggle("Daily files in", isOn: $files.on).toggleStyle(.checkbox)
                TextField("Folder", text: $files.folder).textFieldStyle(.roundedBorder).frame(maxWidth: 380).disabled(!files.on)
                Button("Choose…") { choose() }.disabled(!files.on)
            }
            Text("One file per day (YYYY-MM-DD.md), rewritten by FloatBoard when that day's jots change.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .onAppear { nudge = JotNudge(store: store).settings; files = DailyFiles(store: store).settings; loaded = true }
        .onChange(of: nudge) { _, n in if loaded && n != JotNudge(store: store).settings { JotNudge(store: store).save(n) } }
        .onChange(of: files) { _, f in if loaded && f != DailyFiles(store: store).settings { DailyFiles(store: store).save(f) } }
    }

    private func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.directoryURL = files.url
        if p.runModal() == .OK, let u = p.url { files.folder = (u.path as NSString).abbreviatingWithTildeInPath }
    }
}
