import Foundation

/// What WhatsApp Desktop's own contact list on this Mac says about a linked id (<digits>@lid): its phone number (international
/// digits) and names. Read by WhatsAppContacts (FloatBoardConnectors); never sent anywhere.
public struct ResolvedContact: Equatable, Sendable {
    public let phone: String?
    public let name: String
    public let business: String
    public init(phone: String?, name: String, business: String) { self.phone = phone; self.name = name; self.business = business }
}

/// The numbers behind WhatsApp linked ids, kept in this Mac's board (meta `circle.lid_phones`: id → number, nothing else), so
/// Circle treats an id and its number as one person and shows the number instead of "no number shared". Never sent to the
/// engine (it isn't part of any copy), never written to Activity.
@MainActor public enum LIDBook {
    static let key = "circle.lid_phones"
    /// The map as last read, per board (parsed once, not per row on every redraw); replaced when it is saved.
    private static var cache: [ObjectIdentifier: [String: String]] = [:]
    /// How many times the map was read from the board (checks).
    public private(set) static var parses = 0

    public static func all(_ store: Store) -> [String: String] {
        if let c = cache[ObjectIdentifier(store)] { return c }
        parses += 1
        let raw = (try? store.db.query("SELECT value FROM meta WHERE key=?", [key]) { DB.text($0, 0) })?.first ?? "{}" // try?-ok: unreadable = no numbers known yet (shown as "no number shared")
        let map = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: String]) ?? [:] // try?-ok: unreadable = none known; rewritten at the next save
        cache[ObjectIdentifier(store)] = map
        return map
    }

    /// Adds the numbers found (ids without one are left as they were).
    public static func save(store: Store, _ resolved: [String: ResolvedContact]) {
        var book = all(store)
        var changed = false
        for (lid, r) in resolved {
            guard let phone = r.phone, Handles.normalize(.phone, phone) == phone, book[lid.lowercased()] != phone else { continue }
            book[lid.lowercased()] = phone; changed = true
        }
        guard changed, let data = try? JSONSerialization.data(withJSONObject: book, options: [.sortedKeys]) else { return } // try?-ok: a dictionary of strings always encodes
        cache[ObjectIdentifier(store)] = nil   // read again after the write (whether it worked or not)
        store.perform { try store.db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)", [key, String(decoding: data, as: UTF8.self)]) }
    }

    public static func phone(store: Store, _ lid: String) -> String? { all(store)[lid.lowercased()] }

    /// How a handle is shown: a linked id with a known number shows the number; otherwise as `Handles.display`.
    public static func display(store: Store, _ h: Handle) -> String {
        if Handles.isLinkedID(h), let p = phone(store: store, h.value) { return p }
        return Handles.display(h)
    }

    /// Gives each person with a linked id its number, and each person with a number its linked id, so messages under either
    /// count for them. The usual handle rules apply (a number that is someone else's merges them, as when typed by hand).
    /// Returns how many handles were added.
    @discardableResult
    public static func link(store: Store, now: Date = Date()) -> Int {
        let book = all(store)
        guard !book.isEmpty else { return 0 }
        let byPhone = Dictionary(book.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        let rows: [(Int64, String, String)]
        do {
            rows = try store.db.query("""
                SELECT h.person_id, h.kind, h.value FROM person_handles h JOIN people p ON p.id=h.person_id
                WHERE p.deleted=0 AND (h.kind='phone' OR (h.kind='whatsapp' AND h.value LIKE '%@lid'))
                """) { (DB.int($0, 0), DB.text($0, 1), DB.text($0, 2)) }
        } catch {
            store.activity("circle", .error, "Could not read people's WhatsApp numbers", detail: "\(error)")
            return 0
        }
        let have = Set(rows.map { "\($0.1):\($0.2)" })
        let owned: Set<String>
        do { owned = Set(try store.db.query("SELECT kind || ':' || value FROM person_handles") { DB.text($0, 0) }) } catch {
            store.activity("circle", .error, "Could not read people's handles", detail: "\(error)")
            return 0
        }
        var free: [(Int64, Handle)] = [], taken: [(Int64, Handle)] = []
        var planned = Set<String>()
        for (person, kind, value) in rows {
            let want: Handle?
            if kind == "whatsapp" { want = book[value].map { Handle(kind: .phone, value: $0) } }
            else { want = byPhone[value].map { Handle(kind: .whatsapp, value: $0) } }
            guard let h = want else { continue }
            let k = "\(h.kind.rawValue):\(h.value)"
            guard !have.contains(k), planned.insert(k).inserted else { continue }
            if owned.contains(k) { taken.append((person, h)) } else { free.append((person, h)) }
        }
        var added = 0
        // Handles nobody has: written together, the board re-read once.
        if !free.isEmpty {
            var ok = false
            store.perform {
                for (person, h) in free {
                    try store.db.run("INSERT INTO person_handles(person_id, kind, value, added) VALUES(?,?,?,?)", [person, h.kind.rawValue, h.value, now])
                }
                ok = true
            }
            if ok { added += free.count }
        }
        // A handle someone else has: the usual rule (a number merges the two people), one by one (rare).
        let c = CircleStore(store: store)
        for (person, h) in taken {
            switch c.addHandle(person, h, now: now) {
            case .added, .merged: added += 1
            default: break
            }
        }
        return added
    }
}

/// "Fill from messages" for a WhatsApp linked id: the number and names WhatsApp's own contact list has, filled straight in
/// (no Claude); only empty fields. Returns the note to show.
public enum LIDFill {
    public static func apply(_ f: inout ContactFormFields, resolved: [ResolvedContact], records: Int) -> String {
        guard let r = resolved.first(where: { $0.phone != nil }) ?? resolved.first else {
            return "WhatsApp hides this contact's number and it isn't in WhatsApp's contact list."
        }
        var changed: [String] = []
        let blank = { (s: String) in s.trimmingCharacters(in: .whitespaces).isEmpty }
        if blank(f.name), !blank(r.name) { f.name = r.name; changed.append("name") }
        if blank(f.company), !blank(r.business) { f.company = r.business; changed.append("company") }
        if let p = r.phone {
            if blank(f.phones) { f.phones = p; changed.append("phone") }
            if blank(f.whatsapp) { f.whatsapp = p; changed.append("WhatsApp number") }
        }
        if r.phone == nil && changed.isEmpty { return "WhatsApp hides this contact's number and it isn't in WhatsApp's contact list." }
        let source = "From \(records) WhatsApp message record\(records == 1 ? "" : "s") and WhatsApp's contact list"
        return changed.isEmpty ? source + ": nothing new to add." : source + ": added " + changed.joined(separator: ", ") + "."
    }
}
