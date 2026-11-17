import Foundation
import FloatBoardCore

/// Visible ids (T-142) and the links table: any two items can be linked by id, in either direction.
@MainActor func linkChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-links-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup

    check(ShortID.parse("t-142") == ShortID(kind: .task, number: 142) && ShortID.parse("T-142")?.text == "T-142"
          && ShortID.parse(" E-37 ") == ShortID(kind: .event, number: 37)
          && ShortID.parse("X-1") == nil && ShortID.parse("T-") == nil && ShortID.parse("T-1x") == nil && ShortID.parse("T-0") == nil,
          "short_id_parses_and_prints")

    let store: Store
    do { store = Store(db: try DB(url: root.appendingPathComponent("board.sqlite"))) } catch { check(false, "links setup: \(error)"); return }
    store.add(title: "Link me", area: "Personal", importance: .medium, due: nil)
    store.add(title: "Other task", area: "Personal", importance: .medium, due: nil)
    guard let a = store.cards.first(where: { $0.title == "Link me" }), let b = store.cards.first(where: { $0.title == "Other task" }) else {
        check(false, "links setup: cards missing"); return
    }
    let t = ShortID(kind: .task, number: a.id), t2 = ShortID(kind: .task, number: b.id)
    let e = ShortID(kind: .event, number: 37), e2 = ShortID(kind: .event, number: 38)

    store.link(t, e, actor: .user)
    store.link(e, t, actor: .user) // the same link the other way round
    store.link(t, t2, actor: .user)
    store.link(t, t, actor: .user) // an item is never linked to itself
    let rows = (try? store.db.query("SELECT from_type, from_id, to_type, to_id FROM links ORDER BY id") { // try?-ok: a failed query makes the check fail
        "\(DB.text($0, 0))-\(DB.text($0, 1))>\(DB.text($0, 2))-\(DB.text($0, 3))" }) ?? []
    check(Set(store.links(of: t)) == [e, t2] && store.links(of: e) == [t] && store.links(of: t2) == [t]
          && rows.count == 2 && rows.first == "E-37>T-\(a.id)", "link_is_two_way_and_unique")

    store.unlink(e, t) // either order
    check(store.links(of: t) == [t2] && store.links(of: e).isEmpty, "unlink_removes_both_directions")

    store.link(t, e, actor: .user)
    store.link(t, e2, actor: .user)
    store.link(t2, e, actor: .user)
    store.delete(a)
    check(store.links(of: t).isEmpty && store.links(of: t2) == [e] && store.links(of: e) == [t2] && store.links(of: e2).isEmpty,
          "delete_task_removes_its_links_only")
    store.undoDelete()
    check(Set(store.links(of: t)) == [e, e2, t2] && Set(store.links(of: e)) == [t, t2] && store.links(of: e2) == [t],
          "delete_task_removes_links_undo_restores")

    check(Search.matches(a, "T-\(a.id)") && Search.matches(a, "t-\(a.id)") && !Search.matches(a, "T-\(a.id + 100)")
          && !Search.matches(a, "T-\(a.id)9"), "search_finds_task_by_id")

    linkPickerChecks(store: store, root: root)
}

/// The link picker's search (typed id, titles, ranking) and the rule that linking changes nothing else (D14).
@MainActor private func linkPickerChecks(store: Store, root: URL) {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let hour: TimeInterval = 3600
    func event(_ n: Int64, _ title: String, hoursFromNow h: Double, gone: Bool = false) -> CalEvent {
        var e = CalEvent(shortID: n, account: "me@example.com", calendarID: "primary", eventID: "ev\(n)",
                         start: now.addingTimeInterval(h * hour), end: now.addingTimeInterval((h + 1) * hour), allDay: false,
                         title: title, location: "", videoLink: "", description: "", htmlLink: "", recurringID: nil,
                         googleUpdated: now, fbCard: nil)
        e.gone = gone
        return e
    }
    func task(_ id: Int64, _ title: String, done: Bool = false) -> Card {
        Card(id: id, title: title, notes: "", area: "Personal", importance: .medium, due: nil, status: done ? .done : .todo,
             created: now, started: nil, done: done ? now : nil)
    }
    let tasks = [task(142, "Prepare the deck"), task(1420, "Deck follow-up"), task(7, "Old deck", done: true), task(9, "Book venue")]
    let events = [event(37, "Deck review", hoursFromNow: 26), event(370, "Deck kickoff", hoursFromNow: -48),
                  event(38, "Deck sync", hoursFromNow: 2), event(39, "Deck retro", hoursFromNow: -3), event(40, "Gone deck", hoursFromNow: 1, gone: true)]

    func ids(_ kind: ItemKind, _ q: String, exclude: Set<ShortID> = []) -> [String] {
        LinkPickerSearch.candidates(kind: kind, cards: tasks, events: events, query: q, now: now, exclude: exclude).map(\.id.text)
    }
    check(ids(.task, "t-142") == ["T-142"] && ids(.event, "E-37") == ["E-37"] && ids(.event, " e-370 ") == ["E-370"]
          && ids(.task, "T-5").isEmpty && ids(.task, "E-37").isEmpty && ids(.event, "t-142").isEmpty,
          "link_picker_resolves_typed_id")

    check(ids(.event, "deck") == ["E-38", "E-37", "E-39", "E-370"] && ids(.event, "") == ["E-38", "E-37", "E-39", "E-370"]
          && ids(.task, "deck") == ["T-1420", "T-142", "T-7"] && ids(.task, "venue") == ["T-9"]
          && ids(.event, "deck", exclude: [ShortID(kind: .event, number: 38)]) == ["E-37", "E-39", "E-370"],
          "link_picker_search_ranks_upcoming_first")

    // Linking only writes the links table: the task's due and the calendar outbox stay as they were.
    store.add(title: "Keep my time", area: "Personal", importance: .medium, due: now, dueHasTime: true)
    guard let t = store.cards.first(where: { $0.title == "Keep my time" }) else { check(false, "link picker setup: card missing"); return }
    func outbox() -> Int64 { (try? store.db.query("SELECT COUNT(*) FROM cal_outbox") { DB.int($0, 0) })?.first ?? -1 } // try?-ok: -1 fails the check
    let before = outbox()
    store.link(ShortID(kind: .task, number: t.id), ShortID(kind: .event, number: 37), actor: .user)
    store.unlink(ShortID(kind: .task, number: t.id), ShortID(kind: .event, number: 37))
    store.link(ShortID(kind: .task, number: t.id), ShortID(kind: .event, number: 38), actor: .user)
    let after = store.card(t.id)
    check(after?.due == t.due && after?.dueHasTime == true && outbox() == before && before >= 0
          && store.links(of: ShortID(kind: .task, number: t.id)) == [ShortID(kind: .event, number: 38)],
          "linking_never_changes_due_or_enqueues_write")
}
