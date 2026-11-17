import Foundation
import FloatBoardCore

/// Codex round 1 on the foundation: F1 (one tag rule for the Mac and the engine), F2 (every Mac group/tag change is stamped).
@MainActor func foundationRound1Checks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-foundation-r1-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    tagRuleChecks(root)
    tagStampChecks(root)
}

// MARK: F1

@MainActor private func tagRuleChecks(_ root: URL) {
    // The phone rule (shared with the engine's parseTags): trimmed, 1 to 60 UTF-16 units, no case-insensitive repeat, at most 20.
    let long = String(repeating: "季", count: 59) + "😀"                       // 59 + 2 = 61 UTF-16 units
    let clipped = TagRules.forPhone([" Work ", "work", "", long, String(repeating: "a", count: 70), String(repeating: "A", count: 61)])
    check(clipped.count == 3 && clipped[0] == "Work" && clipped.allSatisfy { !$0.isEmpty && $0.utf16.count <= 60 }
          && Set(clipped.map { $0.lowercased() }).count == clipped.count, "phone_tags_follow_the_engine_rule")
    check(TagRules.forPhone((1...30).map { "Tag \($0)" }).count == 20, "phone_tags_at_most_20")
    guard let store = foundationStore(root, "r1-tags.sqlite") else { return }
    store.addArea(String(repeating: "长", count: 70))
    store.add(title: "Long group", area: String(repeating: "长", count: 70), importance: .medium, due: nil)
    guard let c = store.cards.first else { check(false, "r1 tags setup"); return }
    store.addArea(String(repeating: "长", count: 61) + "x")   // the same as the first once both are cut to 60
    store.setTags(ShortID(kind: .task, number: c.id), primary: c.area, others: [String(repeating: "长", count: 61) + "x"])
    let tags = PhoneBoard.payload(store: store, now: Date()).first?.tags ?? []
    check(tags.count == 1 && tags[0].utf16.count <= 60, "phone_copy_tags_never_break_the_engine_rule")
}

// MARK: F2

@MainActor func tagStampChecks(_ root: URL) {
    guard let store = foundationStore(root, "r1-stamp.sqlite") else { return }
    store.addArea("Health")
    store.add(title: "Stamp me", area: "Work", importance: .medium, due: nil)
    guard let c = store.cards.first else { check(false, "r1 stamp setup"); return }
    let t0 = Date().addingTimeInterval(-3600)
    // The editor saves a group change through update().
    var edited = c; edited.area = "Personal"
    store.update(edited, now: t0)
    check(store.tagsChangedAt(c.id) == t0, "editor_group_change_stamps_tags")
    // A phone tag edit made before that loses.
    let r = store.applyPhoneActions([PhoneAction(id: "r1a", clientID: "r1-tags-a", cardID: c.id, action: "set_tags", madeAt: t0 - 60, tags: ["Work"])],
                                    connector: "ph", now: t0 + 1)
    check(r.skipped.map(\.reason) == ["superseded"] && store.card(c.id)?.area == "Personal", "older_phone_tags_lose_to_editor_group_change")
    // Group rename and delete stamp every task they touch; deleting a tag stamps tasks that carried it.
    guard let personal = store.areas.first(where: { $0.name == "Personal" }) else { return }
    let t1 = Date()
    store.renameArea(personal, to: "Home")
    check((store.tagsChangedAt(c.id) ?? .distantPast) >= t1.addingTimeInterval(-1), "group_rename_stamps_tags")
    store.setTags(ShortID(kind: .task, number: c.id), primary: "Home", others: ["Health"], now: t0)
    let t2 = Date()
    if let health = store.areas.first(where: { $0.name == "Health" }) { store.deleteArea(health, moveTasksTo: "Work") }
    check((store.tagsChangedAt(c.id) ?? .distantPast) >= t2.addingTimeInterval(-1), "tag_delete_stamps_tasks_that_had_it")
    store.setTags(ShortID(kind: .task, number: c.id), primary: "Home", others: [], now: t0)
    let t3 = Date()
    if let home = store.areas.first(where: { $0.name == "Home" }) { store.deleteArea(home, moveTasksTo: "Work") }
    check((store.tagsChangedAt(c.id) ?? .distantPast) >= t3.addingTimeInterval(-1) && store.card(c.id)?.area == "Work", "group_delete_stamps_moved_tasks")
    // The board's own quick group change (card menu / click) is stamped too.
    let t4 = Date()
    if let now = store.card(c.id) { store.setArea(now, "Health2") }   // unknown group name: still a change of group
    check((store.tagsChangedAt(c.id) ?? .distantPast) >= t4.addingTimeInterval(-1), "board_group_change_stamps_tags")
}
