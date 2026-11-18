import CryptoKit
import FloatBoardCore
import Foundation

/// What Claude filled into the Make decision form (features §4 D2; low flag: the owner edits before saving).
public struct DecisionFill: Decodable, Equatable {
    public let decision: String
    public let why: String
    public let expected: String
    public let confidence: Confidence?
    public let type: DecisionType
    public let alternatives: String
    enum CodingKeys: String, CodingKey { case decision, why, expected, confidence, type, alternatives }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        decision = try c.decode(String.self, forKey: .decision)
        why = try c.decodeIfPresent(String.self, forKey: .why) ?? DecisionDraft.notRecorded
        expected = try c.decodeIfPresent(String.self, forKey: .expected) ?? ""
        confidence = (try c.decodeIfPresent(String.self, forKey: .confidence)).flatMap(Confidence.init(rawValue:))
        type = (try c.decodeIfPresent(String.self, forKey: .type)).flatMap(DecisionType.init(rawValue:)) ?? .operational
        alternatives = try c.decodeIfPresent(String.self, forKey: .alternatives) ?? ""
    }
}

/// Decisions' engine calls (docs/superpowers/specs/2026-11-17-decisions-design.md §8). All Haiku, in the engine.
extension ConnectorClient {
    private func post<T: Decodable>(_ path: String, _ body: [String: Any], as: T.Type) async throws -> T {
        let data: Data
        do { data = try JSONSerialization.data(withJSONObject: body) } catch { throw ConnectorError.badResponse("\(error)") }
        let answer = try await call("POST", path, body: data)
        do { return try JSONDecoder().decode(T.self, from: answer) } catch { throw ConnectorError.badResponse("\(path): \(error)") }
    }

    /// D1 ⚑: one batch of jot versions (at most 10, 40,000 characters).
    public func screenDecisions(_ jots: [ScreenJot]) async throws -> [ScreenResult] {
        let body: Data
        do { body = try JSONEncoder().encode(["jots": jots]) } catch { throw ConnectorError.badResponse("\(error)") }
        struct Out: Decodable { let results: [ScreenResult] }
        do { return try JSONDecoder().decode(Out.self, from: try await call("POST", "/v2/decisions/screen", body: body)).results }
        catch let e as ConnectorError { throw e } catch { throw ConnectorError.badResponse("screening: \(error)") }
    }

    public func fillDecision(selection: String, context: String) async throws -> DecisionFill {
        try await post("/v2/decisions/fill", ["selection": selection, "context": context], as: DecisionFill.self)
    }

