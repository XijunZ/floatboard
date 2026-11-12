import CryptoKit
import FloatBoardCore
import Foundation

/// "Archive old data to this Mac" (Connectors tab): moves an engine's old change log and old email task records into a
/// file on this Mac, then has the engine delete exactly those rows (docs/phone-app.md, last section).
///
/// One run: page `GET /v2/archive` until the cursor ends (nothing is written if any page fails); append the run's
/// canonical lines to `archives/engine-<connector>-<yyyy-MM-dd>.jsonl` and fsync; read the file back and check that
/// its last bytes are exactly the run's lines; then `POST /v2/archive/confirm` with the counts and the SHA-256 of those
/// bytes. The engine deletes only when both match. Runs repeat (the engine hands over at most 2,000 rows per run) until
/// one comes back empty. On any failure the engine keeps its data (or, for a run already confirmed, the file has it) and
/// the file is kept.
///
/// Canonical form (the same as the engine's `canonLine`, src/archive.ts): `{"row":{...},"table":"board_log"|"items"}`,
/// keys sorted, no spaces, values text / whole numbers / null; in text only `"`, `\` and control characters are escaped
/// (`\b \f \n \r \t`, else `\u00xx`); one line per row, each ending in "\n".
public enum EngineArchive {
    public static let cutOffChoices = [3, 6, 12]
    public static let defaultMonths = 6
    /// The engine never archives items newer than 90 days; the shortest cut-off stays clear of that line.
    static let minimumDays: TimeInterval = 92
    static let maxRuns = 50
    static let maxPagesPerRun = 20
    public static let limitBytes = 500_000_000
    public static let warnBytes = 250_000_000

    public struct ArchiveError: Error, CustomStringConvertible {
        public let description: String
        init(_ d: String) { description = d }
    }

    /// What one press of Archive did.
    public struct Outcome: Equatable {
        /// Rows saved to the file AND removed from the engine.
        public var saved = 0
        public var file: URL?
        /// Why it stopped early (nil when it finished). Always says what happened to the engine's data and the file.
        public var problem: String?
        public init(saved: Int = 0, file: URL? = nil, problem: String? = nil) { self.saved = saved; self.file = file; self.problem = problem }

        /// One line for the sheet.
        public var message: String {
            let done = saved > 0 && file != nil ? EngineArchive.savedMessage(saved, file: file!) : ""
            if let problem { return done.isEmpty ? problem : done + " Then: " + problem }
            return done.isEmpty ? "Nothing older than the cut-off to archive." : done
        }
    }

    // MARK: Texts

