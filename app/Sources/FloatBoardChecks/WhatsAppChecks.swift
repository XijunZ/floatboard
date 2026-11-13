import Foundation
import SQLite3
import FloatBoardConnectors
import FloatBoardCore

/// A fake WhatsApp Desktop database (only the tables and columns the reader uses), made with the sqlite3 tool.
private func fakeWhatsApp(_ folder: URL, now: Date) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let a = now.timeIntervalSince1970 - 978_307_200 // WhatsApp's clock
    let far = 63_113_904_000.0 // "muted always"
    let sql = """
    CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, ZCONTACTJID TEXT, ZPARTNERNAME TEXT, ZSESSIONTYPE INTEGER, ZUNREADCOUNT INTEGER,
      ZARCHIVED INTEGER, ZREMOVED INTEGER, ZHIDDEN INTEGER);
    CREATE TABLE ZWACHATPUSHCONFIG (Z_PK INTEGER PRIMARY KEY, ZJID TEXT, ZMUTEDUNTIL REAL);
    CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZISFROMME INTEGER, ZMESSAGETYPE INTEGER, ZTEXT TEXT,
      ZMESSAGEDATE REAL, ZSTANZAID TEXT, ZGROUPMEMBER INTEGER, ZPUSHNAME TEXT, ZMEDIAITEM INTEGER);
    CREATE TABLE ZWAGROUPMEMBER (Z_PK INTEGER PRIMARY KEY, ZCONTACTNAME TEXT, ZFIRSTNAME TEXT);
    CREATE TABLE ZWAMEDIAITEM (Z_PK INTEGER PRIMARY KEY, ZTITLE TEXT);
    -- 1 Anna: 2 unread (an ask, then "thanks" filler), after my earlier reply
    INSERT INTO ZWACHATSESSION VALUES (1,'447700900123@s.whatsapp.net','Anna',0,2,0,0,0);
    INSERT INTO ZWAMESSAGE VALUES (1,1,1,0,'See you soon',\(a - 7200),'S1',NULL,NULL,NULL);
    INSERT INTO ZWAMESSAGE VALUES (2,1,0,0,'Can you send me the flat contract by tonight?',\(a - 3600),'S2',NULL,NULL,NULL);
    INSERT INTO ZWAMESSAGE VALUES (3,1,0,0,'thanks!',\(a - 3500),'S3',NULL,NULL,NULL);
    -- 2 muted group with unread: never read
    INSERT INTO ZWACHATSESSION VALUES (2,'120363@g.us','Muted club',1,5,0,0,0);
    INSERT INTO ZWACHATPUSHCONFIG VALUES (1,'120363@g.us',\(far));
    INSERT INTO ZWAMESSAGE VALUES (4,2,0,0,'Please everyone pay £10 today',\(a - 100),'S4',NULL,NULL,NULL);
    -- 3 archived chat with unread: never read
    INSERT INTO ZWACHATSESSION VALUES (3,'447700900999@s.whatsapp.net','Old shop',0,1,1,0,0);
    INSERT INTO ZWAMESSAGE VALUES (5,3,0,0,'Your order is ready',\(a - 100),'S5',NULL,NULL,NULL);
    -- 4 status updates: never read
    INSERT INTO ZWACHATSESSION VALUES (4,'123@lid.status','',3,1,0,0,0);
    -- 5 group, mute expired, a named member asks; a sticker and an emoji are dropped
    INSERT INTO ZWACHATSESSION VALUES (5,'120999@g.us','Family',1,3,0,0,0);
    INSERT INTO ZWACHATPUSHCONFIG VALUES (2,'120999@g.us',\(a - 10));
    INSERT INTO ZWAGROUPMEMBER VALUES (1,'Mum',NULL);
    INSERT INTO ZWAMESSAGE VALUES (6,5,0,0,'Who is bringing dessert on Sunday?',\(a - 600),'S6',1,NULL,NULL);
    INSERT INTO ZWAMESSAGE VALUES (7,5,0,15,NULL,\(a - 590),'S7',1,NULL,NULL);
    INSERT INTO ZWAMESSAGE VALUES (8,5,0,0,'😂😂',\(a - 580),'S8',1,NULL,NULL);
    -- 6 answered: my reply is the newest message (unread count is stale)
    INSERT INTO ZWACHATSESSION VALUES (6,'447700900555@s.whatsapp.net','Ben',0,1,0,0,0);
    INSERT INTO ZWAMESSAGE VALUES (9,6,0,0,'Are you free tomorrow?',\(a - 900),'S9',NULL,NULL,NULL);
    INSERT INTO ZWAMESSAGE VALUES (10,6,1,0,'Yes',\(a - 800),'S10',NULL,NULL,NULL);
    -- 7 only filler and a bare photo: nothing to judge
    INSERT INTO ZWACHATSESSION VALUES (7,'447700900777@s.whatsapp.net','Chris',0,2,0,0,0);
    INSERT INTO ZWAMESSAGE VALUES (11,7,0,0,'ok',\(a - 300),'S11',NULL,NULL,NULL);
    INSERT INTO ZWAMESSAGE VALUES (12,7,0,1,NULL,\(a - 200),'S12',NULL,NULL,NULL);
    -- 8 an old unread message (10 days): outside the 7-day window
    INSERT INTO ZWACHATSESSION VALUES (8,'447700900888@s.whatsapp.net','Dana',0,1,0,0,0);
    INSERT INTO ZWAMESSAGE VALUES (13,8,0,0,'Can you call me?',\(a - 10 * 86400),'S13',NULL,NULL,NULL);
    """
    var db: OpaquePointer?
    guard sqlite3_open(folder.appendingPathComponent("ChatStorage.sqlite").path, &db) == SQLITE_OK else { throw URLError(.cannotCreateFile) }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: String(cString: sqlite3_errmsg(db)), code: 1) }
}

