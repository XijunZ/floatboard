import FloatBoardCore
import Foundation

/// "Screen WeChat": every 5 minutes, while it is on for a connection, the Mac reads WeChat's new notifications from
/// macOS's notification history (`WeChatNotifications`) and sends them to that connection's engine, which turns the ones
/// that need the person into tasks. Per chat, a cursor (the newest notification already sent) means nothing is sent
/// twice. Off by default.
public enum WeChatSync {
    public struct Status: Equatable, Sendable {
        public var lastRead: Date?
        public var lastSent = 0
        public var error: String?
    }
    @MainActor public static var status: [String: Status] = [:]
    @MainActor private static var reported: [String: String] = [:]

    static func onKey(_ id: String) -> String { "wechat.on.\(id)" }
    static func cursorKey(_ id: String) -> String { "wechat.cursors.\(id)" }

    @MainActor public static func isOn(connector id: String, store: Store) -> Bool {
        do { return try store.db.query("SELECT value FROM meta WHERE key=?", [onKey(id)]) { DB.text($0, 0) }.first == "1" }
        catch { return false }
    }

    /// Turning it on starts from the last 7 days of notifications macOS still holds; turning it off forgets the cursors.
    @MainActor public static func setOn(_ on: Bool, connector id: String, store: Store) {
        do {
            if on { try store.db.run("INSERT OR REPLACE INTO meta(key,value) VALUES(?, '1')", [onKey(id)]) }
            else { try store.db.run("DELETE FROM meta WHERE key IN (?,?)", [onKey(id), cursorKey(id)]); status[id] = nil }
            store.activity("connector:\(id)", .info, on ? "WeChat screening turned on" : "WeChat screening turned off")
        } catch {
            store.activity("connector:\(id)", .error, "Could not change WeChat screening", detail: "\(error)")
        }
    }

    /// Moves WeChat screening (its switch and how far it has read) to another connection (switching modes).
    @MainActor public static func move(from: String, to: String, store: Store) {
        guard isOn(connector: from, store: store) else { return }
        let cur = cursors(connector: from, store: store)
        setOn(true, connector: to, store: store)
        do {
            try saveCursors(cur, connector: to, store: store)
            try store.db.run("DELETE FROM meta WHERE key=?", [onKey(from)])
            status[from] = nil
        } catch { store.activity("connector:\(to)", .warning, "WeChat moved, but where it had read up to wasn't kept", detail: "\(error)") }
    }

    @MainActor static func cursors(connector id: String, store: Store) -> [String: Double] {
        do {
            guard let s = try store.db.query("SELECT value FROM meta WHERE key=?", [cursorKey(id)]) { DB.text($0, 0) }.first,
                  let d = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Double] else { return [:] }
            return d
        } catch { return [:] }
    }

    @MainActor static func saveCursors(_ c: [String: Double], connector id: String, store: Store) throws {
        let s = String(decoding: try JSONSerialization.data(withJSONObject: c, options: [.sortedKeys]), as: UTF8.self)
        try store.db.run("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", [cursorKey(id), s])
    }

    /// One pass: read, send in batches of 50, move each sent chat's cursor. Problems are logged once per distinct message.
    @MainActor @discardableResult
    public static func tick(connector id: String, store: Store, client: ConnectorClient, now: Date = Date(),
                            folder: URL = WeChatNotifications.folder) async -> Int {
        guard isOn(connector: id, store: store) else { return 0 }
        var st = status[id] ?? Status()
        var sent = 0
        do {
            var cur = cursors(connector: id, store: store)
            let chats = try WeChatNotifications.newChats(folder: folder, cursors: cur, now: now)
            for start in stride(from: 0, to: chats.count, by: 50) {
                let part = Array(chats[start..<min(start + 50, chats.count)])
                try await client.sendChats(app: "wechat", part)
                for c in part { cur[c.chatID] = max(cur[c.chatID] ?? 0, c.newest) }
                try saveCursors(cur, connector: id, store: store)
                sent += part.count
            }
            st.lastRead = now; st.lastSent = sent; st.error = nil
            if reported.removeValue(forKey: id) != nil { store.activity("connector:\(id)", .info, "WeChat screening works again") }
            if sent > 0 { store.activity("connector:\(id)", .info, "Checking \(sent) WeChat chat\(sent == 1 ? "" : "s") for tasks (from macOS's notifications; nothing is sent on WeChat)") }
        } catch {
            let why = (error as? WeChatNotifications.ReadError)?.description ?? (error as? ConnectorError)?.description ?? "\(error)"
            st.error = why
            if reported[id] != why {
                reported[id] = why
                store.activity("connector:\(id)", .warning, "Could not screen WeChat; will try again", detail: why)
            }
        }
        status[id] = st
        return sent
    }
}
