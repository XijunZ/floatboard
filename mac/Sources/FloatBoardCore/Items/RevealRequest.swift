import CoreGraphics
import Foundation

/// "Show this item" from search, for a tab that may not be on screen yet (round 23): the request waits until the view
/// holding the item appears and takes it (the board's column with the task, the Calendar's block for the event). Each
/// request is new, so picking the same item twice asks twice.
public struct RevealRequest: Equatable {
    public let id: Int64
    let token = UUID()
    public init(_ id: Int64) { self.id = id }

    /// The id when `ids` holds it (the request is then used up); nil when it's someone else's to take.
    public static func take(_ r: inout RevealRequest?, ifIn ids: some Sequence<Int64>) -> Int64? {
        guard let want = r?.id, ids.contains(want) else { return nil }
        r = nil
        return want
    }
}

/// The day grid's part of revealing an event from search (round 24): the hour to scroll to, an hour before the event,
/// only while a request for an event on this page is pending. No request (nil, e.g. just acknowledged) moves nothing.
public enum CalendarReveal {
    public static func scrollHour(for r: RevealRequest?, in events: [CalEvent]) -> Int? {
        guard let want = r?.id, let e = events.first(where: { $0.shortID == want && !$0.allDay }) else { return nil }
        return max(0, AppTime.calendar.component(.hour, from: e.start) - 1)
    }
}

/// The search list's outside-click test (round 24): a click outside every kept area closes the list; the click itself is
/// never taken (what was clicked gets it, focus moves there).
public enum OutsideClick {
    public static func closes(at p: CGPoint, keep: [CGRect]) -> Bool { !keep.contains { $0.contains(p) } }
}

/// Opens an event's panel a moment after search picked it (after the grid has scrolled to it), round 25: one pending
/// open per block, cancelled by a newer schedule or `cancel()` (the block left the page or saw another request); when
/// it fires it opens and then acknowledges only while the current request is still the one it was scheduled for.
@MainActor public final class DelayedReveal {
    private var task: Task<Void, Never>?
    public init() {}

    public func schedule(_ r: RevealRequest, delay: Double, current: @escaping () -> RevealRequest?, open: @escaping () -> Void,
                         acknowledge: @escaping () -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) // try?-ok: a cancelled wait is checked just below
            guard !Task.isCancelled, current() == r else { return }
            open()
            if current() == r { acknowledge() }
        }
    }

    public func cancel() { task?.cancel(); task = nil }
}
