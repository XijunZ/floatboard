import Foundation
import SQLite3
import FloatBoardConnectors
import FloatBoardCore

/// Watch: person + timer, reply detection (engine action for email, local for WhatsApp), chase reminders.
@MainActor func watchChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-watch-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: temp cleanup
    let store: Store
    do { store = Store(db: try DB(url: root.appendingPathComponent("board.sqlite"))) } catch { check(false, "watch setup: \(error)"); return }
    func card(_ title: String) -> Card? { store.cards.last { $0.title == title } }

    // An email task: moving it to Watch starts the timer and suggests the sender.
    _ = store.seedCard(title: "Contract from Anna", source: "email", externalID: "email:<a1@acme>",
                       meta: ["sender": "anna@acme.com", "sender_name": "Anna Lee"])
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    store.move(card("Contract from Anna")!, to: .watch, now: t0)
    var c = card("Contract from Anna")!
    check(c.watchSince == t0 && c.watchPerson == "Anna Lee" && c.watchContact == "email:anna@acme.com", "watch_starts_timer_and_suggests_the_sender")
    check(Watch.line(c, now: t0.addingTimeInterval(3 * 86_400 + 4 * 3600)) == "Waiting on Anna Lee · 3d 4h"
          && Watch.isLate(c, now: t0.addingTimeInterval(3 * 86_400)) && !Watch.isLate(c, now: t0.addingTimeInterval(2 * 86_400)),
          "watch_line_counts_and_turns_late_at_3_days")
    let payload = PhoneBoard.card(for: c, color: nil, calendar: .current)
    check(payload.watch == BoardWatch(person: "Anna Lee", contact: "email:anna@acme.com", since: PhoneBoard.isoUTC(t0)),
          "watch_goes_to_the_phone_and_engine")

    // Editing whom it waits on; a bad email is dropped, the name kept.
    store.setWatch(c, person: "Anna", contact: "email:not an address")
    c = card("Contract from Anna")!
    check(c.watchPerson == "Anna" && c.watchContact == "", "watch_person_can_be_edited_and_bad_contacts_are_dropped")
    store.setWatch(c, person: "Anna", contact: "email:Anna@Acme.com")
    c = card("Contract from Anna")!
    check(c.watchContact == "email:anna@acme.com", "watch_email_contact_is_normalised")

    // The engine found a reply: back to To do, once, with the reason in its history.
    let r = store.applyPhoneActions([PhoneAction(id: "x1", clientID: "watch:\(c.id):s", cardID: c.id, action: "watch_reply",
                                                madeAt: t0.addingTimeInterval(86_400), reason: "Anna replied by email")],
                                    connector: "email", now: t0.addingTimeInterval(86_400 + 60))
    c = card("Contract from Anna")!
    let history = (try? store.db.query("SELECT kind FROM events WHERE card_id=?", [c.id]) { DB.text($0, 0) }) ?? [] // try?-ok: empty fails the check
    check(r.applied == ["x1"] && c.status == .todo && c.watchSince == nil && history.contains("Anna replied by email")
          && c.notes.hasPrefix("↩ Anna replied by email · "),
          "watch_reply_moves_back_to_todo_with_the_reason")
    store.move(c, to: .doing)
    let r2 = store.applyPhoneActions([PhoneAction(id: "x2", clientID: "watch:\(c.id):t", cardID: c.id, action: "watch_reply",
                                                 madeAt: Date(), reason: "Anna replied by email")], connector: "email")
    check(card("Contract from Anna")!.status == .doing && r2.skipped.map(\.id) == ["x2"], "watch_reply_leaves_a_task_that_moved_on")

    // Leaving Watch stops the timer; returning starts a new one but keeps the person.
    store.move(card("Contract from Anna")!, to: .watch, now: t0.addingTimeInterval(5 * 86_400))
    check(card("Contract from Anna")!.watchSince == t0.addingTimeInterval(5 * 86_400) && card("Contract from Anna")!.watchPerson == "Anna",
          "watch_again_restarts_the_timer_and_keeps_the_person")

    // A typed task: no suggestion.
    store.add(title: "Wait for plumber", area: "Personal", importance: .low, due: nil)
    store.move(card("Wait for plumber")!, to: .watch)
    check(card("Wait for plumber")!.watchPerson == "" && card("Wait for plumber")!.watchContact == "" && card("Wait for plumber")!.watchSince != nil,
          "watch_typed_task_has_a_timer_but_no_person")

    // Chase reminders on this Mac: the next one 3 days in, then every 3 days.
    let w = card("Contract from Anna")!
    let since = w.watchSince!
    let plan = DueReminders.plan([w], now: since.addingTimeInterval(3600))
    check(plan.count == 1 && plan[0].fireAt == since.addingTimeInterval(3 * 86_400) && plan[0].body == "Still waiting on Anna · 3 days",
          "watch_chase_reminder_after_3_days")
    let later = DueReminders.plan([w], now: since.addingTimeInterval(4 * 86_400))
    check(later.first?.fireAt == since.addingTimeInterval(6 * 86_400) && later.first?.body == "Still waiting on Anna · 6 days",
          "watch_chase_reminder_every_3_days")

    // Sender details from the engine reach the card.
    let json = #"{"id":"p1","kind":"task","source_key":{"message_id":"<s1@x>","sent_at":"2026-11-13T10:00:00.000Z"},"title":"T","why":null,"due":null,"has_time":false,"group":null,"importance":1,"source_label":"me@gmail.com","link":null,"summary":null,"task_ref":null,"learned":null,"sender":"sam@x.io","sender_name":"Sam","provenance":{"model":"m","skill_version":"v","created":"2026-11-13T10:00:01.000Z"}}"#
    do {
        let p = try JSONDecoder().decode(Proposal.self, from: Data(json.utf8))
        check(p.sender == "sam@x.io" && p.senderName == "Sam", "proposal_carries_the_sender")
    } catch { check(false, "proposal_carries_the_sender: \(error)") }

    // WhatsApp: a message in the watched chat after Watch began moves it back (found on this Mac).
    let wa = root.appendingPathComponent("wa")
    do {
        try FileManager.default.createDirectory(at: wa, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(wa.appendingPathComponent("ChatStorage.sqlite").path, &db) == SQLITE_OK else { throw URLError(.cannotCreateFile) }
        let a = Date().timeIntervalSince1970 - 978_307_200
        let sql = """
        CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, ZCONTACTJID TEXT, ZPARTNERNAME TEXT, ZSESSIONTYPE INTEGER, ZUNREADCOUNT INTEGER, ZARCHIVED INTEGER, ZREMOVED INTEGER, ZHIDDEN INTEGER);
        CREATE TABLE ZWACHATPUSHCONFIG (Z_PK INTEGER PRIMARY KEY, ZJID TEXT, ZMUTEDUNTIL REAL);
        CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZISFROMME INTEGER, ZMESSAGETYPE INTEGER, ZTEXT TEXT, ZMESSAGEDATE REAL, ZSTANZAID TEXT, ZGROUPMEMBER INTEGER, ZPUSHNAME TEXT, ZMEDIAITEM INTEGER);
        CREATE TABLE ZWAGROUPMEMBER (Z_PK INTEGER PRIMARY KEY, ZCONTACTNAME TEXT, ZFIRSTNAME TEXT);
        CREATE TABLE ZWAMEDIAITEM (Z_PK INTEGER PRIMARY KEY, ZTITLE TEXT);
        INSERT INTO ZWACHATSESSION VALUES (1,'447700900123@s.whatsapp.net','Ben',0,0,0,0,0);
        INSERT INTO ZWAMESSAGE VALUES (1,1,0,0,'Sent it!',\(a - 60),'S1',NULL,NULL,NULL);
        INSERT INTO ZWACHATSESSION VALUES (2,'447700900456@s.whatsapp.net','Cara',0,0,0,0,0);
        INSERT INTO ZWAMESSAGE VALUES (2,2,0,0,'old message',\(a - 7200),'S2',NULL,NULL,NULL);
        """
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw URLError(.cannotCreateFile) }
    } catch { check(false, "watch wa fixture: \(error)"); return }
    for (title, jid) in [("Get the form from Ben", "447700900123@s.whatsapp.net"), ("Hear back from Cara", "447700900456@s.whatsapp.net")] {
        _ = store.seedCard(title: title, source: "email", externalID: "wa-\(title)", meta: ["sender_name": String(title.split(separator: " ").last!)])
        _ = try? store.db.run("UPDATE cards SET source_mid=?, source_sent='2026-11-13T00:00:00.000Z' WHERE id=?", ["wa:\(jid):Z", card(title)!.id]) // try?-ok: failure fails the checks below
        store.reload()
        store.move(card(title)!, to: .watch, now: Date().addingTimeInterval(-3600))
    }
    check(card("Get the form from Ben")!.watchContact == "wa:447700900123@s.whatsapp.net" && card("Get the form from Ben")!.watchPerson == "Ben",
          "watch_suggests_the_whatsapp_chat")
    WhatsAppSync.replies(connector: "email", store: store, folder: wa)
    check(card("Get the form from Ben")!.status == .todo && card("Get the form from Ben")!.notes.hasPrefix("↩ Ben replied on WhatsApp · ")
          && card("Hear back from Cara")!.status == .watch,
          "whatsapp_reply_after_watch_moves_back_older_ones_dont")
}
