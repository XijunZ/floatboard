import FloatBoardCore
import SwiftUI

/// Legend for everything the bar and board show.
struct GuideView: View {
    var body: some View {
        ScrollView { content }
            .frame(width: 440, height: 520)
    }

    var content: some View {
            VStack(alignment: .leading, spacing: 14) {
                section("Due dates") {
                    swatch(fill: UrgencyStyle.fill(.overdue, neutral: .clear), ring: true, "Overdue", "red dotted ring")
                    swatch(fill: UrgencyStyle.fill(.today, neutral: .clear), ring: false, tint: UrgencyStyle.tint(.today), "Due today", "light orange")
                    swatch(fill: UrgencyStyle.fill(.tomorrow, neutral: .clear), ring: false, tint: UrgencyStyle.tint(.tomorrow), "Due tomorrow", "light yellow")
                    swatch(fill: Color.primary.opacity(0.08), ring: false, "Later or no due date", "plain")
                    line("11-08", "On the bar: due month-day (configurable on the Bar tab)")
                }
                section("Importance") {
                    line("!!!", "High")
                    line("!!", "Medium")
                    line("!", "Low")
                    note("Click the tag on a card to change it; right-click to choose.")
                }
                section("Groups") {
                    HStack(spacing: 8) {
                        Text("Group").font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.blue.opacity(0.18))).foregroundStyle(Color.blue)
                        Text("Coloured pill = group. Click to move to the next group; right-click to choose.")
                            .font(.system(size: 12))
                    }
                    note("Rename, recolour and reorder groups on the Groups tab.")
                }
                section("Icons") {
                    note("Google Calendar (Connectors tab) is optional and only adds tasks to your calendar and Meet links.")
                    icon("calendar.badge.plus", "Add to Google Calendar (choose account, with or without Meet)")
                    icon("calendar.badge.checkmark", "In Google Calendar (shown under the task): click to open the event")
                    icon("video.fill", "Join the Google Meet call")
                    icon("pin", "Pin the board so it stays open when you click another app")
                    icon("envelope.fill", "✉ chip on a connector's task (where it came from): click to open the source; red if high importance")
                    icon("magnifyingglass", "Search: highlights matches; Enter jumps to the next")
                }
                section("Connector tasks") {
                    note("Connectors (Connectors tab) suggest tasks. Hover the ✉ chip to see why a task was suggested.")
                    note("Changing a connector's task, finishing it, or deleting it with “Not an action (teach)” / “Wrong details (teach)” tells the connector, so it learns.")
                    note("If a connector can't be reached, your changes are kept and sent when it's back. A ⚠︎ on the bar means a connector needs attention.")
                    note("Connectors → Settings shows each connector's settings and what FloatBoard has learned about you; edit anything that's wrong.")
                }
                section("Connectors") {
                    note("A connector is an optional add-on that suggests tasks from somewhere else, such as your email. FloatBoard works fully without one.")
                    note("To add one, open its setup page in your browser and press its “Connect to FloatBoard” link. It opens this app and adds the connector.")
                    note("Connectors tab: each connector has a status line (when it last worked, and how many changes are waiting to send) and a settings form. Edit anything that's wrong and save.")
                    note("Deleting a connector's task offers three choices: “Not an action” (this should never have been a task) and “Wrong details” both teach the connector; “Just delete” doesn't.")
                }
                section("Activity") {
                    note("Help → Activity… lists everything FloatBoard did and every problem it hit, newest first.")
                    note("Select a row and press “Show trace” for the details behind it. Press “Dismiss” on a warning once you've dealt with it; it comes back only if the problem returns.")
                    note("FloatBoard also watches for quiet problems: a connector that can't be reached, changes stuck waiting, or an old backup. These show as a ⚠︎ on the bar and in Activity.")
                }
                section("Re-check") {
                    note("On the Connectors tab, Re-check asks a connector to look at its recent items again.")
                    note("It never deletes anything. Tasks you haven't touched that no longer look like they need action are withdrawn: hidden from the board, not removed.")
                    note("Open “Show withdrawn” on the Connectors tab to see them and restore any you want back.")
                }
                section("Backups") {
                    note("FloatBoard saves a checked copy of your board automatically: daily for 2 weeks, weekly for 2 months, monthly for a year. It also saves one just before an upgrade, a re-check or a restore, and keeps those for 90 days.")
                    note("Help → Restore from backup… brings an earlier copy back. A copy of the current board is saved first, so you can undo it.")
                }
                section("Google Calendar (optional)") {
                    note("Connect a Google account on the Connectors tab only if you want tasks added to your calendar, with or without a Meet link. Nothing else needs it.")
                }
                section("Keyboard") {
                    line("⌃⌥N", "New task from anywhere")
                    line("⌃⌥B", "Show / hide the bar")
                    line("⌘F", "Search the board")
                    line("← →", "Add row: move between group, task, importance, due, time, Add")
                    line("↑ ↓", "Change the selected group / importance / date part")
                    line("Space", "Tick Due / Time, or press Add")
                    line("Enter", "Add the task (from anywhere in the add row)")
                }
                section("Windows") {
                    note("The board is a normal Mac window: red closes it back to the bar (⌘W), yellow minimises it (⌘M), green goes full screen. Hover green, or use Fn-Control-arrow keys, to tile it.")
                    note("Drag empty space to move it; double-click does what your Mac does for title bars (zoom by default). It reopens where you left it. Window → Put Board Back Above the Bar resets it.")
                    note("📌 Pinned: the board stays on top and stays open when you click another app. Unpinned: clicking another app closes it back to the bar (⌘-Tab doesn't).")
                    note("The bar always stays full width at the bottom.")
                }
            }
            .padding(16)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            c()
        }
    }
    private func swatch(fill: Color, ring: Bool, tint: Color? = nil, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 10) {
            Capsule().fill(fill)
                .overlay {
                    if ring { Capsule().strokeBorder(UrgencyStyle.ringColor, style: UrgencyStyle.ringStyle) }
                    else if let tint { Capsule().strokeBorder(tint, lineWidth: 1) }
                }
                .frame(width: 56, height: 18)
            Text(title).font(.system(size: 12, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private func line(_ key: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key).font(.system(size: 12, weight: .semibold, design: .rounded)).frame(width: 56, alignment: .leading)
            Text(text).font(.system(size: 12))
        }
    }
    private func icon(_ name: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: name).frame(width: 56, alignment: .leading)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
    }
}
