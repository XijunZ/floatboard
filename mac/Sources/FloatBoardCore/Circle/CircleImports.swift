import Foundation

/// A person offered by an import (P3), never added in bulk.
public struct CircleCandidate: Identifiable, Equatable {
    public let id: Int64
    public let source: String
    public let name: String
    public let handles: [Handle]
    public let company: String
    public let role: String
}

public struct ImportSummary: Equatable {
    public var rows = 0, candidates = 0, attached = 0, changes = 0
}

/// LinkedIn's Connections.csv and the Google Contacts export (P2, P3, P11): rows become suggestions; an exact email or
/// phone match attaches the row's handles to that person; LinkedIn job changes are found by comparing dated exports.
public enum CircleImports {
    /// RFC 4180 rows: quoted fields may hold commas, newlines and doubled quotes.
    public static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if quoted {
                if ch == "\"" {
                    let n = text.index(after: i)
                    if n < text.endIndex, text[n] == "\"" { field.append("\""); i = text.index(after: n); continue }
                    quoted = false
                } else { field.append(ch) }
            } else {
                switch ch {
                case "\"": quoted = true
                case ",": row.append(field); field = ""
                case "\n", "\r\n", "\r": row.append(field); field = ""; rows.append(row); row = []
                default: field.append(ch)
                }
            }
            i = text.index(after: i)
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.map { $0.map { $0.trimmingCharacters(in: .whitespaces) } }
    }

    public struct LinkedInRow: Equatable { public let url: String; public let name: String; public let email: String; public let company: String; public let position: String }

    /// The connection rows (after LinkedIn's "Notes:" preamble), each with a profile path.
    public static func linkedInRows(_ csv: String) -> [LinkedInRow] {
        let rows = csvRows(csv.replacingOccurrences(of: "\u{FEFF}", with: ""))
        guard let h = rows.firstIndex(where: { $0.contains("URL") && $0.contains("First Name") }) else { return [] }
        let head = rows[h]
        func col(_ name: String) -> Int? { head.firstIndex(of: name) }
        guard let u = col("URL") else { return [] }
        return rows[(h + 1)...].compactMap { r in
            func v(_ n: String) -> String { col(n).flatMap { $0 < r.count ? r[$0] : nil } ?? "" }
            guard u < r.count, let url = Handles.normalize(.linkedin, r[u]) else { return nil }
            let name = [v("First Name"), v("Last Name")].filter { !$0.isEmpty }.joined(separator: " ")
            return LinkedInRow(url: url, name: name, email: v("Email Address"), company: v("Company"), position: v("Position"))
        }
    }

    public struct ContactRow: Equatable { public let name: String; public let handles: [Handle]; public let company: String; public let role: String }

    /// Google Contacts' CSV (the current and the older column names); rows without a name or any handle are skipped.
    public static func googleRows(_ csv: String) -> [ContactRow] {
        let rows = csvRows(csv.replacingOccurrences(of: "\u{FEFF}", with: ""))
        guard let head = rows.first else { return [] }
        func idx(_ names: [String]) -> Int? { names.lazy.compactMap { head.firstIndex(of: $0) }.first }
        let first = idx(["First Name", "Given Name"]), middle = idx(["Middle Name", "Additional Name"]), last = idx(["Last Name", "Family Name"])
        let whole = idx(["Name"]), org = idx(["Organization Name", "Organization 1 - Name"]), title = idx(["Organization Title", "Organization 1 - Title"])
        let emails = head.indices.filter { head[$0].hasPrefix("E-mail") && head[$0].hasSuffix("- Value") }
        let phones = head.indices.filter { head[$0].hasPrefix("Phone") && head[$0].hasSuffix("- Value") }
        return rows.dropFirst().compactMap { r in
            func v(_ i: Int?) -> String { i.flatMap { $0 < r.count ? r[$0] : nil } ?? "" }
            var name = [v(first), v(middle), v(last)].filter { !$0.isEmpty }.joined(separator: " ")
            if name.isEmpty { name = v(whole) }
            var hs: [Handle] = []
            for i in emails { for part in v(i).components(separatedBy: ":::") { if let e = Handles.normalize(.email, part) { hs.append(Handle(kind: .email, value: e)) } } }
            for i in phones { for part in v(i).components(separatedBy: ":::") { if let p = Handles.normalize(.phone, part) { hs.append(Handle(kind: .phone, value: p)) } } }
            guard !name.isEmpty, !hs.isEmpty else { return nil }
            return ContactRow(name: name, handles: hs, company: v(org), role: v(title))
        }
    }

    /// "3 Nov 2026" from "2026-11-03".
    public static func exportLabel(_ day: String) -> String {
        guard let d = Due.startOfDay(day) else { return day }
        return CircleFmt.f("d MMM yyyy", d)
    }
}

