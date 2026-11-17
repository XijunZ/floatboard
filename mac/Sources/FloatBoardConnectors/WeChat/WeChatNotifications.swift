import FloatBoardCore
import Foundation
import SQLite3

/// WeChat, read from macOS's own notification history (never from WeChat): when a WeChat message arrives, macOS stores
/// the notification it shows (who, which chat, the preview text) in its notification database. FloatBoard copies that
/// database (as it does WhatsApp's), takes WeChat's notifications, and groups them per chat for the engine to judge.
/// It cannot see chats you muted in WeChat (they make no notification), messages whose preview WeChat hides, or
/// notifications you cleared before the next read (every 5 minutes). It never touches WeChat itself.
/// Needs Full Disk Access (the same permission as WhatsApp).
public enum WeChatNotifications {
    public static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2")
    }
    static let file = "db"
    /// WeChat's app identifiers on the Mac.
    static let apps = ["com.tencent.xinWeChat", "com.tencent.xinwechat", "com.tencent.WeChat"]
    static let appleEpoch = 978_307_200.0
    static let maxAgeDays = 7.0
    static let perChat = 30

    public enum ReadError: Error, Equatable, CustomStringConvertible {
        case noAccess, notFound, unreadable(String)
        public var description: String {
            switch self {
            case .noAccess: return "FloatBoard isn't allowed to read macOS's notification history. Allow it in System Settings › Privacy & Security › Full Disk Access."
            case .notFound: return "macOS's notification history wasn't found on this Mac."
            case .unreadable(let why): return "macOS's notification history couldn't be read (\(why)). A macOS update may have changed it."
            }
        }
    }

    /// One WeChat notification: the chat (title), who wrote in a group (subtitle), the text, and when it arrived.
    struct Note { let chat: String; let sender: String; let text: String; let at: Date; let stamp: Double }

    /// New WeChat messages to screen, grouped per chat. `cursors`: chat -> newest notification time already sent.
    public static func newChats(folder: URL = folder, cursors: [String: Double], now: Date = Date(),
                                zone: TimeZone = AppTime.zone) throws -> [WhatsAppLocal.Chat] {
        let notes = try readNotes(folder: folder, since: now.addingTimeInterval(-maxAgeDays * 86_400))
        return chats(notes, cursors: cursors, zone: zone)
    }

    /// How many WeChat notifications from the last 7 days macOS still holds (to tell the person it works).
    public static func recentCount(folder: URL = folder, now: Date = Date()) throws -> Int {
        try readNotes(folder: folder, since: now.addingTimeInterval(-maxAgeDays * 86_400)).count
    }

    /// Support: counts and field names of WeChat's notifications in macOS's history (never any text).
    public static func probeSummary(folder: URL = folder) -> String {
        do {
            let notes = try readNotes(folder: folder, since: Date().addingTimeInterval(-maxAgeDays * 86_400))
            let chats = Set(notes.map(\.chat)).count
            let groups = Set(notes.filter { !$0.sender.isEmpty }.map(\.chat)).count
            return "ok: \(notes.count) WeChat notifications in 7 days, \(chats) chats, \(groups) with a sender (group)\n" + (try rawShape(folder: folder))
        } catch { return "error: \(error)" }
    }

    /// The identifiers of apps in the history that look like WeChat, and the keys their records use.
    static func rawShape(folder: URL) throws -> String {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fb-wxp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: tmp) } // try?-ok: temp cleanup
        for s in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: folder.appendingPathComponent(file + s).path) {
            try FileManager.default.copyItem(at: folder.appendingPathComponent(file + s), to: tmp.appendingPathComponent(file + s))
        }
        var db: OpaquePointer?
        guard sqlite3_open(tmp.appendingPathComponent(file).path, &db) == SQLITE_OK, let db else { return "can't open copy" }
        defer { sqlite3_close(db) }
        var out: [String] = []
        var s: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT a.identifier, COUNT(r.rec_id) FROM app a LEFT JOIN record r ON r.app_id=a.app_id WHERE lower(a.identifier) LIKE '%tencent%' OR lower(a.identifier) LIKE '%wechat%' OR lower(a.identifier) LIKE '%weixin%' GROUP BY a.identifier", -1, &s, nil)
        while sqlite3_step(s) == SQLITE_ROW { out.append("app \(String(cString: sqlite3_column_text(s, 0))): \(sqlite3_column_int(s, 1)) records") }
        sqlite3_finalize(s)
        sqlite3_prepare_v2(db, "SELECT r.data FROM record r JOIN app a ON a.app_id=r.app_id WHERE lower(a.identifier) LIKE '%tencent%' ORDER BY r.delivered_date DESC LIMIT 3", -1, &s, nil)
        while sqlite3_step(s) == SQLITE_ROW {
            let n = Int(sqlite3_column_bytes(s, 0))
            guard n > 0, let b = sqlite3_column_blob(s, 0),
                  let p = try? PropertyListSerialization.propertyList(from: Data(bytes: b, count: n), format: nil) as? [String: Any] else { continue } // try?-ok: support output
            out.append("keys \(p.keys.sorted()) req \((p["req"] as? [String: Any])?.keys.sorted() ?? [])")
        }
        sqlite3_finalize(s)
        return out.joined(separator: "\n")
    }

    /// WeChat is screened strictly (the person's choice): only one-to-one chats are sent, and each is marked like a muted
    /// chat so the engine applies its stricter rule (only something clearly asked of the person becomes a task). Group
    /// chats (a sender other than the chat in "Name: text") are skipped here and never leave the Mac.
    static func chats(_ notes: [Note], cursors: [String: Double], zone: TimeZone) -> [WhatsAppLocal.Chat] {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.timeZone = zone; f.dateFormat = "yyyy-MM-dd HH:mm"
        let iso = ISO8601DateFormatter()
        var out: [WhatsAppLocal.Chat] = []
        for (chat, all) in Dictionary(grouping: notes, by: \.chat) {
            let fresh = all.filter { $0.stamp > (cursors[chat] ?? 0) }.sorted { $0.stamp < $1.stamp }.suffix(perChat)
            guard let newest = fresh.last else { continue }
            let senders = Array(Set(fresh.map { $0.sender.isEmpty ? chat : $0.sender })).sorted()
            let group = all.contains { !$0.sender.isEmpty && $0.sender != chat }
            if group { continue }
            let lines = fresh.map { "[\(f.string(from: $0.at))] \($0.sender.isEmpty ? chat : $0.sender): \($0.text)" }
            out.append(WhatsAppLocal.Chat(key: "wx:\(chat):\(iso.string(from: newest.at))", chatID: chat, name: chat, group: false, muted: true,
                                          senders: senders, transcript: lines.joined(separator: "\n"), link: "weixin://",
                                          received: newest.at, newest: newest.stamp))
        }
        return out.sorted { $0.newest < $1.newest }
    }

    static func readNotes(folder: URL, since: Date) throws -> [Note] {
        let fm = FileManager.default
        let src = folder.appendingPathComponent(file)
        guard fm.fileExists(atPath: folder.path) || fm.fileExists(atPath: src.path) else {
            // A folder macOS hides from apps without Full Disk Access looks missing.
            throw fm.fileExists(atPath: folder.deletingLastPathComponent().path) ? ReadError.noAccess : ReadError.notFound
        }
        guard fm.isReadableFile(atPath: src.path) else { throw ReadError.noAccess }
        let tmp = fm.temporaryDirectory.appendingPathComponent("fb-wx-\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: tmp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { throw ReadError.unreadable("no temporary folder") }
        defer { try? fm.removeItem(at: tmp) } // try?-ok: a leftover temp folder is cleaned by macOS
        for suffix in ["", "-wal", "-shm"] {
            let from = folder.appendingPathComponent(file + suffix)
            guard suffix.isEmpty || fm.fileExists(atPath: from.path) else { continue }
            do { try fm.copyItem(at: from, to: tmp.appendingPathComponent(file + suffix)) } catch {
                let ns = error as NSError
                if ns.code == NSFileReadNoPermissionError || (ns.underlyingErrors.first as NSError?)?.code == Int(EPERM) { throw ReadError.noAccess }
                throw ReadError.unreadable(ns.localizedDescription)
            }
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp.appendingPathComponent(file).path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw ReadError.unreadable("can't open the copy")
        }
        defer { sqlite3_close(db) }
        let placeholders = apps.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT r.data, r.delivered_date FROM record r JOIN app a ON a.app_id = r.app_id
            WHERE a.identifier IN (\(placeholders)) AND r.delivered_date > ? ORDER BY r.delivered_date
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ReadError.unreadable(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in apps.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), a, -1, transient) }
        sqlite3_bind_double(stmt, Int32(apps.count + 1), since.timeIntervalSince1970 - appleEpoch)
        var notes: [Note] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let n = Int(sqlite3_column_bytes(stmt, 0))
            guard n > 0, let blob = sqlite3_column_blob(stmt, 0) else { continue }
            let stamp = sqlite3_column_double(stmt, 1)
            if let note = parse(Data(bytes: blob, count: n), stamp: stamp) { notes.append(note) }
        }
        return notes
    }

    /// A notification record's property list: `req` holds the title (chat), subtitle (sender in a group) and body.
    static func parse(_ data: Data, stamp: Double) -> Note? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], // try?-ok: not a notification we can read; skipped
              let req = plist["req"] as? [String: Any] else { return nil }
        let title = (req["titl"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = (req["subt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var body = (req["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !body.isEmpty else { return nil }
        // In a group WeChat often writes "Sender: text" in the body.
        var sender = subtitle
        if sender.isEmpty, let colon = body.firstIndex(of: ":"), body.distance(from: body.startIndex, to: colon) <= 30 {
            let name = String(body[..<colon]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !name.contains(" http") { sender = name; body = String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces) }
        }
        return Note(chat: String(title.prefix(200)), sender: String(sender.prefix(100)), text: String(body.prefix(2000)),
                    at: Date(timeIntervalSince1970: stamp + appleEpoch), stamp: stamp)
    }
}
