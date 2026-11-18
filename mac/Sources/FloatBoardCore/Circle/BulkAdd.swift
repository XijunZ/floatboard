import Foundation

/// A one-to-one WhatsApp chat as Bulk add sees it: who and how many messages, never what they said.
public struct WASession: Equatable, Sendable {
    public let jid: String, name: String, messages: Int, last: Date?
    public init(jid: String, name: String, messages: Int, last: Date?) { self.jid = jid; self.name = name; self.messages = messages; self.last = last }
}

/// A contact in WhatsApp's own contact list on this Mac.
public struct WAContact: Equatable, Sendable {
    public let lid: String?, phone: String?, name: String
    public init(lid: String?, phone: String?, name: String) { self.lid = lid; self.phone = phone; self.name = name }
}

/// One row of the Bulk add sheet: one person, merged across chats and contacts by number and linked id.
public struct BulkRow: Identifiable, Equatable, Sendable {
    public let key: String
    public var name: String
    public var phone: String?
    public var handles: [Handle]
    public var messages: Int
    public var last: Date?
    public var inCircle = false
    public var dismissed = false
    public var id: String { key }
    public init(key: String, name: String, phone: String?, handles: [Handle], messages: Int, last: Date?) {
        self.key = key; self.name = name; self.phone = phone; self.handles = handles; self.messages = messages; self.last = last
    }
}

/// What Bulk add did.
public struct BulkResult {
    public var added = 0, skipped = 0
    public var failed: [(name: String, why: String)] = []
}

/// "Bulk add…" (round 11): people from WhatsApp and WeChat, header data only (who, how many messages, when; never text),
/// added to Circle in one transaction each. No AI anywhere in this flow; nothing new is sent to the engine.
@MainActor public enum BulkAdd {
    /// WhatsApp chats and contacts merged into one row per person: by phone number, and a linked id joins its number (from the
    /// contact list, or `known`: the numbers Circle already knows for linked ids).
    public nonisolated static func whatsappRows(sessions: [WASession], contacts: [WAContact], known: [String: String]) -> [BulkRow] {
        var lidPhone = known.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        for c in contacts { if let l = c.lid?.lowercased(), let p = c.phone { lidPhone[l] = p } }
        var rows: [String: BulkRow] = [:], order: [String] = []
        func upsert(phone: String?, lid: String?, name: String, messages: Int, last: Date?, preferName: Bool) {
            let ph = phone ?? lid.flatMap { lidPhone[$0] }
            guard let key = ph.map({ "phone:" + $0 }) ?? lid.map({ "lid:" + $0 }) else { return }
            var r = rows[key] ?? BulkRow(key: key, name: "", phone: ph, handles: [], messages: 0, last: nil)
            if rows[key] == nil { order.append(key) }
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty && (r.name.isEmpty || preferName) { r.name = n }
            r.messages += messages
            if let last { r.last = max(r.last ?? last, last) }
            if let ph, !r.handles.contains(Handle(kind: .phone, value: ph)) { r.handles.append(Handle(kind: .phone, value: ph)) }
            if let lid, !r.handles.contains(Handle(kind: .whatsapp, value: lid)) { r.handles.append(Handle(kind: .whatsapp, value: lid)) }
            rows[key] = r
        }
        for s in sessions {
            guard let h = Handles.fromWhatsApp(s.jid) else { continue }
            upsert(phone: h.kind == .phone ? h.value : nil, lid: h.kind == .whatsapp && h.value.hasSuffix("@lid") ? h.value : nil,
                   name: s.name, messages: s.messages, last: s.last, preferName: false)
        }
        for c in contacts {   // the contact list's full name wins over a chat's display name
            upsert(phone: c.phone, lid: c.lid?.lowercased(), name: c.name, messages: 0, last: nil, preferName: true)
        }
        return order.compactMap { rows[$0] }.map { r in
            var r = r
            if r.name.isEmpty { r.name = r.phone ?? "WhatsApp contact (no number shared)" }
            return r
        }
    }

    /// People Circle's WeChat reader saw (WeChat's notifications on this Mac): one row per chat name. `messages` counts the days
    /// they were seen (the reader keeps one record per day and direction, not each message).
    public static func wechatRows(store: Store) -> [BulkRow] {
        do {
            return try store.db.query("""
                SELECT handle_kind, handle, count(DISTINCT CAST(at / 86400 AS INTEGER)), max(at),
                       (SELECT x.name FROM circle_exchanges x WHERE x.handle_kind=e.handle_kind AND x.handle=e.handle AND x.name<>'' ORDER BY x.at DESC LIMIT 1)
                FROM circle_exchanges e WHERE channel='wechat' AND ignored=0 GROUP BY handle_kind, handle
                """) { s -> BulkRow? in
                guard let k = HandleKind(rawValue: DB.text(s, 0)) else { return nil }
                let v = DB.text(s, 1), n = DB.text(s, 4)
                return BulkRow(key: "\(k.rawValue):\(v)", name: n.isEmpty ? v : n, phone: nil, handles: [Handle(kind: k, value: v)],
                               messages: Int(DB.int(s, 2)), last: DB.date(s, 3))
            }.compactMap { $0 }
        } catch {
            store.activity("circle", .error, "Could not read WeChat contacts for Bulk add", detail: "\(error)")
            return []
        }
    }

