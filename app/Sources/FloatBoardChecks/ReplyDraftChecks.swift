import Foundation
import FloatBoardCore
import FloatBoardConnectors
import SQLite3

/// Reads rows straight from SQLite on a read-only connection.
private func rows(_ url: URL, _ sql: String) -> [[String?]] {
    var h: OpaquePointer?
    defer { sqlite3_close(h) }
    guard sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
    var st: OpaquePointer?
    defer { sqlite3_finalize(st) }
    guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK else { return [] }
    var out: [[String?]] = []
    while sqlite3_step(st) == SQLITE_ROW {
        out.append((0..<sqlite3_column_count(st)).map { i in sqlite3_column_text(st, i).map { String(cString: $0) } })
    }
    return out
}

private func execRaw(_ url: URL, _ sql: String) -> Bool {
    var h: OpaquePointer?
    defer { sqlite3_close(h) }
    return sqlite3_open(url.path, &h) == SQLITE_OK && sqlite3_exec(h, sql, nil, nil, nil) == SQLITE_OK
}

/// Collapses layout differences in stored CREATE statements (ALTER TABLE ADD COLUMN appends to the stored text).
private func norm(_ rows: [[String?]]) -> [[String?]] {
    rows.map { $0.map { $0.map { s in
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*([(),])\s*"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    } } }
}

private let masterSQL = "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name"
private let draftColumns = ["reply_draft_state", "reply_draft_link", "reply_draft_error", "reply_draft_request", "reply_draft_sent_at"]

/// Counts and content that an upgrade must keep exactly.
private func boardFacts(_ url: URL) -> [String: [[String?]]] {
    [
        "cards": rows(url, "SELECT count(*) FROM cards"),
        "events": rows(url, "SELECT count(*) FROM events"),
        "areas": rows(url, "SELECT count(*) FROM areas"),
        "outbox": rows(url, "SELECT count(*) FROM outbox"),
        "connectors": rows(url, "SELECT count(*) FROM connectors"),
        "card_rows": rows(url, """
            SELECT id,title,notes,area,importance,due,status,created,started,done,updated,deleted,link,gcal_account,gcal_event,
                   gcal_link,source,external_id,source_link,source_meta,imported_at,source_mid,source_sent,withdrawn,ai_summary,
                   connector,proposal_json FROM cards ORDER BY id
            """),
        "event_rows": rows(url, "SELECT * FROM events ORDER BY id"),
        "area_rows": rows(url, "SELECT * FROM areas ORDER BY id"),
    ]
}

private func integrity(_ url: URL) -> String { rows(url, "PRAGMA integrity_check").first?.first.flatMap { $0 } ?? "" }

/// The launch flow on one file: back up first when it needs migrating (as the app's launch does), then open it.
@MainActor private func launch(_ url: URL, backups dir: URL) -> (backedUp: Bool, store: Store?, error: String?) {
    var backedUp = false
    if Backups.migrationCheck(url).needed {
        do { _ = try Backups(dbURL: url, dir: dir).snapshot(reason: "pre-migrate"); backedUp = true } catch {
            return (false, nil, "backup: \(error)")
        }
    }
    do { return (backedUp, Store(db: try DB(url: url)), nil) } catch { return (backedUp, nil, "\(error)") }
}

@MainActor private func makeStore(_ root: URL, _ name: String) throws -> Store {
    let db = try DB(url: root.appendingPathComponent(name))
    try db.run("INSERT INTO connectors(id,name,base_url,settings_json,settings_version) VALUES('email','email','https://engine.test','{}',1)")
    return Store(db: db)
}

/// A connector card from the engine, with Notes written by the user.
@MainActor private func emailCard(_ store: Store, mid: String, sent: String = "2026-11-07T10:00:00.000Z",
                                  notes: String = "Say yes to Tuesday 3pm") throws -> Card {
    let p = Proposal(id: "task-\(mid)", kind: .task, sourceKey: SourceKey(messageID: mid, sentAt: sent), title: "Reply about the meeting",
                     why: "asked", due: nil, hasTime: false, group: nil, importance: 1, sourceLabel: "inbox", link: "",
                     summary: nil, taskRef: nil, learned: nil, provenance: Provenance(model: "m", skillVersion: "1", created: "2026-11-07"))
    _ = try Reconciler.apply([p], connector: "email", store: store, defaultGroup: "Personal", autoAdd: true)
    guard var card = store.cards.first(where: { $0.sourceKey?.messageID == mid }) else { throw DBError.sql("card not added") }
    card.notes = notes
    store.update(card)
    try store.db.run("UPDATE cards SET source_meta=? WHERE id=?", [#"{"itemId":"item-\#(mid)","why":"asked"}"#, card.id])
    store.reload()
    return store.card(card.id) ?? card
}

private func draftProposal(id: String, mid: String, sent: String = "2026-11-07T10:00:00.000Z", request: String,
                           link: String?, why: String?) -> Proposal {
    Proposal(id: id, kind: .draft, sourceKey: SourceKey(messageID: mid, sentAt: sent), title: "", why: why ?? "", due: nil,
             hasTime: false, group: nil, importance: 1, sourceLabel: "me@example.com", link: link ?? "", summary: nil,
             taskRef: request, learned: nil, provenance: Provenance(model: "m", skillVersion: "1", created: "2026-11-08T09:00:00Z"))
}

@MainActor private func outbox(_ store: Store) -> [(uuid: String, kind: String, payload: [String: String], sent: String?)] {
    let r = (try? store.db.query("SELECT uuid,kind,payload_json,sent FROM outbox ORDER BY created, rowid") { s in // try?-ok: a failed query fails the check
        (DB.text(s, 0), DB.text(s, 1), DB.text(s, 2), sqlite3_column_type(s, 3) == SQLITE_NULL ? nil : DB.text(s, 3)) }) ?? []
    return r.map { ($0.0, $0.1, ((try? JSONSerialization.jsonObject(with: Data($0.2.utf8))) as? [String: String]) ?? [:], $0.3) } // try?-ok: bad json fails the check
}

@MainActor private func history(_ store: Store, _ id: Int64) -> [String] {
    (try? store.db.query("SELECT kind FROM events WHERE card_id=? ORDER BY id", [id]) { DB.text($0, 0) }) ?? [] // try?-ok: a failed query fails the check
}

@MainActor func replyDraftChecks() async {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("fb-drafts-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? fm.removeItem(at: root) } // try?-ok: scratch folder cleanup
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures")

    // MARK: Schema 8

    // A v7 board (as every board was before this version) gets the five columns and keeps everything else.
    let v7 = root.appendingPathComponent("v7.sqlite")
    do {
        guard execRaw(v7, v7Schema + """
            PRAGMA user_version = 7;
            INSERT INTO areas(name,color,position) VALUES('Work','#0A84FF',0),('Personal','#30D158',1),('Side','#FF9F0A',2);
            INSERT INTO cards(title,notes,area,importance,due,status,created,updated,connector,source,source_mid,source_sent,source_meta,
                              proposal_json) VALUES('Typed','my note','Work',2,1800000000,'todo',1790000000,1790000001,'','',NULL,NULL,'{}','');
            INSERT INTO cards(title,notes,area,importance,status,created,connector,source,source_mid,source_sent,source_meta,ai_summary)
                VALUES('From mail','','Personal',1,'doing',1790000100,'email','email','<m@x>','2026-11-01T10:00:00Z','{"itemId":"i1"}','sum');
            INSERT INTO events(card_id,at,kind,actor,uuid) VALUES(1,1790000000,'created','user','u1'),(2,1790000100,'created (from email)','connector:email','u2'),
                (2,1790000200,'moved','user','u3');
            INSERT INTO connectors(id,name,settings_json,settings_version) VALUES('email','email','{"learned":"x"}',3);
            INSERT INTO outbox(uuid,connector,kind,payload_json,created,next_try) VALUES('o1','email','done','{"source_mid":"<m@x>"}',1,1);
            """) else { throw DBError.sql("could not build the v7 board") }
        let before = boardFacts(v7)
        let bk = root.appendingPathComponent("v7-bk")
        let opened = launch(v7, backups: bk)
        let cols = rows(v7, "PRAGMA table_info(cards)").compactMap { $0[1] ?? nil }
        let backup = Backups(dbURL: v7, dir: bk).list().first
        let backupVersion = backup.map { rows($0.url, "PRAGMA user_version") } ?? []
        check(opened.store != nil && opened.backedUp && backupVersion == [["7"]] && boardFacts(v7) == before
              && integrity(v7) == "ok" && rows(v7, "PRAGMA user_version") == [["8"]]
              && Array(cols.suffix(5)) == draftColumns
              && rows(v7, "SELECT reply_draft_state,reply_draft_link,reply_draft_error,reply_draft_request,reply_draft_sent_at FROM cards WHERE id=2")
                == [[nil, "", "", "", nil]]
              && opened.store?.card(2)?.replyDraftState == nil,
              "v7_board_upgrades_to_v8_keeping_everything" + (opened.error.map { ": \($0)" } ?? ""))
        // Reopening the upgraded board changes nothing and needs no further backup.
        let schemaAfter = rows(v7, masterSQL)
        do { _ = try DB(url: v7) } catch { check(false, "upgraded_board_reopens: \(error)") }
        check(rows(v7, masterSQL) == schemaAfter && !Backups.migrationCheck(v7).needed, "upgraded_board_reopens_unchanged")
        // v7 backups stay restorable: this version can open them.
        check(Backups(dbURL: v7, dir: bk).restorable().count == 1, "v7_backups_stay_restorable")
    } catch { check(false, "v7_board_upgrades_to_v8_keeping_everything: \(error)") }

    // A new board has exactly the shape of an upgraded one (and of the real board's upgrade, kept as a fixture).
    do {
        let fresh = root.appendingPathComponent("fresh8.sqlite")
        _ = try DB(url: fresh)
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("schema-v8.json"))) as? [[Any]] ?? []
        let expected = raw.map { $0.map { $0 as? String } }
        let freshRows = norm(rows(fresh, masterSQL))
        check(!expected.isEmpty && freshRows == norm(rows(v7, masterSQL)) && freshRows == norm(expected),
              "fresh_schema_matches_upgraded_schema")
    } catch { check(false, "fresh_schema_matches_upgraded_schema: \(error)") }

    // Proof on a copy of a real board (the path is given by the caller; never the live board).
    if let proof = ProcessInfo.processInfo.environment["FLOATBOARD_UPGRADE_PROOF"] {
        let url = URL(fileURLWithPath: proof)
        let before = boardFacts(url)
        let startVersion = rows(url, "PRAGMA user_version")
        let opened = launch(url, backups: root.appendingPathComponent("proof-bk"))
        let n = { (k: String) in before[k]?.first?.first.flatMap { $0 } ?? "?" }
        print("PROOF \(url.lastPathComponent): user_version \(startVersion.first?.first.flatMap { $0 } ?? "?") -> "
              + "\(rows(url, "PRAGMA user_version").first?.first.flatMap { $0 } ?? "?"), cards \(n("cards")), events \(n("events")), "
              + "areas \(n("areas")), integrity \(integrity(url)), pre-migrate backup \(opened.backedUp), "
              + "app cards loaded \(opened.store?.cards.count ?? -1)")
        check(opened.store != nil && boardFacts(url) == before && integrity(url) == "ok"
              && rows(url, "PRAGMA user_version") == [["8"]], "real_board_copy_upgrades_unchanged" + (opened.error.map { ": \($0)" } ?? ""))
    }

    // MARK: Requests

    do {
        let store = try makeStore(root, "request.sqlite")
        let card = try emailCard(store, mid: "<q1@x>", notes: "  Say yes to Tuesday 3pm  ")
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let request = try store.requestReplyDraft(cardID: card.id, now: now)
        let ob = outbox(store)
        let c = store.card(card.id)
        check(ob.count == 1 && ob[0].kind == "draft_reply" && ob[0].kind == OutboxKind.draftReply.rawValue
              && Set(ob[0].payload.keys) == ["source_mid", "source_sent", "item_id", "notes", "request_id"]
              && ob[0].payload["source_mid"] == "<q1@x>" && ob[0].payload["source_sent"] == "2026-11-07T10:00:00.000Z"
              && ob[0].payload["item_id"] == "item-<q1@x>" && ob[0].payload["notes"] == "Say yes to Tuesday 3pm"
              && ob[0].payload["request_id"] == request && !request.isEmpty
              && c?.replyDraftState == .requested && c?.replyDraftRequest == request && c?.replyDraftError == ""
              && c?.replyDraftSentAt == nil && history(store, card.id).last == "Reply draft requested",
              "request_queues_outbox_and_history")
        // A second press before anything was tried replaces the untried row: one row, carrying the newest request.
        let second = try store.requestReplyDraft(cardID: card.id, now: now.addingTimeInterval(5))
        check(second != request && store.card(card.id)?.replyDraftRequest == second && outbox(store).count == 1
              && outbox(store).first?.payload["request_id"] == second, "second_press_before_send_replaces_untried_request")
        // A row already attempted may be held by the engine: the next press gets its own row.
        store.markFailed(outbox(store).map(\.uuid), error: "offline", now: now.addingTimeInterval(6))
        let again = try store.requestReplyDraft(cardID: card.id, now: now.addingTimeInterval(7))
        check(again != second && store.card(card.id)?.replyDraftRequest == again && outbox(store).count == 2,
              "second_request_replaces_the_first")
        // The engine receives notes and request_id (the client sends only known keys).
        let eng = goodEngine()
        _ = await ConnectorSync.run(connector: "email", store: store, client: eng.client(), now: now.addingTimeInterval(100))
        let sentPayloads = eng.bodies("/v2/events").flatMap { ($0["events"] as? [[String: Any]] ?? []) }
            .filter { $0["kind"] as? String == "draft_reply" }.compactMap { $0["payload"] as? [String: String] }
        check(sentPayloads.count == 2 && sentPayloads.allSatisfy { Set($0.keys) == ["source_mid", "source_sent", "item_id", "notes", "request_id"] }
              && sentPayloads.last?["request_id"] == again, "draft_request_payload_reaches_engine")
        // Only the current request's delivery starts its clock.
        check(store.card(card.id)?.replyDraftSentAt == now.addingTimeInterval(100), "mark_sent_sets_reply_draft_sent_at")
    } catch { check(false, "request_queues_outbox_and_history: \(error)") }

    do {
        let store = try makeStore(root, "inflight.sqlite")
        let card = try emailCard(store, mid: "<f1@x>")
        let t = Date(timeIntervalSince1970: 1_900_000_000)
        _ = try store.requestReplyDraft(cardID: card.id, now: t)
        let flying = outbox(store).map(\.uuid)
        store.setOutboxInFlight(flying, true)
        _ = try store.requestReplyDraft(cardID: card.id, now: t.addingTimeInterval(1))
        let kept = outbox(store).count == 2 && flying.allSatisfy { f in outbox(store).contains { $0.uuid == f } }
        store.setOutboxInFlight(flying, false)
        check(kept, "second_press_leaves_in_flight_row_alone")
    } catch { check(false, "second_press_leaves_in_flight_row_alone: \(error)") }

    // A delivered draft request and its card's sent time are one change: both happen or neither.
    do {
        let file = "atomic.sqlite"
        let store = try makeStore(root, file)
        let card = try emailCard(store, mid: "<a1@x>")
        let t = Date(timeIntervalSince1970: 1_900_000_000)
        _ = try store.requestReplyDraft(cardID: card.id, now: t)
        let url = root.appendingPathComponent(file)
        let armed = execRaw(url, """
            CREATE TRIGGER block_sent_at BEFORE UPDATE OF reply_draft_sent_at ON cards
            WHEN NEW.reply_draft_sent_at IS NOT NULL BEGIN SELECT RAISE(ABORT, 'blocked'); END
            """)
        store.markSent(outbox(store).map(\.uuid), now: t.addingTimeInterval(1))
        let split = rows(url, """
            SELECT count(*) FROM outbox o WHERE o.kind='draft_reply' AND o.sent IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM cards c WHERE c.reply_draft_sent_at IS NOT NULL)
            """).first?.first.flatMap { $0 } ?? "?"
        _ = execRaw(url, "DROP TRIGGER block_sent_at")
        store.markSent(outbox(store).map(\.uuid), now: t.addingTimeInterval(2))
        let whole = rows(url, """
            SELECT count(*) FROM outbox o JOIN cards c ON 1=1
            WHERE o.kind='draft_reply' AND o.sent IS NOT NULL AND c.reply_draft_sent_at IS NOT NULL
            """).first?.first.flatMap { $0 } ?? "?"
        check(armed && split == "0" && whole == "1" && store.card(card.id)?.replyDraftSentAt == t.addingTimeInterval(2),
              "sent_draft_row_always_has_card_sent_time")
    } catch { check(false, "sent_draft_row_always_has_card_sent_time: \(error)") }

    do {
        let store = try makeStore(root, "refuse.sqlite")
        let noNotes = try emailCard(store, mid: "<q2@x>", notes: "   \n ")
        store.add(title: "Typed only", area: "Personal", importance: .low, due: nil)
        guard var typed = store.cards.first(where: { $0.title == "Typed only" }) else { throw DBError.sql("no typed card") }
        typed.notes = "Some notes"
        store.update(typed)
        var errors: [String] = []
        for id in [noNotes.id, typed.id, 99_999] {
            do { _ = try store.requestReplyDraft(cardID: id, now: Date()); errors.append("") } catch { errors.append("\(error)") }
        }
        check(errors.allSatisfy { !$0.isEmpty && !$0.contains("\u{2014}") } && outbox(store).isEmpty
              && store.card(noNotes.id)?.replyDraftState == nil && store.card(typed.id)?.replyDraftState == nil
              && !history(store, noNotes.id).contains("Reply draft requested"),
              "request_refused_without_notes_or_source")
        check(errors.first == "Write what to say in Notes first.", "request_refused_without_notes_says_why")
    } catch { check(false, "request_refused_without_notes_or_source: \(error)") }

    // MARK: Results

    do {
        let store = try makeStore(root, "results.sqlite")
        let card = try emailCard(store, mid: "<r1@x>")
        let old = try store.requestReplyDraft(cardID: card.id, now: Date())
        let new = try store.requestReplyDraft(cardID: card.id, now: Date())
        let s1 = try Reconciler.apply([draftProposal(id: "d1", mid: "<r1@x>", request: old, link: "https://mail.google.com/old", why: nil)],
                                      connector: "email", store: store, defaultGroup: "Personal", autoAdd: true)
        let afterOld = store.card(card.id)
        let ignored = afterOld?.replyDraftState == .requested && afterOld?.replyDraftLink == "" && s1.drafts == 0
            && !history(store, card.id).contains("Reply draft ready")
        let s2 = try Reconciler.apply([draftProposal(id: "d2", mid: "<r1@x>", request: new, link: "https://mail.google.com/new", why: nil)],
                                      connector: "email", store: store, defaultGroup: "Personal", autoAdd: true)
        let c = store.card(card.id)
        check(ignored && s2.drafts == 1 && c?.replyDraftState == .ready && c?.replyDraftLink == "https://mail.google.com/new",
              "older_result_ignored_newer_applied")
        // The same result delivered again adds nothing.
        let before = history(store, card.id).count
        _ = try Reconciler.apply([draftProposal(id: "d2", mid: "<r1@x>", request: new, link: "https://mail.google.com/new", why: nil)],
                                 connector: "email", store: store, defaultGroup: "Personal", autoAdd: true)
        check(history(store, card.id).count == before, "repeated_result_adds_no_history")
    } catch { check(false, "older_result_ignored_newer_applied: \(error)") }

    do {
        let store = try makeStore(root, "states.sqlite")
        let card = try emailCard(store, mid: "<s1@x>")
        let r1 = try store.requestReplyDraft(cardID: card.id, now: Date())
        _ = try Reconciler.apply([draftProposal(id: "f1", mid: "<s1@x>", request: r1, link: nil, why: "The inbox isn't connected")],
                                 connector: "email", store: store, defaultGroup: "Personal", autoAdd: true)
        let failed = store.card(card.id)
        let failedOK = failed?.replyDraftState == .failed && failed?.replyDraftError == "The inbox isn't connected"
            && history(store, card.id).last == "Reply draft failed"
        let r2 = try store.requestReplyDraft(cardID: card.id, now: Date())
        let retried = store.card(card.id)
        let retryClears = retried?.replyDraftState == .requested && retried?.replyDraftError == ""
        _ = try Reconciler.apply([draftProposal(id: "g1", mid: "<s1@x>", request: r2, link: "https://mail.google.com/x", why: nil)],
                                 connector: "email", store: store, defaultGroup: "Personal", autoAdd: true)
        let ready = store.card(card.id)
        let actors = (try? store.db.query("SELECT actor FROM events WHERE card_id=? AND kind IN ('Reply draft ready','Reply draft failed')", // try?-ok: a failed query fails the check
                                          [card.id]) { DB.text($0, 0) }) ?? []
        check(failedOK && retryClears && ready?.replyDraftState == .ready && ready?.replyDraftLink == "https://mail.google.com/x"
              && ready?.replyDraftError == "" && history(store, card.id).last == "Reply draft ready"
              && actors == ["connector:email", "connector:email"], "ready_and_failed_results_update_card")
    } catch { check(false, "ready_and_failed_results_update_card: \(error)") }

    // Timed out, then the answer arrives late: the current request's result still counts.
    do {
        let store = try makeStore(root, "late.sqlite")
        let card = try emailCard(store, mid: "<l1@x>")
        let t = Date(timeIntervalSince1970: 1_900_000_000)
        let r = try store.requestReplyDraft(cardID: card.id, now: t)
        store.markSent(outbox(store).map(\.uuid), now: t)
        store.expireReplyDrafts(now: t.addingTimeInterval(700))
        let timedOut = store.card(card.id)?.replyDraftState == .failed
        _ = try Reconciler.apply([draftProposal(id: "late1", mid: "<l1@x>", request: r, link: "https://mail.google.com/late", why: nil)],
                                 connector: "email", store: store, defaultGroup: "Personal", autoAdd: true)
        check(timedOut && store.card(card.id)?.replyDraftState == .ready && store.card(card.id)?.replyDraftError == "",
              "late_result_for_current_request_applies_after_timeout")
    } catch { check(false, "late_result_for_current_request_applies_after_timeout: \(error)") }

    // MARK: Offline, restart, timeout

    do {
        let file = "restart.sqlite"
        var store = try makeStore(root, file)
        let card = try emailCard(store, mid: "<o1@x>")
        let pressed = Date(timeIntervalSince1970: 1_900_000_000)
        let request = try store.requestReplyDraft(cardID: card.id, now: pressed)
        let offline = FakeEngine { _, _, _ in throw URLError(.notConnectedToInternet) }
        _ = await ConnectorSync.run(connector: "email", store: store, client: offline.client(), now: pressed.addingTimeInterval(1))
        // Quit and relaunch.
        store = Store(db: try DB(url: root.appendingPathComponent(file)))
        let pending = store.pendingOutbox(connector: "email", limit: 50, now: pressed.addingTimeInterval(10_000))
        store.expireReplyDrafts(now: pressed.addingTimeInterval(10_000))   // never sent: no clock yet
        let survived = pending.count == 1 && pending[0].kind == .draftReply && pending[0].payload["request_id"] == request
            && store.card(card.id)?.replyDraftState == .requested && store.card(card.id)?.replyDraftSentAt == nil
        let sentAt = pressed.addingTimeInterval(20_000)
        _ = await ConnectorSync.run(connector: "email", store: store, client: goodEngine().client(), now: sentAt)
        let clock = store.card(card.id)?.replyDraftSentAt == sentAt && store.waitingCount(connector: "email") == 0
        store.expireReplyDrafts(now: sentAt.addingTimeInterval(599))
        let stillWaiting = store.card(card.id)?.replyDraftState == .requested
        store.expireReplyDrafts(now: sentAt.addingTimeInterval(601))
        let c = store.card(card.id)
        check(survived && clock && stillWaiting && c?.replyDraftState == .failed && c?.replyDraftError == "No answer from the engine yet"
              && history(store, card.id).last == "Reply draft failed",
              "draft_request_survives_restart_and_times_out_after_send")
    } catch { check(false, "draft_request_survives_restart_and_times_out_after_send: \(error)") }

    // MARK: Waiting for the result: drafts/run while a delivered request has no answer

    do {
        let store = try makeStore(root, "poll.sqlite")
        let card = try emailCard(store, mid: "<p1@x>")
        let t = Date(timeIntervalSince1970: 1_900_000_000)
        let quiet = goodEngine()
        _ = await ConnectorSync.run(connector: "email", store: store, client: quiet.client(), now: t)
        check(!quiet.requests.contains { $0.path == "/v2/drafts/run" } && store.connectorsAwaitingReplyDrafts().isEmpty,
              "sync_without_waiting_reply_draft_skips_drafts_run")
        let r = try store.requestReplyDraft(cardID: card.id, now: t.addingTimeInterval(1))
        check(store.connectorsAwaitingReplyDrafts().isEmpty, "unsent_reply_draft_request_is_not_polled")
        let eng = goodEngine()
        _ = await ConnectorSync.run(connector: "email", store: store, client: eng.client(), now: t.addingTimeInterval(2))
        let paths = eng.requests.map(\.path)
        let events = paths.firstIndex(of: "/v2/events"), run = paths.firstIndex(of: "/v2/drafts/run"), pull = paths.firstIndex(of: "/v2/proposals")
        check(events != nil && run != nil && pull != nil && events! < run! && run! < pull!
              && eng.requests.first { $0.path == "/v2/drafts/run" }?.method == "POST"
              && store.connectorsAwaitingReplyDrafts() == ["email"], "sync_with_waiting_reply_draft_runs_drafts_before_proposals")
        // Every poll sync calls it again until the answer arrives.
        let again = goodEngine()
        _ = await ConnectorSync.run(connector: "email", store: store, client: again.client(), now: t.addingTimeInterval(17))
        check(again.requests.filter { $0.path == "/v2/drafts/run" }.count == 1, "each_poll_sync_runs_drafts_again")
        _ = try Reconciler.apply([draftProposal(id: "p1", mid: "<p1@x>", request: r, link: "https://mail.google.com/p1", why: nil)],
                                 connector: "email", store: store, defaultGroup: "Personal", autoAdd: true)
        store.reload()
        let after = goodEngine()
        _ = await ConnectorSync.run(connector: "email", store: store, client: after.client(), now: t.addingTimeInterval(30))
        check(store.card(card.id)?.replyDraftState == .ready && store.connectorsAwaitingReplyDrafts().isEmpty
              && !after.requests.contains { $0.path == "/v2/drafts/run" }, "polling_stops_when_the_result_arrives")
        // A request that timed out is no longer polled.
        let c2 = try emailCard(store, mid: "<p2@x>")
        _ = try store.requestReplyDraft(cardID: c2.id, now: t.addingTimeInterval(40))
        store.markSent(outbox(store).filter { $0.sent == nil }.map(\.uuid), now: t.addingTimeInterval(41))
        let polled = store.connectorsAwaitingReplyDrafts() == ["email"]
        store.expireReplyDrafts(now: t.addingTimeInterval(41 + Store.replyDraftTimeout + 1))
        check(polled && store.card(c2.id)?.replyDraftState == .failed && store.connectorsAwaitingReplyDrafts().isEmpty,
              "polling_stops_at_the_timeout")
        check(ConnectorSync.replyDraftPollInterval == 15, "reply_draft_poll_interval_is_15_seconds")
    } catch { check(false, "sync_with_waiting_reply_draft_runs_drafts_before_proposals: \(error)") }

    do {
        // An engine without /v2/drafts/run (older) or one that fails it: the sync still pulls proposals and stays OK.
        let store = try makeStore(root, "pollfail.sqlite")
        let card = try emailCard(store, mid: "<p3@x>")
        let t = Date(timeIntervalSince1970: 1_900_000_000)
        _ = try store.requestReplyDraft(cardID: card.id, now: t)
        let old = FakeEngine { m, path, body in
            if path == "/v2/drafts/run" { return (404, #"{"error":"not found"}"#) }
            return try goodEngine().handler(m, path, body)
        }
        let warnings = { store.recentActivity(limit: 1000).filter { $0.message.contains("drafts") }.count }
        let r1 = await ConnectorSync.run(connector: "email", store: store, client: old.client(), now: t.addingTimeInterval(1))
        let w1 = warnings()
        let r2 = await ConnectorSync.run(connector: "email", store: store, client: old.client(), now: t.addingTimeInterval(16))
        check(r1.error == nil && r2.error == nil && old.requests.filter { $0.path == "/v2/proposals" }.count == 2
              && w1 == 1 && warnings() == 1, "drafts_run_failure_does_not_stop_the_sync")
    } catch { check(false, "drafts_run_failure_does_not_stop_the_sync: \(error)") }

    // MARK: Activity stays safe to share

    do {
        let store = try makeStore(root, "activity.sqlite")
        let secret = "SECRET-NOTES-Tell them 3pm works"
        let card = try emailCard(store, mid: "<a1@x>", notes: secret)
        try store.db.run("UPDATE cards SET title='SECRET-SUBJECT quarterly numbers' WHERE id=?", [card.id])
        store.reload()
        let r = try store.requestReplyDraft(cardID: card.id, now: Date())
        store.markSent(outbox(store).map(\.uuid), now: Date())
        _ = try Reconciler.apply([draftProposal(id: "a1", mid: "<a1@x>", request: r, link: nil, why: "Claude couldn't write it")],
                                 connector: "email", store: store, defaultGroup: "Personal", autoAdd: true)
        let r2 = try store.requestReplyDraft(cardID: card.id, now: Date())
        _ = try Reconciler.apply([draftProposal(id: "a2", mid: "<a1@x>", request: r2, link: "https://mail.google.com/a", why: nil)],
                                 connector: "email", store: store, defaultGroup: "Personal", autoAdd: true)
        let lines = store.recentActivity(limit: 1000).flatMap { [$0.message, $0.detail ?? ""] }
        let events = (try? store.db.query("SELECT kind FROM events") { DB.text($0, 0) }) ?? [] // try?-ok: a failed query fails the check
        check(lines.contains { $0.contains("Reply draft") } && !lines.contains { $0.contains("SECRET") }
              && !events.contains { $0.contains("SECRET") }, "activity_never_contains_notes")
    } catch { check(false, "activity_never_contains_notes: \(error)") }

    // MARK: Contract fixture

    do {
        let data = try Data(contentsOf: fixtures.appendingPathComponent("v2-draft.example.json"))
        let p = try JSONDecoder().decode(Proposal.self, from: data)
        let ok = p.kind == .draft && p.why == "" && p.link.hasPrefix("https://mail.google.com/mail/u/") && p.title == ""
            && (p.taskRef ?? "").count == 36 && p.sourceKey.map { !$0.messageID.isEmpty && !$0.undated } == true
        // The same JSON applied to a card waiting on that request makes it ready.
        let store = try makeStore(root, "fixture.sqlite")
        let card = try emailCard(store, mid: p.sourceKey?.messageID ?? "", sent: p.sourceKey?.sentAt ?? "")
        _ = try store.requestReplyDraft(cardID: card.id, now: Date())
        try store.db.run("UPDATE cards SET reply_draft_request=? WHERE id=?", [p.taskRef, card.id])
        store.reload()
        let batch = try Reconciler.decodeBatch(Data("[".utf8) + data + Data("]".utf8), store: store)
        _ = try Reconciler.apply(batch, connector: "email", store: store, defaultGroup: "Personal", autoAdd: true)
        check(ok && batch.count == 1 && store.card(card.id)?.replyDraftState == .ready && store.card(card.id)?.replyDraftLink == p.link,
              "draft_proposal_fixture_decodes")
        // A draft result without a source key is rejected, not guessed.
        var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        obj["source_key"] = nil
        let noKey = try Reconciler.decodeBatch(try JSONSerialization.data(withJSONObject: [obj]), store: store)
        check(noKey.isEmpty, "draft_proposal_without_source_key_rejected")
    } catch { check(false, "draft_proposal_fixture_decodes: \(error)") }
}

/// The schema of every board before version 8 (DB.schema at version 7), to build v7 boards for the upgrade checks.
private let v7Schema = """
    CREATE TABLE cards(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        notes TEXT NOT NULL DEFAULT '',
        area TEXT NOT NULL,
        importance INTEGER NOT NULL DEFAULT 1,
        due REAL,
        status TEXT NOT NULL,
        created REAL NOT NULL,
        started REAL,
        done REAL,
        updated REAL,
        deleted INTEGER NOT NULL DEFAULT 0,
        link TEXT NOT NULL DEFAULT '',
        gcal_account TEXT NOT NULL DEFAULT '',
        gcal_event TEXT NOT NULL DEFAULT '',
        gcal_link TEXT NOT NULL DEFAULT '',
        source TEXT NOT NULL DEFAULT '',
        external_id TEXT NOT NULL DEFAULT '',
        source_link TEXT NOT NULL DEFAULT '',
        source_meta TEXT NOT NULL DEFAULT '{}',
        imported_at REAL,
        source_mid TEXT,
        source_sent TEXT,
        withdrawn INTEGER NOT NULL DEFAULT 0,
        ai_summary TEXT NOT NULL DEFAULT '',
        connector TEXT NOT NULL DEFAULT '',
        proposal_json TEXT NOT NULL DEFAULT ''
    );
    CREATE INDEX cards_external_id ON cards(external_id);
    CREATE UNIQUE INDEX cards_source_key ON cards(connector, source_mid, source_sent)
        WHERE source_mid IS NOT NULL;
    CREATE TABLE events(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        card_id INTEGER NOT NULL REFERENCES cards(id),
        at REAL NOT NULL,
        kind TEXT NOT NULL,
        from_status TEXT,
        to_status TEXT,
        actor TEXT NOT NULL DEFAULT 'user',
        uuid TEXT
    );
    CREATE INDEX events_card ON events(card_id);
    CREATE UNIQUE INDEX events_uuid ON events(uuid);
    CREATE TABLE areas(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE COLLATE NOCASE,
        color TEXT NOT NULL,
        position REAL NOT NULL
    );
    CREATE TABLE module_applied(external_id TEXT PRIMARY KEY, at REAL NOT NULL);
    CREATE TABLE activity(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        at REAL NOT NULL,
        component TEXT NOT NULL,
        level TEXT NOT NULL,
        message TEXT NOT NULL,
        detail TEXT,
        trace TEXT,
        seen INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX activity_trace ON activity(trace);
    CREATE TABLE corrections(
        uuid TEXT PRIMARY KEY, connector TEXT, source_mid TEXT, source_sent TEXT,
        proposed_json TEXT, verdict TEXT, detail TEXT, at REAL
    );
    -- detached: a change kept for the record but never sent. detach_reason is 'no_connector' (queued while no
    -- connector row existed) or 'removed' (its connector was removed later).
    CREATE TABLE outbox(
        uuid TEXT PRIMARY KEY, connector TEXT, kind TEXT, payload_json TEXT, created REAL,
        attempts INTEGER DEFAULT 0, next_try REAL, last_error TEXT, sent REAL,
        detached INTEGER NOT NULL DEFAULT 0, detach_reason TEXT NOT NULL DEFAULT ''
    );
    CREATE TABLE connectors(
        id TEXT PRIMARY KEY, name TEXT, base_url TEXT, capabilities_json TEXT, cursor TEXT,
        settings_json TEXT, settings_version INTEGER DEFAULT 0, engine_settings_version INTEGER DEFAULT 0,
        last_ok REAL, unreachable_since REAL, status_json TEXT NOT NULL DEFAULT '{}'
    );
    -- A removed connector's settings, restored when the same id is added again.
    CREATE TABLE connector_archive(
        id TEXT NOT NULL, removed_at REAL NOT NULL, name TEXT, base_url TEXT, settings_json TEXT,
        settings_version INTEGER, restored_at REAL, PRIMARY KEY(id, removed_at)
    );
    CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
"""
