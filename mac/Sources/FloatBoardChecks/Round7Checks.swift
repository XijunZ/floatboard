import Foundation
import FloatBoardCore
import FloatBoardConnectors

/// Round 7 of the Codex review (codex-review-5.md): conflicts with Google are decided by value, then newest wins.
@MainActor func codexRound7Checks(setup: (String) throws -> (Store, CalendarCache, CalendarOutbox), at: (Int, Int, Int) -> Date) async {
    let acct = "me@example.com"
    let old = Date().addingTimeInterval(-86400)
    let now = Date()
    func ago(_ s: Double) -> Date { now.addingTimeInterval(-s) }

    /// A plain event 10:00-11:00; `queue` patches queued at given times; Google moves the start to 10:30 at `googleAt`.
    func run(_ name: String, googleAt: Date, queue: [(start: Date?, end: Date?, at: Date)]) async throws -> (StatefulEvent, CalendarOutbox) {
        let (store, cache, outbox) = try setup(name)
        cache.apply(account: acct, calendarID: acct, changes: [GoogleEventChange(eventID: name, cancelled: false,
            fields: CalEventFields(start: at(10, 0, 0), end: at(11, 0, 0), title: "Call", googleUpdated: old))], nextToken: nil)
        let server = StatefulEvent(id: name, title: "Call", start: at(10, 0, 0), end: at(11, 0, 0), updated: old)
        var edited = false
        for q in queue {
            if !edited && googleAt < q.at { server.externalEdit(start: at(10, 30, 0), at: googleAt); edited = true }
            _ = outbox.enqueue(.patch(eventID: name, title: nil, start: q.start, end: q.end, allDayStart: nil), account: acct, calendarID: acct, now: q.at)
        }
        if !edited { server.externalEdit(start: at(10, 30, 0), at: googleAt) }
        await CalendarSender(store: store, apiFor: { _ in server.api() }, isOnline: { true }).drain()
        return (server, outbox)
    }
    func report(_ name: String, _ s: StatefulEvent, _ want: (Date, Date)) -> Bool {
        let ok = s.start == want.0 && s.end == want.1
        if !ok { print("  \(name): server \(s.start) - \(s.end)") }
        return ok
    }

    // R7-1, Codex's trace: 12:00-13:00 queued, Google moves the start to 10:30, then 14:00-15:00 queued. The second move is
    // newer than Google's change: it is sent whole (the first move's end-only write must not make Google's start look newer).
    do {
        let (s, o) = try await run("r7-between", googleAt: ago(20), queue: [(at(12, 0, 0), at(13, 0, 0), ago(30)), (at(14, 0, 0), at(15, 0, 0), ago(10))])
        check(report("r7 between", s, (at(14, 0, 0), at(15, 0, 0))) && o.rows(unsent: true).isEmpty, "r7_google_edit_between_queued_moves_newer_move_wins")
    } catch { check(false, "r7 between: \(error)") }

    // Google's change after both moves were queued: Google's start wins over both; the board's last end stays.
    do {
        let (s, o) = try await run("r7-after", googleAt: ago(5), queue: [(at(12, 0, 0), at(13, 0, 0), ago(30)), (at(14, 0, 0), at(15, 0, 0), ago(10))])
        check(report("r7 after", s, (at(10, 30, 0), at(15, 0, 0))) && o.rows(unsent: true).isEmpty, "r7_google_edit_after_queued_moves_google_start_wins")
    } catch { check(false, "r7 after: \(error)") }

    // An end-only change (a resize), then a move; Google's start change came between them: the move is newer and is sent.
    do {
        let (s, _) = try await run("r7-endonly", googleAt: ago(20), queue: [(nil, at(11, 30, 0), ago(30)), (at(13, 0, 0), at(14, 0, 0), ago(10))])
        check(report("r7 end-only", s, (at(13, 0, 0), at(14, 0, 0))), "r7_end_only_write_updates_only_the_end_baseline")
    } catch { check(false, "r7 end-only: \(error)") }

    // An end-only change queued before Google's start change: the start stays Google's, the end is the board's.
    do {
        let (s, _) = try await run("r7-endonly2", googleAt: ago(10), queue: [(nil, at(11, 30, 0), ago(30))])
        check(report("r7 end-only 2", s, (at(10, 30, 0), at(11, 30, 0))), "r7_end_only_change_keeps_googles_start")
    } catch { check(false, "r7 end-only 2: \(error)") }
}
