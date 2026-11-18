import FloatBoardCore
import Foundation
import SQLite3

/// Circle's own WhatsApp reader (features §9): who, when and which way, for one-to-one chats only, from WhatsApp
/// Desktop's database copied to a private folder (as `WhatsAppLocal` does). It never reads a message's text: the query
/// asks for the chat, the direction and the time, nothing else. Groups, status updates, broadcasts and channels are skipped.
public enum CircleWhatsAppReader {
    public struct Result { public let exchanges: [ExchangeInput]; public let cursor: Double; public let earliest: Date? }

    /// Messages after `after` (WhatsApp's clock), or the last `backfillMonths` the first time. One row per chat, day and direction.
    public static func read(folder: URL = WhatsAppLocal.folder, after: Double?, backfillMonths: Int, now: Date = Date()) throws -> Result {
        let floor = (AppTime.calendar.date(byAdding: .month, value: -backfillMonths, to: now) ?? now).timeIntervalSince1970 - WhatsAppLocal.appleEpoch
        let since = max(after ?? floor, floor)
        return try WhatsAppLocal.withCopy(folder) { db in
            var stmt: OpaquePointer?
            let sql = """
                SELECT s.ZCONTACTJID, COALESCE(s.ZPARTNERNAME,''), m.ZISFROMME, m.ZMESSAGEDATE
                FROM ZWAMESSAGE m JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION
                WHERE s.ZSESSIONTYPE = 0 AND s.ZCONTACTJID IS NOT NULL AND s.ZCONTACTJID NOT LIKE '%status'
                  AND s.ZCONTACTJID NOT LIKE '%@broadcast' AND s.ZCONTACTJID NOT LIKE '%@newsletter' AND s.ZCONTACTJID NOT LIKE '%@g.us'
                  AND COALESCE(m.ZMESSAGETYPE, 0) NOT IN (6, 10, 14) AND m.ZMESSAGEDATE > ?
                ORDER BY m.ZMESSAGEDATE
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw WhatsAppLocal.ReadError.unreadable(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, since)
            var byKey: [String: ExchangeInput] = [:]
            var cursor = after ?? 0, earliest: Date?
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw WhatsAppLocal.ReadError.unreadable(String(cString: sqlite3_errmsg(db))) }
                guard let jidC = sqlite3_column_text(stmt, 0), let handle = Handles.fromWhatsApp(String(cString: jidC)) else { continue }
                let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let mine = sqlite3_column_int(stmt, 2) == 1
                let stamp = sqlite3_column_double(stmt, 3)
                let at = Date(timeIntervalSince1970: stamp + WhatsAppLocal.appleEpoch)
                cursor = max(cursor, stamp); earliest = min(earliest ?? at, at)
                let e = ExchangeInput(channel: .whatsapp, direction: mine ? .outgoing : .incoming, at: at, handle: handle, name: mine ? "" : name)
                let key = "whatsapp:\(handle.kind.rawValue):\(handle.value):\(Due.dayString(at)):\(e.direction.rawValue)"
                if let old = byKey[key], old.at >= at { continue }
                byKey[key] = ExchangeInput(channel: .whatsapp, direction: e.direction, at: at, handle: handle,
                                           name: name.isEmpty ? (byKey[key]?.name ?? "") : name)
            }
            return Result(exchanges: byKey.values.sorted { $0.at < $1.at }, cursor: cursor, earliest: earliest)
        }
    }
}

extension CircleWhatsAppReader {
    /// The last few messages of a one-to-one chat, with text, for a draft the owner asked for (P9). Read on request only,
    /// sent to Claude for that draft and never stored.
    public static func lastMessages(folder: URL = WhatsAppLocal.folder, phone: String, limit: Int = 5) throws -> [(direction: String, at: Date, text: String)] {
        try WhatsAppLocal.withCopy(folder) { db in
            var stmt: OpaquePointer?
            let sql = """
                SELECT m.ZISFROMME, m.ZMESSAGEDATE, COALESCE(m.ZTEXT,'') FROM ZWAMESSAGE m JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION
                WHERE s.ZSESSIONTYPE = 0 AND s.ZCONTACTJID = ? AND COALESCE(m.ZMESSAGETYPE, 0) IN (0, 7) AND COALESCE(m.ZTEXT,'') <> ''
                ORDER BY m.ZMESSAGEDATE DESC LIMIT ?
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw WhatsAppLocal.ReadError.unreadable(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, phone + "@s.whatsapp.net", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int(stmt, 2, Int32(limit))
            var out: [(direction: String, at: Date, text: String)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append((sqlite3_column_int(stmt, 0) == 1 ? "out" : "in", Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1) + WhatsAppLocal.appleEpoch),
                            String((sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "").prefix(1000))))
            }
            return out.reversed()
        }
    }
}

