import Foundation
import FloatBoardCore
import FloatBoardConnectors
import SQLite3

/// Jots (docs/superpowers/specs/2026-11-17-jots-design.md): schema 13, the Jots core (query, tags, history), task notes,
/// meeting notes matched to events, tag suggestions, cleanup guard, daily files, the daily nudge and the engine sync.
@MainActor func jotsChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-jots-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    jotsSchemaChecks(root)
    jotsCoreChecks(root)
    taskNoteChecks(root)
    suggestionChecks(root)
    cleanupGuardChecks()
    meetingMatchChecks()
    meetingNotesChecks(root)
    dailyFileChecks(root)
    nudgeChecks(root)
    jotSearchChecks(root)
}

@MainActor func jotsStore(_ root: URL, _ name: String) -> Store? {
    do { return Store(db: try DB(url: root.appendingPathComponent(name))) } catch { check(false, "jots setup \(name): \(error)"); return nil }
}

@MainActor func jotsCount(_ store: Store, _ sql: String, _ args: [Any?] = []) -> Int64 {
    ((try? store.db.query(sql, args) { DB.int($0, 0) }) ?? []).first ?? -1 // try?-ok: -1 fails the check
}

// MARK: Schema 13

/// A board at version 12 built from the v12 fixture (tables, indexes and triggers), plus `extra` SQL.
private func makeV12Board(_ url: URL, extra: String = "") -> Bool {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/schema-v12.json")
    guard let data = try? Data(contentsOf: fixture), // try?-ok: nil fails the check
          let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[Any]] else { return false } // try?-ok: nil fails the check
    let order = ["table": 0, "index": 1, "trigger": 2]
    let sql = rows.filter { !($0[1] as? String ?? "").hasPrefix("sqlite_") && $0[3] is String }
        .sorted { order[$0[0] as? String ?? "", default: 3] < order[$1[0] as? String ?? "", default: 3] }
        .compactMap { $0[3] as? String }.joined(separator: ";\n")
    var h: OpaquePointer?
    defer { sqlite3_close(h) }
    guard sqlite3_open(url.path, &h) == SQLITE_OK else { return false }
    return sqlite3_exec(h, sql + ";\nPRAGMA user_version = 12;\n" + extra, nil, nil, nil) == SQLITE_OK
}

