import Foundation

/// Links made by code (features §6): event ↔ person when a guest's email is exactly one person's (auto); task ↔ person
/// when the task came from their message (its sender, or the contact it watches) (auto); jot ↔ person when the jot names
/// them (suggested). Each item is looked at once (cursors in meta), so a link the owner removed is not made again.
@MainActor public enum CircleLinker {
    private struct Cursors: Codable { var events: Double = 0; var tasks: Double = 0; var jots: Double = 0 }
    static let metaKey = "circle_linker"

    /// New and changed items since the last run; `person`: every item, for that person only (after adding them or a handle).
    @discardableResult
    public static func run(store: Store, now: Date = Date(), person only: Int64? = nil) -> Int {
        guard store.isOn(.circle) else { return 0 }
        let c = CircleStore(store: store)
        var cur = (c.meta(metaKey).flatMap { try? JSONDecoder().decode(Cursors.self, from: Data($0.utf8)) }) ?? Cursors() // try?-ok: unreadable cursor = start again; links are idempotent
        let full = only != nil
        var made = 0
        func link(_ item: ShortID, _ pid: Int64, _ by: LinkMaker) {
            guard only == nil || only == pid else { return }
            if store.link(item, ShortID(kind: .person, number: pid), kind: .related, madeBy: by, actor: .user, now: now) { made += 1 }
        }
        // Events by their guests.
        do {
            let rows = try store.db.query("SELECT short_id, guests, google_updated FROM cal_events WHERE cancelled=0 AND google_updated>?",
                                          [full ? 0 : cur.events]) { (DB.int($0, 0), DB.text($0, 1), DB.date($0, 2)?.timeIntervalSince1970 ?? 0) }
            for (id, raw, updated) in rows {
                let guests = (try? JSONDecoder().decode([CalGuest].self, from: Data(raw.utf8))) ?? [] // try?-ok: unreadable guests = none
                for g in guests {
                    if let pid = c.person(owning: Handle(kind: .email, value: g.email)) { link(ShortID(kind: .event, number: id), pid, .auto) }
                }
                if !full { cur.events = max(cur.events, updated) }
            }
        } catch { store.activity("circle", .error, "Could not link meetings to people", detail: "\(error)") }
        // Tasks from someone's message.
        for card in store.cards where full || card.created.timeIntervalSince1970 > cur.tasks {
            var hs: [Handle] = []
            if let s = card.sourceMeta["sender"], let e = Handles.normalize(.email, s) { hs.append(Handle(kind: .email, value: e)) }
            let w = card.watchContact
            if w.hasPrefix("email:"), let e = Handles.normalize(.email, String(w.dropFirst(6))) { hs.append(Handle(kind: .email, value: e)) }
            if w.hasPrefix("wa:"), let h = Handles.fromWhatsApp(String(w.dropFirst(3))) { hs.append(h) }
            for h in hs { if let pid = c.person(owning: h) { link(ShortID(kind: .task, number: card.id), pid, .auto) } }
            if !full { cur.tasks = max(cur.tasks, card.created.timeIntervalSince1970) }
        }
        // Jots that name someone (suggested).
        let everyone = PeopleStore(store: store).people().filter { only == nil || $0.id == only }
        do {
            let rows = try store.db.query("SELECT id, text, updated FROM jots WHERE deleted=0 AND updated>?", [full ? 0 : cur.jots]) {
                (DB.int($0, 0), DB.text($0, 1), DB.date($0, 2)?.timeIntervalSince1970 ?? 0) }
            for (id, text, updated) in rows {
                for p in peopleNamed(in: text, people: everyone) { link(ShortID(kind: .jot, number: id), p.id, .suggested) }
                if !full { cur.jots = max(cur.jots, updated) }
            }
        } catch { store.activity("circle", .error, "Could not match people named in jots", detail: "\(error)") }
        if !full, let json = try? String(decoding: JSONEncoder().encode(cur), as: UTF8.self) { c.setMeta(metaKey, json) } // try?-ok: three numbers always encode
        return made
    }

    /// People named in a text, by code: a full name of two words or more, or an alias, as whole words (case and accents
    /// ignored).
    public static func peopleNamed(in text: String, people: [Person]) -> [Person] {
        let hay = " " + fold(text) + " "
        return people.filter { p in
            let names = (p.name.split(separator: " ").count >= 2 ? [p.name] : []) + p.aliases
            return names.contains { n in
                let k = fold(n)
                return !k.isEmpty && hay.contains(" " + k + " ")
            }
        }
    }

    /// Lower case, accents off, punctuation as spaces, single spaces.
    static func fold(_ s: String) -> String {
        let f = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let spaced = String(f.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " })
        return spaced.split(separator: " ").joined(separator: " ")
    }
}
