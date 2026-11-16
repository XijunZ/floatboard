import FloatBoardCore
import SwiftUI

struct EditCardView: View {
    @EnvironmentObject var store: Store
    @State var draft: Card
    var close: () -> Void
    @State private var hasDue = false
    @State private var day = Date()
    @State private var hasTime = false
    @State private var time = Due.nextHour

    /// Set when the pop-up closed via Save, Cancel or Delete (so closing it doesn't save again).
    @State private var finished = false
    @State private var replyDraftRefusal: String?
    /// "Link an email…" search shown in place; and why a link change was refused.
    @State private var linkingEmail = false
    @State private var linkRefusal: String?
    /// Size of the pop-up, set by dragging its corner (remembered).
    @AppStorage("editorWidth") private var width: Double = 420
    @AppStorage("editorExtraHeight") private var extraHeight: Double = 0
    @State private var dragStart: (w: Double, h: Double)?

    private func save() {
        finished = true
        guard !draft.title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        draft.due = hasDue ? Due.combine(day: day, time: hasTime ? time : nil) : nil
        draft.dueHasTime = hasDue && hasTime
        if let saved = store.card(draft.id) {
            // Don't overwrite calendar info that may have been set while the pop-up was open.
            draft.gcalAccount = saved.gcalAccount.isEmpty ? draft.gcalAccount : saved.gcalAccount
            // Reply draft fields are changed by the app and the engine, never by this editor.
            draft.replyDraftState = saved.replyDraftState; draft.replyDraftLink = saved.replyDraftLink
            draft.replyDraftError = saved.replyDraftError; draft.replyDraftRequest = saved.replyDraftRequest
            draft.replyDraftSentAt = saved.replyDraftSentAt
            draft.watchSince = saved.watchSince
            if saved.watchPerson != draft.watchPerson || saved.watchContact != draft.watchContact {
                store.setWatch(saved, person: draft.watchPerson, contact: draft.watchContact)
                guard let fresh = store.card(draft.id) else { return }
                draft.watchPerson = fresh.watchPerson; draft.watchContact = fresh.watchContact
            }
        }
        guard store.card(draft.id).map({ $0 != draft }) ?? false else { return }
        store.update(draft)
    }

    /// The task as currently edited (unsaved), for calendar/Join actions.
    private var pending: Card {
        var c = draft
        c.due = hasDue ? Due.combine(day: day, time: hasTime ? time : nil) : nil
        c.dueHasTime = hasDue && hasTime
        return c
    }

    /// The stored card's reply draft state (the editor's own copy is a snapshot taken when it opened).
    private var replyDraftCard: Card { store.card(draft.id) ?? draft }

