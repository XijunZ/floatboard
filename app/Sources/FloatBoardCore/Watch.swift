import Foundation

/// Watch: a task waiting on someone. All fixed rules, no AI:
/// - moving a task to Watch records when (`watchSince`) and, unless already set, whom it waits on, suggested from where
///   the task came from (the email's sender, the WhatsApp chat);
/// - the card shows "Waiting on Anna · 3d 4h", amber from `chaseDays`;
/// - a reply from that person moves it back to To do (email: found by the engine; WhatsApp: found on this Mac);
/// - a chase reminder comes every `chaseDays` days without a reply.
public enum Watch {
    public static let chaseDays = 3
    static let day: TimeInterval = 86_400

    /// Whom a task waits on and how to recognise their reply, from where it came from; empty when unknown.
    public static func suggest(_ c: Card) -> (person: String, contact: String) {
        let name = (c.sourceMeta["sender_name"] ?? "").trimmingCharacters(in: .whitespaces)
        if let mid = c.sourceKey?.messageID, mid.hasPrefix("wa:"), let last = mid.lastIndex(of: ":"), last > mid.index(mid.startIndex, offsetBy: 3) {
            let jid = String(mid[mid.index(mid.startIndex, offsetBy: 3)..<last])
            return (name, "wa:\(jid)")
        }
        let sender = (c.sourceMeta["sender"] ?? "").trimmingCharacters(in: .whitespaces)
        guard let address = Self.address(in: sender) else { return (name, "") }
        var person = name
        if person.isEmpty, let lt = sender.firstIndex(of: "<") {
            person = sender[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        }
        return (person.isEmpty ? address : person, "email:\(address)")
    }

    /// The address in "Name <a@b.c>" or "a@b.c", lower-cased; nil when there is none.
    static func address(in s: String) -> String? {
        var a = s
        if let lt = s.firstIndex(of: "<"), let gt = s.lastIndex(of: ">"), lt < gt { a = String(s[s.index(after: lt)..<gt]) }
        a = a.trimmingCharacters(in: .whitespaces).lowercased()
        let parts = a.split(separator: "@")
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !a.contains(" ") else { return nil }
        return a
    }

    /// "3d 4h", "5h 20m" or "12m" since `since`.
    public static func elapsed(since: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(since)))
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    /// The card's Watch label: "Anna · 3d 4h", or "3d 4h" with no person.
    public static func line(_ c: Card, now: Date = Date()) -> String? {
        guard c.status == .watch, let since = c.watchSince else { return nil }
        let who = c.watchPerson.trimmingCharacters(in: .whitespaces)
        return (who.isEmpty ? "" : "\(who) · ") + elapsed(since: since, now: now)
    }

    /// True from `chaseDays` days on Watch.
    public static func isLate(_ c: Card, now: Date = Date()) -> Bool {
        guard c.status == .watch, let since = c.watchSince else { return false }
        return now.timeIntervalSince(since) >= Double(chaseDays) * day
    }

    /// The next `count` chase times after `now` (every `chaseDays` days from `since`).
    public static func nextChases(since: Date, now: Date, count: Int = 3) -> [Date] {
        let step = Double(chaseDays) * day
        let n = max(1, Int(floor(now.timeIntervalSince(since) / step)) + 1)
        return (0..<count).map { since.addingTimeInterval(step * Double(n + $0)) }
    }

    /// "↩ Anna replied by email · 14 Nov 10:00", put at the top of the task's notes.
    public static func replyNote(_ reason: String, at: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "d MMM HH:mm"
        return "↩ \(reason.prefix(200)) · \(f.string(from: at))"
    }

    /// The text of the n-th chase reminder.
    public static func chaseText(person: String, at: Date, since: Date) -> String {
        let days = Int((at.timeIntervalSince(since) / day).rounded())
        let who = person.trimmingCharacters(in: .whitespaces)
        return "Still waiting on \(who.isEmpty ? "a reply" : who) · \(days) days"
    }
}

