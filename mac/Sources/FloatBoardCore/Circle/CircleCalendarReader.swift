import Foundation

/// The calendar as a Circle reader (§9): a past meeting counts as talked with each guest who accepted, when the owner
/// accepted it too (or organised it: no reply of their own). Read from the calendar directly, not from Fathom; shown as
/// "met"; a meeting can be corrected on the card. All-day events and cancelled ones are not meetings.
@MainActor public enum CircleCalendarReader {
    /// Records the met meetings in the calendar's cache up to `now`. Returns how many guest meetings it saw.
    @discardableResult
    public static func read(store: Store, now: Date = Date()) -> Int {
        guard store.isOn(.circle) else { return 0 }
        let own = Set(CalendarCache(store: store).calendars().map { $0.account.lowercased() })
        var inputs: [ExchangeInput] = []
        var earliest: Date?
        do {
            let rows = try store.db.query("""
                SELECT short_id, start, guests FROM cal_events WHERE cancelled=0 AND gone=0 AND all_day=0 AND "end"<=? ORDER BY start
                """, [now]) { (DB.int($0, 0), DB.date($0, 1) ?? now, DB.text($0, 2)) }
            for (id, start, raw) in rows {
                earliest = min(earliest ?? start, start)
                let guests = (try? JSONDecoder().decode([CalGuest].self, from: Data(raw.utf8))) ?? [] // try?-ok: unreadable guests = none
                let mine = guests.filter { own.contains($0.email.lowercased()) }
                guard mine.isEmpty || mine.contains(where: { $0.status == "accepted" }) else { continue }
                for g in guests where !own.contains(g.email.lowercased()) && g.status == "accepted" {
                    guard let e = Handles.normalize(.email, g.email) else { continue }
                    inputs.append(ExchangeInput(channel: .calendar, direction: .met, at: start, handle: Handle(kind: .email, value: e),
                                                ref: "E-\(id)", key: "calendar:E-\(id):\(e)"))
                }
            }
        } catch {
            store.activity("circle", .error, "Could not read past meetings for Circle", detail: "\(error)")
            return 0
        }
        let c = CircleStore(store: store)
        c.record(inputs, now: now)
        c.setChannel("calendar", asOf: now, completeFrom: earliest, cursor: "", note: Channel.calendar.limits ?? "")
        return inputs.count
    }
}