    private var notesEmpty: Bool { draft.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func requestReplyDraft() {
        replyDraftRefusal = nil
        guard !draft.title.trimmingCharacters(in: .whitespaces).isEmpty else { replyDraftRefusal = "Give the task a title first."; return }
        save()
        finished = false   // the editor stays open, so clicking away must still keep later edits
        do {
            try store.requestReplyDraft(cardID: draft.id)
            ConnectorRunner.shared?.trigger("reply draft")
        } catch {
            replyDraftRefusal = "\(error)"
        }
    }

    /// Draft reply button (cards made from an email) and the status of the latest request.
    @ViewBuilder private var replyDraftSection: some View {
        let card = replyDraftCard
        let waiting = card.replyDraftState == .requested
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                Button { requestReplyDraft() } label: {
                    Label(card.replyDraftState == .failed ? "Try again" : "Draft reply", systemImage: "arrowshape.turn.up.left")
                }
                .disabled(notesEmpty || waiting)
                .help(notesEmpty ? "Write what to say in Notes first." : "Turn your Notes into a reply draft")
                if notesEmpty && card.replyDraftState == nil {
                    Text("Write what to say in Notes first").foregroundStyle(.secondary)
                } else if card.replyDraftState == .ready, let u = URL(string: card.replyDraftLink) {
                    Text("Draft ready").foregroundStyle(.secondary)
                    Button { NSWorkspace.shared.open(u) } label: { Label("Open draft", systemImage: "arrow.up.forward.square") }
                } else if waiting {
                    Text("Drafting reply…").foregroundStyle(.secondary)
                } else if card.replyDraftState == .failed {
                    Text("Couldn't draft: \(card.replyDraftError)").foregroundStyle(.red)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let r = replyDraftRefusal { Text(r).foregroundStyle(.red) }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
    }

    /// The stored card's email link (the editor's copy is a snapshot): copied in after a link change, so Save never
    /// compares against stale link fields.
    private func takeLink(from c: Card) {
        draft.connector = c.connector; draft.source = c.source; draft.sourceKey = c.sourceKey; draft.sourceLink = c.sourceLink
        draft.sourceMeta = c.sourceMeta; draft.externalID = c.externalID
        draft.replyDraftState = c.replyDraftState; draft.replyDraftLink = c.replyDraftLink; draft.replyDraftError = c.replyDraftError
        draft.replyDraftRequest = c.replyDraftRequest; draft.replyDraftSentAt = c.replyDraftSentAt
    }

    /// Open email, "Link an email…" (a task with no email that the sorting did not make), "Remove email link" (one the
    /// user linked), and the search when it is open.
    @ViewBuilder private var emailSection: some View {
        let card = replyDraftCard
        if linkingEmail {
            LinkEmailSearch(cardID: draft.id) { linked in
                linkingEmail = false
                if let linked { takeLink(from: linked) }
            }
        } else if card.emailLink != nil || card.canLinkEmail || card.emailLinkedByUser {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 14) {
                    if let mail = card.emailLink {
                        Button { NSWorkspace.shared.open(mail) } label: { Label("Open email", systemImage: "envelope") }
                            .help(card.sourceMeta["subject"] ?? mail.absoluteString)
                    }
                    if card.canLinkEmail {
                        Button { linkRefusal = nil; linkingEmail = true } label: { Label("Link an email…", systemImage: "envelope.badge") }
                            .help("Find an email in your Gmail and attach it to this task")
                    }
                    if card.emailLinkedByUser {
                        Button {
                            linkRefusal = nil
                            do {
                                try store.unlinkEmail(cardID: draft.id)
                                if let c = store.card(draft.id) { takeLink(from: c) }
                                ConnectorRunner.shared?.trigger("email unlinked")
                            } catch { linkRefusal = "\(error)" }
                        } label: { Label("Remove email link", systemImage: "xmark.circle") }
                    }
                }
                if let r = linkRefusal { Text(r).foregroundStyle(.red) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
        }
    }

    /// Drag the bottom-right corner to make the pop-up wider or taller (Notes and the AI section grow).
    private var resizeGrip: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            .frame(width: 18, height: 18).contentShape(Rectangle())
            .padding(3)
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { g in
                    let start = dragStart ?? (width, extraHeight)
                    dragStart = start
                    width = min(1000, max(360, start.w + g.translation.width))
                    extraHeight = min(700, max(0, start.h + g.translation.height))
                }
                .onEnded { _ in dragStart = nil })
            .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
            .help("Drag to resize")
    }

