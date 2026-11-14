import FloatBoardCore
import AppKit
import SwiftUI

/// Where a card came from ("✉ me@gmail.com ↗"): plain grey text with an icon for the kind of source, never a filled
/// pill, so it can't be mistaken for the group. Click opens the source (e.g. the message); hover shows why it was proposed.
/// (onTapGesture, like the group pill: a Button inside the draggable card doesn't reliably get the click.)
struct ProposalChip: View {
    let card: Card

    var body: some View {
        let link = card.sourceURL
        let why = (card.sourceMeta["why"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let tip = [why.isEmpty ? nil : "Why: \(why)",
                   card.connector.isEmpty ? "From \(card.sourceLabel)" : "From \(card.sourceLabel) (via \(card.connector))",
                   link == nil ? nil : (card.emailLink != nil ? "Click to open the email" : "Click to open the source")].compactMap { $0 }.joined(separator: "\n")
        HStack(spacing: 3) {
            Image(systemName: Self.icon(card)).font(.system(size: 9))
            Text(card.sourceLabel).lineLimit(1)
            if link != nil { Image(systemName: "arrow.up.right").font(.system(size: 7, weight: .semibold)) }
        }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize()
            .contentShape(Rectangle())
            .onTapGesture { if let link { NSWorkspace.shared.open(link) } }
            .onHover { inside in
                guard link != nil else { return }
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help(tip)
    }

    /// WhatsApp chat, meeting notes, or email.
    static func icon(_ c: Card) -> String {
        let mid = c.sourceKey?.messageID ?? ""
        if mid.hasPrefix("wa:") { return "bubble.left" }
        if mid.hasPrefix("fathom:") || c.sourceLabel.lowercased() == "fathom" { return "video" }
        return "envelope"
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
