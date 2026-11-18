import Foundation
import FloatBoardConnectors
import FloatBoardCore
import SQLite3

/// Round 11 (owner's request): "Bulk add…" from WhatsApp and WeChat. The list is built from header data only (who, how
/// many messages, when), contacts are merged by number and linked id, people already in Circle are marked, and adding
/// makes each person in one transaction. Synthetic fixtures only.
@MainActor func bulkAddChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("fb-bulk-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? fm.removeItem(at: root) } // try?-ok: scratch folder cleanup
    let now = Date(timeIntervalSince1970: 1_794_391_200), day: TimeInterval = 86400
    // WhatsApp Desktop's files (synthetic): chats with message counts, and its contact list.
    func makeDB(_ name: String, _ sql: String) {
        var h: OpaquePointer?
        defer { sqlite3_close(h) }
        guard sqlite3_open(root.appendingPathComponent(name).path, &h) == SQLITE_OK, sqlite3_exec(h, sql, nil, nil, nil) == SQLITE_OK else {
            check(false, "bulk fixture \(name): \(String(cString: sqlite3_errmsg(h)))"); return
        }
    }
    let t = { (d: Double) in now.timeIntervalSince1970 - WhatsAppLocal.appleEpoch - d * day }
    var msgs: [String] = []
    for i in 0..<10 { msgs.append("(1, \(t(Double(i))), 0, 0, 'SECRET TEXT A \(i)')") }
    for i in 0..<5 { msgs.append("(2, \(t(Double(i) + 1)), 0, 1, 'SECRET TEXT B')") }
    for i in 0..<3 { msgs.append("(3, \(t(Double(i) + 2)), 0, 0, 'SECRET TEXT C')") }
    for i in 0..<7 { msgs.append("(4, \(t(Double(i))), 0, 0, 'SECRET GROUP TEXT')") }
    msgs.append("(1, \(t(0.5)), 6, 0, 'system')")
    makeDB("ChatStorage.sqlite", """
        CREATE TABLE ZWACHATSESSION(Z_PK INTEGER PRIMARY KEY, ZCONTACTJID TEXT, ZPARTNERNAME TEXT, ZSESSIONTYPE INTEGER, ZARCHIVED INTEGER,
          ZREMOVED INTEGER, ZHIDDEN INTEGER, ZUNREADCOUNT INTEGER);
        CREATE TABLE ZWAMESSAGE(Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZMESSAGEDATE REAL, ZMESSAGETYPE INTEGER, ZISFROMME INTEGER, ZTEXT TEXT);
        INSERT INTO ZWACHATSESSION VALUES (1, '447700900101@s.whatsapp.net', 'Anna', 0, 0, 0, 0, 0),
          (2, '222222222222@lid', 'Ben from chat', 0, 0, 0, 0, 0), (3, '333333333333@lid', '王美玲', 0, 0, 0, 0, 0),
          (4, '120363000000000000@g.us', 'Family group', 1, 0, 0, 0, 0), (5, 'status@broadcast', '', 0, 0, 0, 0, 0);
        INSERT INTO ZWAMESSAGE(ZCHATSESSION, ZMESSAGEDATE, ZMESSAGETYPE, ZISFROMME, ZTEXT) VALUES \(msgs.joined(separator: ",\n"));
        """)
    makeDB("ContactsV2.sqlite", """
        CREATE TABLE ZWAADDRESSBOOKCONTACT(Z_PK INTEGER PRIMARY KEY, ZLID TEXT, ZPHONENUMBER TEXT, ZFULLNAME TEXT, ZGIVENNAME TEXT,
          ZBUSINESSNAME TEXT, ZWHATSAPPID TEXT);
        INSERT INTO ZWAADDRESSBOOKCONTACT(ZLID, ZPHONENUMBER, ZFULLNAME, ZGIVENNAME, ZBUSINESSNAME, ZWHATSAPPID) VALUES
          ('101010101010@lid', '+44 7700 900101', 'Anna Example', 'Anna', '', '447700900101@s.whatsapp.net'),
          ('222222222222@lid', '+44 7700 900202', 'Ben Example', 'Ben', '', NULL),
          (NULL, '+44 7700 900303', 'Dora Example', 'Dora', '', '447700900303@s.whatsapp.net');
        """)
    let dir: WhatsAppDirectory.Listing
    do { dir = try WhatsAppDirectory.read(folder: root) } catch { check(false, "bulk read: \(error)"); return }
    check(dir.sessions.count == 3 && !dir.sessions.contains { $0.jid.hasSuffix("@g.us") || $0.jid.contains("broadcast") }
          && dir.sessions.first { $0.jid.hasPrefix("4477009001") }?.messages == 10 && dir.contacts.count == 3,
          "bulk_reads_one_to_one_chats_with_counts_and_the_contact_list")
    check(!"\(dir)".contains("SECRET"), "bulk_reads_no_message_text")
    let rows = BulkAdd.whatsappRows(sessions: dir.sessions, contacts: dir.contacts, known: [:])
    let anna = rows.first { $0.phone == "447700900101" }, ben = rows.first { $0.phone == "447700900202" }
    let mei = rows.first { $0.name == "王美玲" }, dora = rows.first { $0.phone == "447700900303" }
    check(rows.count == 4 && anna?.name == "Anna Example" && anna?.messages == 10
          && ben?.messages == 5 && ben?.handles.contains(Handle(kind: .whatsapp, value: "222222222222@lid")) == true
          && ben?.handles.contains(Handle(kind: .phone, value: "447700900202")) == true
          && mei?.phone == nil && mei?.handles == [Handle(kind: .whatsapp, value: "333333333333@lid")] && mei?.messages == 3
          && dora?.messages == 0, "bulk_merges_chats_and_contacts_by_number_and_linked_id")

    // In Circle (by any handle, including a linked id's number), dismissed, filters and order.
    let s: Store
    do { s = Store(db: try DB(url: root.appendingPathComponent("board.sqlite"))) } catch { check(false, "bulk board: \(error)"); return }
    s.setModule(.circle, on: true)
    let c = CircleStore(store: s), none = ItemTags(primary: nil, others: [])
    _ = c.add(name: "Anna", tier: .close, tags: none, details: CircleDetails(), handles: [Handle(kind: .phone, value: "447700900101")], now: now)
    _ = c.add(name: "Ben", tier: .close, tags: none, details: CircleDetails(), handles: [Handle(kind: .whatsapp, value: "222222222222@lid")], now: now)
    c.dismiss("handle:phone:447700900303")
    let marked = BulkAdd.mark(rows, store: s)
    check(marked.first { $0.phone == "447700900101" }?.inCircle == true && marked.first { $0.phone == "447700900202" }?.inCircle == true
          && marked.first { $0.name == "王美玲" }?.inCircle == false && marked.first { $0.phone == "447700900303" }?.dismissed == true,
          "bulk_marks_people_already_in_circle_and_dismissed_ones")
    let messaged = BulkAdd.visible(marked, messagedOnly: true, showDismissed: false, query: "")
    check(messaged.map(\.messages) == [10, 5, 3], "bulk_default_shows_people_messaged_most_first")
    check(BulkAdd.visible(marked, messagedOnly: false, showDismissed: false, query: "").count == 3
          && BulkAdd.visible(marked, messagedOnly: false, showDismissed: true, query: "").count == 4
          && BulkAdd.visible(marked, messagedOnly: false, showDismissed: true, query: "美玲").map(\.name) == ["王美玲"], "bulk_toggles_and_search")
    // Adding: one transaction each; already in Circle skipped; a rule failure listed.
    let pick = marked.filter { $0.phone == "447700900101" || $0.name == "王美玲" || $0.phone == "447700900303" }
    let r1 = BulkAdd.add(pick, tier: .network, tag: TagRules.investor, store: s, now: now)
    let added = PeopleStore(store: s).people().filter { $0.name == "王美玲" || $0.name == "Dora Example" }
    check(r1.added == 2 && r1.skipped == 1 && r1.failed.isEmpty && added.count == 2
          && added.allSatisfy { s.itemTags($0.shortID).all == ["Investor"] && $0.tier == .network }
          && c.handles(added.first { $0.name == "王美玲" }!.id) == [Handle(kind: .whatsapp, value: "333333333333@lid")]
          && BulkAdd.summary(r1) == "Added 2, skipped 1 (already in Circle).", "bulk_adds_each_new_person_with_tier_tag_and_handles")
    let r2 = BulkAdd.add(BulkAdd.mark(pick, store: s), tier: .network, tag: nil, store: s, now: now)
    check(r2.added == 0 && r2.skipped == 3, "bulk_add_again_skips_everyone")
    // Family with Prospect is refused per person (listed), nothing half made; a failing write leaves no person behind.
    let newRow = BulkRow(key: "phone:447700900999", name: "Eve Example", phone: "447700900999", handles: [Handle(kind: .phone, value: "447700900999")], messages: 1, last: now)
    let r3 = BulkAdd.add([newRow], tier: .family, tag: TagRules.prospect, store: s, now: now)
    check(r3.added == 0 && r3.failed.map(\.name) == ["Eve Example"] && !PeopleStore(store: s).people().contains { $0.name == "Eve Example" },
          "bulk_rule_failure_is_listed")
    s.performForTest("CREATE TRIGGER fail_h BEFORE INSERT ON person_handles BEGIN SELECT RAISE(ABORT, 'disk I/O error'); END")
    let r4 = BulkAdd.add([newRow], tier: .network, tag: nil, store: s, now: now)
    s.performForTest("DROP TRIGGER fail_h")
    check(r4.added == 0 && r4.failed.count == 1 && !PeopleStore(store: s).people(includeDeleted: true).contains { $0.name == "Eve Example" },
          "bulk_add_is_one_transaction_per_person")
    // WeChat: whoever Circle's notification reader saw (names, counts, last date).
    c.record([ExchangeInput(channel: .wechat, direction: .incoming, at: now, handle: Handle(kind: .wechat, value: "李雷"), name: "李雷"),
              ExchangeInput(channel: .wechat, direction: .incoming, at: now - day, handle: Handle(kind: .wechat, value: "李雷"), name: "李雷")], now: now)
    let wc = BulkAdd.wechatRows(store: s)
    check(wc.count == 1 && wc[0].name == "李雷" && wc[0].messages == 2 && wc[0].handles == [Handle(kind: .wechat, value: "李雷")], "bulk_wechat_lists_who_the_notifications_showed")
    // 2,000 contacts are listed fast (built, marked and filtered well under a second).
    let many = (0..<2000).map { i in WASession(jid: "4477009\(String(format: "%05d", i))@s.whatsapp.net", name: "Person \(i)", messages: i % 50, last: now) }
    let manyContacts = (0..<1000).map { i in WAContact(lid: "\(900000000000 + i)@lid", phone: "4477009\(String(format: "%05d", i))", name: "Contact \(i)") }
    let start = Date()
    let big = BulkAdd.mark(BulkAdd.whatsappRows(sessions: many, contacts: manyContacts, known: [:]), store: s)
    let shown = BulkAdd.visible(big, messagedOnly: true, showDismissed: false, query: "")
    let took = Date().timeIntervalSince(start)
    check(big.count == 2000 && !shown.isEmpty && took < 1.0, "bulk_two_thousand_contacts_list_fast (\(String(format: "%.2f", took)) s)")
    // Adding 300 people: one transaction each, the board re-read once at the end (round 12).
    let three = (0..<300).map { i in BulkRow(key: "phone:4477008\(String(format: "%05d", i))", name: "Batch \(i)", phone: "4477008\(String(format: "%05d", i))",
                                              handles: [Handle(kind: .phone, value: "4477008\(String(format: "%05d", i))")], messages: 1, last: now) }
    let t0 = Date(), reloads0 = s.reloads
    let r300 = BulkAdd.add(three, tier: .network, tag: TagRules.investor, store: s, now: now)
    let took300 = Date().timeIntervalSince(t0), reloads = s.reloads - reloads0
    check(r300.added == 300 && took300 < 2.0, "bulk_adds_300_people_quickly")
    check(reloads == 1, "bulk_add_rereads_the_board_once (\(reloads))")
    if took300 >= 2.0 { print("bulk 300 adds took \(String(format: "%.2f", took300)) s") }
}
