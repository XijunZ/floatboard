import Foundation
import FloatBoardCore
import FloatBoardConnectors

/// An engine that can archive: old rows served in pages (`pageSize`), at most `runCap` rows per run, deleted only by a
/// confirm whose counts and SHA-256 match (as the real engine does, docs/phone-app.md, last section).
private final class ArchiveEngine {
    var log: [[String: Any]] = []
    var items: [[String: Any]] = []
    var pageSize = 2
    var runCap = 3
    var pageStatus: [Int: Int] = [:]      // page number (1-based, counted over the whole check) -> HTTP status
    var confirmStatus: Int?               // force an answer to confirm
    var getStatus: Int?                   // force an answer to every GET
    var pagesServed = 0
    var confirms: [[String: Any]] = []
    var befores: Set<String> = []
    /// What the archive file held when each confirm arrived (the Mac must have written it first).
    var fileAtConfirm: [Data] = []
    var archiveFile: URL?

    /// The current run: board log first, then items, at most `runCap`.
    func run() -> [(table: String, row: [String: Any])] {
        Array((log.map { ("board_log", $0) } + items.map { ("items", $0) }).prefix(runCap)).map { (table: $0.0, row: $0.1) }
    }

    func client() -> ConnectorClient {
        ConnectorClient(baseURL: URL(string: "https://engine.test")!, key: "k1") { [self] req in
            let url = req.url!
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func answer(_ code: Int, _ obj: Any) throws -> (Data, HTTPURLResponse) {
                (try JSONSerialization.data(withJSONObject: obj), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
            }
            guard req.value(forHTTPHeaderField: "Authorization") == "Bearer k1" else { return try answer(401, ["error": "unauthorized"]) }
            switch (req.httpMethod ?? "GET", url.path) {
            case ("GET", "/v2/archive"):
                if let s = getStatus { return try answer(s, ["error": "nope"]) }
                pagesServed += 1
                if let s = pageStatus[pagesServed] { return try answer(s, ["error": "boom"]) }
                befores.insert(q.first { $0.name == "before" }?.value ?? "")
                let start = Int(q.first { $0.name == "cursor" }?.value ?? "0") ?? 0
                let all = run()
                let page = Array(all.dropFirst(start).prefix(pageSize))
                let next = start + page.count < all.count ? String(start + page.count) : nil
                return try answer(200, ["rows": ["board_log": page.filter { $0.table == "board_log" }.map(\.row),
                                                 "items": page.filter { $0.table == "items" }.map(\.row)],
                                        "cursor": next.map { $0 as Any } ?? NSNull()])
            case ("POST", "/v2/archive/confirm"):
                let body = (try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]) ?? [:]
                confirms.append(body)
                fileAtConfirm.append(archiveFile.flatMap { FileManager.default.contents(atPath: $0.path) } ?? Data())
                if let s = confirmStatus { return try answer(s, ["error": "changed"]) }
                let all = run()
                let text = try all.map { try EngineArchive.canonLine(table: $0.table, row: $0.row) + "\n" }.joined()
                let counts = body["counts"] as? [String: Any]
                guard counts?["board_log"] as? Int == all.filter({ $0.table == "board_log" }).count,
                      counts?["items"] as? Int == all.filter({ $0.table == "items" }).count,
                      body["sha256"] as? String == EngineArchive.sha256Hex(Data(text.utf8)) else { return try answer(409, ["error": "mismatch"]) }
                let ids = Set(all.map { $0.row["id"] as? String ?? "" })
                log.removeAll { ids.contains($0["id"] as? String ?? "") }
                items.removeAll { ids.contains($0["id"] as? String ?? "") }
                return try answer(200, ["ok": true])
            default: return try answer(404, ["error": "not found"])
            }
        }
    }

    func seed(log n: Int, items m: Int) {
        log = (0..<n).map { ["id": "log-\($0)", "device": "mac", "card_id": $0, "kind": "status", "value": "done",
                             "made_at": "2026-01-01T00:00:00.000Z", "received_at": "2026-01-01T00:00:00.000Z", "client_id": NSNull()] }
        items = (0..<m).map { ["id": "item-\($0)", "kind": "action", "title": "Reply \"now\"\n任务", "message_id": "<m\($0)@x>", "has_time": 0,
                               "link": NSNull(), "created": "2026-01-01T00:00:00.000Z"] }
    }
}

