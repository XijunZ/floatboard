import FloatBoardCore
import SwiftUI

/// Open tasks due in the next 14 days with a date but no time. Drag one onto the grid to give it a time.
struct DueSoonList: View {
    @EnvironmentObject var store: Store
    @Environment(\.calendarSnapshot) private var snapshot

    private var tasks: [Card] {
        let cal = AppTime.calendar
        let from = cal.startOfDay(for: Date())
        let to = cal.date(byAdding: .day, value: 14, to: from) ?? from
        return store.cards
            .filter { $0.status != .done && !$0.withdrawn && !$0.dueHasTime && ($0.due.map { $0 >= from && $0 < to } ?? false) }
            .sorted { ($0.due ?? .distantFuture, $0.id) < ($1.due ?? .distantFuture, $1.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Due soon").font(.system(size: 12, weight: .semibold))
            if tasks.isEmpty {
                Text("Nothing is due in the next 14 days without a time.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text("Drag onto the calendar to set a time.").font(.system(size: 11)).foregroundStyle(.secondary)
                if snapshot { rows } else { ScrollView(.vertical) { rows } }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(tasks) { t in
                HStack(spacing: 6) {
                    Circle().fill(store.color(t.area)).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.title).font(.system(size: 12)).lineLimit(2)
                        HStack(spacing: 6) {
                            Text(t.due.map(Fmt.short) ?? "")
                            IDChip(id: ShortID(kind: .task, number: t.id))
                        }
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                .draggable(ShortID(kind: .task, number: t.id).text)
            }
        }
    }
}
