import Foundation
import FloatBoardCore

/// "Screen WhatsApp": every few minutes, while it is on for a connection, the Mac reads the unread WhatsApp chats
/// (`WhatsAppLocal`) and sends the new messages to that connection's engine, which turns the ones that need the
/// person into tasks. Per chat, a cursor (the newest message already sent) means nothing is sent twice. Off by default.
public enum WhatsAppSync {
    public static let interval: TimeInterval = 5 * 60
    static let batch = 50

    public struct Status: Equatable, Sendable {
        public var lastRead: Date?
        public var lastSent = 0
        public var error: String?
        public var needsAccess = false
    }
    /// The last tick's outcome per connection, for the Connectors tab.
    @MainActor public static var status: [String: Status] = [:]
    @MainActor private static var reported: [String: String] = [:]

    static func onKey(_ id: String) -> String { "whatsapp.on.\(id)" }
    static func cursorKey(_ id: String) -> String { "whatsapp.cursors.\(id)" }

    @MainActor public static func isOn(connector id: String, store: Store) -> Bool {
        do { return try store.db.query("SELECT value FROM meta WHERE key=?", [onKey(id)]) { DB.text($0, 0) }.first == "1" }
        catch { return false }
    }

    /// Turning it on starts from now: chats already unread before then are still read (they are unread), but nothing
    /// older than 7 days. Turning it off forgets the cursors.
    @MainActor public static func setOn(_ on: Bool, connector id: String, store: Store) {
        do {
            if on { try store.db.run("INSERT OR REPLACE INTO meta(key,value) VALUES(?, '1')", [onKey(id)]) }
            else {
                try store.db.run("DELETE FROM meta WHERE key IN (?,?)", [onKey(id), cursorKey(id)])
                status[id] = nil
            }
            store.activity("connector:\(id)", .info, on ? "WhatsApp screening turned on" : "WhatsApp screening turned off")
        } catch {
            store.activity("connector:\(id)", .error, "Could not change WhatsApp screening", detail: "\(error)")
        }
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

    /// Watch tasks waiting on a WhatsApp chat: a message from that chat after the task went to Watch moves it back to
    /// To do. Problems are only logged (the next read tries again).
    @MainActor public static func replies(connector id: String, store: Store, folder: URL) {
        let watched = store.cards.filter { $0.status == .watch && $0.watchSince != nil && $0.watchContact.hasPrefix("wa:") }
        guard !watched.isEmpty else { return }
        do {
            let latest = try WhatsAppLocal.latestIncoming(folder: folder, chatIDs: watched.map { String($0.watchContact.dropFirst(3)) })
            for c in watched {
                guard let at = latest[String(c.watchContact.dropFirst(3))], let since = c.watchSince, at > since else { continue }
                let who = c.watchPerson.trimmingCharacters(in: .whitespaces)
                if store.watchReply(c, reason: "\(who.isEmpty ? "They" : who) replied on WhatsApp", at: min(at, Date())) {
                    store.activity("connector:\(id)", .info, "\(who.isEmpty ? "A watched chat" : who) replied on WhatsApp: back to To do", detail: c.title)
                }
            }
        } catch {
            store.activity("connector:\(id)", .warning, "Could not check WhatsApp replies for Watch tasks", detail: "\(error)")
        }
    }

    /// One pass: read, send in batches, move each sent chat's cursor. Problems are logged once per distinct message.
    /// Returns how many chats were sent.
    @MainActor @discardableResult
    public static func tick(connector id: String, store: Store, client: ConnectorClient, now: Date = Date(),
                            folder: URL = WhatsAppLocal.folder) async -> Int {
        guard isOn(connector: id, store: store) else { return 0 }
        var st = status[id] ?? Status()
        var sent = 0
        do {
            var cur = cursors(connector: id, store: store)
            let chats = try WhatsAppLocal.unreadChats(folder: folder, cursors: cur, now: now)
            for start in stride(from: 0, to: chats.count, by: batch) {
                let part = Array(chats[start..<min(start + batch, chats.count)])
                try await client.sendChats(app: "whatsapp", part)
                for c in part { cur[c.chatID] = max(cur[c.chatID] ?? 0, c.newest) }
                try saveCursors(cur, connector: id, store: store)
                sent += part.count
            }
            replies(connector: id, store: store, folder: folder)
            st.lastRead = now; st.lastSent = sent; st.error = nil; st.needsAccess = false
            if reported.removeValue(forKey: id) != nil { store.activity("connector:\(id)", .info, "WhatsApp screening works again") }
            if sent > 0 { store.activity("connector:\(id)", .info, "Checking \(sent) WhatsApp chat\(sent == 1 ? "" : "s") for tasks (unread messages passed to the engine; nothing is sent on WhatsApp)") }
        } catch {
            let why = (error as? WhatsAppLocal.ReadError)?.description ?? (error as? ConnectorError)?.description ?? "\(error)"
            st.error = why
            st.needsAccess = (error as? WhatsAppLocal.ReadError) == .noAccess
            if reported[id] != why {
                reported[id] = why
                store.activity("connector:\(id)", .warning, "Could not screen WhatsApp; will try again", detail: why)
            }
        }
        status[id] = st
        return sent
    }
}