@MainActor func archiveChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-archive-\(UUID().uuidString)")
    defer { _ = Backups.removeReporting(root) }
    let now = Date()
    let day: TimeInterval = 86400

    // archive_canonical_lines_match_the_engine: the same rows and golden hash as the engine test
    // (connectors/email/test/archive.test.ts, canonical_lines_match_the_documented_golden_hash).
    do {
        let a = try EngineArchive.canonLine(table: "board_log", row: [
            "id": "a1", "device": "mac", "card_id": 7, "kind": "add",
            "value": "Quote \" back\\ slash / tab\t nl\n ctl\u{01} del\u{7f} 任务 😀 \u{2028}",
            "made_at": "2026-01-01T00:00:00.000Z", "received_at": "2026-01-01T00:00:01.000Z", "client_id": NSNull()])
        let b = try EngineArchive.canonLine(table: "items", row: ["id": "i1", "importance": -2, "title": "Ünïcode é", "link": NSNull(), "has_time": 0])
        // Decoded from the engine's JSON as the client sees it (numbers as NSNumber, null as NSNull).
        let parsed = try JSONSerialization.jsonObject(with: Data(#"{"title":"Ünïcode é","id":"i1","importance":-2,"link":null,"has_time":0}"#.utf8)) as? [String: Any] ?? [:]
        let fromJSON = try EngineArchive.canonLine(table: "items", row: parsed)
        // The engine's own line, parsed as the client parses a page (escapes, CJK, emoji, U+2028), gives the same line back.
        let aRow = (try JSONSerialization.jsonObject(with: Data(a.utf8)) as? [String: Any])?["row"] as? [String: Any] ?? [:]
        let aAgain = try EngineArchive.canonLine(table: "board_log", row: aRow)
        check(aAgain == a, "archive_canonical_line_survives_a_json_round_trip")
        check(b == #"{"row":{"has_time":0,"id":"i1","importance":-2,"link":null,"title":"Ünïcode é"},"table":"items"}"#
              && fromJSON == b
              && EngineArchive.sha256Hex(Data((a + "\n" + b + "\n").utf8)) == "9d19ea473cc84d0959011f59a837c17bd02e9724cf1049f3fc52117870682f80",
              "archive_canonical_lines_match_the_engine")
        var refused = false
        do { _ = try EngineArchive.canonLine(table: "items", row: ["x": 1.5]) } catch { refused = true }
        var refusedBool = false
        do { _ = try EngineArchive.canonLine(table: "items", row: ["x": true]) } catch { refusedBool = true }
        check(refused && refusedBool, "archive_canonical_form_refuses_values_the_engine_never_sends")
    } catch { check(false, "archive_canonical_lines_match_the_engine: \(error)") }

    // archive_cut_off: 3, 6 or 12 months; never less than 92 days, so items newer than 90 days are never asked for.
    let three = EngineArchive.cutOff(months: 3, now: now), six = EngineArchive.cutOff(months: 6, now: now)
    check(EngineArchive.cutOffChoices == [3, 6, 12] && EngineArchive.defaultMonths == 6
          && three <= now.addingTimeInterval(-92 * day) && six <= now.addingTimeInterval(-180 * day) && six >= now.addingTimeInterval(-185 * day),
          "archive_cut_off_choices_and_minimum")

    // The archive folder sits beside the backups folder (FLOATBOARD_BACKUPS is set for checks).
    check(LocalData.archives == LocalData.backups?.deletingLastPathComponent().appendingPathComponent("archives", isDirectory: true)
          && LocalData.archives != nil, "archive_folder_beside_backups")

    // Engine database size from status.
    do {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/v2-status.example.json")
        let st = try JSONDecoder().decode(ConnectorStatus.self, from: Data(contentsOf: fixture))
        let old = try JSONDecoder().decode(ConnectorStatus.self, from: Data(#"{"settings_version":1}"#.utf8))
        let roundTrip = try JSONDecoder().decode(ConnectorStatus.self, from: JSONEncoder().encode(st))
        check(st.dbSizeBytes == 1_400_000 && old.dbSizeBytes == nil && roundTrip.dbSizeBytes == 1_400_000, "status_carries_engine_database_size")
    } catch { check(false, "status_carries_engine_database_size: \(error)") }
    check(EngineArchive.sizeText(1_400_000) == "Engine database: 1.4 MB of 500 MB" && EngineArchive.sizeText(260_000_000) == "Engine database: 260.0 MB of 500 MB"
          && !EngineArchive.isLarge(1_400_000) && EngineArchive.isLarge(260_000_000), "engine_database_size_text")
    check(EngineArchive.savedMessage(1234, file: URL(fileURLWithPath: "/x/engine-email-2026-11-12.jsonl"))
          == "Saved 1,234 entries to engine-email-2026-11-12.jsonl; removed from the engine.", "archive_result_message")

    // archive_writes_the_file_then_confirms: pages, runs of at most runCap rows, until nothing is left.
    do {
        let dir = root.appendingPathComponent("ok/archives")
        let e = ArchiveEngine()
        e.seed(log: 3, items: 2)
        e.archiveFile = EngineArchive.fileURL(dir: dir, connector: "email", now: now)
        var progress: [Int] = []
        let out = await EngineArchive.run(client: e.client(), connector: "email", before: six, dir: dir, now: now) { progress.append($0) }
        let text = (try? String(contentsOf: e.archiveFile!, encoding: .utf8)) ?? "" // try?-ok: an unreadable file fails the check
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let run1 = lines.prefix(3).map { $0 + "\n" }.joined()
        check(out.problem == nil && out.saved == 5 && out.file == e.archiveFile && e.log.isEmpty && e.items.isEmpty
              && lines.count == 6 && lines.last == "" && text.hasSuffix("\n")
              && e.confirms.count == 2 && e.befores == [PhoneBoard.isoUTC(six)]
              && (e.confirms[0]["counts"] as? [String: Int]) == ["board_log": 3, "items": 0]
              && (e.confirms[1]["counts"] as? [String: Int]) == ["board_log": 0, "items": 2]
              && e.confirms[0]["sha256"] as? String == EngineArchive.sha256Hex(Data(run1.utf8))
              && e.confirms[0]["before"] as? String == PhoneBoard.isoUTC(six)
              && String(decoding: e.fileAtConfirm[0], as: UTF8.self) == run1
              && e.fileAtConfirm[1].count == Data(text.utf8).count
              && progress.last == 5 && out.message == EngineArchive.savedMessage(5, file: e.archiveFile!),
              "archive_writes_the_file_then_confirms")
        let attrs = try? FileManager.default.attributesOfItem(atPath: e.archiveFile!.path) // try?-ok: missing attributes fail the check
        check((attrs?[.posixPermissions] as? Int) == 0o600, "archive_file_is_private")
        // A later archive the same day appends to the same file.
        e.seed(log: 1, items: 0)
        let again = await EngineArchive.run(client: e.client(), connector: "email", before: six, dir: dir, now: now)
        let text2 = (try? String(contentsOf: e.archiveFile!, encoding: .utf8)) ?? "" // try?-ok: an unreadable file fails the check
        check(again.saved == 1 && text2.hasPrefix(text) && text2.split(separator: "\n").count == 6, "archive_same_day_appends")
        // Nothing old: no file change, no confirm.
        let confirms = e.confirms.count
        let none = await EngineArchive.run(client: e.client(), connector: "email", before: six, dir: dir, now: now)
        check(none.saved == 0 && none.problem == nil && e.confirms.count == confirms && none.message == "Nothing older than the cut-off to archive.",
              "archive_with_nothing_old_confirms_nothing")
    }

    // archive_failure_mid_way_deletes_nothing: the second page fails, so nothing is written or confirmed.
    do {
        let dir = root.appendingPathComponent("mid/archives")
        let e = ArchiveEngine()
        e.seed(log: 3, items: 0)
        e.pageStatus = [2: 500]
        let out = await EngineArchive.run(client: e.client(), connector: "email", before: six, dir: dir, now: now)
        check(out.saved == 0 && (out.problem ?? "").contains("Nothing was removed from the engine") && e.confirms.isEmpty && e.log.count == 3,
              "archive_failure_mid_way_deletes_nothing")
    }

    // A mismatch (the engine's data changed): the engine keeps its rows, the Mac keeps the file and says so.
    do {
        let dir = root.appendingPathComponent("mismatch/archives")
        let e = ArchiveEngine()
        e.seed(log: 2, items: 0)
        e.confirmStatus = 409
        let out = await EngineArchive.run(client: e.client(), connector: "email", before: six, dir: dir, now: now)
        let file = EngineArchive.fileURL(dir: dir, connector: "email", now: now)
        let kept = (try? String(contentsOf: file, encoding: .utf8))?.split(separator: "\n").count ?? 0 // try?-ok: a missing file fails the check
        check(out.saved == 0 && e.log.count == 2 && kept == 2 && e.confirms.count == 1
              && (out.problem ?? "").contains("nothing was removed") && (out.problem ?? "").contains(file.lastPathComponent),
              "archive_mismatch_keeps_engine_data_and_the_file")
    }

    // The folder can't be written: nothing is confirmed.
    do {
        let blocker = root.appendingPathComponent("blocked")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: check setup
        FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8))
        let e = ArchiveEngine()
        e.seed(log: 2, items: 0)
        let out = await EngineArchive.run(client: e.client(), connector: "email", before: six, dir: blocker.appendingPathComponent("archives"), now: now)
        check(out.saved == 0 && e.confirms.isEmpty && e.log.count == 2 && (out.problem ?? "").contains("Couldn't save"),
              "archive_unwritable_folder_confirms_nothing")
    }

    // An engine without the archive (404) says to update it.
    do {
        let e = ArchiveEngine()
        e.getStatus = 404
        let out = await EngineArchive.run(client: e.client(), connector: "email", before: six, dir: root.appendingPathComponent("old/archives"), now: now)
        check(out.saved == 0 && (out.problem ?? "").contains("Update the engine"), "archive_on_old_engine_says_update")
    }
}
