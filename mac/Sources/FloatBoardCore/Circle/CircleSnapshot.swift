import Foundation

/// What the Circle tab draws from (people, clocks, details, handles, the due list, the suggestions count), worked out once
/// per board change and at most once a minute for the clocks, instead of on every keystroke (round 13, C3).
@MainActor public struct CircleSnapshot {
    public let people: [Person]
    public let clocks: [Int64: Clocks]
    public let details: [Int64: CircleDetails]
    public let handles: [Int64: [Handle]]
    public let due: [DueEntry]
    public let suggestionCount: Int

    private static var cache: [ObjectIdentifier: (gen: Int, minute: Int, snap: CircleSnapshot)] = [:]
    /// How many times a snapshot was built (checks).
    public private(set) static var builds = 0

    public static func current(store: Store, now: Date = Date()) -> CircleSnapshot {
        let key = ObjectIdentifier(store), minute = Int(now.timeIntervalSince1970 / 60)
        if let c = cache[key], c.gen == store.reloads, c.minute == minute { return c.snap }
        builds += 1
        let c = CircleStore(store: store)
        let snap = CircleSnapshot(people: PeopleStore(store: store).people(), clocks: c.allClocks(now: now), details: c.allDetails(),
                                  handles: c.allHandles(), due: CircleDue.entries(store: store, now: now),
                                  suggestionCount: c.conversationSuggestions().count + c.candidates().count + c.mergeSuggestions().count)
        cache[key] = (store.reloads, minute, snap)
        return snap
    }
}
