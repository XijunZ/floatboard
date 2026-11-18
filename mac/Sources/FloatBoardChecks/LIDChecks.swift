import Foundation
import FloatBoardConnectors
import FloatBoardCore
import SQLite3

/// Round 10 (owner's report): a WhatsApp linked id (<digits>@lid) is resolved to its phone number and name from WhatsApp
/// Desktop's own contact list on this Mac (ContactsV2.sqlite, then LID.sqlite), read only; Fill uses it without Claude;
/// Circle treats the id and the number as one person. Synthetic fixtures only.
@MainActor func lidChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("fb-lid-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? fm.removeItem(at: root) } // try?-ok: scratch folder cleanup
    func makeDB(_ name: String, _ sql: String) {
        var h: OpaquePointer?
        defer { sqlite3_close(h) }
        guard sqlite3_open(root.appendingPathComponent(name).path, &h) == SQLITE_OK, sqlite3_exec(h, sql, nil, nil, nil) == SQLITE_OK else {
            check(false, "lid fixture \(name)"); return
        }
    }
    makeDB("ContactsV2.sqlite", """
        CREATE TABLE ZWAADDRESSBOOKCONTACT(Z_PK INTEGER PRIMARY KEY, ZLID TEXT, ZPHONENUMBER TEXT, ZFULLNAME TEXT, ZGIVENNAME TEXT,
          ZBUSINESSNAME TEXT, ZWHATSAPPID TEXT);
        INSERT INTO ZWAADDRESSBOOKCONTACT(ZLID, ZPHONENUMBER, ZFULLNAME, ZGIVENNAME, ZBUSINESSNAME, ZWHATSAPPID) VALUES
          ('111111111111@lid', '+44 7700 900111', 'Lia Example', 'Lia', '', '447700900111@s.whatsapp.net'),
          ('444444444444@lid', NULL, 'Ola Example', 'Ola', 'Ola Trading', '447700900444@s.whatsapp.net'),
          ('555555555555@lid', NULL, '', '', '', NULL);
        """)
    makeDB("LID.sqlite", """
        CREATE TABLE ZWAPHONENUMBERLIDPAIR(Z_PK INTEGER PRIMARY KEY, ZLID TEXT, ZPHONENUMBER TEXT);
        INSERT INTO ZWAPHONENUMBERLIDPAIR(ZLID, ZPHONENUMBER) VALUES ('222222222222@lid', '447700900222');
        """)
    let before = (try? fm.contentsOfDirectory(atPath: root.path).sorted()) ?? [] // try?-ok: compared below
    let r = WhatsAppContacts.resolve(["111111111111@lid", "222222222222@lid", "333333333333@lid", "444444444444@lid", "555555555555@lid"], folder: root)
    check(r["111111111111@lid"] == ResolvedContact(phone: "447700900111", name: "Lia Example", business: "")
          && r["222222222222@lid"]?.phone == "447700900222" && r["333333333333@lid"] == nil
          && r["444444444444@lid"] == ResolvedContact(phone: "447700900444", name: "Ola Example", business: "Ola Trading") && r["555555555555@lid"] == nil,
          "lid_resolves_from_contacts_then_lid_pairs")
    check(((try? fm.contentsOfDirectory(atPath: root.path).sorted()) ?? []) == before, "lid_resolver_leaves_whatsapps_files_alone") // try?-ok: compared
    let activityBefore = sharedStoreActivityCount()
    check(WhatsAppContacts.resolve(["111111111111@lid"], folder: root.appendingPathComponent("nowhere")).isEmpty
          && sharedStoreActivityCount() == activityBefore, "lid_resolver_is_quiet_without_whatsapp")
    try? fm.createDirectory(at: root.appendingPathComponent("Empty"), withIntermediateDirectories: true) // try?-ok: the check below fails without it
    makeDB("Empty/ContactsV2.sqlite", "CREATE TABLE OTHER(x);")
    check(WhatsAppContacts.resolve(["111111111111@lid"], folder: root.appendingPathComponent("Empty")).isEmpty, "lid_resolver_is_quiet_without_its_tables")

    // Circle: the id and its number are one person; the number is stored on this Mac only.
    let s: Store
    do { s = Store(db: try DB(url: root.appendingPathComponent("board.sqlite"))) } catch { check(false, "lid board: \(error)"); return }
    s.setModule(.circle, on: true)
    let c = CircleStore(store: s), now = Date(timeIntervalSince1970: 1_794_391_200), none = ItemTags(primary: nil, others: [])
    guard let lia = c.add(name: "Lia", tier: .close, tags: none, details: CircleDetails(), handles: [Handle(kind: .whatsapp, value: "111111111111@lid")], now: now).person,
          let bob = c.add(name: "Bob", tier: .close, tags: none, details: CircleDetails(), handles: [Handle(kind: .phone, value: "447700900222")], now: now).person
    else { check(false, "lid people"); return }
    c.record([ExchangeInput(channel: .whatsapp, direction: .incoming, at: now.addingTimeInterval(-86400), handle: Handle(kind: .whatsapp, value: "222222222222@lid"), name: "Bob")], now: now)
    LIDBook.save(store: s, r)
    check(LIDBook.phone(store: s, "111111111111@lid") == "447700900111" && LIDBook.phone(store: s, "333333333333@lid") == nil, "lid_book_keeps_numbers_on_this_mac")
    let linked = LIDBook.link(store: s, now: now)
    check(linked == 2 && c.handles(lia.id).contains(Handle(kind: .phone, value: "447700900111"))
          && c.handles(bob.id).contains(Handle(kind: .whatsapp, value: "222222222222@lid")), "lid_and_its_number_become_one_persons_handles")
    let bobClock = c.clocks(PeopleStore(store: s).person(bob.id)!, now: now)
    check(bobClock.lastConversation != nil || bobClock.lastHeard != nil, "messages_under_the_lid_count_for_the_numbers_person")
    check(LIDBook.link(store: s, now: now) == 0, "lid_linking_runs_once")
    check(LIDBook.display(store: s, Handle(kind: .whatsapp, value: "111111111111@lid")) == "447700900111"
          && LIDBook.display(store: s, Handle(kind: .whatsapp, value: "333333333333@lid")) == "WhatsApp contact (no number shared)", "suggestions_show_the_real_number")

    // Fill: the number is filled without Claude, the note gives the real count; nothing found is said so.
    var form = ContactFormFields(name: "", company: "", emails: "", phones: "")
    let note = LIDFill.apply(&form, resolved: [ResolvedContact(phone: "447700900444", name: "Ola Example", business: "Ola Trading")], records: 34)
    check(form.phones == "447700900444" && form.whatsapp == "447700900444" && form.name == "Ola Example" && form.company == "Ola Trading"
          && note == "From 34 WhatsApp message records and WhatsApp's contact list: added name, company, phone, WhatsApp number.", "fill_uses_the_resolved_number_without_claude")
    var kept = ContactFormFields(name: "Mine", company: "", emails: "", phones: "447700900000")
    let note2 = LIDFill.apply(&kept, resolved: [ResolvedContact(phone: "447700900444", name: "Ola Example", business: "")], records: 3)
    check(kept.name == "Mine" && kept.phones == "447700900000" && note2 == "From 3 WhatsApp message records and WhatsApp's contact list: added WhatsApp number.",
          "fill_never_overwrites_typed_fields")
    var nothing = ContactFormFields(name: "", company: "", emails: "", phones: "")
    check(LIDFill.apply(&nothing, resolved: [], records: 34) == "WhatsApp hides this contact's number and it isn't in WhatsApp's contact list.", "fill_says_when_whatsapp_hides_the_number")
}

