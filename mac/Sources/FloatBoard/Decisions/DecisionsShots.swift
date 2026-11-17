import AppKit
import FloatBoardCore
import SwiftUI

/// Dev aid: `FLOATBOARD_DECISIONSHOTS=1 FloatBoard --snapshot <dir>` (scratch database only) draws the Decisions screens in
/// light and dark with made-up data, long and Chinese text included.
@MainActor enum DecisionsShots {
    static func run(dir: String, store: Store, ui: UIState, google: Google) {
        guard LocalData.isScratchDatabase else { return }
        DecisionsArea.registerCore()
        WeeklyReviewRows.views[DecisionReviews.recordedSection] = { AnyView(DecisionReviewRow(item: $0, kind: .recorded)) }
        WeeklyReviewRows.views[DecisionReviews.maybeSection] = { AnyView(DecisionReviewRow(item: $0, kind: .maybe)) }
        WeeklyReviewRows.views[DecisionReviews.reviewsSection] = { AnyView(DecisionReviewRow(item: $0, kind: .review)) }
        store.setModule(.jots, on: true); store.setModule(.decisions, on: true)
        let now = Date()
        let js = JotStore(store: store), ds = DecisionStore(store: store), ps = PeopleStore(store: store)
        let anna = ps.create(name: "Anna Example")
        _ = ps.create(name: "李明")
        let work = store.areas.first?.name ?? "Personal"
        guard let notes = js.create(text: "Board call. We decided to move the offsite to March because the venue was double booked. Anna Example will tell the team.",
                                    kind: .meetingNotes, source: .meeting, now: now.addingTimeInterval(-2 * 86400)),
              let old = js.create(text: "Agreed with the team to stop the weekly newsletter and send a monthly digest instead.", now: now.addingTimeInterval(-40 * 86400)),
              let zh = js.create(text: "和李明确认：我们决定明年春天在上海开设第二个办公室，因为客户大多在那里。", now: now.addingTimeInterval(-86400)) else { return }
        store.setTags(notes.shortID, primary: work, others: [])
        store.setTags(old.shortID, primary: work, others: [])
        let screened = ds.record(DecisionDraft(text: "Move the offsite to March", quote: "We decided to move the offsite to March because the venue was double booked.",
                                               why: "the venue was double booked", type: .strategic, foundByClaude: true, source: .claude, sourceItem: notes.shortID), now: now)
        let digest = ds.record(DecisionDraft(text: "Stop the weekly newsletter; send a monthly digest", quote: "stop the weekly newsletter and send a monthly digest instead",
                                             expected: "Fewer unsubscribes and less work each week", confidence: .medium, type: .operational,
                                             sourceItem: old.shortID), now: now.addingTimeInterval(-39 * 86400))
        _ = ds.record(DecisionDraft(text: "明年春天在上海开设第二个办公室，这是一个很长的决定标题，用来检查换行和截断是否正常显示", quote: "我们决定明年春天在上海开设第二个办公室",
                                    why: "客户大多在那里", type: .investment, foundByClaude: true, source: .claude, sourceItem: zh.shortID), now: now)
        _ = ds.record(DecisionDraft(text: "Maybe hire a second designer", quote: "maybe we could hire a second designer", type: .strategic, status: .maybe,
                                    foundByClaude: true, source: .claude, sourceItem: notes.shortID), now: now)
        if let s = screened, let a = anna { ds.suggest(s.id, kind: .tell, target: a.shortID, text: "Tell Anna Example the offsite moved to March") }
        if let s = screened, let d = digest { ds.suggest(s.id, kind: .supersedes, target: d.shortID) }
        DecisionsUI.shared.selected = screened?.id

        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            shot(DecisionsTab().padding(12), "decisions-tab\(suffix).png", CGSize(width: 1000, height: 640), dark: dark, store: store, ui: ui, google: google, dir: dir)
            shot(MakeDecisionForm(request: MakeDecisionRequest(selection: "We decided to move the offsite to March because the venue was double booked.",
                                                               source: notes.shortID)) {},
                 "decisions-make\(suffix).png", CGSize(width: 460, height: 440), dark: dark, store: store, ui: ui, google: google, dir: dir)
            if let d = digest {
                shot(DecisionReviewSheet(decisionID: d.id) {}, "decisions-review\(suffix).png", CGSize(width: 560, height: 470), dark: dark,
                     store: store, ui: ui, google: google, dir: dir)
            }
            shot(WeeklyReviewView {}, "decisions-weekly-review\(suffix).png", CGSize(width: 520, height: 420), dark: dark, store: store, ui: ui, google: google, dir: dir)
        }
        DecisionsUI.shared.selected = ds.all().first { $0.text.hasPrefix("明年") }?.id
        shot(DecisionsTab().padding(12), "decisions-tab-chinese.png", CGSize(width: 1000, height: 640), dark: false, store: store, ui: ui, google: google, dir: dir)
    }

    /// Drawn by an off-screen window, as the app lays it out, in light or dark.
    private static func shot<V: View>(_ v: V, _ name: String, _ size: CGSize, dark: Bool, store: Store, ui: UIState, google: Google, dir: String) {
        let host = NSHostingView(rootView: v.environmentObject(store).environmentObject(ui).environmentObject(google)
            .frame(width: size.width, height: size.height).background(dark ? Color(white: 0.12) : Color(white: 0.97))
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
        defer { w.close() }
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do { try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name)) } catch {
            store.activity("snapshot", .error, "Could not write the snapshot image \(name)", detail: "\(error)")
        }
    }
}
