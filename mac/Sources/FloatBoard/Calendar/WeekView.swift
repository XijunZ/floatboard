import FloatBoardCore
import SwiftUI

/// Seven days, Monday first, side by side (the week of `anchor`). Drawn by the same grid as the day view.
struct WeekView: View {
    let anchor: Date
    var snapshotHours: ClosedRange<Int>?
    var body: some View {
        TimeGrid(days: CalendarLayout.days(ofWeekContaining: anchor), snapshotHours: snapshotHours)
    }
}