/// Circle's WeChat reader: incoming one-to-one messages from macOS's notification history (who and when only).
/// It can't see what you send, muted chats, or notifications you cleared; the card says so.
public enum CircleWeChatReader {
    public static func read(folder: URL = WeChatNotifications.folder, now: Date = Date(), backfillDays: Double = 365) throws -> [ExchangeInput] {
        let notes = try WeChatNotifications.readNotes(folder: folder, since: now.addingTimeInterval(-backfillDays * 86400))
        let groups = Set(notes.filter { !$0.sender.isEmpty && $0.sender != $0.chat }.map(\.chat))
        var byKey: [String: ExchangeInput] = [:]
        for n in notes where !groups.contains(n.chat) {
            guard let v = Handles.normalize(.wechat, n.chat) else { continue }
            let h = Handle(kind: .wechat, value: v)
            let key = "wechat:wechat:\(v):\(Due.dayString(n.at)):in"
            if let old = byKey[key], old.at >= n.at { continue }
            byKey[key] = ExchangeInput(channel: .wechat, direction: .incoming, at: n.at, handle: h, name: n.chat)
        }
        return byKey.values.sorted { $0.at < $1.at }
    }
}

/// Runs Circle's Mac readers and records their state ("data as of", how far back, what they can't see).
@MainActor public enum CircleReaders {
    /// WhatsApp: from the cursor, or the backfill period the first time.
    /// Whether the last reader copy and scan ran on the main thread (checks; it must not).
    public private(set) static var lastReadOnMainThread: Bool?

    /// The copy of WhatsApp's database and the scan run off the main thread; what they found is recorded here.
    public static func runWhatsApp(store: Store, folder: URL = WhatsAppLocal.folder, now: Date = Date()) async {
        let c = CircleStore(store: store)
        let prev = c.channel("whatsapp")
        let after = prev.flatMap { Double($0.cursor) }, months = c.backfillMonths
        do {
            let (r, onMain) = try await Task.detached { () throws -> (CircleWhatsAppReader.Result, Bool) in
                (try CircleWhatsAppReader.read(folder: folder, after: after, backfillMonths: months, now: now), Thread.isMainThread)
            }.value
            lastReadOnMainThread = onMain
            c.record(r.exchanges, now: now)
            let from = prev?.completeFrom ?? AppTime.calendar.date(byAdding: .month, value: -c.backfillMonths, to: now)
            c.setChannel("whatsapp", asOf: now, completeFrom: from, cursor: String(r.cursor), note: "one-to-one chats only")
            await resolveLinkedIDs(store: store, folder: folder, now: now)
        } catch {
            c.setChannel("whatsapp", asOf: prev?.asOf, completeFrom: prev?.completeFrom, cursor: prev?.cursor ?? "", note: "\(error)")
            if prev?.note != "\(error)" { store.activity("circle", .warning, "Circle could not read WhatsApp", detail: "\(error)") }
        }
    }

    /// WhatsApp linked ids seen in messages or on people: their numbers from WhatsApp's own contact list (this Mac only), so an
    /// id and its number count as one person. Quiet when WhatsApp's contact list isn't there.
    /// Only ids whose number isn't known yet are looked up, off the main thread (copying WhatsApp's contact list and reading
    /// it); the numbers are saved and linked with one write each. Returns how many handles were added to people.
    @discardableResult
    public static func resolveLinkedIDs(store: Store, folder: URL = WhatsAppLocal.folder, now: Date = Date(),
                                        resolve: (@Sendable ([String]) -> [String: ResolvedContact])? = nil) async -> Int {
        let lids: [String]
        do {
            lids = try store.db.query("""
                SELECT handle FROM circle_exchanges WHERE handle_kind='whatsapp' AND handle LIKE '%@lid'
                UNION SELECT value FROM person_handles WHERE kind='whatsapp' AND value LIKE '%@lid'
                """) { DB.text($0, 0) }
        } catch { store.activity("circle", .error, "Could not read WhatsApp contacts for Circle", detail: "\(error)"); return 0 }
        let known = LIDBook.all(store)
        let missing = Array(Set(lids.map { $0.lowercased() }).filter { known[$0] == nil })
        guard !missing.isEmpty else { return LIDBook.link(store: store, now: now) }   // people added since still get linked
        let lookup = resolve ?? { ids in WhatsAppContacts.resolve(ids, folder: folder) }
        let found = await Task.detached { lookup(missing) }.value
        LIDBook.save(store: store, found)
        return LIDBook.link(store: store, now: now)
    }

    public static func runWeChat(store: Store, folder: URL = WeChatNotifications.folder, now: Date = Date()) async {
        let c = CircleStore(store: store)
        let prev = c.channel("wechat")
        do {
            let rows = try await Task.detached { try CircleWeChatReader.read(folder: folder, now: now) }.value   // off the main thread
            c.record(rows, now: now)
            let earliest = rows.map(\.at).min()
            c.setChannel("wechat", asOf: now, completeFrom: [prev?.completeFrom, earliest].compactMap { $0 }.min(), cursor: "", note: Channel.wechat.limits ?? "")
        } catch {
            c.setChannel("wechat", asOf: prev?.asOf, completeFrom: prev?.completeFrom, cursor: "", note: "\(error)")
            if prev?.note != "\(error)" { store.activity("circle", .warning, "Circle could not read WeChat notifications", detail: "\(error)") }
        }
    }

    /// Every Mac reader whose connector is set up (same access as the task connectors), plus the calendar.
    public static func runAll(store: Store, now: Date = Date()) async {
        guard store.isOn(.circle) else { return }
        if store.connectors.contains(where: { WhatsAppSync.isOn(connector: $0.id, store: store) }) { await runWhatsApp(store: store, now: now) }
        if store.connectors.contains(where: { WeChatSync.isOn(connector: $0.id, store: store) }) { await runWeChat(store: store, now: now) }
        CircleCalendarReader.read(store: store, now: now)
    }
}
