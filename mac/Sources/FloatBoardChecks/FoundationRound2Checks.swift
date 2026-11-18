import Foundation
import FloatBoardCore
import FloatBoardConnectors

/// Codex round 2 on the foundation: R1 (a budget reminder counts as shown only once macOS took it; a failure leaves it
/// waiting, with one Activity error) and R2 (the Mac claims the notification id at the engine before showing it, so the Mac
/// and the phone never both show it, even when the Mac's board update is lost).
@MainActor func foundationRound2Checks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-foundation-r2-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    await r1Checks(root)
    await r2Checks(root)
    await r3Checks(root)
}

private struct Refused: Error {}

@MainActor private func grant(_ budget: ReminderBudget, _ n: Int64, _ now: Date) -> String? {
    if case .granted(let id, _) = budget.request(kind: .circleDue, itemID: ShortID(kind: .person, number: n), text: "Message P-\(n)", now: now) { return id }
    return nil
}

// MARK: R1

@MainActor private func r1Checks(_ root: URL) async {
    guard let store = foundationStore(root, "r1.sqlite") else { return }
    let budget = ReminderBudget(store: store)
    let now = Date()
    budget.save(ReminderSettings(dailyLimit: 5, quietStart: 0, quietEnd: 0))   // no quiet hours: the checks may run at night
    guard let a = grant(budget, 1, now) else { check(false, "r1 setup"); return }
    var scheduled: [String] = [], failing = true
    let delivery = ReminderDelivery(store: store, claim: { _ in .noEngine }, schedule: { r in
        if failing { throw Refused() }
        scheduled.append(r.id)
    })
    func errors() -> Int { store.recentActivity(limit: 200).filter { $0.level == .error && $0.trace == a }.count }
    _ = await delivery.tick(now: now.addingTimeInterval(5))
    _ = await delivery.tick(now: now.addingTimeInterval(65))
    check(budget.pending().contains { $0.id == a } && scheduled.isEmpty && errors() == 1, "reminder_not_shown_stays_waiting_with_one_error")
    failing = false
    _ = await delivery.tick(now: now.addingTimeInterval(125))
    check(scheduled == [a] && !budget.pending().contains { $0.id == a }, "reminder_counts_as_shown_once_macos_took_it")
}

// MARK: R2