private func schemaRows(_ url: URL) -> [String] {
    var h: OpaquePointer?, st: OpaquePointer?
    defer { sqlite3_finalize(st); sqlite3_close(h) }
    guard sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          sqlite3_prepare_v2(h, "SELECT type||' '||name||' '||coalesce(sql,'') FROM sqlite_master ORDER BY type, name", -1, &st, nil) == SQLITE_OK else { return [] }
    var out: [String] = []
    while sqlite3_step(st) == SQLITE_ROW {
        out.append(String(cString: sqlite3_column_text(st, 0)).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*([(),])\s*"#, with: "$1", options: .regularExpression))
    }
    return out
}

@MainActor private func jotsSchemaChecks(_ root: URL) {
    check(DB.schemaVersion >= 13, "jots_schema_version_is_13")
    let old = root.appendingPathComponent("v12.sqlite")
    guard makeV12Board(old, extra: """
        INSERT INTO areas(name,color,position) VALUES('Work','#0A84FF',0);
        INSERT INTO jots(id,text,kind,source,added,updated) VALUES(1,'An old jot','jot','typed',1,1);
        """) else { check(false, "v12 board setup"); return }
    guard let up = jotsStore(root, "v12.sqlite"), jotsStore(root, "fresh13.sqlite") != nil else { return }
    let upgraded = schemaRows(old), fresh = schemaRows(root.appendingPathComponent("fresh13.sqlite"))
    check(!upgraded.isEmpty && upgraded == fresh, "jots_v12_upgrade_matches_new_board")
    let tables = Set(upgraded.compactMap { $0.hasPrefix("table ") ? $0.split(separator: " ")[1].description : nil })
    check(tables.isSuperset(of: ["jot_meetings", "jot_suggestions", "jot_sync"]), "jots_tables_exist")
    check(JotStore(store: up).jot(1)?.text == "An old jot" && jotsCount(up, "SELECT count(*) FROM jots WHERE origin='' AND task_id IS NULL") == 1,
          "jots_upgrade_keeps_existing_jots")
}

// MARK: J4, J5, J14 core

@MainActor private func jotsCoreChecks(_ root: URL) {
    guard let store = jotsStore(root, "core.sqlite") else { return }
    store.addArea("Health")
    let js = JotStore(store: store)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    guard let a = js.add("Budget: send the revised numbers", tags: ["Work", "nope", "health"], now: t0),
          let b = js.add("Run before work", now: t0.addingTimeInterval(60)),
          let c = js.add("Meeting notes for the budget review", kind: .meetingNotes, source: .meeting, origin: "fathom:abc", now: t0.addingTimeInterval(120)) else {
        check(false, "jots core setup"); return
    }
    check(store.itemTags(a.shortID) == ItemTags(primary: "Work", others: ["Health"]), "jot_add_keeps_known_tags_primary_first")
    check(js.add("again", origin: "fathom:abc")?.id == c.id && jotsCount(store, "SELECT count(*) FROM jots WHERE origin='fathom:abc'") == 1,
          "jot_origin_is_saved_once")
    check(js.list(JotQuery()).map(\.id) == [c.id, b.id, a.id], "jot_list_newest_first")
    check(js.list(JotQuery(text: "BUDGET")).map(\.id) == [c.id, a.id] && js.list(JotQuery(text: "budget work")).isEmpty == false
          && js.list(JotQuery(text: "budget run")).isEmpty, "jot_search_every_word")
    check(js.list(JotQuery(text: b.shortID.text)).map(\.id) == [b.id], "jot_search_by_id")
    check(js.list(JotQuery(tags: ["health"])).map(\.id) == [a.id], "jot_filter_by_any_tag")
    check(js.list(JotQuery(kinds: [.meetingNotes])).map(\.id) == [c.id], "jot_filter_by_kind")
    check(js.list(JotQuery()).first { $0.id == b.id }?.untagged == true, "untagged_jot_is_marked")
    js.update(a.id, text: "Budget: send the revised numbers to Ann", now: t0.addingTimeInterval(500))
    check(js.list(JotQuery(sort: .updated)).first?.id == a.id, "jot_sort_by_updated")
    check(js.list(JotQuery(sort: .tag)).map(\.id) == [a.id, c.id, b.id], "jot_sort_by_tag_untagged_last")
    // J14: history and restore.
    if let v = js.history(a.id).first {
        js.restore(a.id, to: v, now: t0.addingTimeInterval(600))
        check(js.jot(a.id)?.text == "Budget: send the revised numbers" && js.history(a.id).count == 2, "jot_restore_version_is_an_edit")
    } else { check(false, "jot_restore_version_is_an_edit") }
    js.delete(b.id, now: t0.addingTimeInterval(700))
    check(!js.list(JotQuery()).contains { $0.id == b.id }, "deleted_jot_leaves_the_list")
    js.undoDelete(b.id, now: t0.addingTimeInterval(800))
    check(js.list(JotQuery()).contains { $0.id == b.id }, "undo_delete_brings_jot_back")
    check(js.changed(since: t0.addingTimeInterval(650)).map(\.id) == [b.id], "jots_changed_since")
    check(js.setTags(b.id, ["Nope"]) != nil && js.setTags(b.id, ["Health", "Work"]) == nil
          && store.itemTags(b.shortID) == ItemTags(primary: "Health", others: ["Work"]), "jot_tags_set_first_primary")
    // Own jots today (for the nudge): typed or phone jots only, by the app's day.
    let now = Date()
    check(!js.ownJotAdded(on: now), "no_own_jot_today_yet")
    js.add("Task note text here", kind: .taskNote, now: now)
    js.add("Meeting", kind: .meetingNotes, source: .meeting, now: now)
    check(!js.ownJotAdded(on: now), "task_and_meeting_notes_do_not_count_as_jotted")
    js.add("From the phone", source: .phone, now: now)
    check(js.ownJotAdded(on: now), "phone_jot_counts_as_jotted")
}

// MARK: J10 task notes

@MainActor private func taskNoteChecks(_ root: URL) {
    guard let store = jotsStore(root, "notes.sqlite") else { return }
    store.add(title: "Prepare the offsite", area: "Work", importance: .medium, due: nil)
    guard var card = store.cards.first else { check(false, "task notes setup"); return }
    let js = JotStore(store: store)
    store.setTags(ShortID(kind: .task, number: card.id), primary: "Work", others: ["Personal"])
    card = store.card(card.id) ?? card
    card.notes = "Short"
    store.update(card)
    check(js.taskNote(forTask: card.id) == nil, "short_task_notes_make_no_jot")
    card.notes = "Book the venue and the train"
    store.update(card)
    guard let note = js.taskNote(forTask: card.id) else { check(false, "task_notes_from_10_chars_make_a_jot"); return }
    check(note.kind == .taskNote && note.text == "Book the venue and the train", "task_notes_from_10_chars_make_a_jot")
    check(store.itemTags(note.shortID).all == ["Work", "Personal"], "task_note_jot_has_the_tasks_tags")
    let link = store.itemLinks(of: note.shortID).first { $0.other == ShortID(kind: .task, number: card.id) }
    check(link?.kind == .notesOf && link?.madeBy == .auto && link?.isSubject == true, "task_note_jot_is_notes_of_the_task")
    card = store.card(card.id) ?? card
    card.notes = "Book the venue, the train and dinner"
    store.update(card)
    check(js.jot(note.id)?.text == card.notes && js.history(note.id).map(\.text) == ["Book the venue and the train"]
          && jotsCount(store, "SELECT count(*) FROM jots WHERE task_id=?", [card.id]) == 1, "task_editor_edit_updates_the_same_jot")
    // Editing the jot in the Jots tab changes the task's notes (one record).
    js.update(note.id, text: "Venue booked; train next")
    check(store.card(card.id)?.notes == "Venue booked; train next", "editing_note_jot_changes_task_notes")
    // Deleting the note jot empties the task's notes; Undo brings them back.
    js.delete(note.id)
    check(store.card(card.id)?.notes == "", "deleting_note_jot_empties_task_notes")
    js.undoDelete(note.id)
    check(store.card(card.id)?.notes == "Venue booked; train next", "undo_note_jot_delete_restores_notes")
    // Deleting the task keeps the note jot (it can tell its task was deleted).
    if let c = store.card(card.id) { store.deleteCard(c, verdict: nil) }
    check(js.jot(note.id)?.deleted == false && js.taskID(ofNote: note.id) == card.id
          && store.item(ShortID(kind: .task, number: card.id))?.deleted == true, "deleting_task_keeps_note_jot")
    store.undoDelete()
    check(store.card(card.id)?.notes == "Venue booked; train next", "task_undo_keeps_notes")
}

// MARK: J5 tag suggestions

@MainActor private func suggestionChecks(_ root: URL) {
    guard let store = jotsStore(root, "suggest.sqlite") else { return }
    let js = JotStore(store: store), sg = JotSuggestions(store: store)
    guard let a = js.add("Gym three times"), let b = js.add("Tagged one", tags: ["Work"]), let c = js.add("Quarter plan") else {
        check(false, "suggestions setup"); return
    }
    check(sg.toAsk().map(\.id) == [a.id, c.id], "untagged_new_jots_are_asked_about")
    sg.record(asked: [a.id, c.id], suggestions: [a.id: ["Personal", "Unknown"], c.id: ["Work", "Personal"]])
    check(sg.toAsk().isEmpty, "a_jot_is_asked_about_once")
    check(sg.open(a.id) == ["Personal"] && sg.open(c.id) == ["Work", "Personal"], "only_known_tags_are_suggested")
    sg.accept(c.id, "Work")
    sg.dismiss(c.id, "Personal")
    check(store.itemTags(c.shortID) == ItemTags(primary: "Work", others: []) && sg.open(c.id).isEmpty, "accept_adds_tag_dismiss_hides")
    _ = b
}

// MARK: J6 cleanup guard

private func cleanupGuardChecks() {
    let original = "Call Ann re T-12 about £4,500 by 14:30 on 3/12; see https://example.com/doc and @sam #budget"
    check(CleanupGuard.missing(original: original, cleaned: original.replacingOccurrences(of: "re", with: "about")).isEmpty, "cleanup_guard_passes_kept_substance")
    check(CleanupGuard.missing(original: original, cleaned: "Call Ann about the budget, see the doc").sorted()
          == ["#budget", "14:30", "3/12", "4,500", "@sam", "T-12", "https://example.com/doc"].sorted(), "cleanup_guard_lists_dropped_substance")
}

// MARK: J9 meeting notes

private func calEvent(_ id: Int64, _ start: Date, video: String = "", guests: [String] = [], allDay: Bool = false) -> CalEvent {
    var e = CalEvent(shortID: id, account: "me@example.com", calendarID: "me@example.com", eventID: "ev\(id)", start: start, end: start + 1800,
                     allDay: allDay, title: "Meeting \(id)", location: "", videoLink: video, description: "", htmlLink: "", recurringID: nil,
                     googleUpdated: start, fbCard: nil)
    e.guests = guests.map { CalGuest(email: $0, status: "accepted") }
    return e
}

private func meetingMatchChecks() {
    let t = Date(timeIntervalSince1970: 1_800_000_000)
    let events = [calEvent(1, t, video: "https://meet.google.com/abc-defg-hij", guests: ["ann@example.com"]),
                  calEvent(2, t, video: "https://zoom.us/j/123", guests: ["bob@example.com"]),
                  calEvent(3, t + 3 * 3600, guests: ["ann@example.com"]),
                  calEvent(4, t, guests: ["ann@example.com"], allDay: true)]
    check(MeetingMatch.find(MeetingMeta(recapKey: "k", meetingURL: "meet.google.com/ABC-defg-hij/?authuser=0", scheduledStart: t + 60), events: events)
          == .link(1), "meeting_notes_match_by_call_link")
    check(MeetingMatch.find(MeetingMeta(recapKey: "k", scheduledStart: t + 300, invitees: ["BOB@example.com"]), events: events) == .time(2),
          "meeting_notes_match_by_start_and_invitee")
    check(MeetingMatch.find(MeetingMeta(recapKey: "k", scheduledStart: t + 300, invitees: ["carol@example.com"]), events: events) == .suggested(1),
          "meeting_notes_start_only_is_a_suggestion")
    check(MeetingMatch.find(MeetingMeta(recapKey: "k", scheduledStart: t + 300, invitees: ["ann@example.com", "bob@example.com"]), events: events)
          == .suggested(1), "meeting_notes_two_candidates_is_a_suggestion")
    check(MeetingMatch.find(MeetingMeta(recapKey: "k", scheduledStart: t + 7200), events: events) == .none
          && MeetingMatch.find(MeetingMeta(recapKey: "k", meetingURL: "https://meet.google.com/zzz"), events: events) == .none,
          "meeting_notes_unmatched_when_nothing_fits")
    check(MeetingMatch.sameCall("https://www.zoom.us/j/123#x", "http://zoom.us/j/123/") && !MeetingMatch.sameCall("", ""), "same_call_ignores_dressing")
}

@MainActor private func meetingNotesChecks(_ root: URL) {
    guard let store = jotsStore(root, "meetings.sqlite") else { return }
    let cache = CalendarCache(store: store), acct = "me@example.com"
    cache.upsertCalendars(account: acct, [CalCalendar(account: acct, calendarID: acct, name: "Work", color: "#4285f4", owned: true, shown: true, primary: true)])
    let start = AppTime.calendar.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!
    cache.apply(account: acct, calendarID: acct, changes: [
        GoogleEventChange(eventID: "w1", cancelled: false, fields: CalEventFields(start: start, end: start + 3600, title: "Weekly sync",
                          videoLink: "https://meet.google.com/abc-defg-hij", googleUpdated: Date()), guests: [CalGuest(email: "ann@example.com", status: "accepted")]),
        GoogleEventChange(eventID: "w2", cancelled: false, fields: CalEventFields(start: start + 7200, end: start + 9000, title: "Board call",
                          googleUpdated: Date()), guests: [CalGuest(email: "bob@example.com", status: "accepted")])], nextToken: nil)
    guard let sync = cache.event(account: acct, calendarID: acct, eventID: "w1"), let board = cache.event(account: acct, calendarID: acct, eventID: "w2") else {
        check(false, "meeting notes setup"); return
    }
    store.add(title: "Send the deck", area: "Work", importance: .medium, due: nil)
    guard let task = store.cards.first else { return }
    let tid = ShortID(kind: .task, number: task.id)
    store.setTags(tid, primary: "Work", others: ["Investor"])
    store.link(tid, sync.id, actor: .user)
    let js = JotStore(store: store)
    let text = "## Summary\nAgreed the plan.\n\nAction items:\n- Send the deck (Ann)\n\nhttps://fathom.video/share/abc"
    guard let j = js.takeMeetingNotes(text, meta: MeetingMeta(recapKey: "fathom:abc", fathomURL: "https://fathom.video/share/abc",
                                       meetingURL: "https://meet.google.com/abc-defg-hij", title: "Weekly sync", scheduledStart: start),
                                       origin: "fathom:abc") else { check(false, "meeting_notes_saved_as_jot"); return }
    check(j.kind == .meetingNotes && j.source == .meeting && j.text == text, "meeting_notes_saved_as_jot")
    let l = store.itemLinks(of: j.shortID).first { $0.other == sync.id }
    check(l?.kind == .notesOf && l?.madeBy == .auto && l?.isSubject == true && js.meetingInfo(j.id)?.matchedBy == "link", "meeting_notes_attached_to_event")
    check(store.itemTags(j.shortID).all == ["Work", "Investor"], "meeting_notes_take_linked_tasks_tags")
    check(js.meetingNotes(forTask: task.id).map(\.id) == [j.id], "linked_task_shows_meeting_notes")
    check(js.takeMeetingNotes("again", meta: MeetingMeta(recapKey: "fathom:abc"), origin: "fathom:abc")?.id == j.id
          && jotsCount(store, "SELECT count(*) FROM jots WHERE kind='meeting_notes'") == 1, "meeting_notes_saved_once_per_meeting")
    // By time and invitee; and a suggestion that the owner confirms.
    let byTime = js.takeMeetingNotes("Board notes", meta: MeetingMeta(recapKey: "fathom:b", scheduledStart: board.start + 120, invitees: ["bob@example.com"]),
                                     origin: "fathom:b")
    check(byTime.map { js.meetingInfo($0.id)?.matchedBy } == "time" && byTime.map { store.links(of: $0.shortID) } == [board.id], "meeting_notes_by_time_and_invitee")
    guard let maybe = js.takeMeetingNotes("Who was this?", meta: MeetingMeta(recapKey: "fathom:c", scheduledStart: board.start + 60), origin: "fathom:c") else { return }
    check(store.itemLinks(of: maybe.shortID).first?.madeBy == .suggested && store.itemTags(maybe.shortID).all.isEmpty, "uncertain_meeting_is_suggested_untagged")
    js.confirmMeeting(maybe.id, event: board.shortID)
    check(store.itemLinks(of: maybe.shortID).first?.madeBy == .manual && js.meetingInfo(maybe.id)?.matchedBy == "confirmed", "suggested_meeting_confirmed")
    // Notes that arrive before their event: attached on a later pass.
    guard let early = js.takeMeetingNotes("Later", meta: MeetingMeta(recapKey: "fathom:d", meetingURL: "https://zoom.us/j/999", scheduledStart: start + 14400),
                                          origin: "fathom:d") else { return }
    check(store.links(of: early.shortID).isEmpty, "unmatched_meeting_notes_wait")
    cache.apply(account: acct, calendarID: acct, changes: [GoogleEventChange(eventID: "w3", cancelled: false, fields: CalEventFields(start: start + 14400,
                end: start + 16200, title: "Late", videoLink: "https://zoom.us/j/999", googleUpdated: Date()))], nextToken: nil)
    js.attachPendingMeetingNotes()
    check(js.meetingInfo(early.id)?.matchedBy == "link" && store.links(of: early.shortID).count == 1, "meeting_notes_attached_on_a_later_pass")
}

// MARK: J12 daily files

@MainActor private func dailyFileChecks(_ root: URL) {
    guard let store = jotsStore(root, "files.sqlite") else { return }
    let folder = root.appendingPathComponent("daily")
    let files = DailyFiles(store: store)
    files.save(DailyFilesSettings(on: true, folder: folder.path))
    let cal = AppTime.calendar
    let day1 = cal.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 9, minute: 5))!
    let day2 = cal.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 23, minute: 50))!
    let js = JotStore(store: store)
    guard let a = js.add("First idea", tags: ["Work"], now: day1), let b = js.add("Late thought", now: day2) else { check(false, "files setup"); return }
    js.add("Second idea", now: day1.addingTimeInterval(600))
    let written = files.refresh(now: day2.addingTimeInterval(60))
    let f1 = (try? String(contentsOf: folder.appendingPathComponent("2026-11-16.md"), encoding: .utf8)) ?? "" // try?-ok: empty fails the check
    check(written == ["2026-11-16", "2026-11-17"] && f1.hasPrefix(DailyFiles.marker) && f1.contains("# Jots · Monday 16 November 2026")
          && f1.contains("## 09:05 · \(a.shortID.text) · Jot · Work\n\nFirst idea") && f1.range(of: "First idea")!.lowerBound < f1.range(of: "Second idea")!.lowerBound,
          "daily_file_per_day_oldest_first")
    check(files.refresh(now: day2.addingTimeInterval(120)).isEmpty, "unchanged_days_not_rewritten")
    js.update(a.id, text: "First idea, edited", now: day2.addingTimeInterval(180))
    check(files.refresh(now: day2.addingTimeInterval(240)) == ["2026-11-16"], "edit_rewrites_the_day_it_was_added")
    js.delete(b.id, now: day2.addingTimeInterval(300))
    check(files.refresh(now: day2.addingTimeInterval(360)) == ["2026-11-17"] && !FileManager.default.fileExists(atPath: folder.appendingPathComponent("2026-11-17.md").path),
          "day_with_no_jots_left_loses_its_file")
    let mine = folder.appendingPathComponent("2026-11-18.md")
    try? "my own notes".write(to: mine, atomically: true, encoding: .utf8) // try?-ok: a failure fails the check below
    js.add("x", now: day2.addingTimeInterval(86400))
    if let x = js.list(JotQuery(text: "x")).first?.jot { js.delete(x.id, now: day2.addingTimeInterval(86400 + 60)) }
    files.refresh(now: day2.addingTimeInterval(86400 + 120))
    check((try? String(contentsOf: mine, encoding: .utf8)) == "my own notes", "a_file_floatboard_did_not_write_is_kept") // try?-ok: nil fails the check
}

