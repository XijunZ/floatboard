import Foundation

/// One message header about a person, as Claude's contact_form job may see it: a display name and the address or phone
/// number it came with. Never a subject, a body, a signature, a task title or notes (features §3, §7; circle design: "header
/// names, addresses, phone numbers only").
public struct FillHeader: Equatable, Hashable, Sendable {
    public let name: String
    public let address: String
    public let phone: String
    public init(name: String, address: String, phone: String) { self.name = name; self.address = address; self.phone = phone }
    /// The three keys the engine's /v2/circle/fill reads.
    public var dictionary: [String: String] { ["name": name, "address": address, "phone": phone] }
}

/// "Fill from messages": what FloatBoard already has on this Mac for the phone numbers, emails and WhatsApp numbers typed in
/// the Add / Edit form (and the person's own handles when editing). Sources, headers only: imported email and WhatsApp task
/// cards (their sender and sender name; WhatsApp: the chat's number), and Circle's readers (circle_exchanges: who, when).
@MainActor public enum CircleFillHeaders {
    public static let cap = 20

    /// Headers with a name for any of `handles`, newest first, each once, at most `cap`. Throws when they can't be read.
    public static func find(store: Store, handles: [Handle], personID: Int64?) throws -> [FillHeader] {
        var all = handles
        if let personID { all += try store.db.query("SELECT kind, value FROM person_handles WHERE person_id=?", [personID]) { s in
            HandleKind(rawValue: DB.text(s, 0)).map { Handle(kind: $0, value: DB.text(s, 1)) } }.compactMap { $0 } }
        let emails = Set(all.filter { $0.kind == .email }.compactMap { Handles.normalize(.email, $0.value) })
        let phones = Set(all.filter { $0.kind == .phone || $0.kind == .whatsapp }.compactMap { phoneDigits($0.value) })
        // WhatsApp ids that are not a number (a linked id "<digits>@lid"): matched as they are, never as phone digits.
        let chats = Set(all.filter { $0.kind == .whatsapp && $0.value.contains("@") }.compactMap { Handles.normalize(.whatsapp, $0.value) }
            .filter { Handles.fromWhatsApp($0)?.kind == .whatsapp })
        guard !emails.isEmpty || !phones.isEmpty || !chats.isEmpty else { return [] }
        var out: [FillHeader] = [], seen = Set<FillHeader>()
        func add(_ h: FillHeader) {
            guard !h.name.trimmingCharacters(in: .whitespaces).isEmpty, seen.insert(h).inserted, out.count < cap else { return }
            out.append(h)
        }
        // Circle's readers (Gmail, Outlook, WhatsApp, calendar): the display name each saw with the handle.
        let keys = emails.map { ("email", $0) } + phones.map { ("phone", $0) } + chats.map { ("whatsapp", $0) }
        for (kind, value) in keys {
            let rows = try store.db.query("""
                SELECT name FROM circle_exchanges WHERE ignored=0 AND name<>'' AND handle_kind=? AND handle=? ORDER BY at DESC LIMIT 5
                """, [kind, value]) { DB.text($0, 0) }
            for n in rows { add(FillHeader(name: String(n.prefix(120)), address: kind == "email" ? value : "", phone: kind == "phone" ? value : "")) }
            // (a linked id itself is not sent: its digits are not a number)
        }
        // Imported task cards: only the sender header fields of source_meta and the WhatsApp chat in source_mid.
        let cards = try store.db.query("""
            SELECT source_meta, coalesce(source_mid, '') FROM cards WHERE source_meta LIKE '%sender%' ORDER BY coalesce(imported_at, created) DESC LIMIT 2000
            """) { (DB.text($0, 0), DB.text($0, 1)) }
        for (metaJSON, mid) in cards {
            let meta = (try? JSONSerialization.jsonObject(with: Data(metaJSON.utf8)) as? [String: Any]) ?? [:] // try?-ok: unreadable meta has no header to offer
            let senderName = (meta["sender_name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let sender = (meta["sender"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if let address = Watch.address(in: sender), emails.contains(address) {
                var name = senderName
                if name.isEmpty, let lt = sender.firstIndex(of: "<") { name = sender[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
                add(FillHeader(name: String(name.prefix(120)), address: address, phone: ""))
            }
            if mid.hasPrefix("wa:"), let jidEnd = mid.dropFirst(3).firstIndex(of: "@") {
                let digits = String(mid[mid.index(mid.startIndex, offsetBy: 3)..<jidEnd])
                let rest = mid[jidEnd...]
                let domain = rest.prefix { $0 != ":" }
                let jid = (digits + domain).lowercased()
                if domain == "@s.whatsapp.net" || domain == "@c.us", phones.contains(digits) {
                    add(FillHeader(name: String(senderName.prefix(120)), address: "", phone: digits))
                } else if chats.contains(jid) {
                    // A linked-id chat: its sender header may carry the real number; the id itself is never sent.
                    add(FillHeader(name: String(senderName.prefix(120)), address: "", phone: phoneDigits(sender) ?? ""))
                }
            }
        }
        return out
    }

    /// How many WhatsApp message records Circle's reader kept for these handles (one per handle, day and direction).
    public static func records(store: Store, handles: [Handle]) -> Int {
        var n = 0
        for h in handles where h.kind == .whatsapp || h.kind == .phone {
            n += Int((try? store.db.query("SELECT count(*) FROM circle_exchanges WHERE channel='whatsapp' AND handle_kind=? AND handle=?", // try?-ok: unreadable counts as none; only the note's number
                                          [h.kind.rawValue, h.value]) { DB.int($0, 0) })?.first ?? 0)
        }
        return n
    }

    /// International digits of a phone or WhatsApp number ("+44 7700 900123", "07700 900123" or a chat id).
    static func phoneDigits(_ raw: String) -> String? {
        let t = raw.lowercased()
        if t.contains("@") { return Handles.fromWhatsApp(t).flatMap { $0.kind == .phone ? $0.value : nil } }
        return Handles.normalize(.phone, t)
    }
}

/// The form fields Claude may fill, and how typed handles are read (an unreadable one is reported, never dropped silently).
public struct ContactFormFields: Equatable {
    public var name: String, company: String, emails: String, phones: String
    /// The form's WhatsApp number field.
    public var whatsapp: String
    public init(name: String, company: String, emails: String, phones: String, whatsapp: String = "") {
        self.name = name; self.company = company; self.emails = emails; self.phones = phones; self.whatsapp = whatsapp
    }

    /// "Filled by Claude…" naming what changed; nil when nothing did (no note then).
    public static func note(_ changed: [String]) -> String? {
        changed.isEmpty ? nil : "Filled by Claude from message headers: \(changed.joined(separator: ", ")). Check before saving."
    }

    /// The typed handles, read; every entry that isn't a phone number, address or profile is listed in `unreadable`.
    public static func handles(_ typed: [HandleKind: String]) -> (handles: [Handle], unreadable: [String]) {
        var hs: [Handle] = [], bad: [String] = []
        for k in HandleKind.allCases {
            for raw in (typed[k] ?? "").split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !raw.isEmpty {
                if let v = Handles.normalize(k, raw) { hs.append(Handle(kind: k, value: v)) } else { bad.append(raw) }
            }
        }
        return (hs, bad)
    }
}
