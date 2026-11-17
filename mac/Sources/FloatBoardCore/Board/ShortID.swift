import Foundation

/// The kinds of item that have a visible id: tasks, calendar events, jots, people, decisions and resolutions.
public enum ItemKind: String, CaseIterable {
    case task = "T", event = "E", jot = "J", person = "P", decision = "D", resolution = "R"

    /// "task", "meeting", … for lists and messages.
    public var noun: String {
        switch self {
        case .task: "task"; case .event: "meeting"; case .jot: "jot"; case .person: "person"
        case .decision: "decision"; case .resolution: "goal"
        }
    }
}

/// An item's visible id, such as "T-142" (a task) or "E-37" (a calendar event). The number is the item's row id.
public struct ShortID: Hashable {
    public let kind: ItemKind
    public let number: Int64

    public init(kind: ItemKind, number: Int64) { self.kind = kind; self.number = number }

    public var text: String { "\(kind.rawValue)-\(number)" }

    /// "t-142", "T-142", " J-7 " parse; "X-1", "T-", "T-0" and "T-1x" do not.
    public static func parse(_ s: String) -> ShortID? {
        let parts = s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 1, let kind = ItemKind(rawValue: String(parts[0])),
              !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
              let n = Int64(parts[1]), n > 0 else { return nil }
        return ShortID(kind: kind, number: n)
    }

    /// Every id written in `text` as a word of its own ("see t-12 and J-7."), in order, each once. "AT-9", "T-12b" and
    /// "T-0" are not ids.
    public static func mentions(in text: String) -> [ShortID] {
        var out: [ShortID] = [], seen = Set<ShortID>()
        let ns = text as NSString
        for m in mentionPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let id = parse(ns.substring(with: m.range)), !seen.contains(id) else { continue }
            seen.insert(id); out.append(id)
        }
        return out
    }

    // try?-ok: a fixed, valid pattern
    nonisolated(unsafe) private static let mentionPattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_-])[TEJPDRtejpdr]-[0-9]+(?![A-Za-z0-9_])"#)
}
