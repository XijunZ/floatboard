import CryptoKit
import FloatBoardCore
import Foundation

/// The Mac's side of the phone for Circle, Decisions and Jots, shared: take in what the phone left on the engine (fetch,
/// apply here, acknowledge), send the phone's copy only when it changed for this engine account, and report a problem once.
@MainActor public enum PhoneInbox {
    /// The engines take at most 200 acknowledgements per request.
    public static let ackBatch = 200

    /// One pass: fetch what waits, apply it on this Mac (each area applies once; `apply` returns what to acknowledge: what
    /// was applied and what can never be), then acknowledge that in batches, in order. A failed acknowledgement throws; the
    /// rest stays on the engine and comes again (applying is once-only, so nothing is made twice). Returns how many were
    /// acknowledged (nothing waiting: nothing sent).
    @discardableResult
    public static func take<Item, Ack>(fetch: () async throws -> [Item], apply: ([Item]) -> [Ack], ack: ([Ack]) async throws -> Void) async throws -> Int {
        let items = try await fetch()
        guard !items.isEmpty else { return 0 }
        let acks = apply(items)
        for start in stride(from: 0, to: acks.count, by: ackBatch) {
            try await ack(Array(acks[start..<min(start + ackBatch, acks.count)]))
        }
        return acks.count
    }

    /// Sends `body` with `send` when it differs from what this engine account last got (a hash of the body and the account,
    /// kept under `metaKey`); the hash is kept only after the send worked. Another engine or key always gets it. True when sent.
    @discardableResult
    public static func sendIfChanged(_ body: Data, metaKey: String, store: Store, client: ConnectorClient,
                                     send: (Data) async throws -> Void) async throws -> Bool {
        let hash = SHA256.hash(data: body + Data(client.accountFingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
        let last = (try? store.db.query("SELECT value FROM meta WHERE key=?", [metaKey]) { DB.text($0, 0) })?.first // try?-ok: unknown = send again (harmless)
        guard last != hash else { return false }
        try await send(body)
        try store.db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)", [metaKey, hash])
        return true
    }

    /// Problems reported once per distinct message (per area and connector); a pass that works clears it.
    public struct Reports {
        var last: [String: String] = [:]
        public init() {}
        /// True when `why` is new for `key` (log it now).
        public mutating func failed(_ key: String, _ why: String) -> Bool {
            guard last[key] != why else { return false }
            last[key] = why
            return true
        }
        /// True when a problem had been reported for `key` (the area may say it works again).
        @discardableResult
        public mutating func cleared(_ key: String) -> Bool { last.removeValue(forKey: key) != nil }
    }
}
