import Foundation
import FloatBoardCore

/// The calendar outbox: changes to Google are written down first, survive a restart, and retry with a growing wait.
@MainActor func calendarOutboxChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-caloutbox-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup

    let url = root.appendingPathComponent("board.sqlite")
    let acct = "me@example.com", cal = "primary"
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    func fields(_ title: String) -> CalEventFields {
        CalEventFields(start: base, end: base.addingTimeInterval(1800), title: title, htmlLink: "https://cal.example/e1", googleUpdated: base)
    }

    // Survives a restart: close the board, open it again, the change is still waiting.
    var uuid = ""
    do {
        let store = Store(db: try DB(url: url))
        let outbox = CalendarOutbox(store: store)
        uuid = outbox.enqueue(.create(fields("Plan"), cardID: nil, addMeet: true), account: acct, calendarID: cal)
        check(outbox.due(now: base).count == 1, "outbox_enqueue_is_due_now")
    } catch { check(false, "calendar_outbox_survives_reopen: setup \(error)") }
    do {
        let store = Store(db: try DB(url: url))
        let rows = CalendarOutbox(store: store).due(now: base.addingTimeInterval(1))
        var ok = false
        if rows.count == 1, rows[0].uuid == uuid, rows[0].account == acct, rows[0].calendarID == cal,
           case .create(let f, let cardID, let meet) = rows[0].write { ok = f.title == "Plan" && cardID == nil && meet && f.start == base }
        check(ok, "calendar_outbox_survives_reopen")
    } catch { check(false, "calendar_outbox_survives_reopen: \(error)") }

    // Backoff: 1 min, doubling, never more than an hour; the error text is kept.
    do {
        let store = Store(db: try DB(url: root.appendingPathComponent("backoff.sqlite")))
        let outbox = CalendarOutbox(store: store)
        let id = outbox.enqueue(.delete(eventID: "ev1"), account: acct, calendarID: cal)
        var waits: [Double] = []
        for _ in 0..<9 {
            outbox.markFailed(uuid: id, error: "HTTP 500: boom", now: base)
            guard let row = outbox.rows(unsent: true).first else { break }
            waits.append(row.nextTry.timeIntervalSince(base))
        }
        let row = outbox.rows(unsent: true).first
        check(waits == [60, 120, 240, 480, 960, 1920, 3600, 3600, 3600] && row?.attempts == 9 && row?.lastError == "HTTP 500: boom"
              && outbox.due(now: base.addingTimeInterval(3599)).isEmpty && outbox.due(now: base.addingTimeInterval(3600)).count == 1,
              "calendar_outbox_backoff_doubles_to_one_hour")
    } catch { check(false, "calendar_outbox_backoff_doubles_to_one_hour: \(error)") }

    // A sent create links the card and fills the cache; a sent delete hides the event; pending shows until sent.
    do {
        let store = Store(db: try DB(url: root.appendingPathComponent("sent.sqlite")))
        let cache = CalendarCache(store: store)
        let outbox = CalendarOutbox(store: store)
        cache.upsertCalendars(account: acct, [CalCalendar(account: acct, calendarID: cal, name: "Me", color: "#112233", owned: true, shown: true)])
        store.add(title: "Write plan", area: "Personal", importance: .medium, due: base)
        guard let card = store.cards.first else { check(false, "outbox card setup"); return }
        let id = outbox.enqueue(.create(fields("Write plan"), cardID: card.id, addMeet: false), account: acct, calendarID: cal)
        check(outbox.pending(eventShortID: 1) == false, "pending_flag_false_for_unknown_event")

        outbox.markSent(uuid: id, result: (eventID: "g1", fields: fields("Write plan")))
        let ev = cache.event(account: acct, calendarID: cal, eventID: "g1")
        let linked = store.cards.first { $0.id == card.id }
        var gcal: (String, String, String, Bool) = ("", "", "", false)
        if let r = try? store.db.query("SELECT gcal_account, gcal_calendar, gcal_event, gcal_synced_at IS NOT NULL FROM cards WHERE id=?", [card.id], { (DB.text($0, 0), DB.text($0, 1), DB.text($0, 2), DB.int($0, 3) != 0) }).first { gcal = r } // try?-ok: empty result fails the check
        let history = (try? store.db.query("SELECT kind FROM events WHERE card_id=? AND kind LIKE '%Google Calendar%'", [card.id]) { DB.text($0, 0) }) ?? [] // try?-ok: empty result fails the check
        check(ev?.title == "Write plan" && linked?.gcalLink == "https://cal.example/e1" && gcal == (acct, cal, "g1", true)
              && history.count == 1 && outbox.due(now: base.addingTimeInterval(10_000)).isEmpty,
              "mark_sent_create_links_card_and_cache")

        // Pending: a patch for a known event waits until it is sent.
        guard let shortID = ev?.shortID else { check(false, "pending setup"); return }
        let p = outbox.enqueue(.patch(eventID: "g1", title: "New", start: nil, end: nil, allDayStart: nil), account: acct, calendarID: cal)
        let before = outbox.pending(eventShortID: shortID)
        outbox.markSent(uuid: p, result: (eventID: "g1", fields: fields("New")))
        check(before && !outbox.pending(eventShortID: shortID) && cache.event(shortID: shortID)?.title == "New",
              "pending_flag_shows_until_sent")

        let d = outbox.enqueue(.delete(eventID: "g1"), account: acct, calendarID: cal)
        outbox.markSent(uuid: d, result: nil)
        check(cache.events(from: base.addingTimeInterval(-3600), to: base.addingTimeInterval(7200)).isEmpty
              && cache.event(shortID: shortID) != nil && outbox.due(now: base.addingTimeInterval(10_000)).isEmpty,
              "mark_sent_delete_hides_event")
    } catch { check(false, "calendar outbox sent checks: \(error)") }
}
