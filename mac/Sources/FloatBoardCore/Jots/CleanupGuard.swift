import Foundation

/// J6: Claude's cleanup must never change or remove substance. Before the owner chooses, code lists what of the original
/// is missing from the cleaned text: ids (T-12), web links, numbers (amounts, dates, times) and @names / #tags.
public enum CleanupGuard {
    public static func missing(original: String, cleaned: String) -> [String] {
        let have = cleaned.lowercased()
        var out: [String] = []
        for token in tokens(original) where !have.contains(token.lowercased()) && !out.contains(token) { out.append(token) }
        return out
    }

    static func tokens(_ text: String) -> [String] {
        var out = ShortID.mentions(in: text).map(\.text)
        let patterns = [#"https?://[^\s)\]>"']+"#, #"(?<![\w.])[@#][\p{L}\p{N}_.-]+"#, #"(?<![\p{L}\p{N}])\d+(?:[.,:/]\d+)*%?"#]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue } // try?-ok: fixed patterns; a bad one would only check less
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                var t = ns.substring(with: m.range)
                while let last = t.last, ".,;:".contains(last) { t.removeLast() }
                if !t.isEmpty && !out.contains(t) && !(p.hasPrefix("(?<![\\p{L}") && ShortID.mentions(in: text).contains { $0.text.hasSuffix("-" + t) }) {
                    out.append(t)
                }
            }
        }
        return out
    }
}
