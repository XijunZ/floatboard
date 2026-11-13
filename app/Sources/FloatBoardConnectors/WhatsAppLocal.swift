import Foundation
import SQLite3

/// Reads the person's unread WhatsApp messages from WhatsApp Desktop's own copy on this Mac (`ChatStorage.sqlite`).
/// Nothing here talks to WhatsApp or touches the WhatsApp app: the files are copied to a private temporary folder and
/// read there, so WhatsApp's own database is never opened or locked.
///
/// The free rules (no Claude, nothing leaves the Mac) are applied here:
/// - only one-to-one and group chats with unread messages; muted, archived, hidden or removed chats are never read;
///   status updates, broadcast lists and channels are never read;
/// - only messages newer than the last send for that chat (`cursors`), from the last 7 days, at most 30 per chat;
/// - messages with no words (stickers, reactions, emoji only, "ok", "thanks") are dropped, and a chat with nothing
///   left is not sent; a chat whose newest message is the person's own (they answered) is not sent.
public enum WhatsAppLocal {
    /// WhatsApp Desktop's shared container (the Mac App Store and direct-download apps both use it).
    public static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp.shared", isDirectory: true)
    }
    static let file = "ChatStorage.sqlite"
    /// Core Data dates count seconds from 2001-01-01.
    static let appleEpoch: TimeInterval = 978_307_200
    public static let maxPerChat = 30
    public static let lookback: TimeInterval = 7 * 86_400
    static let maxTranscript = 8000

    public struct Chat: Equatable, Sendable {
        /// "wa:<chat id>:<newest message id>": the engine stores each once.
        public let key: String
        /// WhatsApp's chat id (phone@s.whatsapp.net, id@g.us, ...); the cursor is kept per chat id.
        public let chatID: String
        public let name: String
        public let group: Bool
        public let senders: [String]
        /// "[2026-11-13 09:12] Anna: text" lines, oldest first; context lines start with "(earlier)".
        public let transcript: String
        /// Opens the chat in WhatsApp (one-to-one with a phone number), else WhatsApp itself.
        public let link: String
        public let received: Date
        /// The newest message's date in WhatsApp's own clock (the next cursor for this chat).
        public let newest: Double
    }

    public enum ReadError: Error, Equatable, CustomStringConvertible {
        case notInstalled
        case noAccess
        case unreadable(String)
        public var description: String {
            switch self {
            case .notInstalled: return "WhatsApp Desktop isn't set up on this Mac (no message database). Install it and sign in."
            case .noAccess: return "FloatBoard isn't allowed to read WhatsApp's data. Allow it in System Settings › Privacy & Security › Full Disk Access."
            case .unreadable(let why): return "WhatsApp's message database couldn't be read (\(why)). A WhatsApp update may have changed it."
            }
        }
    }

    /// Unread chats to screen, oldest newest-message first. `cursors`: chat id -> newest message date already sent.
    public static func unreadChats(folder: URL = folder, cursors: [String: Double], now: Date = Date(),
                                   zone: TimeZone = .current) throws -> [Chat] {
        let fm = FileManager.default
        let src = folder.appendingPathComponent(file)
        guard fm.fileExists(atPath: folder.path) else { throw ReadError.notInstalled }
        guard fm.isReadableFile(atPath: src.path) else {
            throw fm.fileExists(atPath: src.path) ? ReadError.noAccess : ReadError.notInstalled
        }
        let tmp = fm.temporaryDirectory.appendingPathComponent("fb-wa-\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: tmp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { throw ReadError.unreadable("no temporary folder: \(error.localizedDescription)") }
        defer { try? fm.removeItem(at: tmp) } // try?-ok: a leftover temp folder is cleaned by macOS
        for suffix in ["", "-wal", "-shm"] {
            let from = folder.appendingPathComponent(file + suffix)
            guard suffix.isEmpty || fm.fileExists(atPath: from.path) else { continue }
            do { try fm.copyItem(at: from, to: tmp.appendingPathComponent(file + suffix)) }
            catch {
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
        return try read(db, cursors: cursors, now: now, zone: zone)
    }

    private static func read(_ db: OpaquePointer, cursors: [String: Double], now: Date, zone: TimeZone) throws -> [Chat] {
        let nowApple = now.timeIntervalSince1970 - appleEpoch
        let chats = try rows(db, """
            SELECT s.Z_PK, s.ZCONTACTJID, COALESCE(s.ZPARTNERNAME,''), s.ZSESSIONTYPE, s.ZUNREADCOUNT
            FROM ZWACHATSESSION s LEFT JOIN ZWACHATPUSHCONFIG p ON p.ZJID = s.ZCONTACTJID
            WHERE s.ZUNREADCOUNT > 0 AND s.ZSESSIONTYPE IN (0,1)
              AND COALESCE(s.ZARCHIVED,0)=0 AND COALESCE(s.ZREMOVED,0)=0 AND COALESCE(s.ZHIDDEN,0)=0
              AND COALESCE(p.ZMUTEDUNTIL,0) <= ?
              AND s.ZCONTACTJID IS NOT NULL AND s.ZCONTACTJID NOT LIKE '%status' AND s.ZCONTACTJID NOT LIKE '%@broadcast'
              AND s.ZCONTACTJID NOT LIKE '%@newsletter'
            """, [.double(nowApple)])
        var out: [Chat] = []
        for c in chats {
            guard let pk = c[0].int, let jid = c[1].text else { continue }
            let partner = c[2].text ?? "", group = c[3].int == 1, unread = max(0, c[4].int ?? 0)
            let msgs = try rows(db, """
                SELECT m.ZISFROMME, m.ZMESSAGETYPE, COALESCE(m.ZTEXT,''), m.ZMESSAGEDATE, COALESCE(m.ZSTANZAID,''),
                       COALESCE(NULLIF(gm.ZCONTACTNAME,''), NULLIF(gm.ZFIRSTNAME,''), NULLIF(CAST(m.ZPUSHNAME AS TEXT),''), ''),
                       COALESCE(mi.ZTITLE,'')
                FROM ZWAMESSAGE m LEFT JOIN ZWAGROUPMEMBER gm ON gm.Z_PK = m.ZGROUPMEMBER
                LEFT JOIN ZWAMEDIAITEM mi ON mi.Z_PK = m.ZMEDIAITEM
                WHERE m.ZCHATSESSION = ? ORDER BY m.ZMESSAGEDATE DESC, m.Z_PK DESC LIMIT ?
                """, [.int(pk), .int(min(unread, maxPerChat) + 3)]).reversed().map(Msg.init)
            guard let newest = msgs.last, !newest.fromMe else { continue } // answered (or nothing): not sent
            let since = max(cursors[jid] ?? -.infinity, nowApple - lookback)
            let unreadMsgs = Array(msgs.suffix(min(unread, maxPerChat)))
            let fresh = unreadMsgs.filter { !$0.fromMe && $0.date > since }
            let worded = fresh.compactMap { m -> (Msg, String)? in body(m).map { (m, $0) } }
            guard !worded.isEmpty, let last = fresh.last else { continue }
            let firstFresh = fresh.first!.date
            let earlier = msgs.filter { $0.date < firstFresh }.suffix(3)
            let nameOf = { (m: Msg) -> String in m.fromMe ? "You" : (group ? (m.sender.isEmpty ? "Someone" : m.sender) : (partner.isEmpty ? "Them" : partner)) }
            var lines = earlier.compactMap { m in body(m).map { "(earlier) [\(stamp(m.date, zone))] \(nameOf(m)): \($0)" } }
            lines += worded.map { "[\(stamp($0.0.date, zone))] \(nameOf($0.0)): \($0.1)" }
            var transcript = lines.joined(separator: "\n")
            while transcript.count > maxTranscript, lines.count > 1 { lines.removeFirst(); transcript = lines.joined(separator: "\n") }
            if transcript.count > maxTranscript { transcript = String(transcript.suffix(maxTranscript)) }
            var senders: [String] = []
            for (m, _) in worded where !senders.contains(nameOf(m)) { senders.append(nameOf(m)) }
            out.append(Chat(key: "wa:\(jid):\(last.stanza.isEmpty ? String(Int(last.date)) : last.stanza)", chatID: jid,
                            name: group ? (partner.isEmpty ? "Group" : partner) : (partner.isEmpty ? phoneOf(jid) ?? "Unknown" : partner),
                            group: group, senders: senders, transcript: transcript, link: link(jid),
                            received: Date(timeIntervalSince1970: last.date + appleEpoch), newest: last.date))
        }
        return out.sorted { $0.newest < $1.newest }
    }

    struct Msg {
        let fromMe: Bool, type: Int, text: String, date: Double, stanza: String, sender: String, caption: String
        init(_ r: [Value]) {
            fromMe = r[0].int == 1; type = r[1].int ?? 0; text = r[2].text ?? ""; date = r[3].double ?? 0
            stanza = r[4].text ?? ""; sender = r[5].text ?? ""; caption = r[6].text ?? ""
        }
    }

    /// Words that on their own never need an action.
    static let filler: Set<String> = ["ok", "okay", "k", "kk", "thanks", "thank you", "thanks!", "thx", "ty", "lol", "haha", "hahaha",
                                      "hehe", "nice", "cool", "great", "sure", "np", "no problem", "好", "好的", "谢谢", "嗯", "哈哈", "哈哈哈"]

    /// What a message says, or nil when it has no words worth reading (system lines, calls, deleted, stickers, emoji only).
    static func body(_ m: Msg) -> String? {
        let media: String?
        switch m.type {
        case 0, 7: media = nil
        case 1: media = "[photo]"
        case 2: media = "[video]"
        case 3: media = "[voice note]"
        case 4: media = "[contact card]"
        case 5: media = "[location]"
        case 8: media = "[document\(m.caption.isEmpty ? "" : ": \(m.caption)")]"
        case 6, 10, 14, 15, 11: return nil // group events, calls, deleted, stickers, GIFs
        default: media = nil
        }
        let text = (m.text.isEmpty && m.type != 8 ? m.caption : m.text).trimmingCharacters(in: .whitespacesAndNewlines)
        if media == nil {
            guard text.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return nil }
            if filler.contains(text.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))) { return nil }
            return String(text.prefix(1500))
        }
        // Media only counts with words (a caption): a bare photo or voice note can't be judged.
        guard m.type == 8 || text.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return nil }
        return text.isEmpty ? media : "\(media!) \(text.prefix(1500))"
    }

    static func phoneOf(_ jid: String) -> String? {
        guard jid.hasSuffix("@s.whatsapp.net") else { return nil }
        let d = String(jid.prefix { $0 != "@" })
        return d.count >= 5 && d.count <= 20 && d.allSatisfy(\.isNumber) ? d : nil
    }

    static func link(_ jid: String) -> String { phoneOf(jid).map { "whatsapp://send?phone=\($0)" } ?? "whatsapp://" }

    static func stamp(_ appleDate: Double, _ zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = zone; f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: appleDate + appleEpoch))
    }

    // MARK: SQLite

    enum Value {
        case int(Int), double(Double), text(String), null
        var int: Int? { if case .int(let v) = self { return v }; if case .double(let v) = self { return Int(v) }; return nil }
        var double: Double? { if case .double(let v) = self { return v }; if case .int(let v) = self { return Double(v) }; return nil }
        var text: String? { if case .text(let v) = self { return v }; return nil }
    }

    private static func rows(_ db: OpaquePointer, _ sql: String, _ args: [Value]) throws -> [[Value]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ReadError.unreadable(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .int(let v): sqlite3_bind_int64(stmt, idx, Int64(v))
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, transient)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        var out: [[Value]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw ReadError.unreadable(String(cString: sqlite3_errmsg(db))) }
            out.append((0..<sqlite3_column_count(stmt)).map { i in
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: return .int(Int(sqlite3_column_int64(stmt, i)))
                case SQLITE_FLOAT: return .double(sqlite3_column_double(stmt, i))
                case SQLITE_NULL: return .null
                default: return sqlite3_column_text(stmt, i).map { .text(String(cString: $0)) } ?? .null
                }
            })
        }
        return out
    }
}
