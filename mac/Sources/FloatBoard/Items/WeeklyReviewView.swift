import FloatBoardCore
import SwiftUI

/// The weekly review page (from the bar's ✓ button and the Sunday nudge): the sections the areas register, empty ones hidden.
struct WeeklyReviewView: View {
    var close: () -> Void
    @EnvironmentObject var store: Store

    var body: some View {
        let now = Date()
        let week = WeeklyReview.week(containing: now)
        let sections = WeeklyReview.sections(store: store, now: now)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Weekly review").font(.system(size: 15, weight: .semibold))
                Text("\(Fmt.short(week.start)) to \(Fmt.short(week.end.addingTimeInterval(-1)))").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { close() }.keyboardShortcut(.defaultAction)
            }
            if sections.isEmpty {
                Text("Nothing to review this week.").font(.system(size: 12)).foregroundStyle(.secondary)
                Text("Decisions and Circle add their sections here when they are on.").font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(sections, id: \.0.id) { section, items in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(section.title).font(.system(size: 13, weight: .semibold))
                                ForEach(items) { i in
                                    if let row = WeeklyReviewRows.views[section.id] {
                                        row(i)
                                    } else {
                                        HStack(spacing: 6) {
                                            if let id = i.item { Text(id.text).monospacedDigit().foregroundStyle(.secondary) }
                                            Text(i.title).lineLimit(1)
                                            if !i.detail.isEmpty { Text(i.detail).foregroundStyle(.secondary).lineLimit(1) }
                                        }
                                        .font(.system(size: 12))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 520, height: 420, alignment: .topLeading)
    }
}

/// How an area draws its rows on the weekly review page (buttons such as "Not a decision" or "Review"), by section id.
/// A section without one gets the plain row (id, title, detail).
@MainActor enum WeeklyReviewRows {
    static var views: [String: (ReviewItem) -> AnyView] = [:]
}
