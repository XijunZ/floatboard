import CryptoKit
import FloatBoardCore
import Foundation

/// Circle's side of the engine (docs/superpowers/specs/2026-11-17-circle-design.md §4–§8): takes in the Gmail/Outlook
/// metadata and What's new by cursor, sends the watch list and the phone copy when they change, and applies the phone's
/// Circle actions. Runs only while Circle is on; every step's problem goes to Activity once and the next step still runs.
public enum CircleSync {
    public struct EngineExchange: Decodable, Equatable {
        public let seq: Int64, key: String, channel: String, direction: String, at: String, account: String, handle: String, name: String
    }
    public struct EngineReader: Decodable, Equatable {
        public let reader: String
        public let asOf: String?
        public let completeFrom: String?
        public let note: String?
        enum CodingKeys: String, CodingKey { case reader, note, asOf = "as_of", completeFrom = "complete_from" }
    }

    static let exchangeCursor = "circle_engine_exchanges", updateCursor = "circle_engine_updates"
    static let watchHash = "circle_watch_hash", copyHash = "circle_copy_hash"
    @MainActor static var reported: [String: String] = [:]

    /// One pass for one engine. Returns the problems met (empty when all went well).
    @MainActor @discardableResult
    public static func run(store: Store, client: ConnectorClient, connector id: String, now: Date = Date()) async -> [String] {
        guard store.isOn(.circle) else { return [] }
        let c = CircleStore(store: store)
        var problems: [String] = []
        func step(_ name: String, _ work: () async throws -> Void) async {
            do { try await work(); reported.removeValue(forKey: id + name) }
            catch ConnectorError.http(404, _) { /* an engine without Circle yet: nothing to do */ }
            catch {
                let why = (error as? ConnectorError)?.description ?? "\(error)"
                problems.append("\(name): \(why)")
                if reported[id + name] != why {
                    reported[id + name] = why
                    store.activity("circle", .warning, "Circle could not \(name); will try again", detail: why)
                }
            }
        }
        await step("take in Gmail and Outlook activity") {
            for _ in 0..<20 {
                let after = Int64(c.meta(exchangeCursor + ":" + id) ?? "") ?? 0
                let page = try await client.circleExchanges(after: after)
                let iso = ISO8601DateFormatter(), frac = ISO8601DateFormatter()
                frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let inputs: [ExchangeInput] = page.exchanges.compactMap { e in
                    guard let ch = Channel(rawValue: e.channel), ch == .gmail || ch == .outlook, let dir = Direction(rawValue: e.direction),
                          let at = frac.date(from: e.at) ?? iso.date(from: e.at) else { return nil }
                    return ExchangeInput(channel: ch, direction: dir, at: at, handle: Handle(kind: .email, value: e.handle), name: e.name, ref: e.account)
                }
                for r in page.readers {
                    let name = r.reader == "outlook" ? "outlook" : r.reader
                    c.setChannel(name, asOf: r.asOf.flatMap { frac.date(from: $0) ?? iso.date(from: $0) },
                                 completeFrom: r.completeFrom.flatMap { frac.date(from: $0) ?? iso.date(from: $0) }, cursor: "",
                                 note: (r.note ?? "").isEmpty ? (name == "outlook" ? Channel.outlook.limits ?? "" : "inbox and Sent") : r.note ?? "")
                }
                // The page and its cursor in one transaction: a failed write keeps the old cursor (the page comes again).
                try c.importExchangePage(inputs, cursorKey: exchangeCursor + ":" + id, cursor: String(page.next), now: now)
                if !page.more { break }
            }
        }
        await step("take in What's new") {
            for _ in 0..<10 {
                let after = Int64(c.meta(updateCursor + ":" + id) ?? "") ?? 0
                let page = try await client.circleUpdates(after: after)
                try c.importUpdatePage(page.updates, cursorKey: updateCursor + ":" + id, cursor: String(page.next), now: now)
                if !page.more { break }
            }
        }
        await step("send the people to follow") {
            let list = CircleCopy.watchList(store: store)
            // Sorted keys: JSONEncoder's key order can differ from one encoding to the next, which changed the hash and sent
            // an unchanged list again.
            let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
            let body = try enc.encode(["people": list])
            let h = hash(body)
            guard c.meta(watchHash + ":" + id) != h else { return }
            try await client.putCircleWatch(body)
            c.setMeta(watchHash + ":" + id, h)
        }
        await step("apply the phone's Circle changes") {
            let actions = try await client.circleActions()
            guard !actions.isEmpty else { return }
            let r = c.applyPhoneActions(actions, now: now)
            try await client.ackCircleActions(r.applied + r.skipped.map(\.id))
        }
        await step("send Circle to the phone") {
            let body = try CircleCopy.body(CircleCopy.phone(store: store, now: now))
            let h = hash(body)
            guard c.meta(copyHash + ":" + id) != h else { return }
            try await client.putCircleCopy(body)
            c.setMeta(copyHash + ":" + id, h)
        }
        return problems
    }

    static func hash(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
}

extension ConnectorClient {
    public func circleExchanges(after: Int64) async throws -> (exchanges: [CircleSync.EngineExchange], readers: [CircleSync.EngineReader], next: Int64, more: Bool) {
        struct A: Decodable { let exchanges: [CircleSync.EngineExchange]; let readers: [CircleSync.EngineReader]; let next: Int64; let more: Bool? }
        let data = try await call("GET", "/v2/circle/exchanges", query: [URLQueryItem(name: "after", value: String(after))])
        do { let a = try JSONDecoder().decode(A.self, from: data); return (a.exchanges, a.readers, a.next, a.more ?? false) }
        catch { throw ConnectorError.badResponse("circle exchanges: \(error)") }
    }

