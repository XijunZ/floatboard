import Foundation
import FloatBoardCore
import FloatBoardConnectors

/// Round 6 of the Codex review (codex-review-4.md: C1, C4).
@MainActor func codexRound6Checks(setup: (String) throws -> (Store, CalendarCache, CalendarOutbox), at: (Int, Int, Int) -> Date,
                                  newTask: (Store, String, Date?, Bool) -> Int64, linkTask: (Store, Int64, String) -> Void) async {
    let acct = "me@example.com"
    let old = Date().addingTimeInterval(-86400)

    // C1. Two time moves queued offline (12:00-13:00, then 14:00-15:00); Google then moves only the start to 10:30. The first
    //     PATCH keeps Google's start and writes only the end, so it must acknowledge only the end: the second PATCH must still
    //     see Google's newer start and keep it.
    do {
        let (store, cache, outbox) = try setup("c1-partial-ack")
        let id = newTask(store, "Review", at(10, 0, 0), true)
        linkTask(store, id, "p1")
        cache.apply(account: acct, calendarID: acct, changes: [GoogleEventChange(eventID: "p1", cancelled: false,
            fields: CalEventFields(start: at(10, 0, 0), end: at(11, 0, 0), title: "Review", googleUpdated: old, fbCard: id))], nextToken: nil)
        let server = StatefulEvent(id: "p1", title: "Review", start: at(10, 0, 0), end: at(11, 0, 0), updated: old)
        if var c = store.card(id) { c.due = at(12, 0, 0); store.update(c, now: Date().addingTimeInterval(-3)) }
        if var c = store.card(id) { c.due = at(14, 0, 0); store.update(c, now: Date().addingTimeInterval(-2)) }
        server.externalEdit(start: at(10, 30, 0))
        await CalendarSender(store: store, apiFor: { _ in server.api() }, isOnline: { true }).drain()
        let ok = server.start == at(10, 30, 0) && server.end == at(15, 0, 0) && outbox.rows(unsent: true).isEmpty
        if !ok { print("  c1: server \(server.start) - \(server.end), unsent \(outbox.rows(unsent: true).count)") }
        check(ok, "c1_end_only_write_does_not_acknowledge_the_start")
    } catch { check(false, "c1: \(error)") }

    // C1. An acknowledgement saved before start and end were tracked apart (one "time" entry) still counts for both.
    do {
        let legacy = #"{"time":{"updated":100,"start":200,"end":300,"allDay":false}}"#
        let own = try JSONDecoder().decode(CalOwnWrite.self, from: Data(legacy.utf8))
        check(own.startAck?.updated == Date(timeIntervalSinceReferenceDate: 100) && own.endAck?.value == Date(timeIntervalSinceReferenceDate: 300),
              "c1_older_saved_time_acknowledgement_still_reads")
    } catch { check(false, "c1 legacy: \(error)") }
}