extension CircleStore {
    // MARK: LinkedIn

    /// Imports a Connections.csv export dated `exportDate` ("yyyy-MM-dd"; today when nil). Rows matching a person (profile
    /// or exact email) update nothing but the comparison; others become suggestions. Job changes against the person's
    /// previous export are recorded as "What's new".
    @discardableResult
    public func importLinkedIn(_ csv: String, exportDate: String?, now: Date = Date()) -> ImportSummary {
        let rows = CircleImports.linkedInRows(csv)
        var sum = ImportSummary(rows: rows.count)
        guard !rows.isEmpty else { return sum }
        let date = exportDate ?? Due.dayString(now)
        var importID: Int64 = 0
        store.perform {
            importID = try store.db.run("INSERT INTO linkedin_imports(export_date, imported, rows) VALUES(?,?,?)", [date, now, rows.count])
            for r in rows {
                try store.db.run("INSERT OR REPLACE INTO linkedin_rows(import_id, url, name, company, position) VALUES(?,?,?,?,?)",
                                 [importID, r.url, r.name, r.company, r.position])
            }
        }
        guard importID > 0 else { return sum }
        for r in rows {
            let li = Handle(kind: .linkedin, value: r.url)
            if let pid = person(owning: li) {
                if let change = linkedInChange(url: r.url, importID: importID) {
                    store.perform {
                        try store.db.run("""
                            INSERT OR IGNORE INTO circle_updates(person_id, kind, key, title, detail, url, at, found) VALUES(?,?,?,?,?,?,?,?)
                            """, [pid, UpdateKind.linkedin.rawValue, "li:\(r.url):\(importID)", change.title, change.detail, "https://www." + r.url,
                                  Due.startOfDay(date), now])
                    }
                    sum.changes += 1
                }
                continue
            }
            if let e = Handles.normalize(.email, r.email), let pid = person(owning: Handle(kind: .email, value: e)) {
                if case .added = addHandle(pid, li, now: now) { sum.attached += 1 }
                continue
            }
            if addCandidateRow(source: "linkedin", key: "linkedin:\(r.url)", name: r.name,
                               handles: [li] + (Handles.normalize(.email, r.email).map { [Handle(kind: .email, value: $0)] } ?? []),
                               company: r.company, role: r.position, now: now) { sum.candidates += 1 }
        }
        return sum
    }

    /// Company and position in this import against the latest earlier import holding the same profile.
    private func linkedInChange(url: String, importID: Int64) -> (title: String, detail: String)? {
        do {
            let rows = try store.db.query("""
                SELECT r.company, r.position, i.export_date FROM linkedin_rows r JOIN linkedin_imports i ON i.id=r.import_id
                WHERE r.url=? AND r.import_id<=? ORDER BY r.import_id DESC LIMIT 2
                """, [url, importID]) { (DB.text($0, 0), DB.text($0, 1), DB.text($0, 2)) }
            guard rows.count == 2, rows[0].0 != rows[1].0 || rows[0].1 != rows[1].1 else { return nil }
            let now = [rows[0].1, rows[0].0].filter { !$0.isEmpty }.joined(separator: " at ")
            let was = [rows[1].1, rows[1].0].filter { !$0.isEmpty }.joined(separator: " at ")
            return ("Now \(now)", "Was \(was) · changed since the export of \(CircleImports.exportLabel(rows[1].2))")
        } catch {
            store.activity("circle", .error, "Could not compare LinkedIn exports", detail: "\(error)")
            return nil
        }
    }

    /// "Not in the export of 3 Dec 2026" when the person's profile is missing from the latest export (never a job change).
    public func linkedInStatus(_ personID: Int64) -> String? {
        guard let url = handles(personID).first(where: { $0.kind == .linkedin })?.value,
              let latest = ((try? store.db.query("SELECT id, export_date FROM linkedin_imports ORDER BY id DESC LIMIT 1") { (DB.int($0, 0), DB.text($0, 1)) }) ?? []).first // try?-ok: unreadable = no status shown
        else { return nil }
        let present = ((try? store.db.query("SELECT 1 FROM linkedin_rows WHERE import_id=? AND url=?", [latest.0, url]) { DB.int($0, 0) }) ?? []).isEmpty == false // try?-ok: unreadable = no status shown
        return present ? nil : "Not in the export of \(CircleImports.exportLabel(latest.1))"
    }

