import FloatBoardCore
import SwiftUI

/// "Link a task…" / "Link a meeting…": type an id (T-142, E-37) or part of a title and pick. The ranking is `LinkPickerSearch`.
struct LinkPicker: View {
    /// What is being looked for: tasks (from an event's panel) or meetings (from a task's editor).
    let kind: ItemKind
    let exclude: Set<ShortID>
    let onPick: (ShortID) -> Void
    @EnvironmentObject var store: Store
    @State private var query = ""

    private var candidates: [LinkCandidate] {
        let now = Date()
        var events: [CalEvent] = []
        if kind == .event {
            let cache = CalendarCache(store: store)
            events = cache.events(from: now.addingTimeInterval(-30 * 86400), to: now.addingTimeInterval(60 * 86400))
            // A typed id may be outside that window: it still resolves.
            if let typed = ShortID.parse(query), typed.kind == .event, !events.contains(where: { $0.id == typed }),
               let e = cache.event(shortID: typed.number) { events.append(e) }
        }
        return LinkPickerSearch.candidates(kind: kind, cards: store.cards, events: events, query: query, now: now, exclude: exclude)
    }

    var body: some View {
        let found = candidates
        VStack(alignment: .leading, spacing: 8) {
            TextField(kind == .task ? "Type T-142 or part of a title" : "Type E-37 or part of a title", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if let first = found.first { onPick(first.id) } }
            if found.isEmpty {
                Text(query.isEmpty ? (kind == .task ? "No tasks to link." : "No meetings to link.") : "Nothing matches.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(found, id: \.id) { c in
                        Button { onPick(c.id) } label: {
                            HStack(spacing: 6) {
                                Text(c.id.text).monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                                if let s = c.start { Text(Fmt.meeting(s)).foregroundStyle(.secondary).fixedSize() }
                                Text(c.title).lineLimit(1).foregroundStyle(c.done ? .secondary : .primary)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .font(.system(size: 12))
        .padding(12)
        .frame(width: 320)
    }
}

/// A row in a "Linked …" list: the content, and a small × on hover that removes the link (never the item).
struct LinkedRow<Content: View>: View {
    let remove: () -> Void
    @ViewBuilder var content: Content
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            content
            Spacer(minLength: 0)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .opacity(hover ? 1 : 0)
                .allowsHitTesting(hover)   // hidden means not clickable either
                .accessibilityLabel("Remove link")
                .help("Remove the link (the item stays)")
        }
        .onHover { hover = $0 }
        .contextMenu { Button("Remove link", action: remove) }
    }
}

/// "Link a task…" / "Link a meeting…" button that opens the picker.
struct LinkButton: View {
    let kind: ItemKind
    let exclude: Set<ShortID>
    let onPick: (ShortID) -> Void
    @State private var open = false

    var body: some View {
        Button { open = true } label: { Label(kind == .task ? "Link a task…" : "Link a meeting…", systemImage: "link") }
            .buttonStyle(.borderless)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                LinkPicker(kind: kind, exclude: exclude) { open = false; onPick($0) }
            }
    }
}

/// The task editor's "Linked meetings": each as "E-37 · Thu 11:00 Title", then "Link a meeting…".
struct LinkedMeetings: View {
    let taskID: Int64
    @EnvironmentObject var store: Store

    var body: some View {
        let me = ShortID(kind: .task, number: taskID)
        let linked = store.links(of: me).filter { $0.kind == .event }
        let cache = CalendarCache(store: store)
        VStack(alignment: .leading, spacing: 4) {
            if !linked.isEmpty {
                Text("Linked meetings").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                ForEach(linked, id: \.self) { id in
                    LinkedRow(remove: { store.unlinkWithUndo(me, id) }) {
                        if let e = cache.event(shortID: id.number) {
                            (Text("\(id.text) · ").foregroundStyle(.secondary).monospacedDigit()
                             + Text(Fmt.meeting(e.start) + " ").foregroundStyle(.secondary)
                             + Text(e.title).foregroundStyle(e.cancelled ? .secondary : .primary))
                                .lineLimit(1)
                        } else {
                            Text(id.text).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
            LinkButton(kind: .event, exclude: Set(linked)) { store.link(me, $0, actor: .user) }
        }
        .font(.system(size: 12))
    }
}

/// The event panel's "Linked tasks": each with its checkbox, title and T-id, then "Link a task…".
struct LinkedTasksSlot: View {
    let event: CalEvent
    @EnvironmentObject var store: Store

    var body: some View {
        let me = event.id
        let linked = store.links(of: me).filter { $0.kind == .task }
        VStack(alignment: .leading, spacing: 4) {
            if !linked.isEmpty {
                Text("Linked tasks").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                ForEach(linked, id: \.self) { id in
                    LinkedRow(remove: { store.unlinkWithUndo(me, id) }) {
                        if let t = store.card(id.number) {
                            TaskCheck(task: t)
                            Text(t.title).lineLimit(1).strikethrough(t.status == .done)
                                .foregroundStyle(t.status == .done ? .secondary : .primary)
                            Text(id.text).monospacedDigit().foregroundStyle(.secondary).font(.system(size: 10)).fixedSize()
                        } else {
                            Text(id.text).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
            LinkButton(kind: .task, exclude: Set(linked)) { store.link(me, $0, actor: .user) }
        }
    }
}
