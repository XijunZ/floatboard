import Foundation
import FloatBoardCore
import FloatBoardConnectors

/// An engine with the phone app: queued phone actions (gone once acked), the board copy, and pairing.
private final class PhoneEngine {
    var pending: [[String: Any]] = []
    var ackStatus = 200
    var actionsStatus = 200
    /// How far the engine's clock is ahead of the Mac's (sent as server_time).
    var serverAhead: TimeInterval = 0
    let fake: FakeEngine
    init() {
        let good = goodEngine().handler
        var me: PhoneEngine?
        fake = FakeEngine { m, p, b in
            guard let e = me else { return (500, "{}") }
            switch p {
            case "/v2/phone-actions":
                guard e.actionsStatus == 200 else { return (e.actionsStatus, #"{"error":"boom"}"#) }
                let serverTime = PhoneBoard.isoUTC(Date().addingTimeInterval(e.serverAhead))
                return (200, String(decoding: try JSONSerialization.data(withJSONObject: ["actions": e.pending, "server_time": serverTime]), as: UTF8.self))
            case "/v2/phone-actions/ack":
                guard e.ackStatus == 200 else { return (e.ackStatus, #"{"error":"boom"}"#) }
                let obj = try JSONSerialization.jsonObject(with: b) as? [String: Any]
                let ids = Set((obj?["ids"] as? [String] ?? []) + (obj?["skipped"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
                e.pending.removeAll { ids.contains($0["id"] as? String ?? "") }
                return (200, #"{"ok":true}"#)
            case "/v2/board": return (200, #"{"ok":true,"count":0}"#)
            case "/v2/app/phones":
                return (200, #"{"phones":[{"id":"d1","name":"Pixel","created":"2026-11-10T08:00:00.000Z","last_seen":"2026-11-13T06:00:00.000Z","shares_passkey":0},{"id":"d2","name":"Old phone","created":"2026-11-11T08:00:00.000Z","last_seen":null,"shares_passkey":1}]}"#)
            case "/v2/app/phones/remove":
                let obj = try JSONSerialization.jsonObject(with: b) as? [String: Any]
                return obj?["device_id"] as? String == "d1" ? (200, #"{"ok":true,"name":"Pixel"}"#) : (404, #"{"error":"That phone isn't paired."}"#)
            case "/v2/app/pair": return (200, #"{"url":"https://engine.test/app/#pair=abc123","expires":"2026-11-12T10:10:00.000Z"}"#)
            default: return try good(m, p, b)
            }
        }
        me = self
    }
    /// `madeAt` is on the engine's clock; `clientID` is the phone's own id.
    func action(_ id: String, _ kind: String, card: Int64? = nil, title: String? = nil, group: String? = nil,
                madeAt: Date? = nil, clientID: String? = nil) {
        var row: [String: Any] = ["id": id, "card_id": card.map { $0 as Any } ?? NSNull(), "action": kind, "title": title.map { $0 as Any } ?? NSNull(),
                                  "group": group.map { $0 as Any } ?? NSNull(), "created": "2026-11-12T09:00:00.000Z"]
        if let madeAt { row["made_at"] = PhoneBoard.isoUTC(madeAt) }
        row["client_id"] = clientID.map { $0 as Any } ?? NSNull()
        pending.append(row)
    }
    var puts: Int { fake.requests.filter { $0.method == "PUT" && $0.path == "/v2/board" }.count }
    var ackedIDs: [String] { appliedIDs + skipped.map(\.id) }
    var appliedIDs: [String] { fake.bodies("/v2/phone-actions/ack").flatMap { $0["ids"] as? [String] ?? [] } }
    var skipped: [(id: String, reason: String)] {
        fake.bodies("/v2/phone-actions/ack").flatMap { ($0["skipped"] as? [[String: Any]] ?? []).map { ($0["id"] as? String ?? "", $0["reason"] as? String ?? "") } }
    }
}

@MainActor func phoneChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-phone-\(UUID().uuidString)")
    let store: Store
    do { store = Store(db: try DB(url: root.appendingPathComponent("phone.sqlite"))) } catch { check(false, "phone setup: \(error)"); return }
    let now = Date()
    let cal = Calendar.current
    func newest(_ title: String) -> Card? { store.cards.last { $0.title == title } }
    func warnings(_ id: String) -> [ActivityEntry] { connectorActivity(store, id).filter { $0.level != .info } }

    // Board payload: open tasks + done today, the engine's fields, local dates.
    store.add(title: "P all-day", area: "Work", importance: .high, due: Due.combine(day: now, time: nil))
    store.add(title: "P timed", area: "Personal", importance: .low,
              due: cal.date(bySettingHour: 14, minute: 30, second: 0, of: now), status: .doing)
    store.add(title: "P watch", area: "Work", importance: .medium, due: nil, status: .watch)
    store.add(title: "P done today", area: "Work", importance: .medium, due: nil)
    store.add(title: "P done before", area: "Work", importance: .medium, due: nil)
    store.add(title: "P withdrawn", area: "Work", importance: .medium, due: nil)
    store.add(title: "P deleted", area: "Work", importance: .medium, due: nil)
    guard let allDay = newest("P all-day"), let timed = newest("P timed"), let watch = newest("P watch"),
          let doneToday = newest("P done today"), let doneBefore = newest("P done before"),
          let withdrawn = newest("P withdrawn"), let deleted = newest("P deleted") else { check(false, "phone seed"); return }
    var linked = allDay; linked.link = "https://example.com/a"
    store.update(linked)
    var badLink = watch; badLink.link = "not a link"
    store.update(badLink)
    store.move(doneToday, to: .done, now: now)
    store.move(doneBefore, to: .done, now: now.addingTimeInterval(-3 * 86400))
    store.performForTest("UPDATE cards SET withdrawn=1 WHERE id=\(withdrawn.id)")
    store.delete(deleted)

    let payload = PhoneBoard.payload(store: store, now: now)
    let byID = Dictionary(uniqueKeysWithValues: payload.map { ($0.id, $0) })
    do {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        store.setLastBoardHash("abc", connector: "hashcheck", now: t0)
        check(store.lastBoardHash(connector: "hashcheck", now: t0.addingTimeInterval(60)) == "abc"
              && store.lastBoardHash(connector: "hashcheck", now: t0.addingTimeInterval(3601)) == nil,
              "phone_board_resent_after_an_hour_even_if_unchanged")
    }
    check(Set(payload.map(\.id)) == [allDay.id, timed.id, watch.id, doneToday.id] && payload.last?.id == doneToday.id,
          "phone_board_has_only_open_and_done_today")
    let dayRE = #"^\d{4}-\d{2}-\d{2}$"#
    let a = byID[allDay.id], t = byID[timed.id], w = byID[watch.id], d = byID[doneToday.id]
    let workHex = store.areas.first { $0.name == "Work" }?.colorHex
    let iso = ISO8601DateFormatter()
    check(a?.due?.range(of: dayRE, options: .regularExpression) != nil && a?.due == { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: now) }() && a?.hasTime == false
          && a?.group == "Work" && a?.color == workHex && a?.importance == 2 && a?.status == "todo" && a?.link == "https://example.com/a"
          && a?.doneAt == nil,
          "phone_board_all_day_due_is_local_date")
    check(t?.hasTime == true && t?.status == "doing" && t?.due.flatMap { iso.date(from: $0) } == timed.due
          && (t?.due?.hasSuffix("Z") == true || t?.due?.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) != nil),
          "phone_board_timed_due_is_iso_with_offset")
    check(w?.due == nil && w?.link == nil && w?.status == "watch" && d?.status == "done" && d?.doneAt.flatMap { iso.date(from: $0) } != nil,
          "phone_board_bad_link_null_and_done_at_set")
    do {
        let obj = try JSONSerialization.jsonObject(with: try PhoneBoard.body(payload)) as? [String: Any]
        let first = (obj?["cards"] as? [[String: Any]])?.first { ($0["id"] as? Int).map(Int64.init) == watch.id }
        check(first.map { Set($0.keys) == ["id", "title", "group", "color", "importance", "due", "has_time", "status", "link", "links", "done_at", "status_at"]
                          && $0["due"] is NSNull && $0["link"] is NSNull } ?? false, "phone_board_body_has_every_field")
    } catch { check(false, "phone_board_body_has_every_field: \(error)") }
    check(PhoneBoard.clip(String(repeating: "é", count: 150) + String(repeating: "😀", count: 100)).utf16.count <= 200,
          "phone_board_title_capped_at_200")

    // Push only when the board changed.
    do {
        let e = PhoneEngine()
        let r1 = await ConnectorSync.phoneTick(connector: "ph", store: store, client: e.fake.client(), now: now)
        let r2 = await ConnectorSync.phoneTick(connector: "ph", store: store, client: e.fake.client(), now: now)
        let firstBody = e.fake.bodies("/v2/board").first?["cards"] as? [[String: Any]]
        check(r1.pushed && !r2.pushed && e.puts == 1 && firstBody?.count == 4, "phone_board_unchanged_not_sent_again")
        store.setImportance(watch, .high)
        let r3 = await ConnectorSync.phoneTick(connector: "ph", store: store, client: e.fake.client(), now: now)
        check(r3.pushed && e.puts == 2, "phone_board_sent_after_a_change")
    }

    // Phone actions: a move is applied once and acked.
    do {
        let e = PhoneEngine()
        e.action("mv-1", "doing", card: allDay.id)
        let r = await ConnectorSync.phoneTick(connector: "ph", store: store, client: e.fake.client(), now: now)
        let moves = (try? store.db.query("SELECT actor FROM events WHERE card_id=? AND kind='moved'", [allDay.id]) { DB.text($0, 0) }) ?? [] // try?-ok: check helper
        check(store.card(allDay.id)?.status == .doing && r.acked == 1 && e.ackedIDs == ["mv-1"] && e.pending.isEmpty
              && moves == [Actor.user.stored], "phone_move_applied_once_and_acked")
        check(r.pushed && (e.fake.bodies("/v2/board").last?["cards"] as? [[String: Any]])?
                .first { ($0["id"] as? Int).map(Int64.init) == allDay.id }?["status"] as? String == "doing",
              "phone_board_sent_after_applying_actions")
    }

    // The same id twice (in one list, and again after a lost ack) is applied once.
    do {
        let e = PhoneEngine()
        e.action("add-1", "add", title: "Phone dup", group: "Work")
        e.action("add-1", "add", title: "Phone dup", group: "Work")
        e.ackStatus = 500
        let r1 = await ConnectorSync.phoneTick(connector: "ph", store: store, client: e.fake.client(), now: now)
        e.ackStatus = 200
        let r2 = await ConnectorSync.phoneTick(connector: "ph", store: store, client: e.fake.client(), now: now)
        check(r1.error != nil && r2.error == nil && store.cards.filter { $0.title == "Phone dup" }.count == 1 && e.pending.isEmpty,
              "phone_duplicate_action_applied_once")
    }

    // add: a To do task (medium, no due) in the named group, else the first group.
    do {
        let e = PhoneEngine()
        e.action("add-2", "add", title: "  Phone in Work  ", group: "Work")
        e.action("add-3", "add", title: "Phone nowhere", group: "No such group")
        e.action("add-4", "add", title: "Phone no group")
        _ = await ConnectorSync.phoneTick(connector: "ph", store: store, client: e.fake.client(), now: now)
        let first = store.areas.first?.name
        let w = newest("Phone in Work"), n = newest("Phone nowhere"), g = newest("Phone no group")
        check(w?.area == "Work" && w?.status == .todo && w?.importance == .medium && w?.due == nil && w?.connector == "",
              "phone_add_creates_todo_in_named_group")
        check(n?.area == first && g?.area == first && n?.status == .todo && e.pending.isEmpty, "phone_add_unknown_group_uses_first_group")
    }

    // Done on a connector card queues the connector's done event (and asks for a sync to send it).
    do {
        store.performForTest("INSERT OR IGNORE INTO connectors(id,name,settings_json,settings_version) VALUES('phc','phc','{}',1)")
        store.reload()
        store.seedCard(title: "Phone email task", area: "Work", importance: .medium, source: "phc", externalID: "email:ph-1")
        guard let c = store.card(externalID: "email:ph-1") else { check(false, "phone connector card seed"); return }
        let doneEvents = { store.pendingOutbox(connector: "phc", limit: 50, now: .distantFuture).filter { $0.kind == .done }.count }
        let before = doneEvents()
        let e = PhoneEngine()
        e.action("dn-1", "done", card: c.id)
        let r = await ConnectorSync.phoneTick(connector: "ph", store: store, client: e.fake.client(), now: now)
        check(store.card(c.id)?.status == .done && doneEvents() == before + 1 && e.pending.isEmpty, "phone_done_on_connector_card_queues_done_event")
        let e2 = PhoneEngine()
        guard let c2 = newest("Phone in Work") else { check(false, "phone queued flag seed"); return }
        e2.action("dn-2", "done", card: c2.id)
        let r2 = await ConnectorSync.phoneTick(connector: "phc", store: store, client: e2.fake.client(), now: now)
        let e3 = PhoneEngine()
        guard let c3 = store.card(externalID: "email:ph-1") else { return }
        store.move(c3, to: .todo)
        e3.action("dn-3", "done", card: c3.id)
        let r3 = await ConnectorSync.phoneTick(connector: "phc", store: store, client: e3.fake.client(), now: now)
        check(!r2.queuedEvents && r3.queuedEvents && r.acked == 1, "phone_tick_reports_queued_engine_events")
    }

    // Unknown and deleted cards: acked and logged (count and ids only, no titles).
    do {
        let e = PhoneEngine()
        e.action("un-1", "done", card: 987_654)
        e.action("un-2", "doing", card: deleted.id)
        _ = await ConnectorSync.phoneTick(connector: "ph", store: store, client: e.fake.client(), now: now)
        let line = connectorActivity(store, "ph").first { $0.message.contains("no longer on the board") }
        check(Set(e.ackedIDs) == ["un-1", "un-2"] && e.appliedIDs.isEmpty && e.skipped.allSatisfy { $0.reason == "gone" } && e.pending.isEmpty && line?.message.hasPrefix("2 ") == true
              && line?.detail?.contains("987654") == true && store.card(deleted.id) == nil, "phone_unknown_card_acked_and_logged")
        let texts = connectorActivity(store, "ph").map { $0.message + ($0.detail ?? "") }.joined(separator: "\n")
        check(!texts.contains("Phone in Work") && !texts.contains("Phone dup") && !texts.contains("P all-day"), "phone_activity_has_no_task_titles")
    }

    // An engine without the phone app (404): no error, nothing logged, sync still fine.
    do {
        let before = warnings("old").count
        let eng = goodEngine()
        let r = await ConnectorSync.phoneTick(connector: "old", store: store, client: eng.client(), now: now)
        let s = await ConnectorSync.run(connector: "old", store: store, client: eng.client(), now: now)
        check(!r.supported && r.error == nil && s.error == nil && warnings("old").count == before
              && ConnectorSync.phoneSupport["old"] == false && connectorRow(store, "old", "unreachable_since") == "",
              "phone_404_engine_skipped_quietly")
    }

    // A failing engine is logged once, not on every poll, and never fails the main sync.
    do {
        let e = PhoneEngine()
        e.actionsStatus = 500
        for _ in 0..<3 { _ = await ConnectorSync.phoneTick(connector: "flaky", store: store, client: e.fake.client(), now: now) }
        let s = await ConnectorSync.run(connector: "flaky", store: store, client: e.fake.client(), now: now)
        check(warnings("flaky").count == 1 && s.error == nil, "phone_error_logged_once_and_sync_still_ok")
        e.actionsStatus = 200
        let r = await ConnectorSync.phoneTick(connector: "flaky", store: store, client: e.fake.client(), now: now)
        check(r.error == nil && connectorActivity(store, "flaky").contains { $0.message.contains("in sync again") }, "phone_recovery_logged")
    }

    // Applied ids are forgotten after 7 days.
    do {
        let old = now.addingTimeInterval(-8 * 86400)
        store.performForTest("INSERT OR REPLACE INTO meta(key,value) VALUES('phone_action:ph:ancient','\(old.timeIntervalSince1970)')")
        _ = store.applyPhoneActions([], connector: "ph", now: now)
        let left = (try? store.db.query("SELECT count(*) FROM meta WHERE key='phone_action:ph:ancient'") { DB.int($0, 0) }.first) ?? -1 // try?-ok: check helper
        let kept = (try? store.db.query("SELECT count(*) FROM meta WHERE key='phone_action:ph:mv-1'") { DB.int($0, 0) }.first) ?? -1 // try?-ok: check helper
        check(left == 0 && kept == 1, "phone_applied_ids_kept_7_days")
    }

    // Sync v2: each card's status_at, sent_at, and newest change wins.
    do {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        store.add(title: "V2 status", area: "Work", importance: .medium, due: nil)
        store.add(title: "V2 fresh", area: "Work", importance: .medium, due: nil)
        guard let v = newest("V2 status"), let fresh = newest("V2 fresh") else { check(false, "phone v2 seed"); return }
        store.move(v, to: .doing, now: t0)
        let p1 = PhoneBoard.payload(store: store, now: now)
        let b1 = p1.first { $0.id == v.id }, f1 = p1.first { $0.id == fresh.id }
        check(b1?.statusAt == "2027-01-15T08:00:00.000Z" && b1?.statusAt.flatMap(PhoneBoard.parseISO) == t0
              && f1?.statusAt.flatMap(PhoneBoard.parseISO).map { abs($0.timeIntervalSince(fresh.created)) < 0.001 } == true,
              "phone_v2_status_at_is_last_step_change")
        let h1 = try PhoneBoard.hash(p1, engine: "e")
        guard let v1 = store.card(v.id) else { return }
        store.move(v1, to: .todo, now: t0.addingTimeInterval(10))
        guard let v2 = store.card(v.id) else { return }
        store.move(v2, to: .doing, now: t0.addingTimeInterval(20))
        let p2 = PhoneBoard.payload(store: store, now: now)
        let h2 = try PhoneBoard.hash(p2, engine: "e")
        check(h1 != h2 && p2.first { $0.id == v.id }?.status == "doing" && p2.first { $0.id == v.id }?.statusAt == PhoneBoard.isoUTC(t0.addingTimeInterval(20)),
              "phone_v2_step_change_changes_hash")

        // Store level, engine clock exactly 2 h ahead: equal time goes to the phone, a millisecond older loses.
        store.add(title: "V2 tie", area: "Work", importance: .medium, due: nil)
        store.add(title: "V2 older", area: "Work", importance: .medium, due: nil)
        guard let tie = newest("V2 tie"), let older = newest("V2 older") else { return }
        store.move(tie, to: .watch, now: t0)
        store.move(older, to: .watch, now: t0)
        let r = store.applyPhoneActions([
            PhoneAction(id: "s-tie", clientID: "c-tie", cardID: tie.id, action: "doing", madeAt: t0.addingTimeInterval(7200)),
            PhoneAction(id: "s-older", clientID: "c-older", cardID: older.id, action: "doing", madeAt: t0.addingTimeInterval(7200 - 0.01)),
        ], connector: "v2s", now: t0.addingTimeInterval(100), engineAhead: 7200)
        check(store.card(tie.id)?.status == .doing && r.applied == ["s-tie"], "phone_v2_equal_time_goes_to_the_phone")
        check(store.card(older.id)?.status == .watch && r.skipped == [PhoneSkip(id: "s-older", reason: "superseded")],
              "phone_v2_clock_conversion_orders_correctly")
    } catch { check(false, "phone v2 status_at: \(error)") }

    // End to end: engine clock 2 h ahead of the Mac's.
    do {
        let n2 = Date()
        let tMac = n2.addingTimeInterval(-600)
        let ahead: TimeInterval = 7200
        for t in ["V2 lose", "V2 win", "V2 two"] { store.add(title: t, area: "Work", importance: .medium, due: nil) }
        guard let lose = newest("V2 lose"), let win = newest("V2 win"), let two = newest("V2 two") else { check(false, "phone v2 e2e seed"); return }
        // The tasks were made before the Mac's change (their created rows are moved back an hour).
        store.performForTest("UPDATE events SET at=\(tMac.timeIntervalSince1970 - 3600) WHERE kind='created' AND card_id IN (\(lose.id),\(win.id),\(two.id))")
        for c in [lose, win, two] { store.move(c, to: .watch, now: tMac) }
        let e = PhoneEngine()
        e.serverAhead = ahead
        // Made 60 s before the Mac's change: on the engine's clock it reads 2 h later, but it is older.
        e.action("sv-lose", "doing", card: lose.id, madeAt: tMac.addingTimeInterval(-60 + ahead), clientID: "cl-lose")
        e.action("sv-win", "doing", card: win.id, madeAt: tMac.addingTimeInterval(60 + ahead), clientID: "cl-win")
        e.action("sv-two-a", "doing", card: two.id, madeAt: tMac.addingTimeInterval(60 + ahead), clientID: "cl-two-a")
        e.action("sv-two-b", "done", card: two.id, madeAt: tMac.addingTimeInterval(120 + ahead), clientID: "cl-two-b")
        e.action("sv-gone", "doing", card: 987_655, madeAt: tMac.addingTimeInterval(ahead), clientID: "cl-gone")
        e.action("sv-add-1", "add", title: "V2 phone add", group: "Work", madeAt: tMac.addingTimeInterval(ahead), clientID: "cl-add")
        e.action("sv-add-2", "add", title: "V2 phone add", group: "Work", madeAt: tMac.addingTimeInterval(ahead), clientID: "cl-add")
        let r = await ConnectorSync.phoneTick(connector: "v2", store: store, client: e.fake.client(), now: n2)
        let skipped = Dictionary(e.skipped.map { ($0.id, $0.reason) }, uniquingKeysWith: { a, _ in a })
        check(store.card(lose.id)?.status == .watch && skipped["sv-lose"] == "superseded" && !e.appliedIDs.contains("sv-lose"),
              "phone_v2_older_phone_move_skipped_as_superseded")
        check(store.card(win.id)?.status == .doing && e.appliedIDs.contains("sv-win"), "phone_v2_newer_phone_move_applied")
        check(store.card(two.id)?.status == .done && e.appliedIDs.contains("sv-two-a") && e.appliedIDs.contains("sv-two-b"),
              "phone_v2_two_phone_moves_in_one_batch_both_apply")
        check(skipped["sv-gone"] == "gone" && !e.appliedIDs.contains("sv-gone"), "phone_v2_gone_card_skipped_as_gone")
        check(store.cards.filter { $0.title == "V2 phone add" }.count == 1 && e.appliedIDs.contains("sv-add-1") && e.appliedIDs.contains("sv-add-2")
              && e.pending.isEmpty && r.acked == 7 && r.skipped == 2, "phone_v2_add_applied_once_by_client_id")
        let line = connectorActivity(store, "v2").first { $0.message == "Kept a newer change from this Mac" }
        let texts = connectorActivity(store, "v2").map { $0.message + ($0.detail ?? "") }.joined(separator: "\n")
        check(line?.detail?.hasPrefix("1 ") == true && !texts.contains("V2 "), "phone_v2_kept_mac_change_logged_without_titles")
        let sent = e.fake.bodies("/v2/board").last
        let winSent = (sent?["cards"] as? [[String: Any]])?.first { ($0["id"] as? Int).map(Int64.init) == win.id }
        let winAt = (winSent?["status_at"] as? String).flatMap(PhoneBoard.parseISO)
        let sentAt = (sent?["sent_at"] as? String).flatMap(PhoneBoard.parseISO)
        check(r.pushed && sentAt.map { abs($0.timeIntervalSinceNow) < 60 } == true
              && winAt.map { abs($0.timeIntervalSince(tMac.addingTimeInterval(60))) < 2 } == true,
              "phone_v2_board_sends_sent_at_and_applied_move_time")
    }

    // Pairing.
    do {
        let e = PhoneEngine()
        let p = try await e.fake.client().pairPhone()
        check(p.url.absoluteString == "https://engine.test/app/#pair=abc123" && p.expires == ISO8601DateFormatter().date(from: "2026-11-12T10:10:00Z")
              && e.fake.requests.last?.method == "POST", "phone_pairing_returns_url")
    } catch { check(false, "phone_pairing_returns_url: \(error)") }
    // Paired phones: list and disconnect.
    do {
        let e = PhoneEngine()
        let phones = try await e.fake.client().phones()
        check(phones.map(\.name) == ["Pixel", "Old phone"] && phones[0].lastSeen != nil && phones[1].lastSeen == nil
              && phones[1].sharesPasskey == 1, "paired_phones_are_listed")
        let name = try await e.fake.client().removePhone(id: "d1")
        let sent = e.fake.requests.last
        check(name == "Pixel" && sent?.method == "POST" && sent?.path == "/v2/app/phones/remove", "disconnect_phone_sends_its_id")
    } catch { check(false, "paired_phones: \(error)") }
    do {
        _ = try await PhoneEngine().fake.client().removePhone(id: "gone")
        check(false, "disconnect_unknown_phone_fails")
    } catch { check(true, "disconnect_unknown_phone_fails") }
    do {
        _ = try await goodEngine().client().pairPhone()
        check(false, "phone_pairing_on_old_engine_says_no_phone_app")
    } catch { check((error as? ConnectorError) == .noPhoneApp, "phone_pairing_on_old_engine_says_no_phone_app") }
}
