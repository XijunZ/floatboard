import SwiftUI
import FloatBoardCore

extension Importance {
    var color: Color { switch self { case .low: .secondary.opacity(0.7); case .medium: .secondary; case .high: .primary } }
    var weight: Font.Weight { switch self { case .low: .regular; case .medium: .semibold; case .high: .heavy } }
}

extension FloatBoardCore.Category {
    var color: Color { Color(hex: colorHex) }
}

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt64(h, radix: 16) ?? 0x8E8E93
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

extension Store {
    func color(_ area: String) -> Color { areas.first { $0.name == area }?.color ?? .gray }
    func markInCalendar(_ card: Card, account: String, event: Google.CreatedEvent) {
        markInCalendar(card, account: account, eventID: event.id, htmlLink: event.htmlLink, meetLink: event.meetLink)
    }
}

extension Search {
    /// The text with every occurrence of the query's words highlighted.
    static func highlighted(_ text: String, _ q: String) -> AttributedString {
        var a = AttributedString(text)
        for w in words(q) {
            var start = a.startIndex
            while start < a.endIndex,
                  let r = a[start...].range(of: w, options: [.caseInsensitive, .diacriticInsensitive]) {
                a[r].backgroundColor = Color.yellow.opacity(0.55)
                a[r].foregroundColor = Color.black
                start = r.upperBound
            }
        }
        return a
    }
}

/// Shared colours for due-date urgency.
enum UrgencyStyle {
    static func fill(_ u: Card.Urgency, neutral: Color) -> Color {
        switch u {
        case .overdue: return Color.red.opacity(0.10)
        case .today: return Color.orange.opacity(0.14)
        case .tomorrow: return Color.yellow.opacity(0.16)
        case .none: return neutral
        }
    }
    /// Thin outline in the same hue, giving today/tomorrow a light tinted edge.
    static func tint(_ u: Card.Urgency) -> Color? {
        switch u {
        case .today: return Color.orange.opacity(0.55)
        case .tomorrow: return Color.yellow.opacity(0.75)
        default: return nil
        }
    }
    /// Red dotted ring for overdue tasks.
    static let ringColor = Color.red
    static let ringStyle = StrokeStyle(lineWidth: 1.5, dash: [2.5, 2.5])
}

extension Status {
    /// SF Symbol for the step: dashed circle to do, ◐ doing, 👁 watch, ✓ done.
    var icon: String {
        switch self {
        case .todo: "circle.dashed"
        case .doing: "circle.lefthalf.filled"
        case .watch: "eye"
        case .done: "checkmark.circle"
        }
    }
}