    /// Watch: whom it waits on, and the email address whose reply moves it back (a WhatsApp chat is shown, not typed).
    private var waitingOn: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Waiting on").foregroundStyle(.secondary)
                TextField("Name", text: $draft.watchPerson).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                if draft.watchContact.hasPrefix("wa:") {
                    Label("WhatsApp chat", systemImage: "bubble.left.and.bubble.right").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Clear") { draft.watchContact = "" }.buttonStyle(.link).font(.system(size: 11))
                } else {
                    TextField("Their email, to notice the reply (optional)", text: Binding(
                        get: { draft.watchContact.hasPrefix("email:") ? String(draft.watchContact.dropFirst(6)) : "" },
                        set: { v in let t = v.trimmingCharacters(in: .whitespaces); draft.watchContact = t.isEmpty ? "" : "email:\(t)" }))
                        .textFieldStyle(.roundedBorder)
                }
            }
            if let line = Watch.line(draft) {
                Text(line + " · back to To do when they reply; a reminder every \(Watch.chaseDays) days until then")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $draft.title).textFieldStyle(.roundedBorder)
            TextField("Notes", text: $draft.notes, axis: .vertical)
                .lineLimit(3...(8 + Int(extraHeight / 16))).textFieldStyle(.roundedBorder)
            if !draft.aiSummary.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("From the email or meeting (AI)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    // Grows with the pop-up: drag the corner down to read more.
                    Text(LinkedText.make(draft.aiSummary)).font(.system(size: 12)).textSelection(.enabled)
                        .lineLimit(6 + Int(extraHeight / 15))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }
            TextField("Link: a call (Meet, Zoom, Teams) or any web page (optional)", text: $draft.link)
                .textFieldStyle(.roundedBorder)
            if draft.status == .watch { waitingOn }
            HStack(spacing: 8) {
                Text("Group").foregroundStyle(.secondary)
                Dropdown(options: store.areas.map(\.name), selection: $draft.area, dot: store.color)
                Text("Importance").foregroundStyle(.secondary).padding(.leading, 8)
                Dropdown(options: Importance.allCases, selection: $draft.importance, title: \.label)
            }
            .font(.system(size: 12))
            HStack { DueFields(hasDue: $hasDue, day: $day, hasTime: $hasTime, time: $time) }
            HStack(spacing: 14) {
                if hasDue {
                    // Uses the date/time as currently set here, even before Save.
                    CalendarMenu(card: pending, labeled: true) { account, ev in
                        draft.gcalAccount = account
                        draft.gcalLink = ev.htmlLink
                        if let meet = ev.meetLink, draft.link.trimmingCharacters(in: .whitespaces).isEmpty {
                            draft.link = meet
                        }
                    }
                }
                if let meet = pending.meetingLink {
                    Button { NSWorkspace.shared.open(meet) } label: { Label("Join call", systemImage: "video.fill") }
                        .help(meet.absoluteString)
                }
                if let other = pending.otherLink {
                    Button { NSWorkspace.shared.open(other) } label: { Label("Open link", systemImage: "link") }
                        .help(other.absoluteString)
                }
                if !draft.gcalAccount.isEmpty, let u = URL(string: draft.gcalLink) {
                    Button { NSWorkspace.shared.open(u) } label: { Label("Open event", systemImage: "arrow.up.forward.square") }
                        .help("In \(draft.gcalAccount)'s Google Calendar")
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            emailSection
            if replyDraftCard.canDraftReply { replyDraftSection }
            VStack(alignment: .leading, spacing: 2) {
                Text("Added \(Fmt.withTime(draft.created))")
                if let s = draft.started { Text("Started \(Fmt.withTime(s))") }
                if let d = draft.done { Text("Done \(Fmt.withTime(d))") }
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Delete", role: .destructive) { finished = true; store.deleteCard(draft, verdict: nil); close() }
                Spacer()
                Button("Cancel") { finished = true; close() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    save()
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: width)
        .overlay(alignment: .bottomTrailing) { resizeGrip }
        // Clicking away (or the board collapsing) closes the pop-up: keep the edits.
        .onDisappear { if !finished { save() } }
        .onAppear {
            hasDue = draft.due != nil
            if let d = draft.due {
                day = d
                hasTime = draft.dueHasTime
                if hasTime { time = d }
            }
        }
    }
}

/// "Due ☐ [date]  Time ☐ [hh:mm]": a due date, with an optional time for meetings.
struct DueFields: View {
    @Binding var hasDue: Bool
    @Binding var day: Date
    @Binding var hasTime: Bool
    @Binding var time: Date
    var nav: NavChain? = nil

    var body: some View {
        FocusCheck(label: "Due", isOn: $hasDue, nav: nav, navID: "due")
        if hasDue {
            DateInput(date: $day, nav: nav, navID: "date")
            FocusCheck(label: "Time", isOn: $hasTime, nav: nav, navID: "timeOn")
            if hasTime { TimeInput(time: $time, nav: nav, navID: "time") }
        }
    }
}

