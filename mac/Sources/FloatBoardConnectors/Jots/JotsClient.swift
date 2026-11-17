import FloatBoardCore
import Foundation

/// What Claude filled into the Make task form (`fill_form`).
public struct FilledForm: Equatable, Sendable {
    public let title: String
    public let due: Date?
    public let hasTime: Bool
}

/// The engine's Jots routes (docs/superpowers/specs/2026-11-17-jots-design.md §3, §4).
extension ConnectorClient {
    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    private func json(_ obj: Any) throws -> Data {
        do { return try JSONSerialization.data(withJSONObject: obj) } catch { throw ConnectorError.badResponse("\(error)") }
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ConnectorError.badResponse("not a JSON object") } // try?-ok: reported as badResponse
        return o
    }

    /// Sends jots to the online copy, with the nudge's state. Returns the numbers the engine accepted.
    public func putJots(_ jots: [PushJot], nudge: JotNudgeState?) async throws -> [Int64] {
        var body: [String: Any] = ["jots": jots.map { j in
            ["id": j.id, "text": j.text, "kind": j.kind.rawValue, "source": j.source.rawValue, "tags": j.tags,
             "added": Self.iso(j.added), "updated": Self.iso(j.updated), "deleted": j.deleted] as [String: Any]
        }]
        if let n = nudge {
            body["nudge"] = ["minutes": n.minutes.map { $0 as Any } ?? NSNull(), "zone": n.zone, "shown_day": n.shownDay.map { $0 as Any } ?? NSNull(),
                             "jotted_day": n.jottedDay.map { $0 as Any } ?? NSNull(), "done_today": n.doneToday]
        }
        let o = try object(try await call("PUT", "/v2/jots", body: try json(body)))
        return (o["accepted"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.int64Value }
    }

    /// Phone captures, edits, deletes, meeting notes and phone actions waiting for this Mac.
    public func waitingJots() async throws -> [EngineJot] {
        let o = try object(try await call("GET", "/v2/jots/waiting"))
        guard let list = o["jots"] as? [[String: Any]] else { throw ConnectorError.badResponse("no jots list") }
        return list.compactMap { r in
            guard let key = r["key"] as? String, let text = r["text"] as? String, let kind = r["kind"] as? String,
                  let added = (r["added"] as? String).flatMap(Self.parseISODate), let updated = (r["updated"] as? String).flatMap(Self.parseISODate),
                  let rev = (r["rev"] as? NSNumber)?.intValue else { return nil }
            var meeting: MeetingMeta?
            if let m = r["meeting"] as? [String: Any] {
                meeting = MeetingMeta(recapKey: m["recap_key"] as? String ?? key, fathomURL: m["fathom_url"] as? String ?? "",
                                      meetingURL: m["meeting_url"] as? String ?? "", title: m["title"] as? String ?? "",
                                      scheduledStart: (m["scheduled_start"] as? String).flatMap(Self.parseISODate),
                                      invitees: m["invitees"] as? [String] ?? [], received: added)
            }
            return EngineJot(key: key, macID: (r["mac_id"] as? NSNumber)?.int64Value, text: text, kind: kind, source: r["source"] as? String ?? "phone",
                             tags: r["tags"] as? [String] ?? [], added: added, updated: updated, deleted: r["deleted"] as? Bool ?? false, rev: rev,
                             ref: r["ref"] as? String, meeting: meeting,
                             versions: (r["versions"] as? [[String: Any]] ?? []).compactMap { v in
                                 guard let t = v["text"] as? String, let at = (v["at"] as? String).flatMap(Self.parseISODate) else { return nil }
                                 return EarlierText(text: t, at: at)
                             })
        }
    }

    public func ackJots(_ acks: [JotAck]) async throws {
        let items: [[String: Any]] = acks.map { a in ["key": a.key, "rev": a.rev, "mac_id": a.macID.map { $0 as Any } ?? NSNull()] }
        _ = try await call("POST", "/v2/jots/ack", body: try json(["items": items]))
    }

    /// `jot_tags` (Haiku): up to 20 jots in one call; only names from `tags` come back.
    public func suggestTags(_ jots: [(id: Int64, text: String)], tags: [String]) async throws -> [Int64: [String]] {
        let body: [String: Any] = ["tags": tags, "jots": jots.map { ["id": $0.id, "text": String($0.text.prefix(4000))] as [String: Any] }]
        let o = try object(try await call("POST", "/v2/jots/tags", body: try json(body)))
        var out: [Int64: [String]] = [:]
        for s in o["suggestions"] as? [[String: Any]] ?? [] {
            if let id = (s["id"] as? NSNumber)?.int64Value { out[id] = s["tags"] as? [String] ?? [] }
        }
        return out
    }

    /// `jot_cleanup` (Haiku): grammar and structure only; the owner compares before and after.
    public func cleanupJot(_ text: String) async throws -> String {
        let o = try object(try await call("POST", "/v2/jots/cleanup", body: try json(["text": text])))
        guard let c = o["cleaned"] as? String, !c.isEmpty else { throw ConnectorError.badResponse("no cleaned text") }
        return c
    }

    /// `fill_form` (Haiku): a short title and the due date the selection mentions.
    public func fillForm(selection: String, context: String, now: Date = Date()) async throws -> FilledForm {
        let day = DailyFiles.dayKey(now)
        let o = try object(try await call("POST", "/v2/jots/fill", body: try json(["selection": String(selection.prefix(4000)),
            "context": String(context.prefix(4000)), "today": day, "zone": AppTime.zone.identifier])))
        let title = o["title"] as? String ?? ""
        let hasTime = o["has_time"] as? Bool ?? false
        var due: Date?
        if let d = o["due"] as? String {
            let p = d.split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
            if p.count >= 3 {
                due = AppTime.calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: hasTime && p.count >= 5 ? p[3] : nil,
                                                                 minute: hasTime && p.count >= 5 ? p[4] : nil))
            }
        }
        return FilledForm(title: title, due: due, hasTime: hasTime && due != nil)
    }
}