@MainActor func whatsappChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-wa-checks-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: temp cleanup
    let folder = root.appendingPathComponent("wa")
    let now = Date()
    do { try fakeWhatsApp(folder, now: now) } catch { check(false, "whatsapp fixture: \(error)"); return }
    let utc = TimeZone(identifier: "UTC")!

    do {
        let chats = try WhatsAppLocal.unreadChats(folder: folder, cursors: [:], now: now, zone: utc)
        check(chats.map(\.name) == ["Anna", "Family"], "whatsapp_reads_only_unread_unmuted_unarchived_unanswered_worded_recent_chats")
        let anna = chats.first { $0.name == "Anna" }
        check(anna?.transcript.contains("(earlier)") == true && anna?.transcript.contains("You: See you soon") == true
              && anna?.transcript.contains("Anna: Can you send me the flat contract by tonight?") == true
              && anna?.transcript.contains("thanks!") == false, "whatsapp_transcript_has_context_and_drops_filler")
        check(anna?.link == "whatsapp://send?phone=447700900123" && anna?.group == false && anna?.key == "wa:447700900123@s.whatsapp.net:S3",
              "whatsapp_one_to_one_links_to_the_chat")
        let fam = chats.first { $0.name == "Family" }
        check(fam?.group == true && fam?.senders == ["Mum"] && fam?.link == "whatsapp://"
              && fam?.transcript.contains("Mum: Who is bringing dessert on Sunday?") == true && fam?.transcript.contains("😂") == false,
              "whatsapp_group_names_the_member_and_drops_stickers_and_emoji")
        let again = try WhatsAppLocal.unreadChats(folder: folder, cursors: Dictionary(uniqueKeysWithValues: chats.map { ($0.chatID, $0.newest) }), now: now, zone: utc)
        check(again.isEmpty, "whatsapp_nothing_is_sent_twice")
    } catch { check(false, "whatsapp_read: \(error)") }

    do {
        _ = try WhatsAppLocal.unreadChats(folder: root.appendingPathComponent("missing"), cursors: [:], now: now)
        check(false, "whatsapp_not_installed_is_said_plainly")
    } catch { check((error as? WhatsAppLocal.ReadError) == .notInstalled, "whatsapp_not_installed_is_said_plainly") }

    // The sync step: off by default; on, it sends once and moves the cursors; an old engine is reported, not retried silently.
    let store: Store
    do { store = Store(db: try DB(url: root.appendingPathComponent("board.sqlite"))) } catch { check(false, "whatsapp store: \(error)"); return }
    var bodies: [[String: Any]] = []
    let eng = FakeEngine { _, path, body in
        guard path == "/v2/chats" else { return (404, "{}") }
        bodies.append((try JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:])
        return (200, #"{"ok":true,"stored":2,"duplicates":0,"skipped":0}"#)
    }
    let off = await WhatsAppSync.tick(connector: "wa", store: store, client: eng.client(), now: now, folder: folder)
    check(off == 0 && bodies.isEmpty, "whatsapp_screening_is_off_by_default")
    WhatsAppSync.setOn(true, connector: "wa", store: store)
    let n1 = await WhatsAppSync.tick(connector: "wa", store: store, client: eng.client(), now: now, folder: folder)
    let n2 = await WhatsAppSync.tick(connector: "wa", store: store, client: eng.client(), now: now, folder: folder)
    let sent = (bodies.first?["chats"] as? [[String: Any]]) ?? []
    check(n1 == 2 && n2 == 0 && bodies.count == 1 && bodies[0]["app"] as? String == "whatsapp"
          && sent.map { $0["name"] as? String ?? "" } == ["Anna", "Family"] && sent[0]["received"] is String,
          "whatsapp_sync_sends_new_chats_once")
    WhatsAppSync.setOn(false, connector: "wa", store: store)
    WhatsAppSync.setOn(true, connector: "wa", store: store)
    _ = await WhatsAppSync.tick(connector: "wa", store: store, client: eng.client(), now: now, folder: folder)
    check(bodies.count == 2, "whatsapp_turning_off_forgets_what_was_sent")

    var card = Card(id: 1, title: "Reply to Anna", notes: "", area: "Personal", importance: .medium, due: nil, status: .todo,
                    created: now, started: nil, done: nil)
    card.sourceLink = "whatsapp://send?phone=447700900123"
    check(PhoneBoard.links(for: card).map(\.url) == ["https://wa.me/447700900123"], "whatsapp_chat_opens_on_the_phone_as_wa_me")
    card.sourceLink = "whatsapp://"
    check(PhoneBoard.links(for: card).isEmpty, "whatsapp_group_has_no_phone_link")

    let old = FakeEngine { _, _, _ in (404, #"{"error":"not found"}"#) }
    WhatsAppSync.setOn(true, connector: "old", store: store)
    _ = await WhatsAppSync.tick(connector: "old", store: store, client: old.client(), now: now, folder: folder)
    check(WhatsAppSync.status["old"]?.error?.contains("Update the engine") == true, "whatsapp_old_engine_says_update")
}
