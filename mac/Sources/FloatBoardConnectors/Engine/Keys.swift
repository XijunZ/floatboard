import FloatBoardCore
import Foundation

/// Settings › Keys (docs/architecture.md, Edition 2, C9): the keys you enter on this Mac, kept in `Credentials`
/// (the Keychain), and sent to each connected engine that needs them. Sending is retried on every sync until the
/// engine confirms, so a key entered while offline still arrives. Only names wait in the board's `meta` table, never
/// the keys themselves.
public enum Keys {
    /// Credential names on this Mac.
    public static let claude = "claude-key"
    public static let gmailClientID = "gmail-client-id"
    public static let gmailClientSecret = "gmail-client-secret"
    /// Circle's What's new: UK Companies House officers and appointments (a free key).
    public static let companiesHouse = "companies-house-key"

    /// What can wait to be sent: the Claude key, and the Google client the engine uses for Gmail.
    public enum Item: String, CaseIterable, Sendable { case claude, googleClient = "google_client", companiesHouse = "companies_house" }

    static func pendingKey(_ connector: String) -> String { "keys.pending.\(connector)" }

    @MainActor public static func pending(connector: String, store: Store) -> Set<Item> {
        do {
            let raw = try store.db.query("SELECT value FROM meta WHERE key=?", [pendingKey(connector)]) { DB.text($0, 0) }.first ?? ""
            return Set(raw.split(separator: ",").compactMap { Item(rawValue: String($0)) })
        } catch {
            store.activity("keys", .warning, "Could not read which keys wait to be sent", detail: "\(error)")
            return []
        }
    }

    @MainActor static func setPending(_ items: Set<Item>, connector: String, store: Store) throws {
        if items.isEmpty { try store.db.run("DELETE FROM meta WHERE key=?", [pendingKey(connector)]); return }
        try store.db.run("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)",
                         [pendingKey(connector), items.map(\.rawValue).sorted().joined(separator: ",")])
    }

    /// The value on this Mac, or nil when it isn't set here (or can't be read; that is logged by `Credentials`).
    @MainActor public static func value(_ name: String, store: Store) -> String? {
        do { return try Credentials.logging("read a key", store: store) { try Credentials.get(name) } } catch { return nil }
    }

    /// Saves (or, with "", removes) the Claude key on this Mac and queues it for every engine.
    @MainActor public static func setClaude(_ key: String, store: Store) throws {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try Credentials.logging(k.isEmpty ? "remove the Claude key" : "save the Claude key", store: store) {
            if k.isEmpty { try Credentials.delete(claude) } else { try Credentials.set(k, claude) }
        }
        try queue(.claude, store: store)
        store.activity("keys", .info, k.isEmpty ? "Claude key removed from this Mac" : "Claude key saved on this Mac")
    }

    /// Saves (or, with "", removes) the Companies House key on this Mac and queues it for every engine.
    @MainActor public static func setCompaniesHouse(_ key: String, store: Store) throws {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try Credentials.logging(k.isEmpty ? "remove the Companies House key" : "save the Companies House key", store: store) {
            if k.isEmpty { try Credentials.delete(companiesHouse) } else { try Credentials.set(k, companiesHouse) }
        }
        try queue(.companiesHouse, store: store)
        store.activity("keys", .info, k.isEmpty ? "Companies House key removed from this Mac" : "Companies House key saved on this Mac")
    }

    /// Saves (or, with an empty id, removes) the Google client the engine uses to read Gmail, and queues it.
    @MainActor public static func setGmailClient(id: String, secret: String, store: Store) throws {
        let i = id.trimmingCharacters(in: .whitespacesAndNewlines), s = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        try Credentials.logging(i.isEmpty ? "remove the Google client" : "save the Google client", store: store) {
            if i.isEmpty { try Credentials.delete(gmailClientID); try Credentials.delete(gmailClientSecret) }
            else { try Credentials.set(i, gmailClientID); try Credentials.set(s, gmailClientSecret) }
        }
        try queue(.googleClient, store: store)
        store.activity("keys", .info, i.isEmpty ? "Google client for Gmail removed from this Mac" : "Google client for Gmail saved on this Mac")
    }

    @MainActor static func queue(_ item: Item, store: Store) throws {
        for c in store.connectors where !c.baseURL.isEmpty {
            try setPending(pending(connector: c.id, store: store).union([item]), connector: c.id, store: store)
        }
    }

    /// Sends what waits for this engine. Returns true when nothing is left waiting. Failures are logged once per sync
    /// and retried next time; nothing is dropped.
    @MainActor @discardableResult
    public static func push(connector id: String, store: Store, client: ConnectorClient) async -> Bool {
        let items = pending(connector: id, store: store)
        guard !items.isEmpty else { return true }
        var claudeKey: String?, google: (id: String, secret: String)?, chKey: String?
        if items.contains(.claude) { claudeKey = value(claude, store: store) ?? "" }
        if items.contains(.companiesHouse) { chKey = value(companiesHouse, store: store) ?? "" }
        if items.contains(.googleClient) {
            let gid = value(gmailClientID, store: store) ?? ""
            let secret = value(gmailClientSecret, store: store) ?? ""
            google = gid.isEmpty || secret.isEmpty ? ("", "") : (gid, secret)
        }
        do {
            try await client.setKeys(claudeKey: claudeKey, googleClient: google, companiesHouseKey: chKey)
            // Only clear what was sent: a key changed meanwhile stays queued.
            try setPending(pending(connector: id, store: store).subtracting(items), connector: id, store: store)
            store.activity("connector:\(id)", .info, "Keys sent to the engine",
                           detail: items.map { $0 == .claude ? "Claude key" : $0 == .companiesHouse ? "Companies House key" : "Google client" }.sorted().joined(separator: ", "))
            return pending(connector: id, store: store).isEmpty
        } catch {
            store.activity("connector:\(id)", .warning, "Could not send keys to the engine; will try again at the next sync",
                           detail: (error as? ConnectorError)?.description ?? "\(error)")
            return false
        }
    }
}