    /// ⚑ suggestion only: `items` = [(new id, text, earlier [(id, text)])] → new id → the id it may replace.
    public func supersedes(_ items: [(id: String, text: String, earlier: [(id: String, text: String)])]) async throws -> [String: String] {
        struct R: Decodable { let id: String; let supersedes: String? }
        struct Out: Decodable { let results: [R] }
        let out = try await post("/v2/decisions/supersedes", ["items": items.map { i in
            ["id": i.id, "text": i.text, "earlier": i.earlier.map { ["id": $0.id, "text": $0.text] }] as [String: Any] }], as: Out.self)
        return Dictionary(out.results.compactMap { r in r.supersedes.map { (r.id, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    /// Tell / ask suggestions: decision id → [(person id, tell | ask, task title)].
    public func tellAsk(_ items: [(id: String, text: String, people: [(id: String, name: String)])]) async throws -> [String: [(String, String, String)]] {
        struct S: Decodable { let person: String; let kind: String; let title: String }
        struct R: Decodable { let id: String; let suggestions: [S] }
        struct Out: Decodable { let results: [R] }
        let out = try await post("/v2/decisions/tell-ask", ["items": items.map { i in
            ["id": i.id, "text": i.text, "people": i.people.map { ["id": $0.id, "name": $0.name] }] as [String: Any] }], as: Out.self)
        return Dictionary(out.results.map { r in (r.id, r.suggestions.map { ($0.person, $0.kind, $0.title) }) }, uniquingKeysWith: { a, _ in a })
    }

    public func putDecisions(_ copy: [PhoneDecision]) async throws {
        let body: Data
        do { body = try JSONEncoder().encode(["decisions": copy]) } catch { throw ConnectorError.badResponse("\(error)") }
        _ = try await call("PUT", "/v2/decisions", body: body)
    }

    public func decisionActions() async throws -> [PhoneDecisionAction] {
        struct Out: Decodable { let actions: [PhoneDecisionAction] }
        do { return try JSONDecoder().decode(Out.self, from: try await call("GET", "/v2/decision-actions")).actions }
        catch let e as ConnectorError { throw e } catch { throw ConnectorError.badResponse("decision actions: \(error)") }
    }

    public func ackDecisionActions(_ ids: [String]) async throws {
        let body: Data
        do { body = try JSONSerialization.data(withJSONObject: ["ids": ids]) } catch { throw ConnectorError.badResponse("\(error)") }
        _ = try await call("POST", "/v2/decision-actions/ack", body: body)
    }
}

/// The Decisions jobs that need the engine: the weekly screening (D1), the follow-up suggestions, form filling and the phone.
@MainActor public enum DecisionsEngine {
    private static var screening = false
    /// After a failed run, the next try waits an hour (the timer runs every 10 minutes).
    static var lastFailure: Date?
    public static let retryAfter: TimeInterval = 3600
    /// The last phone problem logged per connector, so a poll every 2 minutes doesn't repeat it.
    private static var phoneReports = PhoneInbox.Reports()

    /// The engine that does Claude's work: this Mac's engine in Mac only mode, else the first online one.
    public static func client(store: Store) -> (id: String, client: ConnectorClient)? {
        let infos = LocalMode.isOn(store: store) ? store.connectors.filter { $0.id == LocalMode.connectorID } : LocalMode.online(store)
        for info in infos { if let c = ConnectorAccounts.client(for: info, store: store) { return (info.id, c) } }
        return nil
    }

    /// Registers the phone step with the connector sync (once, at launch).
    public static func register() {
        ConnectorSync.phoneHooks.append { id, store, client, now in await phoneStep(connector: id, store: store, client: client, now: now) }
    }

    /// The weekly screening, when it is due (Sunday from 17:00, once a week) and Decisions is on. Waiting "Not a decision"
    /// examples go into the rulebook first. A failed request leaves everything as it was (the run stays due). Returns what was
    /// recorded, or nil when nothing ran.
    @discardableResult
    public static func screenIfDue(store: Store, connector: String, client: ConnectorClient, now: Date = Date(), force: Bool = false) async -> ScreenOutcome? {
        guard store.isOn(.decisions), !screening else { return nil }
        guard force || DecisionScreening.isDue(now: now, lastRun: DecisionScreening.lastRun(store: store)) else { return nil }
        if !force, let f = lastFailure, now.timeIntervalSince(f) < retryAfter, now >= f { return nil }
        screening = true
        defer { screening = false }
        DecisionRulebook.applyPending(store: store, connector: connector, now: now)
        let readFrom = DecisionScreening.readFrom(store: store, now: now)
        let jotsUpTo = DecisionScreening.lastJotID(store: store)
        let pending = DecisionScreening.pending(store: store, now: now)
        var total = ScreenOutcome()
        for batch in DecisionScreening.batches(pending) {
            do {
                let results = try await client.screenDecisions(batch)
                let o = DecisionScreening.apply(results, sent: batch, store: store, now: now)
                total.recorded += o.recorded; total.maybe += o.maybe; total.references += o.references
                total.unreadable += o.unreadable; total.screened += o.screened
            } catch {
                store.activity("decisions", .warning, "The weekly decision screening could not finish; it will try again",
                               detail: (error as? ConnectorError)?.description ?? "\(error)")
                if total.screened == 0 { lastFailure = now; return nil }
                total.unreadable += batch.count
                break
            }
        }
        lastFailure = nil
        DecisionScreening.finishRun(store: store, started: now, readFrom: readFrom, complete: total.unreadable == 0, now: now,
                                    jotsUpTo: jotsUpTo)
        if total.unreadable > 0 {
            store.activity("decisions", .warning, "Couldn't read Claude's answer for \(total.unreadable) jot\(total.unreadable == 1 ? "" : "s"); they are read again next week")
        }
        store.activity("decisions", .info, "Weekly screening: \(total.recorded.count) decision\(total.recorded.count == 1 ? "" : "s") recorded, \(total.maybe.count) maybe",
                       detail: "\(total.screened) jot versions read; \(total.references) references to earlier decisions skipped")
        await suggest(for: total.recorded, store: store, client: client, now: now)
        return total
    }

    /// Supersedes (⚑ suggestion only) and tell / ask suggestions for new decisions, one batched call each. Failures are logged;
    /// nothing is suggested then.
    public static func suggest(for ids: [Int64], store: Store, client: ConnectorClient, now: Date = Date()) async {
        let ds = DecisionStore(store: store)
        let fresh = ids.compactMap { ds.decision($0) }.filter { !$0.deleted && $0.status != .maybe }
        guard !fresh.isEmpty else { return }
        let earlierAll = ds.all().filter { d in d.status != .maybe && !fresh.contains { $0.id == d.id } }
        let supItems = fresh.prefix(20).compactMap { d -> (id: String, text: String, earlier: [(id: String, text: String)])? in
            let tags = Set(store.itemTags(d.shortID).all.map { $0.lowercased() })
            guard !tags.isEmpty else { return nil }
            let earlier = earlierAll.filter { e in e.recorded <= d.recorded && store.itemTags(e.shortID).all.contains { tags.contains($0.lowercased()) } }.prefix(10)
            return earlier.isEmpty ? nil : (d.shortID.text, d.text, earlier.map { ($0.shortID.text, $0.text) })
        }
        if !supItems.isEmpty {
            do {
                for (new, old) in try await client.supersedes(Array(supItems)) {
                    guard let n = ShortID.parse(new), let o = ShortID.parse(old) else { continue }
                    ds.suggest(n.number, kind: .supersedes, target: o, now: now)
                }
            } catch { store.activity("decisions", .warning, "Couldn't ask which earlier decisions the new ones replace", detail: "\(error)") }
        }
        let tellItems = fresh.prefix(20).compactMap { d -> (id: String, text: String, people: [(id: String, name: String)])? in
            let people = ds.people(of: d.id)
            return people.isEmpty ? nil : (d.shortID.text, d.text, people.map { ($0.shortID.text, $0.name) })
        }
        if !tellItems.isEmpty {
            do {
                for (id, list) in try await client.tellAsk(Array(tellItems)) {
                    guard let d = ShortID.parse(id) else { continue }
                    for (person, kind, title) in list {
                        guard let p = ShortID.parse(person), let k = DecisionStore.SuggestionKind(rawValue: kind) else { continue }
                        ds.suggest(d.number, kind: k, target: p, text: title, now: now)
                    }
                }
            } catch { store.activity("decisions", .warning, "Couldn't ask for tell / ask task suggestions", detail: "\(error)") }
        }
    }

    /// The phone step for Decisions: apply and acknowledge the phone's actions, write waiting rulebook examples, and send the
    /// copy when it changed. Problems are logged once per distinct message.
    public static func phoneStep(connector id: String, store: Store, client: ConnectorClient, now: Date = Date()) async {
        do {
            try await PhoneInbox.take(fetch: client.decisionActions, apply: { actions in
                let r = DecisionPhone.apply(actions, store: store, now: now)
                for (aid, why) in r.skipped { store.activity("decisions", .info, "A change from the phone was not applied: \(why)", detail: aid) }
                return r.applied + r.skipped.map(\.0)   // `r.waiting` stays on the engine for the next sync
            }, ack: client.ackDecisionActions)
            // Examples go into the rulebook of the engine that screens (this Mac's in Mac only mode).
            if DecisionsEngine.client(store: store)?.id == id { DecisionRulebook.applyPending(store: store, connector: id, now: now) }
            let copy = DecisionPhone.copy(store: store, now: now)
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]   // a stable hash: key order is otherwise not guaranteed
            try await PhoneInbox.sendIfChanged(try enc.encode(copy), metaKey: DecisionPhone.hashKey(id), store: store, client: client) { _ in
                try await client.putDecisions(copy)
            }
            phoneReports.cleared(id)
        } catch ConnectorError.http(404, _) {
            return   // an engine from before Decisions: nothing to sync
        } catch {
            let why = (error as? ConnectorError)?.description ?? "\(error)"
            if phoneReports.failed(id, why) {
                store.activity("connector:\(id)", .warning, "Could not sync Decisions with the phone; will try again", detail: why)
            }
        }
    }
}
