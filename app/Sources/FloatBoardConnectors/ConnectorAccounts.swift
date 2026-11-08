import FloatBoardCore
import Foundation

/// `floatboard://connect?url=<engine address>&key=<key>&name=<name>`, made by a connector's setup page.
public enum ConnectLink {
    /// The parts of a connect link, or nil if it isn't one or is unsafe (an address that isn't https,
    /// except http://localhost or http://127.0.0.1 for a connector running on this Mac; an empty key).
    public static func parse(_ link: URL) -> (url: URL, key: String, name: String)? {
        guard link.scheme?.lowercased() == "floatboard", link.host?.lowercased() == "connect",
              let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ k: String) -> String { (items.first { $0.name == k }?.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let key = value("key")
        guard !key.isEmpty else { return nil }
        let raw = value("url").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: raw), isAllowed(url) else { return nil }
        let name = displayName(value("name"))
        return (url, key, name.isEmpty ? (url.host ?? "Connector") : name)
    }

    /// The link's name is chosen by whoever made the link, so it is shown only as a plain label: letters, digits,
    /// spaces and - _ & ' (no dots, slashes or colons, so it can't pose as an address), one line, at most 40 characters.
    public static func displayName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_&'"))
        let cleaned = String(raw.unicodeScalars.map { allowed.contains($0) && !CharacterSet.controlCharacters.contains($0) ? Character($0) : " " })
        let words = cleaned.split(separator: " ").joined(separator: " ")
        return String(words.prefix(40)).trimmingCharacters(in: .whitespaces)
    }

    /// https anywhere; plain http only to this Mac.
    public static func isAllowed(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return host == "localhost" || host == "127.0.0.1"
        default: return false
        }
    }

    /// The connector id for a name: lower-case letters, digits and dashes ("My Calendar!" -> "my-calendar").
    public static func id(forName name: String) -> String {
        var out = ""
        for ch in name.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch) } else if !out.isEmpty && out.last != "-" { out.append("-") }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "connector" : out
    }
}

/// Adding and removing connectors: the address goes in the database, the key in the credentials file.
public enum ConnectorAccounts {
    static func credentialName(_ id: String) -> String { "connector-key:\(id)" }

    public static func key(for id: String) throws -> String? { try Credentials.get(credentialName(id)) }

    /// Saves the connector's row, then its key. When the address changes, the old key is deleted first, so no failure
    /// can leave the new key next to the old address (or the old key next to the new one). Throws (caller logs).
    @MainActor
    public static func add(id: String, name: String, baseURL: URL, key: String, store: Store) throws {
        let address = baseURL.absoluteString
        let replacing = store.connectors.contains { $0.id == id && !$0.baseURL.isEmpty && !ConnectorInfo.sameAddress($0.baseURL, address) }
        if replacing { try Credentials.delete(credentialName(id)) }
        do { try store.upsertConnector(id: id, name: name, baseURL: address) } catch {
            if replacing {
                store.activity("connector:\(id)", .warning, "\(name) wasn't moved; its old key was already removed, so open its connect link again")
            }
            throw error
        }
        try Credentials.set(key, credentialName(id))
        reported[id] = nil
    }

    /// Removes the connector's row and key. Its cards and their history stay on the board. Throws (caller logs).
    @MainActor
    public static func remove(id: String, store: Store) throws {
        try store.removeConnector(id: id)
        try Credentials.delete(credentialName(id))
        reported[id] = nil
    }

    /// The last problem logged per connector, so each one is logged once per change, not on every sync trigger.
    @MainActor static var reported: [String: String] = [:]

    @MainActor
    private static func report(_ store: Store, _ id: String, _ level: ActivityLevel, _ message: String, detail: String? = nil) {
        guard reported[id] != message else { return }
        reported[id] = message
        store.activity("connector:\(id)", level, message, detail: detail)
    }

    /// A client for the connector, or nil (logged once per change) when its address or key is missing or unsafe.
    @MainActor
    public static func client(for info: ConnectorInfo, store: Store) -> ConnectorClient? {
        guard !info.baseURL.isEmpty else { return nil }
        guard let url = URL(string: info.baseURL), ConnectLink.isAllowed(url) else {
            // Host only: the full address can carry a path or token.
            report(store, info.id, .error, "The connector's address must start with https://; not syncing",
                   detail: URL(string: info.baseURL)?.host ?? "(address not readable)")
            return nil
        }
        do {
            guard let key = try key(for: info.id), !key.isEmpty else {
                report(store, info.id, .warning, "No saved key for \(info.name); open its connect link again from its setup page")
                return nil
            }
            reported[info.id] = nil
            return ConnectorClient(baseURL: url, key: key)
        } catch {
            report(store, info.id, .error, "Could not read the connector's key", detail: "\(error)")
            return nil
        }
    }
}
