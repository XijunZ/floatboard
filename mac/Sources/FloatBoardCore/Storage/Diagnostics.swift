import Foundation

/// A support dump that is safe to paste anywhere: no keys, tokens, full URLs, email text or card titles.
@MainActor
public enum Diagnostics {
    static let detailLimit = 300

    public static func json(store: Store, backups: Backups?, appVersion: String, now: Date = Date()) -> String {
        let iso = ISO8601DateFormatter()
        func date(_ d: Date?) -> Any { d.map { iso.string(from: $0) } ?? NSNull() }
        let scrub = scrubber(store)

        var connectors: [[String: Any]] = []
        do {
            for c in try store.loadConnectors() {
                var lines: [String] = []
                if let data = c.statusJSON.data(using: .utf8),
                   let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { // try?-ok: unreadable status just has no lines
                    lines = ((o["needs_attention"] as? [String]) ?? []).map { scrub(Redact.attention($0)) }
                }
                connectors.append(["id": c.id, "host": URL(string: c.baseURL)?.host ?? "", "last_ok": date(c.lastOK),
                                   "unreachable_since": date(c.unreachableSince), "settings_version": c.settingsVersion,
                                   "engine_settings_version": c.engineSettingsVersion,
                                   "waiting": store.waitingCount(connector: c.id), "needs_attention": lines])
            }
        } catch {
            store.activity("diagnostics", .error, "Could not read connectors for the diagnostics", detail: "\(error)")
        }

        let problems = Health.evaluate(store: store, backups: backups, now: now).map {
            ["id": scrub($0.id), "message": scrub($0.message), "since": iso.string(from: $0.since)]
        }
        let rows: [[String: Any]] = store.recentActivity(limit: 200).map { e in
            let full = scrub(e.detail ?? "")
            let d = full.count > detailLimit ? String(full.prefix(detailLimit)) + "…" : full
            return ["at": iso.string(from: e.at), "component": scrub(e.component), "level": e.level.rawValue,
                    "message": scrub(e.message), "detail": d, "trace": e.trace ?? "", "seen": e.seen]
        }
        let doc: [String: Any] = ["app_version": appVersion, "schema_version": DB.schemaVersion, "generated": iso.string(from: now),
                                  "connectors": connectors, "problems": problems, "activity": rows]
        do {
            return String(decoding: try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
        } catch {
            store.activity("diagnostics", .error, "Could not build the diagnostics", detail: "\(error)")
            return "{\"error\":\"could not build diagnostics\"}"
        }
    }

    private static let patterns: [(NSRegularExpression, String)] = [
        (#"(?i)bearer\s+\S+"#, "Bearer [hidden]"),
        (#"([A-Za-z][A-Za-z0-9+.-]*://)(?:[^/@\s]*@)?([^/:?#\s]+)(?::\d+)?[^\s]*"#, "$1$2"),
        (Redact.emailPattern, "<email>"),
    ].compactMap { pattern, repl in
        do { return (try NSRegularExpression(pattern: pattern), repl) } catch {
            FileHandle.standardError.write(Data("FloatBoard: diagnostics redaction rule failed to compile: \(error)\n".utf8))
            return nil
        }
    }

    /// Removes URL paths/userinfo/queries (-> scheme://host), bearer tokens and email addresses. Card titles are never written
    /// to Activity in the first place, so nothing needs hunting for here; trace ids (UUIDs) are kept on purpose.
    static func scrubber(_ store: Store) -> (String) -> String {
        return { text in
            var s = text
            for (re, repl) in patterns { s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: repl) }
            return s
        }
    }
}

/// Redaction of text that comes from outside (engine status lines): addresses and quoted text can carry email content.
enum Redact {
    static let emailPattern = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
    private static let rules: [(NSRegularExpression, String)] = [
        (emailPattern, "<email>"), (#""[^"]*""#, "\"<…>\""), (#"“[^”]*”"#, "“<…>”"),
    ].compactMap { pattern, repl in
        do { return (try NSRegularExpression(pattern: pattern), NSRegularExpression.escapedTemplate(for: repl)) } catch {
            FileHandle.standardError.write(Data("FloatBoard: redaction rule failed to compile: \(error)\n".utf8))
            return nil
        }
    }

    static func attention(_ line: String) -> String {
        var s = line
        for (re, repl) in rules { s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: repl) }
        return s
    }
}
