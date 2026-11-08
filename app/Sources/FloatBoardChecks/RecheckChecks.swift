import Foundation
import FloatBoardCore
import FloatBoardConnectors

/// Re-check reconciles; it never deletes.
@MainActor func recheckChecks() async {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("fb-recheck-\(UUID().uuidString)")
    let dbURL = root.appendingPathComponent("recheck.sqlite")
    let store: Store
    do { store = Store(db: try DB(url: dbURL)) } catch { check(false, "recheck setup: \(error)"); return }
    let bk = Backups(dbURL: dbURL, dir: root.appendingPathComponent("bk", isDirectory: true))
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func count(_ t: String) -> Int {
        ((try? store.db.query("SELECT count(*) FROM \(t)") { DB.int($0, 0) })?.first).map { Int($0) } ?? -1 // try?-ok: failed query fails the check
    }
    func withdrawItem(_ mid: String, _ n: Int) -> String {
        #"{"id":"w\#(n)","kind":"withdraw","source_key":{"message_id":"\#(mid)","sent_at":"s"},"provenance":{"model":"m","skill_version":"1","created":"c"}}"#
    }
    func mk(_ kind: ProposalKind, _ mid: String, _ title: String = "T") -> Proposal {
        Proposal(id: "p-\(kind.rawValue)-\(mid)", kind: kind, sourceKey: SourceKey(messageID: mid, sentAt: "s"), title: title, why: "w", due: nil,
                 hasTime: false, group: "Personal", importance: 1, sourceLabel: "Inbox", link: "https://mail/\(mid)", summary: nil,
                 taskRef: nil, learned: nil, provenance: Provenance(model: "m", skillVersion: "1", created: "c"))
    }
    func seed(_ n: Int, from: Int = 0) {
        do {
            _ = try Reconciler.apply((from..<(from + n)).map { mk(.task, "m\($0)", "T\($0)") }, connector: "rk", store: store,
                                     defaultGroup: "Personal", autoAdd: true)
        } catch { check(false, "recheck seed: \(error)") }
    }
    /// Engine model: /v2/recheck produces nothing; each /v2/run makes the next batch of `batches` available as proposals and
    /// reports done after the last one (or never, with `neverDone`).
    func engine(_ batches: [[String]], neverDone: Bool = false) -> FakeEngine {
        var ran = 0, served = 0
        let eng = goodEngine()
        let good = eng.handler
        eng.handler = { m, p, b in
            switch p {
            case "/v2/recheck": return (200, "{}")
            case "/v2/run":
                ran += 1
                let done = !neverDone && ran >= batches.count
                return (200, #"{"processed":\#(ran <= batches.count ? batches[ran - 1].count : 1),"done":\#(done)}"#)
            case "/v2/proposals":
                if served < ran { served = ran; let items = batches[min(ran, batches.count) - 1].joined(separator: ",")
                    return (200, #"{"items":[\#(items)],"cursor":"c\#(ran)"}"#) }
                return (200, #"{"items":[],"cursor":"c\#(ran)"}"#)
            default: return try good(m, p, b)
            }
        }
        return eng
    }

    // recheck_never_deletes
    seed(15)
    for i in 13..<15 { if let c = store.cards.first(where: { $0.sourceKey?.messageID == "m\(i)" }) { store.update({ var x = c; x.notes = "mine"; return x }()) } }
    let cards0 = count("cards"), events0 = count("events")
    let eng = engine([(0..<15).map { withdrawItem("m\($0)", $0) }])
    let s1 = await ConnectorSync.recheck(connector: "rk", days: 7, store: store, client: eng.client(), now: t0, backups: bk)
    check(s1?.withdrawn == 13 && s1?.keptTouched == 2 && count("cards") == cards0 && count("events") >= events0
          && store.cards.filter(\.withdrawn).count == 13 && store.withdrawnCards.count == 13
          && store.active.allSatisfy { !$0.withdrawn }
          && !bk.list().filter { $0.reason == "pre-recheck" }.isEmpty
          && eng.requests.contains { $0.path == "/v2/recheck" && $0.query == "days=7" }, "recheck_never_deletes")

    // snapshot failure aborts
    let blocker = root.appendingPathComponent("not-a-dir")
    do { try Data("x".utf8).write(to: blocker) } catch { check(false, "recheck blocker: \(error)") }
    let badBackups = Backups(dbURL: dbURL, dir: blocker)
    store.performForTest("UPDATE cards SET withdrawn=0")
    let before = (count("cards"), count("events"), store.cards.filter(\.withdrawn).count)
    let eng2 = engine([(0..<15).map { withdrawItem("m\($0)", $0) }])
    let out2 = await ConnectorSync.recheckOutcome(connector: "rk", days: 7, store: store, client: eng2.client(), now: t0, backups: badBackups)
    check(out2.summary == nil && eng2.requests.isEmpty && out2.notice.contains("backup")
          && (count("cards"), count("events"), store.cards.filter(\.withdrawn).count) == before
          && store.recentActivity(limit: 50).contains { $0.level == .error && $0.message.hasPrefix("Re-check cancelled") }, "recheck_snapshot_failure_aborts")

    // summary accumulates across passes; an empty first pass is not "Nothing changed" while run says not done
    let eng3 = engine([[], [withdrawItem("m0", 0)], [withdrawItem("m1", 1), withdrawItem("m2", 2)]])
    let out3 = await ConnectorSync.recheckOutcome(connector: "rk", days: 14, store: store, client: eng3.client(), now: t0, backups: nil)
    let s3 = out3.summary
    check(s3?.withdrawn == 3 && out3.notice == "3 withdrawn" && eng3.requests.filter { $0.path == "/v2/run" }.count == 3
          && !out3.stillRunning && !out3.problems, "recheck_summary_accumulates_across_passes")
    let eng3b = engine([[], []], neverDone: true)
    let out3b = await ConnectorSync.recheckOutcome(connector: "rk", days: 14, store: store, client: eng3b.client(), now: t0, backups: nil)
    check(out3b.stillRunning && out3b.notice.contains("Nothing changed") && out3b.notice.contains("still running"), "recheck_empty_pass_not_done_says_running")
    let eng3c = engine([[]])
    let out3c = await ConnectorSync.recheckOutcome(connector: "rk", days: 14, store: store, client: eng3c.client(), now: t0, backups: nil)
    check(out3c.notice == "Nothing changed" && !out3c.stillRunning, "recheck_done_with_nothing_says_nothing_changed")
    let engF = engine([[]])
    let goodF = engF.handler
    engF.handler = { m, p, b in p == "/v2/run" ? (500, "{}") : try goodF(m, p, b) }
    let outF = await ConnectorSync.recheckOutcome(connector: "rk", days: 7, store: store, client: engF.client(), now: t0, backups: nil)
    check(outF.problems && outF.summary != nil, "recheck_run_failure_reports_problems")
    check(ConnectorSync.recheckLine(ReconcileSummary()) == "Nothing changed"
          && ConnectorSync.recheckLine(ReconcileSummary(added: 2, withdrawn: 11, keptTouched: 3, skippedExisting: 5))
              == "2 added · 11 withdrawn · 3 kept because you'd changed them · 5 already on your board"
          && ConnectorSync.recheckLine(ReconcileSummary(added: 1, refreshed: 4, withdrawn: 2, keptTouched: 3, skippedExisting: 5))
              == "1 added · 4 updated · 2 withdrawn · 3 kept because you'd changed them · 5 already on your board", "recheck_summary_line")

    // bounded: an engine that never stops sending
    let eng4 = engine([[withdrawItem("m0", 0)]], neverDone: true)
    let out4 = await ConnectorSync.recheckOutcome(connector: "rk", days: 7, store: store, client: eng4.client(), now: t0, backups: nil)
    check(out4.stillRunning && out4.notice.contains("still running on the engine")
          && eng4.requests.filter { $0.path == "/v2/run" }.count == 10, "recheck_is_bounded")

    // restore marks touched; a later re-check does not withdraw it again
    store.performForTest("UPDATE cards SET withdrawn=0")
    seed(1, from: 15)
    guard let c = store.cards.first(where: { $0.sourceKey?.messageID == "m15" }) else { check(false, "restore setup"); return }
    do {
        _ = try Reconciler.apply([mk(.withdraw, "m15")], connector: "rk", store: store, defaultGroup: "Personal", autoAdd: true)
    } catch { check(false, "recheck withdraw: \(error)") }
    let wasWithdrawn = store.card(c.id)?.withdrawn == true && !store.isTouched(c.id)
    store.restoreWithdrawn(c.id)
    let eng5 = engine([[withdrawItem("m15", 15)]])
    let s5 = await ConnectorSync.recheck(connector: "rk", days: 7, store: store, client: eng5.client(), now: t0, backups: nil)
    check(wasWithdrawn && store.isTouched(c.id) && store.card(c.id)?.withdrawn == false && s5?.keptTouched == 1 && s5?.withdrawn == 0,
          "restore_withdrawn_marks_touched")
    // restore is a no-op on a card that is not withdrawn; withdrawn list covers orphaned/empty connectors
    let evBefore = count("events")
    store.restoreWithdrawn(c.id)
    store.restoreWithdrawn(999_999)
    check(count("events") == evBefore, "restore_not_withdrawn_is_noop")
    store.performForTest("UPDATE cards SET withdrawn=1 WHERE id=\(c.id)")
    store.performForTest("UPDATE cards SET connector='' WHERE id=\(c.id)")
    check(store.withdrawnCards.contains { $0.id == c.id }, "withdrawn_list_includes_cards_without_connector")
    store.performForTest("UPDATE cards SET connector='gone-forever' WHERE id=\(c.id)")
    check(store.withdrawnCards.contains { $0.id == c.id } && !store.connectors.contains { $0.id == "gone-forever" }, "withdrawn_list_includes_removed_connector")
    store.restoreWithdrawn(c.id)
    check(store.card(c.id)?.withdrawn == false && !store.withdrawnCards.contains { $0.id == c.id }, "withdrawn_restore_from_list")
    try? fm.removeItem(at: root) // try?-ok: scratch cleanup
}
