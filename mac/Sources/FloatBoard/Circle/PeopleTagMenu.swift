import FloatBoardCore
import SwiftUI

/// The "+" menu for a person's tags: Investor, Prospect and tags already on people (PeopleTags.offered), never the
/// board's groups, plus "New tag…". Used by the detail pane, the bulk bar's Add tag and the Add / Edit form.
struct PeopleTagMenu<Label: View>: View {
    @EnvironmentObject var store: Store
    /// Tags to leave out (already on the person).
    var except: [String] = []
    let pick: (String) -> Void
    @ViewBuilder let label: () -> Label
    @State private var naming = false
    @State private var newName = ""
    @State private var problem: String?

    var body: some View {
        Menu {
            let offered = PeopleTags.offered(store: store).filter { t in !except.contains { $0.caseInsensitiveCompare(t) == .orderedSame } }
            ForEach(offered, id: \.self) { t in Button(t) { pick(t) } }
            if !offered.isEmpty { Divider() }
            Button("New tag…") { newName = ""; problem = nil; naming = true }
        } label: { label() }
        .alert("New tag for people", isPresented: $naming) {
            TextField("Tag name", text: $newName)
            Button("Add") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                if let why = PeopleTags.add(store: store, name) {
                    problem = why
                    DispatchQueue.main.async { naming = true }   // asked again, with the reason, instead of failing silently
                } else { pick(name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text(problem ?? "A tag for people only; it isn't a board group.") }
    }
}

/// A tag chip in the board card's style: the tag's colour, tinted capsule, semibold.
struct PersonTagChip: View {
    @EnvironmentObject var store: Store
    @Environment(\.colorScheme) private var scheme
    let tag: String
    var size: CGFloat = 10
    var remove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 3) {
            // A long tag is cut at 24 characters so a chip never pushes the row apart.
            Text(tag.count > 24 ? String(tag.prefix(23)) + "…" : tag).fontWeight(.semibold).lineLimit(1)
            if let remove {
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: size - 3, weight: .bold)) }
                    .buttonStyle(.borderless).help("Remove \(tag)")
            }
        }
        .font(.system(size: size))
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(Capsule().fill(store.color(tag).opacity(0.18)))
        .foregroundStyle(store.ink(tag, scheme))
        .fixedSize()
    }
}

/// A person's tier in the list, outlined and neutral so it reads as the tier, not as a tag.
struct TierChip: View {
    let tier: PersonTier
    var body: some View {
        Text(tier.title).font(.system(size: 10, weight: .medium)).lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 1)
            .overlay(Capsule().stroke(Color.secondary.opacity(0.55), lineWidth: 1))
            .foregroundStyle(.secondary)
    }
}

/// The tier toggles above the Circle list, one chip per tier, in the look of the board's group chips: filled while its
/// people are shown, outlined and dimmed while hidden. Click hides or shows that tier; Option-click shows only that tier
/// (again: all). Kept across launches (CircleTierFilter).
struct TierToggles: View {
    @Binding var filter: CircleTierFilter

    static func help(_ t: PersonTier, on: Bool) -> String {
        let verb: String = on ? "Hide" : "Show"
        return "\(verb) \(t.title) in this list and Due this week (Option-click: only \(t.title)). "
            + "Only changes what you see here: reminders and notifications still come for every tier."
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PersonTier.allCases, id: \.self) { t in
                let on = filter.shows(t)
                Text(t.title)
                    .font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(on ? Color.primary.opacity(0.12) : Color.clear))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(on ? 0 : 0.25), lineWidth: 1))
                    .contentShape(Capsule())
                    .onTapGesture {
                        if NSEvent.modifierFlags.contains(.option) { filter.only(t) } else { filter.toggle(t) }
                    }
                    .help(Self.help(t, on: on))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityValue(on ? "shown" : "hidden")
            }
        }
    }
}
