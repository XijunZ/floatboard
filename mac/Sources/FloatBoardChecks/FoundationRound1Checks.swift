import Foundation
import FloatBoardCore

/// Codex round 1 on the foundation: F1 (one tag rule for the Mac and the engine), F2 (every Mac group/tag change is stamped).
@MainActor func foundationRound1Checks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-foundation-r1-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    tagRuleChecks(root)
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