    private static let countFormat: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        return f
    }()

    /// 1,234 (the archive's texts use English digit grouping).
    public static func count(_ n: Int) -> String { countFormat.string(from: NSNumber(value: n)) ?? String(n) }

    public static func savedMessage(_ n: Int, file: URL) -> String {
        "Saved \(count(n)) \(n == 1 ? "entry" : "entries") to \(file.lastPathComponent); removed from the engine."
    }

    static func mb(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_000_000) }

    /// "Engine database: 1.4 MB of 500 MB".
    public static func sizeText(_ bytes: Int) -> String { "Engine database: \(mb(bytes)) of \(limitBytes / 1_000_000) MB" }
    public static func isLarge(_ bytes: Int) -> Bool { bytes > warnBytes }

    // MARK: Cut-off and file

    /// `months` back from now (calendar months), and never less than 92 days back.
    public static func cutOff(months: Int, now: Date) -> Date {
        let back = Calendar(identifier: .gregorian).date(byAdding: .month, value: -months, to: now) ?? now
        return min(back, now.addingTimeInterval(-minimumDays * 86400))
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func fileURL(dir: URL, connector: String, now: Date) -> URL {
        let safe = String(connector.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "-" })
        return dir.appendingPathComponent("engine-\(safe.isEmpty ? "connector" : safe)-\(dayFormat.string(from: now)).jsonl")
    }

    // MARK: Canonical form

    /// One line of the archive file (without its "\n"); throws on a value the engine never sends (a fraction, true/false,
    /// a list or an object).
    public static func canonLine(table: String, row: [String: Any]) throws -> String {
        var out = #"{"row":{"#
        let keys = row.keys.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
        for (i, k) in keys.enumerated() {
            if i > 0 { out += "," }
            out += quote(k) + ":" + (try value(row[k]!, key: k))
        }
        return out + #"},"table":"# + quote(table) + "}"
    }

    private static func value(_ v: Any, key: String) throws -> String {
        switch v {
        case is NSNull: return "null"
        case let s as String: return quote(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { throw ArchiveError("\(key) is true/false, which the archive never holds") }
            let d = n.doubleValue
            guard d == d.rounded(), abs(d) <= 9_007_199_254_740_991 else { throw ArchiveError("\(key) is not a whole number") }
            return String(n.int64Value)
        case let i as Int: return String(i)
        default: throw ArchiveError("\(key) has a value the archive never holds")
        }
    }

    /// A JSON string as JavaScript's JSON.stringify writes it.
    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0..<0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Run

    /// Archives everything older than `before`, run after run. `progress` gets the rows handled so far.
    public static func run(client: ConnectorClient, connector: String, before: Date, dir: URL, now: Date = Date(),
                           progress: @escaping (Int) -> Void = { _ in }) async -> Outcome {
        var out = Outcome()
        let beforeISO = PhoneBoard.isoUTC(before)
        let file = fileURL(dir: dir, connector: connector, now: now)
        for _ in 0..<maxRuns {
            // 1. Read the whole run. Nothing is written or deleted if any page fails.
            var rows: [(table: String, row: [String: Any])] = []
            var cursor: String?
            var pages = 0
            do {
                repeat {
                    let page = try await client.archivePage(before: beforeISO, cursor: cursor)
                    rows += page.rows
                    cursor = page.cursor
                    pages += 1
                    progress(out.saved + rows.count)
                } while cursor != nil && pages < maxPagesPerRun
                if cursor != nil { throw ArchiveError("the engine kept sending pages") }
            } catch {
                out.problem = "Couldn't read the old data from the engine: \(why(error)). Nothing was removed from the engine."
                return out
            }
            if rows.isEmpty { return out }

            // 2. The run's lines, exactly as the engine hashes them.
            let data: Data
            do {
                data = Data(try rows.map { try canonLine(table: $0.table, row: $0.row) + "\n" }.joined().utf8)
            } catch {
                out.problem = "The engine sent data this Mac can't archive (\(why(error))). Nothing was removed from the engine."
                return out
            }

            // 3. Write, fsync, read back.
            do { try appendVerified(data, to: file) } catch {
                out.problem = "Couldn't save the file \(file.lastPathComponent): \(why(error)). Nothing was removed from the engine."
                    + (FileManager.default.fileExists(atPath: file.path) ? " The file is kept in \(file.deletingLastPathComponent().path)." : "")
                return out
            }

            // 4. Only now ask the engine to delete exactly these rows.
            let logCount = rows.filter { $0.table == "board_log" }.count
            do {
                try await client.confirmArchive(before: beforeISO, boardLog: logCount, items: rows.count - logCount, sha256: sha256Hex(data))
            } catch ConnectorError.http(409, _) {
                out.problem = "The engine's data changed while archiving, so nothing was removed from it this time. The saved copy is kept in \(file.lastPathComponent); try again."
                return out
            } catch {
                out.problem = "Couldn't confirm with the engine: \(why(error)). The saved copy is kept in \(file.lastPathComponent); if the engine didn't get the confirmation, its data is still there."
                return out
            }
            out.saved += rows.count
            out.file = file
            progress(out.saved)
        }
        out.problem = "Stopped after \(maxRuns) rounds; press Archive again to continue."
        return out
    }

    private static func why(_ error: Error) -> String {
        if case ConnectorError.http(404, _) = error { return "this engine can't archive yet. Update the engine first" }
        return (error as? ConnectorError)?.description ?? "\(error)"
    }

    /// Appends `data` to `file` (owner read/write only), forces it to disk, reads the file back and checks that it ends
    /// with exactly `data`. A file whose last line was cut off gets a line break first.
    static func appendVerified(_ data: Data, to file: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: file.path) {
            guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw ArchiveError("the file could not be created")
            }
        }
        let h = try FileHandle(forUpdating: file)
        let start: UInt64
        do {
            var end = try h.seekToEnd()
            if end > 0 {
                try h.seek(toOffset: end - 1)
                if try h.read(upToCount: 1) != Data("\n".utf8) {
                    try h.seekToEnd()
                    try h.write(contentsOf: Data("\n".utf8))
                    end += 1
                }
            }
            start = end
            try h.seekToEnd()
            try h.write(contentsOf: data)
            try h.synchronize()
            try h.close()
        } catch {
            do { try h.close() } catch { /* already reporting the first problem */ }
            throw error
        }
        let back = try Data(contentsOf: file, options: .uncached)
        guard back.count == Int(start) + data.count, back.suffix(data.count) == data,
              sha256Hex(back.suffix(data.count)) == sha256Hex(data) else {
            throw ArchiveError("the file didn't read back the same")
        }
    }
}
