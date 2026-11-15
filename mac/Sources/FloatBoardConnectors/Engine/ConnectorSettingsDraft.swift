import FloatBoardCore
import Foundation

public struct SettingsInvalid: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// What the settings form is editing. Kept apart from the view so the rules are checked:
/// - a newer stored value (e.g. a sync brought new "learned" lines) replaces a field you haven't edited;
/// - saving sends only the fields you changed, so the store merges them over everything else it has.
/// "New tasks go to" (default_group), "Add tasks automatically" (auto_add) and "learned" are always present.
public struct ConnectorSettingsDraft {
    public static let builtIn: Set<String> = ["default_group", "auto_add", "learned"]

    public private(set) var fields: [SettingField] = []
    public var text: [String: String] = [:]
    public var flags: [String: Bool] = [:]
    public var notes: [String: [String: String]] = [:]
    private var baseText: [String: String] = [:]
    private var baseFlags: [String: Bool] = [:]
    private var baseNotes: [String: [String: String]] = [:]

    public init() {}

    public init(settings: [String: Any], schema: [SettingField], groups: [String]) {
        (fields, text, flags, notes) = Self.state(settings, schema, groups)
        (baseText, baseFlags, baseNotes) = (text, flags, notes)
    }

    /// True when any field differs from what was loaded (or last saved).
    public var isEdited: Bool { text != baseText || flags != baseFlags || notes != baseNotes }

    /// Take newer stored values for every field you haven't edited; keep your edits.
    public mutating func rebase(stored: [String: Any], schema: [SettingField], groups: [String]) {
        let (f, t, b, n) = Self.state(stored, schema, groups)
        fields = f
        for (k, v) in t where text[k] == nil || text[k] == baseText[k] { text[k] = v }
        for (k, v) in b where flags[k] == nil || flags[k] == baseFlags[k] { flags[k] = v }
        for (k, v) in n where notes[k] == nil || notes[k] == baseNotes[k] { notes[k] = v }
        (baseText, baseFlags, baseNotes) = (t, b, n)
    }

    /// After a successful save, what you see is what's stored.
    public mutating func markSaved() { (baseText, baseFlags, baseNotes) = (text, flags, notes) }

    /// Only the fields you changed, as settings values. Throws when a number field isn't a whole number.
    public func changedValues(groups: [String]) throws -> [String: Any] {
        var out: [String: Any] = [:]
        for f in fields {
            switch f.kind {
            case "bool":
                if flags[f.key] != baseFlags[f.key] { out[f.key] = flags[f.key] ?? false }
            case "int":
                guard text[f.key] != baseText[f.key] else { continue }
                let raw = (text[f.key] ?? "").trimmingCharacters(in: .whitespaces)
                if raw.isEmpty { continue } // an empty number field leaves the stored value as it is
                guard let v = Int(raw) else { throw SettingsInvalid(message: "\(f.label) must be a whole number.") }
                out[f.key] = v
            case "list":
                if text[f.key] != baseText[f.key] {
                    out[f.key] = (text[f.key] ?? "").split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }
            case "groupNotes":
                if notes[f.key] != baseNotes[f.key] {
                    let names = Set(groups)
                    out[f.key] = (notes[f.key] ?? [:]).filter { names.contains($0.key) }
                        .mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.value.isEmpty }
                }
            case "text", "longtext", "choice": // a choice is sent as its option text, e.g. "50"
                if text[f.key] != baseText[f.key] { out[f.key] = text[f.key] ?? "" }
            default: continue // not editable here: left as stored
            }
        }
        if text["default_group"] != baseText["default_group"] { out["default_group"] = text["default_group"] ?? "" }
        if flags["auto_add"] != baseFlags["auto_add"] { out["auto_add"] = flags["auto_add"] ?? true }
        if text["learned"] != baseText["learned"] { out["learned"] = text["learned"] ?? "" }
        return out
    }

    private static func string(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID(): return n.stringValue
        default: return nil
        }
    }

    private static func state(_ s: [String: Any], _ schema: [SettingField], _ groups: [String])
        -> ([SettingField], [String: String], [String: Bool], [String: [String: String]]) {
        let fields = schema.filter { !builtIn.contains($0.key) }
        var t: [String: String] = [:], b: [String: Bool] = [:], n: [String: [String: String]] = [:]
        for f in fields {
            switch f.kind {
            case "bool": b[f.key] = s[f.key] as? Bool ?? false
            case "list": t[f.key] = (s[f.key] as? [String] ?? []).joined(separator: "\n")
            case "groupNotes": n[f.key] = s[f.key] as? [String: String] ?? [:]
            default: t[f.key] = string(s[f.key]) ?? "" // text, longtext, int, choice (stored as text or number)
            }
        }
        let group = s["default_group"] as? String ?? ""
        t["default_group"] = groups.contains(group) ? group : (groups.first ?? "")
        b["auto_add"] = s["auto_add"] as? Bool ?? true
        t["learned"] = s["learned"] as? String ?? ""
        return (fields, t, b, n)
    }
}
