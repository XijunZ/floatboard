import FloatBoardCore
import SwiftUI

struct CardView: View {
    @EnvironmentObject var ui: UIState
    @EnvironmentObject var store: Store
    let card: Card
    @State private var hover = false
    @State private var editing = false

    private var searching: Bool { !ui.search.trimmingCharacters(in: .whitespaces).isEmpty }
    private var isMatch: Bool { searching && Search.matches(card, ui.search) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                Circle().fill(store.color(card.area)).frame(width: 8, height: 8).padding(.top, 4)
                Text(searching ? Search.highlighted(card.title, ui.search) : AttributedString(card.title))
                    .font(.system(size: 13, weight: .medium)).lineLimit(3)
                    .strikethrough(card.status == .done, color: .secondary)
                Spacer(minLength: 4)
                if let meet = card.meetingLink {
                    Button { NSWorkspace.shared.open(meet) } label: {
                        Label("Join", systemImage: "video.fill").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("Join call: \(meet.absoluteString)")
                } else if let other = card.otherLink {
                    Button { NSWorkspace.shared.open(other) } label: {
                        Label("Open", systemImage: "link").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("Open link: \(other.absoluteString)")
                }
                // Importance tag: monochrome "!" marks in an outlined capsule
                // (groups are filled, coloured pills, so the two don't look alike or clash).
                Text(card.importance.marks)
                    .font(.system(size: 11, weight: card.importance.weight, design: .rounded))
                    .frame(minWidth: 22)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(card.importance.color.opacity(0.6), lineWidth: 1))
                    .foregroundStyle(card.importance.color)
                    .contentShape(Rectangle())
                    // Click: Low → Medium → High → Low. Right-click: pick one.
                    .onTapGesture {
                        let all = Importance.allCases
                        let next = all[((all.firstIndex(of: card.importance) ?? 0) + 1) % all.count]
                        store.setImportance(card, next)
                    }
                    .contextMenu {
                        ForEach(Importance.allCases) { imp in
                            Button { store.setImportance(card, imp) } label: {
                                if imp == card.importance { Label(imp.title, systemImage: "checkmark") } else { Text(imp.title) }
                            }
                        }
                    }
                    .help("\(card.importance.title) importance: click to change, right-click to choose")
            }
            if !card.notes.isEmpty {
                Text(card.notes).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
            }
            if !card.aiSummary.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text("AI summary").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    Text(card.aiSummary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            FlowLayout(hSpacing: 10, vSpacing: 3) {
                Text(card.area)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(store.color(card.area).opacity(0.18)))
                    .foregroundStyle(store.color(card.area))
                    .contentShape(Capsule())
                    // Click: next group. Right-click: pick one.
                    .onTapGesture { store.setArea(card, store.shift(card.area, by: 1)) }
                    .contextMenu {
                        ForEach(store.areas) { a in
                            Button { store.setArea(card, a.name) } label: {
                                if a.name == card.area { Label(a.name, systemImage: "checkmark") } else { Text(a.name) }
                            }
                        }
                    }
                    .help("Click to change group (right-click to choose)")
                if card.showsSourceChip { ProposalChip(card: card) }
                if card.status == .watch, card.watchSince != nil {
                    // Time on Watch, updated every minute: green under 3 days, orange from 3 (chase reminders start), red from 7.
                    TimelineView(.periodic(from: .now, by: 60)) { ctx in
                        let wait = Watch.wait(card, now: ctx.date)
                        Label(Watch.line(card, now: ctx.date) ?? "", systemImage: "hourglass")
                            .foregroundStyle(wait == .late ? Color.red : wait == .chase ? Color.orange : Color.green)
                            .fixedSize()
                            .help((card.watchPerson.isEmpty ? "Waiting" : "Waiting on \(card.watchPerson)") + " since it went to Watch. "
                                  + (card.watchContact.isEmpty ? "No contact: it won't move back by itself when they reply. Add one in the task (double-click)."
                                     : "Moves back to To do when they reply (\(card.watchContact.hasPrefix("wa:") ? "on WhatsApp" : "by email")). A reminder every 3 days until then."))
                    }
                }
                Text("Added \(Fmt.short(card.created))").fixedSize()
                if let due = card.due {
                    Text("Due \(Fmt.due(due))")
                        .foregroundStyle(card.isOverdue ? Color.red : Color.secondary)
                        .fontWeight(card.isOverdue ? .semibold : .regular)
                        .fixedSize()
                }
                if let d = card.done { Text("Done \(Fmt.withTime(d))").fixedSize() }
                if !card.gcalAccount.isEmpty {
                    Button { if let u = URL(string: card.gcalLink) { NSWorkspace.shared.open(u) } } label: {
                        Image(systemName: "calendar.badge.checkmark")
                    }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .help("In Google Calendar (\(card.gcalAccount)). Click to open the event.")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)

            if hover {
                HStack(spacing: 2) {
                    if let p = card.status.prev {
                        BarButton("arrow.left", "Move to \(p.title)") { store.move(card, to: p) }
                    }
                    if let n = card.status.next {
                        BarButton(n == .done ? "checkmark" : "arrow.right", "Move to \(n.title)") { store.move(card, to: n) }
                    }
                    if card.status == .todo || card.status == .doing {
                        BarButton("eye", "Move to Watch (waiting on someone else)") { store.move(card, to: .watch) }
                    }
                    Spacer()
                    if card.due != nil { CalendarMenu(card: card) }
                    BarButton("pencil", "Edit") { editing = true }
                    DeleteControl(card: card)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(isMatch ? Color.accentColor.opacity(0.14)
                  : UrgencyStyle.fill(card.urgency, neutral: Color.primary.opacity(hover ? 0.10 : 0.06))))
        .overlay {
            if !isMatch {
                if card.urgency == .overdue {
                    RoundedRectangle(cornerRadius: 7).strokeBorder(UrgencyStyle.ringColor, style: UrgencyStyle.ringStyle)
                } else if let tint = UrgencyStyle.tint(card.urgency) {
                    RoundedRectangle(cornerRadius: 7).strokeBorder(tint, lineWidth: 1)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(isMatch ? Color.accentColor : Color.clear, lineWidth: ui.currentMatch == card.id && isMatch ? 3.5 : 2))
        .id(card.id)
        .opacity(searching && !isMatch ? 0.3 : 1)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { if isMatch { ui.searchCommitted = true }; editing = true }
        .draggable(String(card.id))
        .contextMenu {
            ForEach(Status.allCases.filter { $0 != card.status }) { s in
                Button("Move to \(s.title)") { store.move(card, to: s) }
            }
            Divider()
            Button("Edit…") { editing = true }
            if card.teachOnDelete {
                Menu("Delete") { ConnectorDeleteChoices(card: card) }
            } else {
                Button("Delete") { store.deleteCard(card, verdict: nil) }
            }
        }
        .popover(isPresented: $editing, arrowEdge: .trailing) {
            EditCardView(draft: card) { editing = false }
        }
    }
}

/// "Deleted “…” · Undo" at the bottom of the board for 8 seconds after a delete (Edit → Undo Delete works after).
struct UndoDeleteBar: View {
    @EnvironmentObject var store: Store

    var body: some View {
        if let d = store.lastDeleted, d.barShown {
            HStack(spacing: 10) {
                Image(systemName: "trash").foregroundStyle(.secondary)
                Text("Deleted “\(d.title)”").lineLimit(1).truncationMode(.tail)
                Button("Undo") { store.undoDelete() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .help("Bring the task back (also Edit → Undo Delete, ⌥⌘Z)")
                Button { store.dismissUndoBar(for: d) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
            .shadow(radius: 6, y: 2)
            .padding(.bottom, 16)
            .frame(maxWidth: 520)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: d.at) {
                try? await Task.sleep(for: .seconds(8)) // try?-ok: cancelled when another delete replaces this bar
                if !Task.isCancelled { withAnimation { store.dismissUndoBar(for: d) } }
            }
        }
    }
}

/// Text with its web addresses turned into clickable links.
enum LinkedText {
    static func make(_ s: String) -> AttributedString {
        var out = AttributedString(s)
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return out } // try?-ok: no detector = plain text
        for m in det.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let url = m.url, let r = Range(m.range, in: s), let ar = Range(r, in: out) else { continue }
            out[ar].link = url
        }
        return out
    }
}


/// Trash button; a card made by the email sorting offers "teach" choices so the sorting learns from the delete.
struct DeleteControl: View {
    @EnvironmentObject var store: Store
    let card: Card

    var body: some View {
        if !card.teachOnDelete {
            BarButton("trash", "Delete") { store.deleteCard(card, verdict: nil) }
        } else {
            Menu {
                ConnectorDeleteChoices(card: card)
            } label: {
                Image(systemName: "trash").font(.system(size: 11, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Delete")
        }
    }
}
