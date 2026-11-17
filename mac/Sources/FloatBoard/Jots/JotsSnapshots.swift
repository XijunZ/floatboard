import AppKit
import FloatBoardCore
import SwiftUI

/// Jots pictures for review (`FLOATBOARD_JOTSHOTS=1 … FloatBoard --snapshot <dir>`, scratch database only), light and dark,
/// with long and Chinese text.
@MainActor enum JotsSnapshots {
    static func run(dir: String, store: Store, ui: UIState, google: Google) {
        store.setModule(.jots, on: true)
        CalendarCache.connectedAccounts = nil
        let js = JotStore(store: store)
        let cal = AppTime.calendar, now = Date()
        let today = cal.startOfDay(for: now)
        let work = store.areas.first?.name ?? "Work"
        // A meeting today with a call link, its task, and Fathom's notes attached to it.
        let acct = "me@example.com", cache = CalendarCache(store: store)
        cache.upsertCalendars(account: acct, [CalCalendar(account: acct, calendarID: acct, name: "Work", color: "#4285f4", owned: true, shown: true, primary: true)])
        let ten = today.addingTimeInterval(10 * 3600), three = today.addingTimeInterval(15 * 3600)
        cache.apply(account: acct, calendarID: acct, changes: [
            GoogleEventChange(eventID: "s1", cancelled: false, fields: CalEventFields(start: ten, end: ten + 1800, title: "Weekly planning",
                              videoLink: "https://meet.google.com/abc-defg-hij", googleUpdated: now)),
            GoogleEventChange(eventID: "s2", cancelled: false, fields: CalEventFields(start: three, end: three + 3600, title: "Investor update call", googleUpdated: now))],
            nextToken: nil)
        store.add(title: "Send the revised budget to the team", area: work, importance: .high, due: nil)
        guard let task = store.cards.last, let ev = cache.event(account: acct, calendarID: acct, eventID: "s1") else { return }
        let tid = ShortID(kind: .task, number: task.id)
        store.setTags(tid, primary: work, others: [TagRules.investor])
        store.link(tid, ev.id, actor: .user)
        let notes = js.takeMeetingNotes("""
            ## Summary
            Agreed to move the offsite to March and to send the revised budget before Friday. Q1 hiring stays at two people.

            Action items:
            - Send the revised budget to the team (Sam)
            - Book the venue for March (Alex)

            https://fathom.video/share/example
            """, meta: MeetingMeta(recapKey: "fathom:example", fathomURL: "https://fathom.video/share/example",
                                   meetingURL: "https://meet.google.com/abc-defg-hij", title: "Weekly planning", scheduledStart: ten, received: ten + 3600),
            origin: "fathom:example", now: ten + 3600)
        var card = store.card(task.id) ?? task
        card.notes = "Numbers from finance arrive Thursday; check the travel line before sending."
        store.update(card)
        js.add("预算：周五之前把修订版发给团队，顺便确认三月的场地。", source: .phone, tags: [work], now: today.addingTimeInterval(8 * 3600))
        let long = js.add("""
            Thinking about the quarter: the board deck needs a clearer story. Lead with what changed since September (two new partners, \
            churn down), then the ask. Keep the appendix for the numbers. T-\(task.id) has the budget part. Call Ann about the intro \
            to her fund by 21 November.
            """, now: today.addingTimeInterval(9 * 3600))
        let untagged = js.add("Idea: a short weekly note to the team instead of the long Monday meeting", now: today.addingTimeInterval(-86400 + 7 * 3600))
        if let u = untagged { JotSuggestions(store: store).record(asked: [u.id], suggestions: [u.id: [work, "Personal"]]) }
        let ui2 = UIState()
        func shot<V: View>(_ v: V, _ name: String, _ size: CGSize) {
            for dark in [false, true] {
                let host = NSHostingView(rootView: v.environmentObject(store).environmentObject(ui2).environmentObject(google)
                    .frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = CGRect(origin: .zero, size: size)
                let w = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
                w.isReleasedWhenClosed = false
                w.appearance = host.appearance
                w.contentView = host
                w.setFrameOrigin(NSPoint(x: -30000, y: -30000))
                w.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        do { try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")) }
                        catch { store.activity("snapshot", .error, "Could not write \(name)", detail: "\(error)") }
                    }
                }
                w.close()
            }
        }
        shot(JotsTab(initial: long?.id).padding(12), "jots-tab", CGSize(width: 1000, height: 600))
        if let n = notes { shot(JotsTab(initial: n.id).padding(12), "jots-tab-meeting-notes", CGSize(width: 1000, height: 600)) }
        if let u = untagged { shot(JotDetail(jotID: u.id) { _ in }.padding(12), "jot-detail-suggestions", CGSize(width: 640, height: 420)) }
        if let note = js.taskNote(forTask: task.id) { shot(JotDetail(jotID: note.id) { _ in }.padding(12), "jot-detail-task-note", CGSize(width: 640, height: 380)) }
        let model = CaptureModel()
        model.text = "Ask Sam whether the venue can hold 40 people; 也要确认交通。"
        model.task = task.id
        shot(CaptureView(model: model, save: {}, close: {}), "capture-window", CGSize(width: 440, height: 210))
        let original = "call ann abt the intro to her fund by 21 nov, see T-\(task.id) and https://example.com/deck"
        shot(CleanupSheet(proposal: CleanupProposal(original: original, cleaned: "Call Ann about the introduction to her fund by 21 November.")) { _ in },
             "cleanup-before-after", CGSize(width: 720, height: 460))
        shot(EditCardView(draft: store.card(task.id) ?? task) {}, "task-editor-notes-and-meeting-notes", CGSize(width: 440, height: 720))
        shot(VStack(alignment: .leading) { JotsSettings() }.padding(12), "settings-jots", CGSize(width: 720, height: 170))
        print("JOTSHOTS written to \(dir)")
    }
}
