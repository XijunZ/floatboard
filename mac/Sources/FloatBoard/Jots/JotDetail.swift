import FloatBoardConnectors
import FloatBoardCore
import SwiftUI

/// One jot, editable (J14): its text (right-click a selection for Make task / Make decision / Copy id link, J7), tags and
/// Claude's suggestions (J5), what it belongs to (a task's notes, a meeting), Clean up (J6), history and Delete.
/// Edits save a moment after typing stops and when leaving the jot; each save keeps the previous text in the history.
struct JotDetail: View {
    let jotID: Int64
    let onDelete: (Jot) -> Void
    @EnvironmentObject var store: Store
    @EnvironmentObject var ui: UIState
    @State private var text = ""
    @State private var saved = ""
    @State private var loaded = false
    @State private var showHistory = false
    @State private var cleanup: CleanupProposal?
    @State private var working = false
    @State private var problem: String?

    private var js: JotStore { JotStore(store: store) }

    var body: some View {
        if let jot = js.jot(jotID) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    IDChip(id: jot.shortID).font(.system(size: 12, weight: .semibold))
                    Text(jot.kind.title + " · " + jot.source.title).foregroundStyle(.secondary)
                    Spacer()
                    Text("Added \(Fmt.withTime(jot.added))" + (jot.updated > jot.added.addingTimeInterval(1) ? " · updated \(Fmt.withTime(jot.updated))" : ""))
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 11))
                belongsTo(jot)
                ScrollView {
                    SelectableTextEditor(text: $text, source: jot.shortID, fontSize: 13)
                        .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
                .frame(minHeight: 180, maxHeight: .infinity)
                JotTagRow(jotID: jotID)
                LinkChips(item: jot.shortID)
                if let p = problem { Text(p).font(.system(size: 11)).foregroundStyle(.red) }
                HStack(spacing: 14) {
                    Button { Task { await askCleanup() } } label: { Label(working ? "Cleaning up…" : "Clean up", systemImage: "wand.and.stars") }
                        .disabled(working || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || JotsAI.client(store: store) == nil)
                        .help(JotsAI.client(store: store) == nil ? "Needs an engine with your Claude key (Settings › Mode)." : "Claude fixes grammar and structure only; you compare before choosing")
                    Button { save(); showHistory.toggle() } label: { Label("History (\(js.history(jotID).count))", systemImage: "clock.arrow.circlepath") }
                        .disabled(js.history(jotID).isEmpty)
                        .popover(isPresented: $showHistory, arrowEdge: .top) { JotHistoryView(jotID: jotID) { v in restore(v) } }
                    Spacer()
                    Button(role: .destructive) { save(); js.delete(jotID); onDelete(jot) } label: { Label("Delete", systemImage: "trash") }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
            }
            .onAppear { if !loaded { text = jot.text; saved = jot.text; loaded = true } }
            .onDisappear { save() }
            .onChange(of: jot.text) { _, new in if new != saved && text == saved { text = new; saved = new } }   // changed elsewhere (phone, task editor)
            .task(id: text) {
                try? await Task.sleep(for: .seconds(1)) // try?-ok: cancelled when typing continues; the next pause saves
                if !Task.isCancelled { save() }
            }
            .sheet(item: $cleanup) { p in
                CleanupSheet(proposal: p) { use in
                    if use { text = p.cleaned; save() }
                    cleanup = nil
                }
            }
        }
    }

    private func save() {
        guard loaded, text != saved, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if js.update(jotID, text: text) { saved = text }
    }

    private func restore(_ v: JotVersion) {
        save()
        js.restore(jotID, to: v)
        text = v.text; saved = v.text
        showHistory = false
    }

    private func askCleanup() async {
        save()
        guard let client = JotsAI.client(store: store) else { return }
        working = true; problem = nil
        defer { working = false }
        do {
            let cleaned = try await client.cleanupJot(saved)
            cleanup = CleanupProposal(original: saved, cleaned: cleaned)
        } catch {
            problem = "Couldn't clean up: " + ((error as? ConnectorError)?.description ?? "\(error)")
        }
    }

    /// What the jot belongs to: a task (task note), a meeting (meeting notes), with the meeting suggestion to confirm.
    @ViewBuilder private func belongsTo(_ jot: Jot) -> some View {
        if jot.kind == .taskNote, let tid = js.taskID(ofNote: jot.id) {
            let task = store.item(ShortID(kind: .task, number: tid))
            HStack(spacing: 6) {
                Image(systemName: "checklist").foregroundStyle(.secondary)
                Text("Notes of T-\(tid) · \(task?.title ?? "")").lineLimit(1)
                if task?.deleted == true { Text("task deleted").italic().foregroundStyle(.secondary) }
            }
            .font(.system(size: 12))
        }
        if jot.kind == .meetingNotes, let info = js.meetingInfo(jot.id) {
            let events = store.itemLinks(of: jot.shortID).filter { $0.other.kind == .event }
            VStack(alignment: .leading, spacing: 4) {
                if let l = events.first, let e = CalendarCache(store: store).kept(shortID: l.other.number) {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar").foregroundStyle(.secondary)
                        Text("\(l.madeBy == .suggested ? "Is this" : "Notes of") \(l.other.text) · \(e.title) · \(Fmt.withTime(e.start))\(l.madeBy == .suggested ? "?" : "")")
                            .lineLimit(1)
                        if l.madeBy == .suggested {
                            Button("Confirm") { js.confirmMeeting(jot.id, event: l.other.number) }.controlSize(.small)
                            Button { store.unlinkWithUndo(jot.shortID, l.other) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Not this meeting")
                        } else {
                            Text(info.matchedBy == "link" ? "matched by the call link" : info.matchedBy == "time" ? "matched by time and guests" : "")
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    Label("Not attached to a meeting yet. Type its E-number in the notes (e.g. E-41) to attach them.", systemImage: "calendar.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                }
                if let u = URL(string: info.meta.fathomURL), !info.meta.fathomURL.isEmpty {
                    Button { NSWorkspace.shared.open(u) } label: { Label("Open in Fathom", systemImage: "arrow.up.forward.square") }.buttonStyle(.link)
                }
            }
            .font(.system(size: 12))
        }
    }
}

/// The jot's tags (the first is primary) with ✕ and +, then Claude's suggestions as ✓/✗ chips (J5).
struct JotTagRow: View {
    let jotID: Int64
    @EnvironmentObject var store: Store
    @State private var refusal: String?

    var body: some View {
        let id = ShortID(kind: .jot, number: jotID)
        let tags = store.itemTags(id).all
        let suggestions = JotSuggestions(store: store).open(jotID).filter { s in !tags.contains { $0.caseInsensitiveCompare(s) == .orderedSame } }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Tags").foregroundStyle(.secondary)
                if tags.isEmpty { Text("untagged").italic().foregroundStyle(.tertiary) }
                ForEach(tags, id: \.self) { t in
                    HStack(spacing: 3) {
                        Circle().fill(store.color(t)).frame(width: 7, height: 7)
                        Text(t)
                        Button { set(tags.filter { $0 != t }) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                            .buttonStyle(.borderless).help("Remove this tag")
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                Menu {
                    ForEach(store.tags.map(\.name).filter { !tags.contains($0) }, id: \.self) { n in Button(n) { set(tags + [n]) } }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).fixedSize().help("Add a tag")
            }
            if !suggestions.isEmpty {
                HStack(spacing: 6) {
                    Label("Claude suggests", systemImage: "sparkles").foregroundStyle(.secondary)
                    ForEach(suggestions, id: \.self) { s in
                        HStack(spacing: 4) {
                            Text(s)
                            Button { JotSuggestions(store: store).accept(jotID, s) } label: { Image(systemName: "checkmark") }.buttonStyle(.borderless).help("Add \(s)")
                            Button { JotSuggestions(store: store).dismiss(jotID, s) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Not \(s)")
                        }
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3])))
                    }
                }
            }
            if let r = refusal { Text(r).foregroundStyle(.red) }
        }
        .font(.system(size: 12))
    }

    private func set(_ tags: [String]) { refusal = JotStore(store: store).setTags(jotID, tags) }
}

/// Earlier texts of a jot, newest first, each with Restore.
struct JotHistoryView: View {
    let jotID: Int64
    let restore: (JotVersion) -> Void
    @EnvironmentObject var store: Store

    var body: some View {
        let versions = Array(JotStore(store: store).history(jotID).reversed())
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Earlier versions").font(.system(size: 12, weight: .semibold))
                ForEach(Array(versions.enumerated()), id: \.offset) { _, v in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Replaced \(Fmt.withTime(v.at))").foregroundStyle(.secondary)
                            Spacer()
                            Button("Restore") { restore(v) }.controlSize(.small)
                        }
                        Text(v.text).lineLimit(6).textSelection(.enabled)
                    }
                    .font(.system(size: 11))
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                }
            }
            .padding(12)
        }
        .frame(width: 380, height: 320)
    }
}