    /// Marks who is already in Circle (any handle, a linked id's known number counting too) and who was dismissed.
    public static func mark(_ rows: [BulkRow], store: Store) -> [BulkRow] {
        let owned: Set<String>, dismissed: Set<String>
        do {
            owned = Set(try store.db.query("SELECT h.kind || ':' || h.value FROM person_handles h JOIN people p ON p.id=h.person_id WHERE p.deleted=0") { DB.text($0, 0) })
            dismissed = Set(try store.db.query("SELECT key FROM circle_dismissed") { DB.text($0, 0) })
        } catch {
            store.activity("circle", .error, "Could not read who is in Circle for Bulk add", detail: "\(error)")
            return rows
        }
        let book = LIDBook.all(store)
        return rows.map { r in
            var r = r
            let keys = r.handles.flatMap { h -> [String] in
                var k = ["\(h.kind.rawValue):\(h.value)"]
                if Handles.isLinkedID(h), let p = book[h.value] { k.append("phone:\(p)") }
                return k
            } + (r.phone.map { p in book.filter { $0.value == p }.map { "whatsapp:\($0.key)" } } ?? [])
            r.inCircle = keys.contains { owned.contains($0) }
            r.dismissed = r.handles.contains { dismissed.contains("handle:\($0.kind.rawValue):\($0.value)") }
            return r
        }
    }

    /// The rows shown: messaged only (default) or all; dismissed only when asked; search by name or number; most messages first.
    public nonisolated static func visible(_ rows: [BulkRow], messagedOnly: Bool, showDismissed: Bool, query: String) -> [BulkRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return rows.filter { r in
            (!messagedOnly || r.messages > 0) && (showDismissed || !r.dismissed)
                && (q.isEmpty || r.name.lowercased().contains(q) || (r.phone ?? "").contains(q.filter(\.isNumber).isEmpty ? "\u{1}" : q.filter(\.isNumber)))
        }.sorted { ($0.messages, $1.name) > ($1.messages, $0.name) }
    }

    /// Adds each row as a new person (name, tier, the optional people tag, its handles), one transaction each, the board
    /// re-read once at the end. A row whose
    /// handle is already someone's in Circle is skipped; a rule or a write that fails is listed and leaves nothing behind.
    public static func add(_ rows: [BulkRow], tier: PersonTier, tag: String?, store: Store, now: Date = Date()) -> BulkResult {
        var out = BulkResult()
        let tags = tag.map { [$0] } ?? []
        if let why = TagRules.problems(tags: tags, tier: tier).first {
            out.failed = rows.map { ($0.name, why) }
            return out
        }
        let c = CircleStore(store: store)
        for r in mark(rows, store: store) {
            if r.inCircle { out.skipped += 1; continue }
            let handles = r.handles.compactMap { h in Handles.normalize(h.kind, h.value).map { Handle(kind: h.kind, value: $0) } }
            let name = r.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { out.failed.append((r.name, "no name")); continue }
            do {
                // One transaction per person; the board is re-read once, after the batch (not per person).
                try store.db.transaction {
                    let id = try store.db.run("INSERT INTO people(name, aliases, tier, source, added, updated) VALUES(?,?,?,?,?,?)",
                                              [name, "[]", tier.rawValue, ItemSource.typed.rawValue, now, now])
                    for h in handles {
                        // A handle a deleted person still holds moves to the new person (as addHandle does); a live owner was
                        // skipped above (In Circle).
                        try store.db.run("""
                            INSERT INTO person_handles(person_id, kind, value, added) VALUES(?,?,?,?)
                            ON CONFLICT(kind, value) DO UPDATE SET person_id=excluded.person_id, added=excluded.added
                            WHERE person_id IN (SELECT id FROM people WHERE deleted=1)
                            """, [id, h.kind.rawValue, h.value, now])
                        guard try store.db.query("SELECT person_id FROM person_handles WHERE kind=? AND value=?", [h.kind.rawValue, h.value]) { DB.int($0, 0) }.first == id else {
                            throw DBError.sql("a handle belongs to someone in Circle")
                        }
                    }
                    try c.writeDetailsRow(id, CircleDetails())
                    if let tag { try store.setTagsRow(ShortID(kind: .person, number: id), primary: tag, others: [], now: now) }
                }
                out.added += 1
            } catch {
                out.failed.append((name, "couldn't be saved"))
                store.activity("circle", .error, "Bulk add couldn't save a person; nothing of them was kept", detail: "\(error)")
            }
        }
        store.reload()
        return out
    }

    public nonisolated static func summary(_ r: BulkResult) -> String {
        var s = "Added \(r.added), skipped \(r.skipped) (already in Circle)."
        if !r.failed.isEmpty { s += " Not added: " + r.failed.map { "\($0.name) (\($0.why))" }.joined(separator: ", ") + "." }
        return s
    }
}