// MARK: J11 nudge

@MainActor private func nudgeChecks(_ root: URL) {
    guard let store = jotsStore(root, "nudge.sqlite") else { return }
    let n = JotNudge(store: store)
    let cal = AppTime.calendar
    let today = cal.startOfDay(for: Date())
    let early = today.addingTimeInterval(20 * 3600), late = today.addingTimeInterval(21 * 3600 + 60)
    check(n.due(now: late) == nil, "nudge_off_while_jots_off")
    store.setModule(.jots, on: true)
    check(n.due(now: early) == nil, "nudge_waits_for_its_time")
    store.add(title: "Ship the release", area: "Work", importance: .medium, due: nil)
    if let c = store.cards.first { store.move(c, to: .done, now: today.addingTimeInterval(10 * 3600)) }
    let due = n.due(now: late)
    check(due?.title == "Anything to jot today?" && due?.body == "Done today: Ship the release.", "nudge_shows_finished_tasks")
    check(n.state(now: late).minutes == 21 * 60 && n.state(now: late).doneToday == ["Ship the release"] && n.state(now: late).jottedDay == nil, "nudge_state_for_the_engine")
    n.markShown(now: late)
    check(n.due(now: late.addingTimeInterval(60)) == nil && n.state(now: late).shownDay == DailyFiles.dayKey(late), "nudge_shown_once_a_day")
    store.performForTest("DELETE FROM meta WHERE key='jot_nudged_day'")
    JotStore(store: store).add("Wrote something", now: today.addingTimeInterval(12 * 3600))
    check(n.due(now: late) == nil && n.state(now: late).jottedDay == DailyFiles.dayKey(late), "nudge_skipped_when_already_jotted")
    n.save(JotNudgeSettings(on: false, minutes: 600))
    check(n.settings == JotNudgeSettings(on: false, minutes: 600) && n.state(now: late).minutes == nil, "nudge_settings_saved")
}

// MARK: Search

@MainActor private func jotSearchChecks(_ root: URL) {
    guard let store = jotsStore(root, "search.sqlite") else { return }
    JotsArea.register()
    JotStore(store: store).add("Quarterly budget thoughts\nmore", tags: ["Work"])
    check(GlobalSearch.run("budget", store: store).isEmpty, "jot_search_off_with_jots_off")
    store.setModule(.jots, on: true)
    let hit = GlobalSearch.run("budget", store: store).first { $0.0 == .jot }?.1.first
    check(hit?.title == "Quarterly budget thoughts" && hit?.detail == "Jot · Work", "jots_in_search_everything")
}
