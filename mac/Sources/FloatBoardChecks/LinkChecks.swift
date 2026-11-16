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
}
