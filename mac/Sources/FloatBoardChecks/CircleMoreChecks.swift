import Foundation
import SQLite3
import FloatBoardCore
import FloatBoardConnectors

/// Circle beyond the core: imports (LinkedIn, Google Contacts), What's new (Companies House, news, posts), auto links,
/// the readers (WhatsApp, WeChat, calendar) on fixtures, the phone copy, the watch list and the phone's actions.
@MainActor func circleMoreChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-circle-more-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    circleLinkedInChecks(root)
    circleGoogleContactsChecks(root)
    circleUpdateChecks(root)
    circleLinkerChecks(root)
    circleCalendarReaderChecks(root)
    circleWhatsAppReaderChecks(root)
    circleWeChatReaderChecks(root)
    circleCopyChecks(root)
}

private let noTags = ItemTags(primary: nil, others: [])

@MainActor private func circleLinkedInChecks(_ root: URL) {
    guard let s = circleStore(root, "li.sqlite") else { return }
    let c = CircleStore(store: s)
    guard let anna = c.add(name: "Anna Example", tier: .network, tags: ItemTags(primary: TagRules.investor, others: []), details: CircleDetails(),
                           handles: [Handle(kind: .linkedin, value: "https://www.linkedin.com/in/anna-example")]).person,
          let ben = c.add(name: "Ben Example", tier: .network, tags: noTags, details: CircleDetails(),
                          handles: [Handle(kind: .email, value: "ben@example.com")]).person else { check(false, "li setup"); return }
    let first = """
    Notes:
    "When exporting your connection data, you may notice that some of the email addresses are missing."

    First Name,Last Name,URL,Email Address,Company,Position,Connected On
    Anna,Example,https://www.linkedin.com/in/anna-example,,Acme Capital,Associate,03 Nov 2025
    Ben,Example,https://www.linkedin.com/in/ben-example,ben@example.com,"Widgets, Ltd",Engineer,01 Jan 2024
    Cara,Example,https://www.linkedin.com/in/cara-example,,Northwind,"Head of ""Ops""\",05 Feb 2023
    """
    let r1 = c.importLinkedIn(first, exportDate: "2026-11-03", now: circleDay(3))
    check(r1.rows == 3 && r1.candidates == 1 && r1.attached == 1 && r1.changes == 0, "linkedin_import_counts")
    check(c.candidates().map(\.name) == ["Cara Example"] && c.candidates().first?.role == "Head of \"Ops\"" && c.handles(ben.id).contains { $0.kind == .linkedin },
          "linkedin_rows_become_suggestions_or_attach_by_exact_email")
    check(PeopleStore(store: s).people().count == 2, "linkedin_import_never_adds_people_in_bulk")
    // A month later: Anna changed job; Ben is missing from the export.
    let second = """
    First Name,Last Name,URL,Email Address,Company,Position,Connected On
    Anna,Example,https://www.linkedin.com/in/anna-example/,,Beta Ventures,Partner,03 Nov 2025
    Cara,Example,https://www.linkedin.com/in/cara-example,,Northwind,"Head of ""Ops""\",05 Feb 2023
    """
    let r2 = c.importLinkedIn(second, exportDate: "2026-12-03", now: circleDay(3, month: 12))
    let u = c.updates(anna.id).first
    check(r2.changes == 1 && u?.kind == .linkedin && u?.title == "Now Partner at Beta Ventures"
          && u?.detail == "Was Associate at Acme Capital · changed since the export of 3 Nov 2026", "linkedin_change_found_by_profile_url_with_export_date")
    check(c.linkedInStatus(ben.id) == "Not in the export of 3 Dec 2026" && c.updates(ben.id).isEmpty, "missing_row_is_not_a_job_change")
    check(c.linkedInNudgeDue(now: circleDay(20, month: 12)) == false && c.linkedInNudgeDue(now: circleDay(10, month: 1).addingTimeInterval(365 * 86400)) == true,
          "linkedin_monthly_nudge")
    // Adding a suggestion makes the person with their handles and job; dismissing keeps it away.
    guard let cand = c.candidates().first else { check(false, "candidate"); return }
    let added = c.addCandidate(cand.id, tier: .network, tags: noTags).person
    check(added?.name == "Cara Example" && c.details(added!.id).company == "Northwind" && c.handles(added!.id).first?.kind == .linkedin
          && c.candidates().isEmpty, "suggestion_added_as_person")
}