    public func circleUpdates(after: Int64) async throws -> (updates: [EngineUpdate], next: Int64, more: Bool) {
        struct Row: Decodable { let seq: Int64; let key: String; let person: String; let kind: String; let title: String?; let detail: String?; let url: String?
            let at: String?; let match: String?; let born: String?; let officer: String? }
        struct A: Decodable { let updates: [Row]; let next: Int64; let more: Bool? }
        let data = try await call("GET", "/v2/circle/updates", query: [URLQueryItem(name: "after", value: String(after))])
        do {
            let a = try JSONDecoder().decode(A.self, from: data)
            return (a.updates.map { EngineUpdate(seq: $0.seq, person: $0.person, kind: $0.kind, key: $0.key, title: $0.title ?? "", detail: $0.detail ?? "",
                                                 url: $0.url ?? "", at: $0.at, match: $0.match ?? "", born: $0.born, officer: $0.officer) }, a.next, a.more ?? false)
        } catch { throw ConnectorError.badResponse("circle updates: \(error)") }
    }

    public func putCircleWatch(_ body: Data) async throws { _ = try await call("PUT", "/v2/circle/watch", body: body) }

    public func putCircleCopy(_ copy: Data) async throws {
        guard let obj = try? JSONSerialization.jsonObject(with: copy), // try?-ok: reported as badResponse below
              let body = try? JSONSerialization.data(withJSONObject: ["copy": obj]) else { throw ConnectorError.badResponse("circle copy") } // try?-ok: reported as badResponse
        _ = try await call("PUT", "/v2/circle", body: body)
    }

    public func circleActions() async throws -> [CirclePhoneAction] {
        struct A: Decodable { let actions: [CirclePhoneAction] }
        let data = try await call("GET", "/v2/circle/actions")
        do { return try JSONDecoder().decode(A.self, from: data).actions } catch { throw ConnectorError.badResponse("circle actions: \(error)") }
    }

    public func ackCircleActions(_ ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        for chunk in stride(from: 0, to: ids.count, by: 200).map({ Array(ids[$0..<min($0 + 200, ids.count)]) }) {
            let body: Data
            do { body = try JSONSerialization.data(withJSONObject: ["ids": chunk]) } catch { throw ConnectorError.badResponse("\(error)") }
            _ = try await call("POST", "/v2/circle/actions/ack", body: body)
        }
    }

    /// contact_form: names, addresses and phone numbers from message headers only.
    public struct CircleFill: Decodable, Equatable { public let name: String; public let emails: [String]; public let phones: [String]; public let company: String }
    public func circleFill(headers: [[String: String]]) async throws -> CircleFill {
        let clean = headers.map { h in ["name": h["name"] ?? "", "address": h["address"] ?? "", "phone": h["phone"] ?? ""] }
        let body: Data
        do { body = try JSONSerialization.data(withJSONObject: ["headers": clean]) } catch { throw ConnectorError.badResponse("\(error)") }
        let data = try await call("POST", "/v2/circle/fill", body: body)
        do { return try JSONDecoder().decode(CircleFill.self, from: data) } catch { throw ConnectorError.badResponse("circle fill: \(error)") }
    }

    /// draft_message: never sent; nothing kept. `messages`: the last few, oldest first ("in"/"out", ISO time, text).
    public func circleDraft(name: String, language: String, notes: String, howKnown: String, channel: String,
                            messages: [(direction: String, at: String, text: String)]) async throws -> String {
        let obj: [String: Any] = ["name": name, "language": language, "notes": notes, "how_known": howKnown, "channel": channel,
                                  "messages": messages.suffix(5).map { ["direction": $0.direction, "at": $0.at, "text": $0.text] }]
        let body: Data
        do { body = try JSONSerialization.data(withJSONObject: obj) } catch { throw ConnectorError.badResponse("\(error)") }
        let data = try await call("POST", "/v2/circle/draft", body: body)
        guard let d = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["draft"] as? String else { // try?-ok: reported as badResponse
            throw ConnectorError.badResponse("circle draft")
        }
        return d
    }
}

extension ConnectorClient.CircleFill {
    /// Fills only the empty fields; returns which changed ("name", "company", "emails", "phones"), in that order.
    public func fill(_ f: inout ContactFormFields) -> [String] {
        var changed: [String] = []
        let n = name.trimmingCharacters(in: .whitespaces), c = company.trimmingCharacters(in: .whitespaces)
        if f.name.trimmingCharacters(in: .whitespaces).isEmpty, !n.isEmpty { f.name = n; changed.append("name") }
        if f.company.trimmingCharacters(in: .whitespaces).isEmpty, !c.isEmpty { f.company = c; changed.append("company") }
        let e = emails.filter { !$0.isEmpty }.joined(separator: ", "), p = phones.filter { !$0.isEmpty }.joined(separator: ", ")
        if f.emails.trimmingCharacters(in: .whitespaces).isEmpty, !e.isEmpty { f.emails = e; changed.append("emails") }
        if f.phones.trimmingCharacters(in: .whitespaces).isEmpty, !p.isEmpty { f.phones = p; changed.append("phones") }
        return changed
    }
}
