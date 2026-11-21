import FloatBoardConnectors
import FloatBoardCore
import SwiftUI

/// The Jots tab (J4): one list, newest first, grouped by day, with today's meetings at the top of Today; search, filter by
/// tag and kind, sort by date added, date updated or tag. The selected jot opens on the right.
struct JotsTab: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var ui: UIState
    @State private var query = JotQuery()
    @State private var selected: Int64?
    @State private var deleted: Jot?
    /// The jot selected when the tab first shows (pictures).
    var initial: Int64? = nil

    var body: some View {
        let rows = JotStore(store: store).list(query)
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                header
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if showMeetings { TodaysMeetings(selected: $selected) }
                        ForEach(groups(rows), id: \.0) { day, items in
                            Text(day).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).textCase(.uppercase)
                                .padding(.top, 8).padding(.leading, 4)
                            ForEach(items) { r in
                                JotRowView(row: r, selected: selected == r.id) { selected = r.id }
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 1.5)
                                        .opacity(ui.reveals.item == ShortID(kind: .jot, number: r.id) ? 1 : 0))   // shown from search (round 37)
                                    .id(r.id)
                            }
                        }
                        if rows.isEmpty {
                            Text(isFiltered ? "No jots match." : "No jots yet. Press ⌃⌥J anywhere, or ✎ on the bar, to write one.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 20)
                        }
                    }
                    .padding(.bottom, 40)
                }
                // A jot shown from search (round 37): scrolled into view and outlined; it opens only on Enter or a click.
                .onAppear { if let id = ui.reveals.item, id.kind == .jot { proxy.scrollTo(id.number, anchor: .center) } }
                .onChange(of: ui.reveals.item) { _, id in if let id, id.kind == .jot { proxy.scrollTo(id.number, anchor: .center) } }
                }
            }
            .frame(width: 330)
            .padding(.trailing, 10)
            Divider()
            Group {
                if let id = selected, let jot = JotStore(store: store).jot(id), !jot.deleted {
                    JotDetail(jotID: id) { d in deleted = d; selected = nil }.id(id)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "note.text").font(.system(size: 28)).foregroundStyle(.tertiary)
                        Text("Select a jot, or press ⌃⌥J to write one.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .overlay(alignment: .bottom) { if let d = deleted { UndoJotDeleteBar(jot: d) { deleted = nil } } }
        .onAppear { if selected == nil, let initial { selected = initial } }
        .onReceive(NotificationCenter.default.publisher(for: .floatBoardOpenJot)) { n in
            if let id = n.object as? Int64 { query = JotQuery(sort: query.sort); selected = id }
        }
    }

    private var isFiltered: Bool { !query.text.isEmpty || !query.tags.isEmpty || !query.kinds.isEmpty || query.untagged }
    private var showMeetings: Bool { query.sort == .added && !isFiltered }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search jots (words or J-12)", text: $query.text).textFieldStyle(.plain)
                    .leavesOnEsc()
                Button { CaptureController.shared?.show(task: nil) } label: { Label("New jot", systemImage: "square.and.pencil") }
                    .buttonStyle(.borderless).help("Write a jot (⌃⌥J)")
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
            HStack(spacing: 10) {
                Menu {
                    Button("All kinds") { query.kinds = [] }
                    Divider()
                    ForEach(JotKind.allCases, id: \.self) { k in
                        Button { toggle(k) } label: { Label(k.title, systemImage: query.kinds.contains(k) ? "checkmark" : "") }
                    }
                } label: { Text(query.kinds.isEmpty ? "All kinds" : query.kinds.map(\.title).sorted().joined(separator: ", ")) }
                .menuStyle(.borderlessButton).fixedSize()
                Menu {
                    Button("All tags") { query.tags = []; query.untagged = false }
                    Button { query.untagged.toggle(); if query.untagged { query.tags = [] } } label: {
                        Label("Untagged", systemImage: query.untagged ? "checkmark" : "")
                    }
                    Divider()
                    ForEach(store.tags.map(\.name), id: \.self) { t in
                        Button {
                            query.untagged = false
                            if query.tags.contains(t) { query.tags.remove(t) } else { query.tags.insert(t) }
                        } label: { Label(t, systemImage: query.tags.contains(t) ? "checkmark" : "") }
                    }
                } label: { Text(query.untagged ? "Untagged" : query.tags.isEmpty ? "All tags" : query.tags.sorted().joined(separator: ", ")) }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Menu {
                    ForEach(JotSort.allCases, id: \.self) { s in
                        Button { query.sort = s } label: { Label(s.title, systemImage: query.sort == s ? "checkmark" : "") }
                    }
                } label: { Label(query.sort.title, systemImage: "arrow.up.arrow.down") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            .font(.system(size: 11))
        }
    }

    private func toggle(_ k: JotKind) { if query.kinds.contains(k) { query.kinds.remove(k) } else { query.kinds.insert(k) } }

    /// Day headers in the app's zone ("Today", "Yesterday", "Mon 10 Nov"); by tag when sorted by tag.
    private func groups(_ rows: [JotRow]) -> [(String, [JotRow])] {
        var out: [(String, [JotRow])] = []
        for r in rows {
            let key: String
            switch query.sort {
            case .tag: key = r.tags.primary ?? "untagged"
            case .updated: key = Self.dayLabel(r.jot.updated)
            case .added: key = Self.dayLabel(r.jot.added)
            }
            if out.last?.0 == key { out[out.count - 1].1.append(r) } else { out.append((key, [r])) }
        }
        return out
    }

    static func dayLabel(_ d: Date, now: Date = Date()) -> String {
        let cal = AppTime.calendar
        if cal.isDate(d, inSameDayAs: now) { return "Today" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "Yesterday" }
        let f = DateFormatter(); f.calendar = cal; f.timeZone = AppTime.zone; f.locale = Locale(identifier: "en_GB")
        f.dateFormat = cal.isDate(d, equalTo: now, toGranularity: .year) ? "EEE d MMM" : "EEE d MMM yyyy"
        return f.string(from: d)
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter(); f.timeZone = AppTime.zone; f.locale = Locale(identifier: "en_GB"); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

/// One jot in the list: its first lines, the time, kind and tags ("untagged" when none).
struct JotRowView: View {
    let row: JotRow
    let selected: Bool
    let open: () -> Void
    @EnvironmentObject var store: Store

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.jot.text.trimmingCharacters(in: .whitespacesAndNewlines)).lineLimit(3).font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(JotsTab.time(row.jot.added)).monospacedDigit()
                    if row.jot.kind != .jot { Label(row.jot.kind.title, systemImage: row.jot.kind == .meetingNotes ? "person.2" : "checklist").labelStyle(.titleAndIcon) }
                    if row.jot.source == .phone { Image(systemName: "iphone").help("Written on the phone") }
                    if row.untagged {
                        Text("untagged").italic().foregroundStyle(.tertiary)
                    } else {
                        ForEach(row.tags.all, id: \.self) { t in
                            HStack(spacing: 3) { Circle().fill(store.color(t)).frame(width: 6, height: 6); Text(t) }
                        }
                    }
                    if !JotSuggestions(store: store).open(row.id).isEmpty { Image(systemName: "sparkles").help("Claude suggested tags") }
                }
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.035)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Today's meetings at the top of Today: each with its meeting notes when they have come, else "No notes yet".
struct TodaysMeetings: View {
    @Binding var selected: Int64?
    @EnvironmentObject var store: Store