@MainActor private func circleGoogleContactsChecks(_ root: URL) {
    guard let s = circleStore(root, "gc.sqlite") else { return }
    let c = CircleStore(store: s)
    guard let dan = c.add(name: "Dan Example", tier: .close, tags: noTags, details: CircleDetails(),
                          handles: [Handle(kind: .phone, value: "+44 7700 900321")]).person else { return }
    let csv = """
    First Name,Middle Name,Last Name,Organization Name,Organization Title,E-mail 1 - Label,E-mail 1 - Value,Phone 1 - Label,Phone 1 - Value
    Dan,,Example,,,* Home,dan@example.com,Mobile,07700 900321
    Erin,,Example,Fabrikam,CTO,Work,erin@example.com ::: erin.e@example.org,Mobile,+44 7700 900654
    ,,,,,,,,
    """
    let r = c.importGoogleContacts(csv, now: circleDay(5))
    check(r.rows == 2 && r.candidates == 1 && r.attached == 1 && c.handles(dan.id).contains(Handle(kind: .email, value: "dan@example.com")),
          "google_contacts_attach_on_exact_phone_or_suggest")
    let erin = c.candidates().first
    check(erin?.name == "Erin Example" && erin?.company == "Fabrikam" && erin?.handles.count == 3, "google_contact_suggestion_keeps_all_handles")
    if let e = erin { c.dismissCandidate(e.id) }
    check(c.candidates().isEmpty && c.importGoogleContacts(csv, now: circleDay(6)).candidates == 0, "dismissed_suggestion_not_offered_again")
}

@MainActor private func circleUpdateChecks(_ root: URL) {
    guard let s = circleStore(root, "upd.sqlite") else { return }
    let c = CircleStore(store: s)
    var investorDetails = CircleDetails(); investorDetails.firm = "Acme Capital"; investorDetails.birthday = "1980-04-12"
    guard let inv = c.add(name: "Ivy Example", tier: .network, tags: ItemTags(primary: TagRules.investor, others: []), details: investorDetails,
                          handles: []).person,
          let fam = c.add(name: "Fred Example", tier: .family, tags: ItemTags(primary: TagRules.investor, others: []), details: CircleDetails(), handles: []).person,
          let plain = c.add(name: "Pat Example", tier: .close, tags: noTags, details: CircleDetails(), handles: []).person else { return }
    // Updates are for Investor/Prospect, never Family, and others only on request.
    let watch = CircleCopy.watchList(store: s)
    check(watch.map(\.person) == [inv.shortID.text] && watch.first?.firm == "Acme Capital" && watch.first?.born == "1980-04"
          && watch.first?.news == true && watch.first?.ch == true, "watch_list_investor_prospect_not_family")
    var pd = c.details(plain.id); pd.updatesOn = true; c.save(plain.id, pd)
    check(Set(CircleCopy.watchList(store: s).map(\.person)) == [inv.shortID.text, plain.shortID.text] && !CircleCopy.watchList(store: s).contains { $0.person == fam.shortID.text },
          "updates_on_request")
    // Engine results: officer candidates (born month matches first), news possible / set aside, directorships.
    let iso = { (d: Date) in ISO8601DateFormatter().string(from: d) }
    let items: [EngineUpdate] = [
        EngineUpdate(seq: 1, person: inv.shortID.text, kind: "officer_candidate", key: "ch:cand:OFF2", title: "EXAMPLE, Ivy Jane", detail: "London · 3 appointments",
                     url: "", at: nil, match: "", born: "1981-02", officer: "OFF2"),
        EngineUpdate(seq: 2, person: inv.shortID.text, kind: "officer_candidate", key: "ch:cand:OFF1", title: "EXAMPLE, Ivy", detail: "London · 2 appointments",
                     url: "", at: nil, match: "", born: "1980-04", officer: "OFF1"),
        EngineUpdate(seq: 3, person: inv.shortID.text, kind: "news_person", key: "news:a", title: "Ivy Example joins Beta board", detail: "The Paper",
                     url: "https://example.com/a", at: iso(circleDay(4)), match: "possible", born: nil, officer: nil),
        EngineUpdate(seq: 4, person: inv.shortID.text, kind: "news_person", key: "news:b", title: "Ivy Example wins local bake-off", detail: "Village News",
                     url: "https://example.com/b", at: iso(circleDay(5)), match: "unlikely", born: nil, officer: nil),
        EngineUpdate(seq: 5, person: inv.shortID.text, kind: "news_firm", key: "news:c", title: "Acme Capital closes fund", detail: "Wire",
                     url: "https://example.com/c", at: iso(circleDay(6)), match: "possible", born: nil, officer: nil),
    ]
    check(c.applyEngineUpdates(items, now: circleDay(7)) == 5, "engine_updates_stored")
    check(c.applyEngineUpdates(items, now: circleDay(7)) == 0, "engine_updates_stored_once")
    let cands = c.officerCandidates(inv.id)
    check(cands.map(\.officerID) == ["OFF1", "OFF2"] && cands.first?.bornMatches == true && c.details(inv.id).officerID.isEmpty,
          "officer_candidates_shown_not_linked")
    c.confirmOfficer(inv.id, cands[0])
    check(c.details(inv.id).officerID == "OFF1" && c.officerCandidates(inv.id).isEmpty && CircleCopy.watchList(store: s).first?.officerID == "OFF1",
          "officer_bound_once_confirmed")
    let shown = c.updates(inv.id)
    check(shown.map(\.title) == ["Acme Capital closes fund", "Ivy Example joins Beta board"] && shown.allSatisfy { $0.verdict == .none }
          && c.updates(inv.id, includeSetAside: true).count == 3, "news_possible_and_set_aside")
    c.setVerdict(shown[1].id, .wrong)
    check(c.updates(inv.id).map(\.title) == ["Acme Capital closes fund"] && c.updates(inv.id, includeWrong: true).count == 2, "news_marked_wrong_hidden")
    c.setVerdict(shown[0].id, .right)
    check(c.updates(inv.id).first?.verdict == .right, "news_marked_right")
    c.setNewsMuted(inv.id, true)
    check(c.updates(inv.id).isEmpty && CircleCopy.watchList(store: s).first?.news == false, "news_muted_per_person")
    // Companies House directorships: kept and shown separately from news.
    _ = c.applyEngineUpdates([EngineUpdate(seq: 6, person: inv.shortID.text, kind: "appointment", key: "ch:OFF1:123:a", title: "Director, Beta Ltd",
                                           detail: "Appointed 1 Nov 2026", url: "https://find-and-update.company-information.service.gov.uk/company/123",
                                           at: iso(circleDay(1)), match: "", born: nil, officer: nil)], now: circleDay(8))
    check(c.updates(inv.id).map(\.kind) == [.appointment], "appointments_shown_when_news_muted")
}