    /// When the last LinkedIn export was imported.
    public var lastLinkedInImport: Date? {
        ((try? store.db.query("SELECT max(imported) FROM linkedin_imports") { DB.date($0, 0) }) ?? []).first ?? nil // try?-ok: unreadable = never
    }

    /// The monthly reminder to download the export: once at least one import exists, when the last is 30+ days old, at most
    /// once a month (outside the reminder budget, §9). Records the nudge when it says yes.
    public func linkedInNudgeDue(now: Date = Date()) -> Bool {
        guard let last = lastLinkedInImport, now.timeIntervalSince(last) >= 30 * 86400 else { return false }
        if let n = meta("circle_linkedin_nudged").flatMap(Double.init), now.timeIntervalSince1970 - n < 30 * 86400 { return false }
        setMeta("circle_linkedin_nudged", String(now.timeIntervalSince1970))
        return true
    }

    // MARK: Google Contacts

    @discardableResult
    public func importGoogleContacts(_ csv: String, now: Date = Date()) -> ImportSummary {
        let rows = CircleImports.googleRows(csv)
        var sum = ImportSummary(rows: rows.count)
        for r in rows {
            if let pid = r.handles.lazy.filter({ $0.kind.mergesOnMatch }).compactMap({ person(owning: $0) }).first {
                var attached = false
                for h in r.handles where !handles(pid).contains(h) {
                    if case .added = addHandle(pid, h, now: now) { attached = true }
                }
                if attached { sum.attached += 1 }
                continue
            }
            let key = "google:" + (r.handles.first?.value ?? PeopleStore.key(r.name))
            if addCandidateRow(source: "google", key: key, name: r.name, handles: r.handles, company: r.company, role: r.role, now: now) { sum.candidates += 1 }
        }
        return sum
    }

    // MARK: Suggestions from imports

    /// True when a new suggestion was stored (one already offered, added or dismissed is not offered again).
    private func addCandidateRow(source: String, key: String, name: String, handles hs: [Handle], company: String, role: String, now: Date) -> Bool {
        let json = (try? String(decoding: JSONEncoder().encode(hs), as: UTF8.self)) ?? "[]" // try?-ok: handles always encode
        var added = false
        store.perform {
            let before = try store.db.query("SELECT count(*) FROM circle_candidates WHERE key=?", [key]) { DB.int($0, 0) }.first ?? 0
            guard before == 0 else { return }
            try store.db.run("INSERT INTO circle_candidates(source, key, name, handles, company, role, added) VALUES(?,?,?,?,?,?,?)",
                             [source, key, name, json, company, role, now])
            added = true
        }
        return added
    }

    /// Suggestions not yet added or dismissed, by name.
    public func candidates() -> [CircleCandidate] {
        do {
            return try store.db.query("SELECT id, source, name, handles, company, role FROM circle_candidates WHERE state='new' ORDER BY name COLLATE NOCASE") { s in
                let hs = (try? JSONDecoder().decode([Handle].self, from: Data(DB.text(s, 3).utf8))) ?? [] // try?-ok: unreadable handles read as none
                return CircleCandidate(id: DB.int(s, 0), source: DB.text(s, 1), name: DB.text(s, 2), handles: hs, company: DB.text(s, 4), role: DB.text(s, 5))
            }
        } catch {
            store.activity("circle", .error, "Could not read suggested people", detail: "\(error)")
            return []
        }
    }

    /// Adds a suggestion as a person (with its handles, company and role).
    public func addCandidate(_ id: Int64, tier: PersonTier, tags: ItemTags, now: Date = Date()) -> AddResult {
        guard let c = candidates().first(where: { $0.id == id }) else { return AddResult(person: nil, problem: "That suggestion is gone.") }
        var d = CircleDetails(); d.company = c.company; d.role = c.role
        d.howKnown = c.source == "linkedin" ? "LinkedIn" : ""
        let r = add(name: c.name, tier: tier, tags: tags, details: d, handles: c.handles, source: .typed, now: now)
        if r.person != nil { store.perform { try store.db.run("UPDATE circle_candidates SET state='added' WHERE id=?", [id]) } }
        return r
    }

    /// A suggestion added through the form (the person was made there).
    public func markCandidateAdded(_ id: Int64) {
        store.perform { try store.db.run("UPDATE circle_candidates SET state='added' WHERE id=?", [id]) }
    }

    public func dismissCandidate(_ id: Int64) {
        store.perform { try store.db.run("UPDATE circle_candidates SET state='dismissed' WHERE id=?", [id]) }
    }
}
