import Foundation
import SQLite3
import FloatBoardConnectors
import FloatBoardCore

/// WeChat from macOS's notification history: a made-up notification database in macOS's shape.
@MainActor func wechatChecks() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fb-wx-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: temp cleanup
    do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { check(false, "wechat setup"); return }
    var db: OpaquePointer?
    guard sqlite3_open(dir.appendingPathComponent("db").path, &db) == SQLITE_OK, let db else { check(false, "wechat db"); return }
    sqlite3_exec(db, "CREATE TABLE app(app_id INTEGER PRIMARY KEY, identifier TEXT); CREATE TABLE record(rec_id INTEGER PRIMARY KEY, app_id INTEGER, data BLOB, delivered_date REAL);"
                 + "INSERT INTO app VALUES(1,'com.tencent.xinWeChat'),(2,'com.apple.mail');", nil, nil, nil)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func note(_ app: Int, _ title: String, _ subtitle: String, _ body: String, minutesAgo: Double) {
        let plist: [String: Any] = ["app": "x", "req": ["titl": title, "subt": subtitle, "body": body]]
        let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        var s: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO record(app_id,data,delivered_date) VALUES(?,?,?)", -1, &s, nil)
        sqlite3_bind_int(s, 1, Int32(app))
        _ = data.withUnsafeBytes { sqlite3_bind_blob(s, 2, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        sqlite3_bind_double(s, 3, now.timeIntervalSince1970 - 978_307_200 - minutesAgo * 60)
        sqlite3_step(s); sqlite3_finalize(s)
    }
    note(1, "Anna", "", "Can you send me the deck tonight?", minutesAgo: 30)
    note(1, "Anna", "", "Thanks!", minutesAgo: 20)
    note(1, "School parents", "", "Mrs Lee: Please bring the form on Monday", minutesAgo: 10)
    note(2, "Inbox", "", "Not WeChat", minutesAgo: 5)
    note(1, "Old chat", "", "From last month", minutesAgo: 60 * 24 * 30)
    sqlite3_close(db)

    do {
        let chats = try WeChatNotifications.newChats(folder: dir, cursors: [:], now: now, zone: TimeZone(identifier: "UTC")!)
        let anna = chats.first { $0.name == "Anna" }, school = chats.first { $0.name == "School parents" }
        check(chats.count == 1 && anna?.transcript.components(separatedBy: "\n").count == 2 && anna?.group == false && anna?.muted == true
              && anna?.key.hasPrefix("wx:Anna:") == true && anna?.link == "weixin://", "wechat_notifications_grouped_per_chat_only_wechat_last_7_days")
        check(school == nil, "wechat_group_chats_are_not_sent")
        let again = try WeChatNotifications.newChats(folder: dir, cursors: ["Anna": anna!.newest], now: now)
        check(again.isEmpty, "wechat_nothing_sent_twice")
        check(try WeChatNotifications.recentCount(folder: dir, now: now) == 3, "wechat_recent_count")
    } catch { check(false, "wechat: \(error)") }
    let missing = dir.appendingPathComponent("nope/db2")
    do { _ = try WeChatNotifications.newChats(folder: missing, cursors: [:]) ; check(false, "wechat_missing_folder_is_reported") }
    catch { check(error is WeChatNotifications.ReadError, "wechat_missing_folder_is_reported") }
}

/// Updates: what GitHub's comparison means for this build.
@MainActor func updateChecks() {
    let built = "aaa", head = "bbb"
    check(UpdateCheck.decide(built: "abc", compare: nil, head: "abc") == .upToDate, "update_same_commit_is_up_to_date")
    let ahead: [String: Any] = ["status": "ahead", "ahead_by": 2, "commits": [["commit": ["message": "First change\n\nbody"]], ["commit": ["message": "Second change"]]]]
    check(UpdateCheck.decide(built: built, compare: ahead, head: head) == .available(.init(head: head, count: 2, messages: ["Second change", "First change"])),
          "update_available_lists_changes_newest_first")
    if case .unknown = UpdateCheck.decide(built: built, compare: nil, head: head) { check(true, "update_unknown_when_build_is_not_on_github") }
    else { check(false, "update_unknown_when_build_is_not_on_github") }
    if case .unknown = UpdateCheck.decide(built: built, compare: ["status": "diverged"], head: head) { check(true, "update_refused_when_build_has_local_commits") }
    else { check(false, "update_refused_when_build_has_local_commits") }
    if case .unknown = UpdateCheck.decide(built: "", compare: nil, head: head) { check(true, "update_unknown_without_a_build_commit") }
    else { check(false, "update_unknown_without_a_build_commit") }
}
