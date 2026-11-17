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
    /// The task as the pop-up opened (with its due as the fields show it): only fields changed from this are saved.
    @State private var opened: Card?
    @State private var replyDraftRefusal: String?
    /// "Link an email…" search shown in place; and why a link change was refused.
    @State private var linkingEmail = false
    @State private var linkRefusal: String?
    /// Size of the pop-up, set by dragging its corner (remembered).
    @AppStorage("editorWidth") private var width: Double = 420
    @AppStorage("editorExtraHeight") private var extraHeight: Double = 0
    @State private var dragStart: (w: Double, h: Double)?
    /// The task's tags other than its group, as the pop-up opened and as edited (saved with the task).
    @State private var openedTags: [String] = []
    @State private var otherTags: [String] = []

    /// Saves only the fields the user changed since the pop-up opened (`opened`); everything else is taken from the card as
    /// stored now, so a title, time or Meet link that Google sent meanwhile is kept (and not sent back as a newer edit).
    private func save() {
        finished = true
        guard !draft.title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        draft.due = hasDue ? Due.combine(day: day, time: hasTime ? time : nil) : nil
        draft.dueHasTime = hasDue && hasTime
        guard let saved = store.card(draft.id) else { return }
        let base = opened ?? saved
        if draft.watchPerson != base.watchPerson || draft.watchContact != base.watchContact,
           saved.watchPerson != draft.watchPerson || saved.watchContact != draft.watchContact {
            store.setWatch(saved, person: draft.watchPerson, contact: draft.watchContact)
        }
        guard let current = store.card(draft.id) else { return }
        let merged = Card.editorSave(opened: base, edited: draft, current: current)
        opened = draft   // the editor may stay open (Draft reply): later changes are measured from here
        if merged != current { store.update(merged) }
        // Other tags: saved when changed here (the group is saved above, as before).
        if otherTags != openedTags, let now = store.card(draft.id) {
            store.setTags(ShortID(kind: .task, number: draft.id), primary: now.area, others: otherTags)
            openedTags = otherTags
        }
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

    /// The notes field: editable text with the selection actions; "Jot about this" next to it while Jots is on (J8).
    private var notesEditor: some View {
        let note = store.isOn(.jots) ? JotStore(store: store).taskNote(forTask: draft.id) : nil
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("Notes").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                if let note { Text(note.shortID.text).font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit().help("These notes are jot \(note.shortID.text)") }
                Spacer()
                if store.isOn(.jots) {
                    Button { save(); finished = false; CaptureController.shared?.show(task: draft.id) } label: { Label("Jot about this", systemImage: "square.and.pencil") }
                        .buttonStyle(.borderless).font(.system(size: 11)).help("Write a jot linked to this task, with its tags")
                }
            }
            ScrollView {
                SelectableTextEditor(text: $draft.notes, source: note?.shortID ?? ShortID(kind: .task, number: draft.id))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            }
            .frame(minHeight: 54, maxHeight: CGFloat(130 + extraHeight / 2))
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $draft.title).textFieldStyle(.roundedBorder)
            // Notes are the task's note jot once they reach 10 characters (Jots J10): selectable, with Make task / Make decision /
            // Copy id link on right-click (the source is the note jot when there is one).
            notesEditor
            TaskMeetingNotes(taskID: draft.id, maxHeight: CGFloat(110 + extraHeight / 2))
            if !draft.aiSummary.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("From the email or meeting (AI)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    // Grows with the pop-up: drag the corner down to read more.
                    // Selectable, with Make task / Copy id link on right-click; grows with the pop-up.
                    ScrollView { SelectableText(attributed: LinkedText.make(draft.aiSummary), source: ShortID(kind: .task, number: draft.id)) }
                        .frame(maxWidth: .infinity, maxHeight: CGFloat(110 + extraHeight / 2), alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }
            TextField("Link: a call (Meet, Zoom, Teams) or any web page (optional)", text: $draft.link)
                .textFieldStyle(.roundedBorder)
            if draft.status == .watch { waitingOn }
            TagEditor(primary: $draft.area, others: $otherTags)
            HStack(spacing: 8) {
                Text("Importance").foregroundStyle(.secondary)
                Dropdown(options: Importance.allCases, selection: $draft.importance, title: \.label)
            }
            .font(.system(size: 12))
            HStack { DueFields(hasDue: $hasDue, day: $day, hasTime: $hasTime, time: $time) }
            HStack(spacing: 14) {
                if hasDue {
                    // Uses the date/time as currently set here, even before Save.
                    CalendarMenu(card: pending, labeled: true) { account in
                        draft.gcalAccount = account
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
            LinkedMeetings(taskID: draft.id)
            LinkChips(item: ShortID(kind: .task, number: draft.id), except: [.event])
            GoalPicker(item: ShortID(kind: .task, number: draft.id))
            emailSection
            if replyDraftCard.canDraftReply { replyDraftSection }
            VStack(alignment: .leading, spacing: 2) {
                IDChip(id: ShortID(kind: .task, number: draft.id))
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
            if opened == nil {
                opened = draft
                openedTags = store.itemTags(ShortID(kind: .task, number: draft.id)).others
                otherTags = openedTags
            }
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

