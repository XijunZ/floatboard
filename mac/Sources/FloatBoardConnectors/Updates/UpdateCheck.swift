import Foundation

/// What GitHub says about this build compared with the repository's `main` (pure, so it is checked).
public enum UpdateCheck {
    public struct Available: Equatable, Sendable {
        public let head: String; public let count: Int; public let messages: [String]
        public init(head: String, count: Int, messages: [String]) { self.head = head; self.count = count; self.messages = messages }
    }
    public enum Result: Equatable, Sendable { case upToDate, available(Available), unknown(String) }

    /// `compare` is GitHub's /compare/<built>...main answer; `head` is main's newest commit.
    public static func decide(built: String, compare: [String: Any]?, head: String) -> Result {
        guard !built.isEmpty else { return .unknown("this build doesn't know its version (built outside git)") }
        if head == built { return .upToDate }
        guard let c = compare, let status = c["status"] as? String else {
            return .unknown("this build's version isn't on GitHub (local changes); update it from its folder")
        }
        switch status {
        case "identical", "behind": return .upToDate
        case "ahead":
            let commits = (c["commits"] as? [[String: Any]] ?? []).compactMap { ($0["commit"] as? [String: Any])?["message"] as? String }
            let messages = commits.reversed().map { String($0.split(separator: "\n").first ?? "") }
            return .available(Available(head: head, count: c["ahead_by"] as? Int ?? commits.count, messages: Array(messages.prefix(10))))
        default: return .unknown("this build has changes that aren't on GitHub (\(status)); update it from its folder")
        }
    }
}
