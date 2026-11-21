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

/// What search asked to show, in one place (round 26): at most one pending request, of the kind last picked. A new pick
/// of any kind replaces it; it lasts only through the move to its own destination (the board for a task; the Calendar
/// on the event's day for an event): another tab or another day drops it, so coming back later opens nothing.
public struct PendingReveals: Equatable {
    public enum Destination { case board, calendar, other }
    public var task: RevealRequest?
    public var event: RevealRequest?
    public private(set) var eventDay: Date?
    /// A jot, person, decision or goal shown in its tab's list (scrolled to and highlighted), round 37.
    public private(set) var item: ShortID?
    /// False for a preview (the search list's highlight): shown, but no panel or editor opens.
    public private(set) var opens = true
    public init() {}

    public mutating func pick(task id: Int64, opens: Bool = true) { self = PendingReveals(); task = RevealRequest(id); self.opens = opens }
    public mutating func pick(event id: Int64, day: Date?, opens: Bool = true) {
        self = PendingReveals(); event = RevealRequest(id); eventDay = day; self.opens = opens
    }
    /// A result of another kind (a jot, a person, a decision, a goal): nothing of the board's or the Calendar's waits.
    public mutating func pickOther() { self = PendingReveals() }
    /// A result of another kind shown in its list; `opens` false for a preview.
    public mutating func pick(item id: ShortID, opens: Bool) { self = PendingReveals(); item = id; self.opens = opens }

    /// A tab is showing: requests for other tabs are dropped.
    public mutating func shown(_ d: Destination) {
        if d != .board { task = nil }
        if d != .calendar { event = nil; eventDay = nil }
    }

    /// The Calendar moved to `day`: an event request for another day is dropped.
    public mutating func calendarShows(day: Date) {
        guard let d = eventDay, event != nil else { return }
        if !AppTime.calendar.isDate(d, inSameDayAs: day) { event = nil; eventDay = nil }
    }
}

/// Where a search result lives (round 37): the tab its preview and its opening go to.
public enum SearchDestination: Equatable {
    case board, calendar, jots, circle, decisions, resolutions
    public static func of(_ k: ItemKind) -> SearchDestination {
        switch k { case .task: .board; case .event: .calendar; case .jot: .jots; case .person: .circle; case .decision: .decisions; case .resolution: .resolutions }
    }
}

/// A result shown from search, in one place (round 37): the request for its tab (a task, an event, or another item in its
/// list), marked as a preview (`opens` false) or an opening. Returns the tab to show.
public enum SearchPreviewApply {
    public static func apply(_ h: SearchHit, opens: Bool, reveals: inout PendingReveals) -> SearchDestination {
        switch h.id.kind {
        case .task: reveals.pick(task: h.id.number, opens: opens)
        case .event: reveals.pick(event: h.id.number, day: h.date, opens: opens)
        default: reveals.pick(item: h.id, opens: opens)
        }
        return SearchDestination.of(h.id.kind)
    }
}

/// The search list's highlight shown live (round 37). Moving the highlight with the keyboard previews the result on its
/// tab (scrolled to and highlighted, nothing opened); Enter or a click opens it as before; Esc goes back to where the
/// owner was before the first preview. The top result highlighted by typing is previewed only once typing has stopped
/// for `debounce` seconds, so typing never hops between tabs; a newer highlight replaces one still waiting.
@MainActor public final class SearchPreviewer<Place>: ObservableObject {
    /// Where the owner is now (kept at the first preview, for Esc).
    public var here: () -> Place? = { nil }
    public var goBack: (Place) -> Void = { _ in }
    /// Shows a result on its tab: `opens` false for a preview, true for Enter or a click.
    public var show: (SearchHit, Bool) -> Void = { _, _ in }
    public private(set) var origin: Place?
    public let debounce: Double
    private var lastTyped = Date.distantPast
    private var waiting: Task<Void, Never>?

    public init(debounce: Double = 0.25) { self.debounce = debounce }

    /// A key typed in the search box: a preview still waiting is dropped and the debounce starts again.
    public func keystroke(now: Date = Date()) { lastTyped = now; stopWaiting() }

    /// New results highlighted their top row: previewed once typing has been still for the debounce.
    public func typedTop(_ hit: SearchHit?) {
        stopWaiting()
        guard let hit else { return }
        let wait = max(0, debounce - Date().timeIntervalSince(lastTyped))
        waiting = Task { @MainActor [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) } // try?-ok: a cancelled wait is checked just below
            guard !Task.isCancelled, let self else { return }
            self.preview(hit)
        }
    }

    /// ↑/↓ moved the highlight: previewed at once (a "Show all" row previews nothing).
    public func highlighted(_ hit: SearchHit?) { stopWaiting(); if let hit { preview(hit) } }

    /// Enter or a click: opens it, as before; Esc no longer goes back.
    public func commit(_ hit: SearchHit) { stopWaiting(); origin = nil; show(hit, true) }

    /// Esc: back to where the owner was before the first preview.
    public func escape() { stopWaiting(); if let o = origin { origin = nil; goBack(o) } }

    /// The list closed another way (a click elsewhere, another tab picked): stays where it is.
    public func settle() { stopWaiting(); origin = nil }

    private func preview(_ hit: SearchHit) {
        if origin == nil { origin = here() }
        show(hit, false)
    }

    private func stopWaiting() { waiting?.cancel(); waiting = nil }
}
