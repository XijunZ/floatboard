import Foundation

/// People named in a decision (features §4 D7, §9): matched by code against Circle's names and aliases, never by AI.
public enum DecisionPeople {
    /// Live people whose name or an alias appears in `text` as whole words (case and accents ignored). A name written in
    /// Chinese, Japanese or Korean characters (no spaces between words) matches anywhere in the text. Names shorter than two
    /// letters are ignored. Each person once, in the order given.
    public static func named(in text: String, people: [Person]) -> [Person] {
        let hay = fold(text)
        return people.filter { p in
            !p.deleted && ([p.name] + p.aliases).contains { name in
                let n = fold(name.trimmingCharacters(in: .whitespacesAndNewlines))
                guard n.count >= 2 else { return false }
                if n.unicodeScalars.contains(where: isCJK) { return hay.contains(n) }
                return wholeWord(n, in: hay)
            }
        }
    }

    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil) }

    static func isCJK(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF: true
        default: false
        }
    }

    /// `needle` in `hay` with no letter or digit right before or after it.
    static func wholeWord(_ needle: String, in hay: String) -> Bool {
        var from = hay.startIndex
        while let r = hay.range(of: needle, range: from..<hay.endIndex) {
            let before = r.lowerBound == hay.startIndex ? nil : hay[hay.index(before: r.lowerBound)]
            let after = r.upperBound == hay.endIndex ? nil : hay[r.upperBound]
            let edge = { (c: Character?) in c.map { !($0.isLetter || $0.isNumber) } ?? true }
            if edge(before) && edge(after) { return true }
            from = hay.index(after: r.lowerBound)
        }
        return false
    }
}
