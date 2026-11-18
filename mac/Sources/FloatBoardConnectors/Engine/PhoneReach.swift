import FloatBoardCore
import Foundation

extension ConnectorClient {
    /// Whether a reminder the engine sends reaches a phone (`reachable` from `GET /v2/app/phones`); nil from an engine
    /// that doesn't say.
    public func phoneReach() async throws -> Bool? {
        let data = try await phoneCall("GET", "/v2/app/phones")
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ConnectorError.badResponse("phone list") } // try?-ok: reported as badResponse
        return obj["reachable"] as? Bool
    }
}

/// Whether any engine can reach a phone with a reminder, asked at most every 10 minutes per connector. The Mac shows a
/// late reminder itself unless one can (ReminderDelivery's `phoneAvailable`). Never heard from: no phone; an engine that
/// stops answering keeps its last answer; an engine from before this answer counts as reachable (the earlier behaviour).
@MainActor public enum PhoneReach {
    static var known: [String: (reachable: Bool, at: Date)] = [:]
    public static let every: TimeInterval = 600

    public static func any() -> Bool { known.values.contains { $0.reachable } }

    public static func refresh(connector id: String, client: ConnectorClient, now: Date = Date(), force: Bool = false) async {
        if !force, let k = known[id], now.timeIntervalSince(k.at) < every { return }
        do { known[id] = ((try await client.phoneReach()) ?? true, now) } catch {
            if let k = known[id] { known[id] = (k.reachable, now) }   // keep the last answer; asked again later
        }
    }

    /// The connector was removed or moved: what it said no longer counts.
    public static func forget(_ id: String) { known[id] = nil }
    public static func reset() { known = [:] }
}