@MainActor private func circleLinkerChecks(_ root: URL) {
    guard let s = circleStore(root, "link.sqlite") else { return }
    let c = CircleStore(store: s)
    guard let p = c.add(name: "Hana Example", aliases: ["Hana"], tier: .close, tags: noTags, details: CircleDetails(),
                        handles: [Handle(kind: .email, value: "hana@example.com")]).person else { return }
    let cache = CalendarCache(store: s)
    cache.upsertCalendars(account: "me@example.com", [CalCalendar(account: "me@example.com", calendarID: "me@example.com", name: "Me", color: "#000",
                                                                    owned: true, shown: true, primary: true)])
    let f = CalEventFields(start: circleDay(20), end: circleDay(20) + 3600, title: "Coffee", googleUpdated: circleDay(1))
    cache.apply(account: "me@example.com", calendarID: "me@example.com", changes: [GoogleEventChange(eventID: "c1", cancelled: false, fields: f,
        guests: [CalGuest(email: "hana@example.com", status: "accepted"), CalGuest(email: "me@example.com", status: "accepted")])], nextToken: nil)
    guard let ev = cache.event(account: "me@example.com", calendarID: "me@example.com", eventID: "c1") else { check(false, "linker event"); return }
    s.seedCard(title: "Reply to Hana", importance: .medium, source: "email", externalID: "email:h1", meta: ["sender": "hana@example.com"])
    guard let task = s.card(externalID: "email:h1") else { return }
    guard let jot = JotStore(store: s).create(text: "Idea from lunch with Hana Example about the trip") else { return }
    _ = JotStore(store: s).create(text: "Hanami season")
    CircleLinker.run(store: s, now: circleDay(10))
    let links = s.itemLinks(of: p.shortID)
    check(links.first { $0.other == ev.id }?.madeBy == .auto && links.first { $0.other == ShortID(kind: .task, number: task.id) }?.madeBy == .auto
          && links.first { $0.other == jot.shortID }?.madeBy == .suggested && links.count == 3, "auto_links_events_tasks_and_suggested_jots")
    check(CircleLinker.peopleNamed(in: "met hana yesterday", people: [p]).map(\.id) == [p.id]
          && CircleLinker.peopleNamed(in: "Hanami and Hanabi", people: [p]).isEmpty, "names_matched_as_whole_words")
    // A link the owner removed is not made again by the next run.
    s.unlinkWithUndo(p.shortID, jot.shortID)
    CircleLinker.run(store: s, now: circleDay(11))
    check(!s.links(of: p.shortID).contains(jot.shortID), "unlinked_auto_link_not_remade")
}

