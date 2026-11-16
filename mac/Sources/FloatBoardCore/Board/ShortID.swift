import Foundation

/// The kinds of item that have a visible id. Later parts add more letters.
public enum ItemKind: String {
    case task = "T", event = "E"
}

/// An item's visible id, such as "T-142" (a task) or "E-37" (a calendar event). The number is the item's row id.
public struct ShortID: Hashable {
    public let kind: ItemKind
    public let number: Int64

    public init(kind: ItemKind, number: Int64) { self.kind = kind; self.number = number }

    public var text: String { "\(kind.rawValue)-\(number)" }

    /// "t-142", "T-142" and " E-37 " parse; "X-1", "T-", "T-0" and "T-1x" do not.
    public static func parse(_ s: String) -> ShortID? {
        let parts = s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 1, let kind = ItemKind(rawValue: String(parts[0])),
              !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
              let n = Int64(parts[1]), n > 0 else { return nil }
        return ShortID(kind: kind, number: n)
    }
}