@MainActor private func r2Checks(_ root: URL) async {
    // The engine's answer, as the client reads it.
    func client(_ status: Int, _ body: String) -> ConnectorClient {
        ConnectorClient(baseURL: URL(string: "https://engine.test")!, key: "k") { req in
            (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
    let mine = await client(200, #"{"owner":"mac"}"#).claimReminder("rb-x")
    let phones = await client(200, #"{"owner":"phone"}"#).claimReminder("rb-x")
    let old = await client(404, #"{"error":"not found"}"#).claimReminder("rb-x")
    let down = await ConnectorClient(baseURL: URL(string: "https://engine.test")!, key: "k") { _ in throw URLError(.notConnectedToInternet) }.claimReminder("rb-x")
    check(mine == .mine && phones == .phones && old == .noEngine && down == .unreachable, "reminder_claim_answers_read")

    guard let store = foundationStore(root, "r2.sqlite") else { return }
    let budget = ReminderBudget(store: store)
    budget.save(ReminderSettings(dailyLimit: 5, quietStart: 0, quietEnd: 0))
    let now = Date()
    guard let a = grant(budget, 1, now), let b = grant(budget, 2, now) else { check(false, "r2 setup"); return }
    var scheduled: [String] = []
    var claims: [String: ReminderClaim] = [a: .phones, b: .unreachable]
    let delivery = ReminderDelivery(store: store, claim: { claims[$0] ?? .noEngine }, schedule: { scheduled.append($0.id) })
    _ = await delivery.tick(now: now.addingTimeInterval(5))
    check(!budget.pending().contains { $0.id == a } && scheduled.isEmpty, "reminder_the_phone_already_has_is_not_shown_here")
    check(budget.pending().contains { $0.id == b } && scheduled.isEmpty, "reminder_waits_while_the_engine_cannot_be_asked")
    claims[b] = .unreachable
    _ = await delivery.tick(now: now.addingTimeInterval(ReminderBudget.phoneGrace + 5))
    check(!budget.pending().contains { $0.id == b } && scheduled.isEmpty, "unanswered_reminder_left_to_the_phone")
}

// MARK: Round 3: never shown nowhere

@MainActor private func r3Checks(_ root: URL) async {
    let ok = await ConnectorClient(baseURL: URL(string: "https://engine.test")!, key: "k") { req in
        (Data(#"{"released":true}"#.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }.releaseReminder("rb-x")
    let down = await ConnectorClient(baseURL: URL(string: "https://engine.test")!, key: "k") { _ in throw URLError(.notConnectedToInternet) }.releaseReminder("rb-x")
    check(ok && !down, "reminder_release_answers_read")

    guard let store = foundationStore(root, "r3.sqlite") else { return }
    let budget = ReminderBudget(store: store)
    budget.save(ReminderSettings(dailyLimit: 5, quietStart: 0, quietEnd: 0))
    let now = Date()
    guard let a = grant(budget, 1, now), let b = grant(budget, 2, now) else { check(false, "r3 setup"); return }
    var released: [String] = [], reachable = false
    let delivery = ReminderDelivery(store: store, claim: { _ in .mine }, schedule: { _ in throw Refused() },
                                    release: { id in if reachable { released.append(id) }; return reachable })
    _ = await delivery.tick(now: now.addingTimeInterval(5))            // claimed here; macOS refuses
    let late = now.addingTimeInterval(ReminderBudget.phoneGrace + 5)
    _ = await delivery.tick(now: late)                                  // engine not reachable: still waiting
    check(budget.pending().map(\.id).sorted() == [a, b].sorted() && released.isEmpty, "claimed_reminder_waits_until_it_can_be_handed_back")
    reachable = true
    _ = await delivery.tick(now: late.addingTimeInterval(60))
    let lines = store.recentActivity(limit: 200).filter { $0.message.hasPrefix("A reminder could not be shown on this Mac") }
    check(Set(released) == [a, b] && budget.pending().isEmpty && budget.forPhone(now: late).count == 2 && lines.count == 2,
          "reminder_this_mac_could_not_show_is_handed_to_the_phone")
    // A reminder this Mac never claimed is left to the phone without asking.
    guard let c = grant(budget, 3, now) else { return }
    released = []
    _ = await delivery.tick(now: late.addingTimeInterval(120))
    check(released.isEmpty && !budget.pending().contains { $0.id == c }, "unclaimed_reminder_left_to_the_phone_without_release")
}

// MARK: Integration round 5: a claim whose answer was lost (Codex review 3, finding 5)

@MainActor func lostClaimChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-lost-claim-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    guard let store = foundationStore(root, "lost.sqlite") else { return }
    let budget = ReminderBudget(store: store)
    budget.save(ReminderSettings(dailyLimit: 5, quietStart: 0, quietEnd: 0))
    let now = Date()
    guard let a = grant(budget, 1, now) else { check(false, "lost claim setup"); return }
    // The engine took the claim but its answer never arrived (the Mac sees "unreachable") until the grace ran out.
    var engineHolds = Set<String>(), released: [String] = []
    let delivery = ReminderDelivery(store: store, claim: { id in engineHolds.insert(id); return .unreachable }, schedule: { _ in },
                                    release: { id in released.append(id); engineHolds.remove(id); return true })
    _ = await delivery.tick(now: now.addingTimeInterval(5))
    _ = await delivery.tick(now: now.addingTimeInterval(65))
    check(budget.pending().contains { $0.id == a } && released.isEmpty, "unanswered_claim_waits_within_the_grace")
    _ = await delivery.tick(now: now.addingTimeInterval(ReminderBudget.phoneGrace + 5))
    check(released == [a] && engineHolds.isEmpty && !budget.pending().contains { $0.id == a } && budget.forPhone(now: now.addingTimeInterval(ReminderBudget.phoneGrace + 5)).contains { $0.id == a },
          "claim_with_a_lost_answer_is_released_at_handoff_so_the_phone_gets_it")
    // The intent survives a restart of the app (a new delivery object): it is kept in the database before the claim is sent.
    guard let b = grant(budget, 2, now) else { return }
    _ = await ReminderDelivery(store: store, claim: { _ in .unreachable }, schedule: { _ in }).tick(now: now.addingTimeInterval(5))
    released = []
    _ = await ReminderDelivery(store: store, claim: { _ in .unreachable }, schedule: { _ in },
                               release: { id in released.append(id); return true }).tick(now: now.addingTimeInterval(ReminderBudget.phoneGrace + 5))
    check(released == [b], "claim_intent_survives_a_restart")
}