@MainActor private func circleCalendarReaderChecks(_ root: URL) {
    guard let s = circleStore(root, "calr.sqlite") else { return }
    let c = CircleStore(store: s)
    guard let p = c.add(name: "Ian Example", tier: .close, tags: noTags, details: CircleDetails(),
                        handles: [Handle(kind: .email, value: "ian@example.com")]).person else { return }
    let cache = CalendarCache(store: s)
    cache.upsertCalendars(account: "me@example.com", [CalCalendar(account: "me@example.com", calendarID: "me@example.com", name: "Me", color: "#000",
                                                                    owned: true, shown: true, primary: true)])
    func ev(_ id: String, _ day: Int, ian: String, me: String?) -> GoogleEventChange {
        let f = CalEventFields(start: circleDay(day), end: circleDay(day) + 1800, title: "Meeting \(id)", googleUpdated: circleDay(1))
        return GoogleEventChange(eventID: id, cancelled: false, fields: f,
                                 guests: [CalGuest(email: "ian@example.com", status: ian)] + (me.map { [CalGuest(email: "me@example.com", status: $0)] } ?? []))
    }
    cache.apply(account: "me@example.com", calendarID: "me@example.com", changes: [
        ev("a", 10, ian: "accepted", me: "accepted"), ev("b", 11, ian: "declined", me: "accepted"), ev("c", 12, ian: "accepted", me: "declined"),
        ev("d", 13, ian: "accepted", me: nil), ev("e", 25, ian: "accepted", me: "accepted")], nextToken: nil)
    let n = CircleCalendarReader.read(store: s, now: circleDay(18))
    let met = c.exchanges(of: p.id).filter { $0.channel == .calendar }
    check(n == 2 && met.count == 2 && Set(met.map { Calendar.current.component(.day, from: $0.at) }) == [10, 13] && c.channel("calendar")?.asOf == circleDay(18),
          "calendar_meetings_both_accepted_count_as_met")
    check(c.clocks(p, now: circleDay(18)).lastConversation == circleDay(13) && c.clocks(p, now: circleDay(18)).conversationVia == .calendar,
          "met_meeting_sets_last_talked")
    if let m = met.first { c.setIgnored(m.id, true) }
    check(c.clocks(p, now: circleDay(18)).lastConversation == circleDay(10), "meeting_can_be_corrected")
}

/// A fake WhatsApp database for Circle's reader: a 1:1 chat both ways, a group, and an old message.
private func fakeWhatsAppForCircle(_ folder: URL, now: Date) -> Bool {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) // try?-ok: the open below fails the check
    let a = now.timeIntervalSince1970 - 978_307_200
    let sql = """
    CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, ZCONTACTJID TEXT, ZPARTNERNAME TEXT, ZSESSIONTYPE INTEGER, ZUNREADCOUNT INTEGER,
      ZARCHIVED INTEGER, ZREMOVED INTEGER, ZHIDDEN INTEGER);
    CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZISFROMME INTEGER, ZMESSAGETYPE INTEGER, ZTEXT TEXT,
      ZMESSAGEDATE REAL, ZSTANZAID TEXT, ZGROUPMEMBER INTEGER, ZPUSHNAME TEXT, ZMEDIAITEM INTEGER);
    INSERT INTO ZWACHATSESSION VALUES (1,'447700900123@s.whatsapp.net','Jo Example',0,0,0,0,0);
    INSERT INTO ZWAMESSAGE VALUES (1,1,0,0,'secret words',\(a - 3 * 86400),'S1',NULL,NULL,NULL);
    INSERT INTO ZWAMESSAGE VALUES (2,1,1,0,'more secret words',\(a - 2 * 86400),'S2',NULL,NULL,NULL);
    INSERT INTO ZWAMESSAGE VALUES (3,1,1,0,'again',\(a - 2 * 86400 + 60),'S3',NULL,NULL,NULL);
    INSERT INTO ZWAMESSAGE VALUES (4,1,0,6,NULL,\(a - 86400),'S4',NULL,NULL,NULL);
    INSERT INTO ZWAMESSAGE VALUES (5,1,0,0,'too old',\(a - 400 * 86400),'S5',NULL,NULL,NULL);
    INSERT INTO ZWACHATSESSION VALUES (2,'120363@g.us','Club',1,0,0,0,0);
    INSERT INTO ZWAMESSAGE VALUES (6,2,0,0,'group words',\(a - 3600),'S6',NULL,NULL,NULL);
    """
    var db: OpaquePointer?
    guard sqlite3_open(folder.appendingPathComponent("ChatStorage.sqlite").path, &db) == SQLITE_OK else { return false }
    defer { sqlite3_close(db) }
    return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
}

@MainActor private func circleWhatsAppReaderChecks(_ root: URL) {
    let now = circleDay(18)
    let folder = root.appendingPathComponent("wa")
    guard fakeWhatsAppForCircle(folder, now: now) else { check(false, "wa fixture"); return }
    do {
        let r = try CircleWhatsAppReader.read(folder: folder, after: nil, backfillMonths: 12, now: now)
        check(r.exchanges.count == 2 && Set(r.exchanges.map(\.direction)) == [.incoming, .outgoing]
              && r.exchanges.allSatisfy { $0.handle == Handle(kind: .phone, value: "447700900123") && $0.name == "Jo Example" }
              && r.cursor > 0, "whatsapp_reader_one_to_one_metadata_only_in_backfill")
        let again = try CircleWhatsAppReader.read(folder: folder, after: r.cursor, backfillMonths: 12, now: now)
        check(again.exchanges.isEmpty, "whatsapp_reader_resumes_from_cursor")
    } catch { check(false, "whatsapp_reader: \(error)") }
    guard let s = circleStore(root, "war.sqlite") else { return }
    CircleReaders.runWhatsApp(store: s, folder: folder, now: now)
    let st = CircleStore(store: s).channel("whatsapp")
    check(st?.asOf == now && st?.completeFrom != nil && CircleStore(store: s).conversationSuggestions().first?.name == "Jo Example", "whatsapp_reader_records_data_as_of")
    CircleReaders.runWhatsApp(store: s, folder: root.appendingPathComponent("missing"), now: now)
    check(CircleStore(store: s).channel("whatsapp")?.note.contains("isn't set up") == true, "whatsapp_reader_says_what_it_cannot_see")
}