extension Store {
    /// Inside a move: entering Watch starts the timer and fills in whom it waits on (if not set); leaving stops it.
    func watchRow(_ id: Int64, entering: Bool, now: Date) throws {
        guard entering else {
            try db.run("UPDATE cards SET watch_since=NULL WHERE id=?", [id])
            return
        }
        try db.run("UPDATE cards SET watch_since=? WHERE id=?", [now, id])
        // Keep whom it waits on when already set (a task watched before, or edited).
        let set = try db.query("SELECT watch_person <> '' OR watch_contact <> '' FROM cards WHERE id=?", [id]) { DB.int($0, 0) }.first ?? 0
        guard set == 0, let c = try currentCard(id)?.card else { return }
        let s = Watch.suggest(c)
        if !s.person.isEmpty || !s.contact.isEmpty {
            try db.run("UPDATE cards SET watch_person=?, watch_contact=? WHERE id=?", [s.person, s.contact, id])
        }
    }

    /// Tasks already on Watch from before Watch had a timer: the timer starts at their last move to Watch (from their
    /// history, else their last update), and whom they wait on is suggested as for a new move. Runs at launch; a task
    /// that has a start time is never touched.
    public func fillWatchStarts() {
        do {
            let ids = try db.query("SELECT id FROM cards WHERE status='watch' AND deleted=0 AND watch_since IS NULL") { DB.int($0, 0) }
            guard !ids.isEmpty else { return }
            perform {
                for id in ids {
                    try db.run("""
                        UPDATE cards SET watch_since = COALESCE((SELECT MAX(at) FROM events WHERE card_id=cards.id AND to_status='watch'),
                                                              updated, created) WHERE id=?
                        """, [id])
                    let set = try db.query("SELECT watch_person <> '' OR watch_contact <> '' FROM cards WHERE id=?", [id]) { DB.int($0, 0) }.first ?? 0
                    if set == 0, let c = try currentCard(id)?.card {
                        let s = Watch.suggest(c)
                        try db.run("UPDATE cards SET watch_person=?, watch_contact=? WHERE id=?", [s.person, s.contact, id])
                    }
                }
            }
            activity("board", .info, "Watch timers started for \(ids.count) task\(ids.count == 1 ? "" : "s") already on Watch")
        } catch {
            activity("board", .warning, "Could not start Watch timers for older tasks", detail: "\(error)")
        }
    }

    /// Sets whom a task waits on. `contact` is kept only when it is "email:<address>" or "wa:<chat id>".
    public func setWatch(_ card: Card, person: String, contact: String, now: Date = Date()) {
        let p = String(person.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        var k = contact.trimmingCharacters(in: .whitespaces)
        if k.hasPrefix("email:") { k = Watch.address(in: String(k.dropFirst(6))).map { "email:\($0)" } ?? "" }
        else if !(k.hasPrefix("wa:") && k.count > 3 && k.count <= 330) { k = "" }
        perform {
            try db.run("UPDATE cards SET watch_person=?, watch_contact=?, updated=? WHERE id=?", [p, k, now, card.id])
            try insertEvent(card.id, p.isEmpty ? "waiting on: cleared" : "waiting on: \(p)", actor: .user, at: now)
        }
    }

    /// A reply from the person a Watch task waits on: back to To do, with the reason in its history. Only while the
    /// task is still on Watch (a task moved on since is left alone). Returns true when it moved.
    @discardableResult
    func watchReplyRow(_ id: Int64, reason: String, at: Date) throws -> Bool {
        guard let status = try db.query("SELECT status FROM cards WHERE id=? AND deleted=0", [id], { DB.text($0, 0) }).first,
              status == Status.watch.rawValue else { return false }
        guard try moveRow(id, to: .todo, now: at) else { return false }
        try insertEvent(id, String(reason.prefix(200)), actor: .connector("watch"), at: at)
        // A line at the top of the notes, so the card itself says why it came back.
        let note = Watch.replyNote(reason, at: at)
        try db.run("UPDATE cards SET notes = CASE WHEN notes='' THEN ? ELSE ? || char(10) || notes END WHERE id=?", [note, note, id])
        return true
    }

    /// Public wrapper for replies found on this Mac (WhatsApp).
    @discardableResult
    public func watchReply(_ card: Card, reason: String, at: Date = Date()) -> Bool {
        var moved = false
        perform { moved = try watchReplyRow(card.id, reason: reason, at: at) }
        return moved
    }
}
