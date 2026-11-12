import FloatBoardCore
import AppKit
import SwiftUI

/// The source chip ("✉ <source label>") on a card made by the email sorting or with a source link (`showsSourceChip`).
/// Click opens the source (e.g. the message); hover shows why the connector proposed it. Red when the task is high importance.
/// (onTapGesture, like the group pill: a Button inside the draggable card doesn't reliably get the click.)
struct ProposalChip: View {
    let card: Card

    var body: some View {
        let high = card.importance == .high
        let link = card.sourceURL
        let why = (card.sourceMeta["why"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let tip = [why.isEmpty ? nil : "Why: \(why)",
                   card.connector.isEmpty ? "From \(card.sourceLabel)" : "From \(card.sourceLabel) (via \(card.connector))",
                   link == nil ? nil : (card.emailLink != nil ? "Click to open the email" : "Click to open the source")].compactMap { $0 }.joined(separator: "\n")
        Text("✉ \(card.sourceLabel)")
            .lineLimit(1)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill((high ? Color.red : Color.accentColor).opacity(0.14)))
            .foregroundStyle(high ? Color.red : Color.accentColor)
            .fixedSize()
            .contentShape(Capsule())
            .onTapGesture { if let link { NSWorkspace.shared.open(link) } }
            .onHover { inside in
                guard link != nil else { return }
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help(tip)
    }
}

/// Delete choices for a card made by the email sorting (`teachOnDelete`). The "teach" ones tell the connector why, so it learns.
struct ConnectorDeleteChoices: View {
    @EnvironmentObject var store: Store
    let card: Card

    var body: some View {
        Button("Not an action (teach)") { store.deleteCard(card, verdict: "not_action") }
        Button("Wrong details (teach)") { store.deleteCard(card, verdict: "wrong_details") }
        Button("Duplicate (teach)") { store.deleteCard(card, verdict: "duplicate") }
        Divider()
        Button("Just delete") { store.deleteCard(card, verdict: nil) }
    }
}