@MainActor private func circleWeChatReaderChecks(_ root: URL) {
    let dir = root.appendingPathComponent("wx")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) // try?-ok: the open below fails the check
    var db: OpaquePointer?
    guard sqlite3_open(dir.appendingPathComponent("db").path, &db) == SQLITE_OK, let db else { check(false, "wx db"); return }
    sqlite3_exec(db, "CREATE TABLE app(app_id INTEGER PRIMARY KEY, identifier TEXT); CREATE TABLE record(rec_id INTEGER PRIMARY KEY, app_id INTEGER, data BLOB, delivered_date REAL);"
                 + "INSERT INTO app VALUES(1,'com.tencent.xinWeChat');", nil, nil, nil)
    let now = circleDay(18)
    func note(_ title: String, _ body: String, hoursAgo: Double) {
        let plist: [String: Any] = ["app": "x", "req": ["titl": title, "subt": "", "body": body]]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) else { return } // try?-ok: fixture
        var s: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO record(app_id,data,delivered_date) VALUES(1,?,?)", -1, &s, nil)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(s, 1, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        sqlite3_bind_double(s, 2, now.timeIntervalSince1970 - 978_307_200 - hoursAgo * 3600)
        sqlite3_step(s); sqlite3_finalize(s)
    }
    note("王小明", "明天见", hoursAgo: 5)
    note("王小明", "好的", hoursAgo: 4)
    note("Parents group", "Mrs Lee: bring the form", hoursAgo: 3)
    sqlite3_close(db)
    do {
        let rows = try CircleWeChatReader.read(folder: dir, now: now)
        check(rows.count == 1 && rows.first?.handle == Handle(kind: .wechat, value: "王小明") && rows.first?.direction == .incoming,
              "wechat_reader_incoming_one_to_one_only")
    } catch { check(false, "wechat_reader: \(error)") }
}

@MainActor private func circleCopyChecks(_ root: URL) {
    guard let s = circleStore(root, "copy.sqlite") else { return }
    let c = CircleStore(store: s)
    var d = CircleDetails(); d.notes = "Likes hiking"; d.language = "English"
    guard let p = c.add(name: "Kim Example", tier: .close, tags: noTags, details: d,
                        handles: [Handle(kind: .phone, value: "447700900777"), Handle(kind: .email, value: "kim@example.com")], now: circleDay(1, month: 9)).person
    else { return }
    let now = circleDay(18)
    let copy = CircleCopy.phone(store: s, now: now)
    let kim = copy.people.first
    check(copy.due == [p.shortID.text] && kim?.name == "Kim Example" && kim?.due == true && kim?.wa == "447700900777" && kim?.email == "kim@example.com"
          && kim?.notes == "Likes hiking", "phone_copy_has_due_list_and_cards")
    let body = (try? CircleCopy.body(copy)).map { String(decoding: $0, as: UTF8.self) } ?? "" // try?-ok: empty fails the check
    check(body.contains("\"due\"") && !body.contains("secret"), "phone_copy_encodes")
    // The phone's actions: contacted (outreach), snooze, talked; newest wins; each id once.
    let iso = ISO8601DateFormatter()
    let r = c.applyPhoneActions([CirclePhoneAction(id: "ca-1", person: p.shortID.text, action: "contacted", madeAt: iso.string(from: now)),
                                 CirclePhoneAction(id: "ca-2", person: "P-99999", action: "snooze", madeAt: iso.string(from: now)),
                                 CirclePhoneAction(id: "ca-3", person: p.shortID.text, action: "dance", madeAt: iso.string(from: now))], now: now)
    check(r.applied == ["ca-1"] && Set(r.skipped.map(\.id)) == ["ca-2", "ca-3"] && !c.clocks(p, now: now + 60).due, "phone_contacted_applied")
    _ = c.applyPhoneActions([CirclePhoneAction(id: "ca-4", person: p.shortID.text, action: "snooze", madeAt: iso.string(from: now + 8 * 86400))], now: now + 8 * 86400)
    check(c.details(p.id).snoozedUntil == AppTime.calendar.date(byAdding: .day, value: 14, to: now + 8 * 86400), "phone_snooze_applied")
}