    var body: some View {
        let cal = AppTime.calendar
        let start = cal.startOfDay(for: Date())
        let meetings = CalendarCache(store: store).meetings(from: start, to: start.addingTimeInterval(86400)).filter { !$0.allDay }
        if !meetings.isEmpty {
            Text("Today's meetings").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).textCase(.uppercase).padding(.leading, 4)
            ForEach(meetings, id: \.shortID) { e in
                let notes = JotStore(store: store).meetingNotes(forEvent: e.shortID).first
                Button { if let n = notes { selected = n.id } } label: {
                    HStack(spacing: 6) {
                        Text(JotsTab.time(e.start)).monospacedDigit().foregroundStyle(.secondary)
                        Text(e.title).lineLimit(1)
                        Spacer(minLength: 4)
                        if let n = notes { Label(n.shortID.text, systemImage: "doc.text").foregroundStyle(.secondary) }
                        else { Text("No notes yet").foregroundStyle(.tertiary) }
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(notes == nil)
            }
        }
    }
}

/// "Deleted J-14 · Undo" for 8 seconds after a delete (J14).
struct UndoJotDeleteBar: View {
    let jot: Jot
    let done: () -> Void
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash").foregroundStyle(.secondary)
            Text("Deleted \(jot.shortID.text)").lineLimit(1)
            Button("Undo") { JotStore(store: store).undoDelete(jot.id); done() }.buttonStyle(.borderedProminent).controlSize(.small)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
        .shadow(radius: 6, y: 2)
        .padding(.bottom, 16)
        .task(id: jot.id) {
            try? await Task.sleep(for: .seconds(8)) // try?-ok: cancelled when another delete replaces this bar
            if !Task.isCancelled { done() }
        }
    }
}

extension Notification.Name {
    /// Opens a jot in the Jots tab (object: the jot's number).
    static let floatBoardOpenJot = Notification.Name("floatBoardOpenJot")
}
