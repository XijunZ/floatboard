import Foundation

/// What a click on a calendar item opens.
public enum CalendarClick: Equatable {
    /// The board's task editor (the same one a task on the board opens), for the task with this id.
    case taskEditor(Int64)
    /// The event panel, for the event with this E-number.
    case eventPanel(Int64)
}

extension CalendarLayout {
    /// How a timed block uses its height (points): as many title lines as fit, then its time, then its id. When space is
    /// short the time goes first, so the title keeps at least one line.
    public struct BlockText: Equatable {
        public var titleLines: Int
        public var showTime: Bool
        public var showID: Bool
    }

    /// Line heights at the grid's fonts (title 11 pt, time 10 pt, id 9 pt) and the block's 2 pt padding top and bottom.
    static let titleLine: CGFloat = 13.5, timeLine: CGFloat = 12.5, idLine: CGFloat = 11.5, blockPadding: CGFloat = 4

    public static func blockText(height: CGFloat) -> BlockText {
        let room = height - blockPadding
        guard room >= 2 * titleLine + timeLine else {
            return BlockText(titleLines: max(1, Int(room / titleLine)), showTime: false, showID: false)
        }
        let rest = room - timeLine
        let showID = rest >= 3 * titleLine + idLine
        return BlockText(titleLines: max(2, Int((rest - (showID ? idLine : 0)) / titleLine)), showTime: true, showID: showID)
    }

    /// The all-day row of one day: up to `limit` items stacked; with more, `limit - 1` and a "+N more" line in the last place.
    public static func stripSplit(count: Int, limit: Int = 3) -> (shown: Int, more: Int) {
        count <= limit ? (count, 0) : (limit - 1, count - (limit - 1))
    }

    /// A click on a task opens the board's task editor; on an event, its event panel.
    public static func clickTarget(_ content: PlacedItem.Content) -> CalendarClick {
        switch content {
        case .task(let t): .taskEditor(t.id)
        case .event(let e): .eventPanel(e.shortID)
        }
    }
}

/// When a calendar item's hover details may show: after the pointer has rested on it (`waited`), unless something
/// suppressed them since it entered (a click's panel or editor, a drag, a resize). Once suppressed they stay closed until
/// the pointer leaves and enters again, so they never pop up mid-drag or linger after a drop.
public struct HoverGate: Equatable {
    public private(set) var armed = false
    public private(set) var shown = false
    public init() {}
    public mutating func enter(suppressed: Bool) { armed = !suppressed; shown = false }
    public mutating func waited(suppressed: Bool) { if armed && !suppressed { shown = true } }
    public mutating func suppress() { armed = false; shown = false }
    public mutating func leave() { armed = false; shown = false }
    /// The popover closed by itself (Escape, a click elsewhere).
    public mutating func closed() { shown = false }
}
