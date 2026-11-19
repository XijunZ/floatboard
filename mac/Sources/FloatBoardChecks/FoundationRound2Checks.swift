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
    let g = try? budget.request(kind: .circleDue, itemID: ShortID(kind: .person, number: n), text: "Message P-\(n)", now: now) // try?-ok: nil fails the caller's check
    if case .granted(let id, _) = g { return id }
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

/// Round 13 (A3): a reminder past the Mac's grace with no engine that can reach a phone is shown late on this Mac, never
/// marked as the phone's (shown nowhere).
@MainActor func lateReminderNoPhoneChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-late-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    guard let store = foundationStore(root, "late.sqlite") else { return }
    let budget = ReminderBudget(store: store)
    budget.save(ReminderSettings(dailyLimit: 5, quietStart: 0, quietEnd: 0))
    let now = Date()
    guard let a = grant(budget, 1, now) else { check(false, "late setup"); return }
    var scheduled: [String] = []
    let delivery = ReminderDelivery(store: store, claim: { _ in .noEngine }, schedule: { scheduled.append($0.id) }, phoneAvailable: { false })
    _ = await delivery.tick(now: now.addingTimeInterval(ReminderBudget.phoneGrace + 60))   // the Mac was asleep through the grace
    check(scheduled == [a] && budget.pending().isEmpty && !budget.forPhone(now: now.addingTimeInterval(ReminderBudget.phoneGrace + 60)).contains { $0.id == a },
          "late_reminder_without_a_phone_is_shown_on_the_mac")
    // With a phone that can be reached, a late one still goes to the phone (as before).
    guard let b = grant(budget, 2, now) else { return }
    scheduled = []
    let withPhone = ReminderDelivery(store: store, claim: { _ in .mine }, schedule: { scheduled.append($0.id) }, phoneAvailable: { true })
    _ = await withPhone.tick(now: now.addingTimeInterval(ReminderBudget.phoneGrace + 60))
    check(scheduled.isEmpty && budget.forPhone(now: now.addingTimeInterval(ReminderBudget.phoneGrace + 60)).contains { $0.id == b }, "late_reminder_with_a_phone_goes_to_the_phone")
    // Round 14 (7): more than a day late it is dropped, never shown (the engine's "within a day"); in quiet hours it waits.
    guard let c = grant(budget, 3, now) else { return }
    scheduled = []
    _ = await delivery.tick(now: now.addingTimeInterval(26 * 3600))
    check(scheduled.isEmpty && !budget.pending().contains { $0.id == c }, "late_reminder_more_than_a_day_old_is_dropped_not_shown")
    let cal = AppTime.calendar
    let evening = cal.date(bySettingHour: 20, minute: 0, second: 0, of: now)!
    budget.save(ReminderSettings(dailyLimit: 5, quietStart: 22 * 60, quietEnd: 8 * 60))
    guard let d = grant(budget, 4, evening) else { check(false, "quiet setup"); return }
    scheduled = []
    let night = cal.date(bySettingHour: 23, minute: 0, second: 0, of: evening)!
    _ = await delivery.tick(now: night)
    let held = scheduled.isEmpty && budget.pending().contains { $0.id == d }
    let morning = cal.date(byAdding: .day, value: 1, to: cal.date(bySettingHour: 8, minute: 5, second: 0, of: evening)!)!
    _ = await delivery.tick(now: morning)
    check(held && scheduled == [d], "late_reminder_waits_for_the_end_of_quiet_hours")
}

/// Round 14 (6): "a phone can be reached" comes from the engine (a paired phone with notifications, or ntfy), cached per
/// connector; a connector never heard from counts as no phone, one that stops answering keeps its last answer, and an
/// engine from before this answer counts as reachable (as before).
@MainActor func phoneReachChecks() async {
    var answer = "{\"phones\":[],\"reachable\":false}", status = 200
    let client = ConnectorClient(baseURL: URL(string: "https://reach.test")!, key: "k") { req in
        await MainActor.run { (Data(answer.utf8), HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!) }
    }
    PhoneReach.reset()
    check(!PhoneReach.any(), "no_answer_yet_means_no_phone")
    await PhoneReach.refresh(connector: "r1", client: client, now: Date(), force: true)
    let off = PhoneReach.any()
    answer = "{\"phones\":[],\"reachable\":true}"
    await PhoneReach.refresh(connector: "r1", client: client, now: Date(), force: true)
    let on = PhoneReach.any()
    status = 500
    await PhoneReach.refresh(connector: "r1", client: client, now: Date(), force: true)
    let kept = PhoneReach.any()
    status = 200; answer = "{\"phones\":[]}"
    await PhoneReach.refresh(connector: "r2", client: client, now: Date(), force: true)
    PhoneReach.forget("r1")
    check(!off && on && kept && PhoneReach.any(), "phone_reach_follows_the_engine_and_keeps_the_last_answer")
    // Round 15: an engine that fails (or hangs until the timeout) is asked again only after 10 minutes, even with no answer
    // yet ("unknown": no phone), so it never slows every minute's tick.
    PhoneReach.reset()
    var asked = 0
    let down = ConnectorClient(baseURL: URL(string: "https://down.test")!, key: "k") { req in
        await MainActor.run { asked += 1; return (Data(), HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!) }
    }
    let t0 = Date()
    await PhoneReach.refresh(connector: "d1", client: down, now: t0)
    await PhoneReach.refresh(connector: "d1", client: down, now: t0.addingTimeInterval(60))
    let quiet = asked
    await PhoneReach.refresh(connector: "d1", client: down, now: t0.addingTimeInterval(PhoneReach.every + 1))
    check(quiet == 1 && asked == 2 && !PhoneReach.any(), "an_engine_that_fails_is_asked_again_only_after_10_minutes")
    PhoneReach.reset()
}

/// Round 20 (7): a reminder this Mac claimed but couldn't show is handed back at the phone's turn; when no phone can be
/// reached it is not marked as the phone's (it would be shown nowhere): it stays, and this Mac shows it late.
@MainActor func releasedWithoutPhoneChecks() async {
    let root = checkFolder("fb-release-nophone")
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    guard let store = foundationStore(root, "rel.sqlite") else { return }
    let budget = ReminderBudget(store: store)
    budget.save(ReminderSettings(dailyLimit: 5, quietStart: 0, quietEnd: 0))
    let now = Date()
    guard let id = grant(budget, 7, now) else { check(false, "rel setup"); return }
    var fail = true, shown: [String] = [], released: [String] = []
    struct Refused: Error {}
    let d = ReminderDelivery(store: store, claim: { _ in .mine }, schedule: { r in if fail { throw Refused() }; shown.append(r.id) },
                             release: { rid in released.append(rid); return true }, phoneAvailable: { false })
    _ = await d.tick(now: now.addingTimeInterval(1))             // claimed here; macOS refused to show it (a second after its time:
                                                                 // the stored time can round a hair later than `now`)
    fail = false
    let later = now.addingTimeInterval(ReminderBudget.phoneGrace + 60)
    _ = await d.tick(now: later)                                 // the phone's turn: handed back
    _ = await d.tick(now: later.addingTimeInterval(60))          // no phone: shown here, late
    let phoneMarked = budget.forPhone(now: later).contains { $0.id == id }
    check(released == [id] && shown == [id] && budget.pending().isEmpty && !phoneMarked, "a_released_reminder_with_no_phone_is_shown_late_on_the_mac")
}