/// The engine side on a fake engine: metadata and What's new taken in by cursor, the watch list and the phone copy sent
/// once until they change, the phone's actions applied and acknowledged, nothing while Circle is off.
@MainActor func circleSyncChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-circle-sync-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    guard let s = circleStore(root, "sync.sqlite") else { return }
    let c = CircleStore(store: s)
    guard let p = c.add(name: "Lou Example", tier: .network, tags: ItemTags(primary: TagRules.investor, others: []), details: CircleDetails(),
                        handles: [Handle(kind: .email, value: "lou@example.com")]).person else { return }
    final class Log: @unchecked Sendable { var calls: [String] = []; var bodies: [String: String] = [:] }
    let log = Log()
    let pid = p.shortID.text
    let client = ConnectorClient(baseURL: URL(string: "https://engine.test")!, key: "k") { req in
        let path = req.url!.path, q = req.url!.query ?? ""
        log.calls.append("\(req.httpMethod!) \(path)\(q.isEmpty ? "" : "?" + q)")
        if let b = req.httpBody { log.bodies[path] = String(decoding: b, as: UTF8.self) }
        func ok(_ o: Any) -> (Data, HTTPURLResponse) {
            (try! JSONSerialization.data(withJSONObject: o), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        switch path {
        case "/v2/circle/exchanges":
            if q.contains("after=0") {
                return ok(["exchanges": [["seq": 7, "key": "gmail:x:1:0", "channel": "gmail", "direction": "in", "at": "2026-11-16T10:00:00.000Z",
                                          "account": "me@example.com", "handle": "lou@example.com", "name": "Lou Example"]],
                           "readers": [["reader": "gmail:me@example.com", "as_of": "2026-11-17T10:00:00.000Z", "complete_from": "2025-11-17T00:00:00.000Z", "note": ""]],
                           "next": 7, "more": false])
            }
            return ok(["exchanges": [], "readers": [], "next": 7, "more": false])
        case "/v2/circle/updates":
            return ok(["updates": q.contains("after=0") ? [["seq": 3, "key": "news:\(pid):x", "person": pid, "kind": "news_person", "title": "Lou Example speaks",
                                                            "detail": "Wire", "url": "https://example.com/n", "at": "2026-11-15T10:00:00.000Z", "match": "possible"]] : [],
                       "next": 3, "more": false])
        case "/v2/circle/actions":
            return ok(["actions": log.calls.filter { $0.hasPrefix("GET /v2/circle/actions") }.count == 1
                       ? [["id": "cact-0001", "person": pid, "action": "contacted", "made_at": "2026-11-17T09:00:00.000Z"]] : []])
        default: return ok(["ok": true])
        }
    }
    let now = circleDay(17)
    let problems = await CircleSync.run(store: s, client: client, connector: "c1", now: now)
    check(problems.isEmpty, "circle_sync_runs_clean")
    check(c.exchanges(of: p.id).contains { $0.channel == .gmail && $0.direction == .incoming } && c.channel("gmail:me@example.com")?.asOf != nil,
          "circle_sync_takes_in_gmail_metadata_with_data_as_of")
    check(c.updates(p.id).first?.title == "Lou Example speaks", "circle_sync_takes_in_whats_new")
    check(log.calls.contains("POST /v2/circle/actions/ack") && c.exchanges(of: p.id).contains { $0.channel == .manual }, "circle_sync_applies_phone_actions")
    check(log.bodies["/v2/circle/watch"]?.contains("Lou Example") == true && log.bodies["/v2/circle"]?.contains("\"due\"") == true, "circle_sync_sends_watch_and_copy")
    let before = log.calls.count
    _ = await CircleSync.run(store: s, client: client, connector: "c1", now: now)
    let second = log.calls[before...]
    check(!second.contains { $0.hasPrefix("PUT") } && second.contains("GET /v2/circle/exchanges?after=7"), "circle_sync_sends_only_changes_and_resumes")
    s.setModule(.circle, on: false)
    let before2 = log.calls.count
    _ = await CircleSync.run(store: s, client: client, connector: "c1", now: now)
    check(log.calls.count == before2, "circle_sync_idle_while_circle_off")
}

/// Settings › Keys › Companies House: saved on this Mac like the other keys, queued (names only), sent with PUT /v2/keys,
/// removable, and the engine's status read back.
@MainActor func circleKeyChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-chkey-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: temp cleanup
    let store: Store
    do { store = Store(db: try DB(url: root.appendingPathComponent("board.sqlite"))) } catch { check(false, "ch key setup: \(error)"); return }
    do {
        try ConnectorAccounts.add(id: "ch", name: "CH", baseURL: URL(string: "https://ch.example")!, key: "k", store: store)
        try Keys.setCompaniesHouse("ch-secret-key-1", store: store)
        let meta = (try? store.db.query("SELECT group_concat(value) FROM meta") { DB.text($0, 0) }.first) ?? "" // try?-ok: empty fails the check
        check(Keys.pending(connector: "ch", store: store) == [.companiesHouse] && Keys.value(Keys.companiesHouse, store: store) == "ch-secret-key-1"
              && !meta.contains("ch-secret"), "companies_house_key_saved_on_the_mac_and_queued")
        let up = FakeEngine { _, p, _ in p == "/v2/keys" ? (200, #"{"ok":true,"keys":{"claude":false,"google_client_id":null,"companies_house":true}}"#) : (404, "{}") }
        let ok = await Keys.push(connector: "ch", store: store, client: up.client())
        check(ok && up.bodies("/v2/keys").first?["companies_house_key"] as? String == "ch-secret-key-1" && up.bodies("/v2/keys").first?["claude_key"] == nil,
              "companies_house_key_sent_to_the_engine")
        let keys = try JSONDecoder().decode(EngineKeys.self, from: Data(#"{"claude":true,"google_client_id":null,"companies_house":true}"#.utf8))
        let old = try JSONDecoder().decode(EngineKeys.self, from: Data(#"{"claude":true,"google_client_id":null}"#.utf8))
        check(keys.companiesHouse && !old.companiesHouse, "engine_reports_companies_house_key_status")
        try Keys.setCompaniesHouse("", store: store)
        _ = await Keys.push(connector: "ch", store: store, client: up.client())
        check(up.bodies("/v2/keys").last?["companies_house_key"] as? String == "" && Keys.value(Keys.companiesHouse, store: store) == nil,
              "companies_house_key_removed_on_the_engine_too")
    } catch { check(false, "ch key: \(error)") }
}

/// Codex C2: a phone action whose local write fails is not acknowledged (it stays queued on the engine and is retried),
/// with one Activity error.
@MainActor func circlePhoneWriteFailChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-circle-pwf-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    guard let s = circleStore(root, "pwf.sqlite") else { return }
    let c = CircleStore(store: s)
    guard let p = c.add(name: "Vic Example", tier: .close, tags: ItemTags(primary: nil, others: []), details: CircleDetails(), handles: []).person else { return }
    let iso = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
    s.performForTest("CREATE TRIGGER fail_x BEFORE INSERT ON circle_exchanges BEGIN SELECT RAISE(ABORT, 'disk full'); END")
    s.performForTest("CREATE TRIGGER fail_p BEFORE INSERT ON circle_people BEGIN SELECT RAISE(ABORT, 'disk full'); END")
    let errorsBefore = s.recentActivity(limit: 200).filter { $0.level == .error }.count
    let r = c.applyPhoneActions([CirclePhoneAction(id: "pw-00001", person: p.shortID.text, action: "contacted", madeAt: iso),
                                 CirclePhoneAction(id: "pw-00002", person: p.shortID.text, action: "snooze", madeAt: iso)])
    let newErrors = s.recentActivity(limit: 200).filter { $0.level == .error }.count - errorsBefore
    check(r.applied.isEmpty && r.skipped.isEmpty && r.failed == ["pw-00001", "pw-00002"]
          && s.recentActivity(limit: 200).filter { $0.level == .error && $0.message.contains("phone's Circle") }.count == 1 && newErrors >= 1,
          "failed_phone_write_is_not_acknowledged")
    s.performForTest("DROP TRIGGER fail_x"); s.performForTest("DROP TRIGGER fail_p")
    let again = c.applyPhoneActions([CirclePhoneAction(id: "pw-00001", person: p.shortID.text, action: "contacted", madeAt: iso)])
    check(again.applied == ["pw-00001"] && c.exchanges(of: p.id).contains { $0.channel == .manual }, "failed_phone_write_applies_on_retry")
}

/// Codex round 2 #2: a page from the engine and its cursor are written together; a failed write keeps the old cursor, so the
/// page comes again (nothing is skipped for good).
@MainActor func circleSyncAtomicChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-circle-atomic-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    guard let s = circleStore(root, "atomic.sqlite") else { return }
    let c = CircleStore(store: s)
    guard let p = c.add(name: "Wes Example", tier: .network, tags: ItemTags(primary: nil, others: []), details: CircleDetails(),
                        handles: [Handle(kind: .email, value: "wes@example.com")]).person else { return }
    let pid = p.shortID.text
    let client = ConnectorClient(baseURL: URL(string: "https://engine.test")!, key: "k") { req in
        let path = req.url!.path, q = req.url!.query ?? ""
        func ok(_ o: Any) -> (Data, HTTPURLResponse) {
            (try! JSONSerialization.data(withJSONObject: o), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let first = q.contains("after=0")
        switch path {
        case "/v2/circle/exchanges":
            return ok(["exchanges": first ? [["seq": 5, "key": "gmail:x:1:0", "channel": "gmail", "direction": "in", "at": "2026-11-16T10:00:00.000Z",
                                              "account": "me@example.com", "handle": "wes@example.com", "name": "Wes"]] : [], "readers": [], "next": first ? 5 : 5, "more": false])
        case "/v2/circle/updates":
            return ok(["updates": first ? [["seq": 9, "key": "news:\(pid):w", "person": pid, "kind": "news_person", "title": "Wes Example speaks",
                                            "detail": "", "url": "https://example.com/w", "at": "2026-11-15T10:00:00.000Z", "match": "possible"]] : [],
                       "next": first ? 9 : 9, "more": false])
        case "/v2/circle/actions": return ok(["actions": []])
        default: return ok(["ok": true])
        }
    }
    s.performForTest("CREATE TRIGGER fail_x BEFORE INSERT ON circle_exchanges BEGIN SELECT RAISE(ABORT, 'disk full'); END")
    s.performForTest("CREATE TRIGGER fail_u BEFORE INSERT ON circle_updates BEGIN SELECT RAISE(ABORT, 'disk full'); END")
    let problems = await CircleSync.run(store: s, client: client, connector: "c1", now: circleDay(17))
    check(problems.count >= 2 && c.meta("circle_engine_exchanges:c1") == nil && c.meta("circle_engine_updates:c1") == nil,
          "failed_page_write_keeps_the_old_cursor")
    s.performForTest("DROP TRIGGER fail_x"); s.performForTest("DROP TRIGGER fail_u")
    _ = await CircleSync.run(store: s, client: client, connector: "c1", now: circleDay(17))
    check(c.exchanges(of: p.id).contains { $0.channel == .gmail } && c.updates(p.id).first?.title == "Wes Example speaks"
          && c.meta("circle_engine_exchanges:c1") == "5", "failed_page_comes_again_and_is_taken_in")
}

/// Codex round 3 (1): on this Mac the engine's fetches go through the app's bridge, which can reach the home network. A
/// Circle feed fetch is marked "public only": the bridge resolves the name and refuses private, loopback and link-local
/// answers, and a "manual" redirect is not followed (the engine checks each hop itself).
@MainActor func circleBridgeChecks() {
    check(["127.0.0.1", "10.0.0.5", "172.20.1.1", "192.168.1.2", "169.254.1.1", "100.64.3.4", "0.0.0.0", "224.0.0.1", "::1", "::", "fe80::1",
           "fd00::1", "::ffff:192.168.0.1", "64:ff9b::a00:1", "::127.0.0.1", "::7f00:1"].allSatisfy { !PublicAddress.isPublic($0) }
          && ["8.8.8.8", "93.184.216.34", "2606:4700::1111"].allSatisfy { PublicAddress.isPublic($0) }, "bridge_classifies_private_addresses")
    func req(_ url: String, publicOnly: Bool, redirect: String = "manual", answers: [String]) -> (URLRequest?, [String]) {
        var asked: [String] = []
        let r = try? LocalEngine.request(from: ["url": url, "method": "GET", "publicOnly": publicOnly, "redirect": redirect], // try?-ok: nil is checked
                                         resolve: { host in asked.append(host); return answers })
        return (r, asked)
    }
    let priv = req("https://feed.example.com/rss", publicOnly: true, answers: ["93.184.216.34", "192.168.1.10"])
    check(priv.0 == nil && priv.1 == ["feed.example.com"], "bridge_refuses_a_name_that_resolves_to_a_private_address")
    let lit = req("http://127.0.0.1:8080/admin", publicOnly: true, answers: ["93.184.216.34"])
    check(lit.0 == nil, "bridge_refuses_a_private_literal_ip")
    let none = req("https://nowhere.example.com/rss", publicOnly: true, answers: [])
    check(none.0 == nil, "bridge_refuses_a_name_that_does_not_resolve")
    let ok = req("https://feed.example.com/rss", publicOnly: true, answers: ["93.184.216.34"])
    check(ok.0 != nil && LocalEngine.wantsManualRedirect(ok.0!), "bridge_lets_public_feeds_through_without_following_redirects")
    let other = req("https://api.example.com/x", publicOnly: false, redirect: "follow", answers: ["10.0.0.1"])
    check(other.0 != nil && other.1.isEmpty && !LocalEngine.wantsManualRedirect(other.0!), "bridge_leaves_other_fetches_alone")
    // The Mac runtime hands both on (the same script is bundled as Resources/engine.js).
    let runtime = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("engine/local/runtime.js")
    let text = (try? String(contentsOf: runtime, encoding: .utf8)) ?? "" // try?-ok: empty fails the check
    check(text.contains("redirect: req.redirect") && text.contains("publicOnly: init.fbPublicOnly === true"), "mac_runtime_passes_redirect_and_public_only")
}