/// Activity rows in the shared check store (the resolver must not add any).
@MainActor func sharedStoreActivityCount() -> Int { sharedStore?.recentActivity(limit: 500).count ?? 0 }

/// Round 12 (4, 5): the resolver looks up only ids not known yet, off the main thread; linking re-reads the board once; the
/// map is parsed once and kept until it changes.
@MainActor func lidPerformanceChecks() async {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("fb-lid-perf-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? fm.removeItem(at: root) } // try?-ok: scratch folder cleanup
    let s: Store
    do { s = Store(db: try DB(url: root.appendingPathComponent("board.sqlite"))) } catch { check(false, "lid perf board: \(error)"); return }
    s.setModule(.circle, on: true)
    let c = CircleStore(store: s), now = Date(timeIntervalSince1970: 1_794_391_200), none = ItemTags(primary: nil, others: [])
    for i in 0..<40 {
        _ = c.add(name: "Lid \(i)", tier: .network, tags: none, details: CircleDetails(), handles: [Handle(kind: .whatsapp, value: "7000000000\(String(format: "%02d", i))@lid")], now: now)
    }
    LIDBook.save(store: s, ["700000000000@lid": ResolvedContact(phone: "447700800000", name: "", business: "")])
    final class Seen: @unchecked Sendable { var asked: [String] = []; var onMain = true }
    let seen = Seen()
    let reloads0 = s.reloads
    let linked = await CircleReaders.resolveLinkedIDs(store: s, now: now) { ids in
        seen.asked = ids.sorted(); seen.onMain = Thread.isMainThread
        return Dictionary(uniqueKeysWithValues: ids.map { ($0, ResolvedContact(phone: "4477008" + String($0.prefix(12).suffix(5)), name: "", business: "")) })
    }
    check(seen.asked.count == 39 && !seen.asked.contains("700000000000@lid") && !seen.onMain, "lid_resolver_asks_only_for_unknown_ids_off_the_main_thread")
    check(linked == 40 && s.reloads - reloads0 <= 3, "lid_linking_rereads_the_board_once (\(s.reloads - reloads0))")
    seen.asked = []
    let again = await CircleReaders.resolveLinkedIDs(store: s, now: now) { ids in seen.asked = ids; return [:] }
    check(again == 0 && seen.asked.isEmpty, "lid_resolver_skips_when_every_id_is_known")
    // The map is parsed once for many rows, and again only after it changes.
    let p0 = LIDBook.parses
    for _ in 0..<200 { _ = LIDBook.display(store: s, Handle(kind: .whatsapp, value: "700000000001@lid")) }
    check(LIDBook.parses - p0 <= 1, "lid_map_is_parsed_once_for_many_rows")
    LIDBook.save(store: s, ["799999999999@lid": ResolvedContact(phone: "447700899999", name: "", business: "")])
    check(LIDBook.display(store: s, Handle(kind: .whatsapp, value: "799999999999@lid")) == "447700899999", "lid_map_cache_follows_changes")
}
