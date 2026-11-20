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
