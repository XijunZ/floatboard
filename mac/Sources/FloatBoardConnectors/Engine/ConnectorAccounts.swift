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
    public static func credentialName(_ id: String) -> String { "connector-key:\(id)" }

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
        ConnectorMemory.forget(connector: id, store: store)   // a new or re-pointed engine gets the phone's copies again
        PhoneReach.forget(id)
        reported[id] = nil
    }

    /// Removes the connector's row and key. Its cards and their history stay on the board. Throws (caller logs).
    @MainActor
    public static func remove(id: String, store: Store) throws {
        try store.removeConnector(id: id)
        try Credentials.delete(credentialName(id))
        reported[id] = nil
        PhoneReach.forget(id)
    }

    /// Checks only: every online connector's traffic goes here instead of the network.
    @MainActor public static var testTransport: ConnectorClient.Transport?

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
        if info.id == LocalMode.connectorID { return LocalMode.client(store: store) }
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
            if let testTransport { return ConnectorClient(baseURL: url, key: key, transport: testTransport) }
            return ConnectorClient(baseURL: url, key: key)
        } catch {
            if case CredentialsError.unavailable = error { return nil } // the Mac is asleep or locked: the next sync tries again
            report(store, info.id, .error, "Could not read the connector's key", detail: "\(error)")
            return nil
        }
    }
}

/// What a floatboard://connect link asks before joining (round 29, security L4): the engine's address, and a warning when
/// it would replace an engine already connected under that name. A link fired again within a few seconds (a page
/// re-firing it to wear the owner down) is ignored rather than asked again.
@MainActor public enum ConnectPrompt {
    public struct Text: Equatable { public let message: String; public let info: String; public let replaces: Bool }

    /// "https://host" or "http://localhost:8787": scheme, host and any port, taken from the URL itself.
    public static func address(_ url: URL?) -> String {
        guard let url, let host = url.host else { return url?.absoluteString ?? "" }
        return "\(url.scheme ?? "https")://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    /// The dialog's words for a link (nil when the link can't be used).
    public static func confirmation(_ link: URL, store: Store) -> Text? {
        guard let parts = ConnectLink.parse(link) else { return nil }
        let name = parts.name, id = ConnectLink.id(forName: name)
        let replaced = store.connectors.first { $0.id == id && !$0.baseURL.isEmpty && !ConnectorInfo.sameAddress($0.baseURL, parts.url.absoluteString) }
        var info = "Address: \(address(parts.url))\n\nIt will suggest tasks for your board and hear back what you do with them. Only join addresses you trust."
        let current = store.connectors.filter { !$0.baseURL.isEmpty }.map { "“\($0.name)” (\(address(URL(string: $0.baseURL))))" }
        if !current.isEmpty { info += "\n\nCurrently connected: " + current.joined(separator: ", ") + "." }
        if let replaced {
            info += "\n\nThis REPLACES “\(replaced.name)” at \(address(URL(string: replaced.baseURL))). Its tasks stay on your board."
                + " Unsent changes and your settings (including what FloatBoard has learned about you) will go to the new address."
        }
        return Text(message: "Connect “\(name)”?", info: info, replaces: replaced != nil)
    }

    /// The same link again within `window` seconds is not asked again.
    public struct RepeatGate {
        var last: [String: Date] = [:]
        public let window: TimeInterval
        public init(window: TimeInterval = 10) { self.window = window }
        public mutating func allows(_ link: URL, at now: Date = Date()) -> Bool {
            let k = link.absoluteString
            if let t = last[k], now.timeIntervalSince(t) < window { return false }
            last[k] = now
            return true
        }
    }
}
