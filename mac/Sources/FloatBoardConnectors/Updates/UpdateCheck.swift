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

    /// The "Update now" script, run in the source folder by a login shell (`set -e`: it stops at the first failure). The engine's
    /// packages are installed for every user (`npm ci`), since the app build bundles the engine for Mac only mode; only
    /// someone who deploys an online engine from this Mac also updates it.
    public static func updateScript(dir: String, deploysEngine: Bool) -> String {
        let quoted = "'" + dir.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
            set -e
            cd \(quoted)
            echo "== $(date) updating from $(git rev-parse --short HEAD)"
            if [ -n "$(git status --porcelain --untracked-files=no)" ]; then echo "STOP: the source folder has changes that aren't committed"; exit 3; fi
            git fetch --quiet origin main
            if [ -n "$(git log --oneline origin/main..HEAD)" ]; then echo "STOP: the source folder has commits that aren't on GitHub"; exit 4; fi
            git merge --ff-only --quiet origin/main
            command -v npm >/dev/null || { echo "STOP: npm (Node.js) is needed to build FloatBoard; install Node.js, then try again"; exit 5; }
            (cd engine && npm ci --silent)
            \(deploysEngine ? "(cd engine && npm run --silent update)" : "echo 'no online engine deployed from this Mac'")
            cd mac && ./scripts/build-app.sh
            echo "== done $(git rev-parse --short HEAD)"
            """
    }
}