/// Claude's cleaned text next to the owner's (J6).
struct CleanupProposal: Identifiable {
    let id = UUID()
    let original: String
    let cleaned: String
}

/// Before and after side by side; what of the original the cleaned text lacks is listed in red; "Use cleaned" or "Keep mine".
struct CleanupSheet: View {
    let proposal: CleanupProposal
    let done: (Bool) -> Void

    var body: some View {
        let missing = CleanupGuard.missing(original: proposal.original, cleaned: proposal.cleaned)
        VStack(alignment: .leading, spacing: 10) {
            Text("Clean up").font(.system(size: 14, weight: .semibold))
            Text("Claude fixed grammar and structure only. Your text stays in the jot's history either way.").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 10) {
                side("Yours", proposal.original)
                side("Cleaned", proposal.cleaned)
            }
            if !missing.isEmpty {
                Label("The cleaned text leaves out: " + missing.joined(separator: ", "), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Keep mine") { done(false) }.keyboardShortcut(.cancelAction)
                Button("Use cleaned") { done(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 720, height: 460)
    }

    private func side(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).textCase(.uppercase)
            ScrollView { Text(text).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading) }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The engine that runs Jots' Claude jobs: an online engine first, else the one on this Mac.
@MainActor enum JotsAI {
    static func client(store: Store) -> ConnectorClient? {
        let list = store.connectors.sorted { ($0.id == LocalMode.connectorID ? 1 : 0) < ($1.id == LocalMode.connectorID ? 1 : 0) }
        for info in list { if let c = ConnectorAccounts.client(for: info, store: store) { return c } }
        return nil
    }
}
