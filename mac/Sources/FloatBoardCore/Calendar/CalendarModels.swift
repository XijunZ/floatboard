import Foundation

/// One Google calendar the user can see, as kept on the board.
public struct CalCalendar: Equatable {
    public var account: String
    public var calendarID: String
    public var name: String
    /// Google's colour for it, such as "#9fe1e7".
    public var color: String
    /// True when the user owns it (can create events on it).
    public var owned: Bool
    /// False hides the calendar's events everywhere.
    public var shown: Bool
    /// True when Google refused our access and the user has to sign in again.
    public var needsReconnect: Bool
    /// Google's bookmark for "everything since last time"; nil means the next sync reads the whole window.
    public var syncToken: String?
    public var syncedAt: Date?
    /// When the whole window was last read (a daily full read finds events that were beyond the window earlier).
    public var fullReadAt: Date?
    /// True for the account's main calendar, as Google flags it in the calendar list (or the "primary" stand-in used until
    /// the list can be read). Its id is usually, not always, the account's address.
    public var primary: Bool

    public init(account: String, calendarID: String, name: String, color: String, owned: Bool, shown: Bool,
                needsReconnect: Bool = false, syncToken: String? = nil, syncedAt: Date? = nil, fullReadAt: Date? = nil, primary: Bool = false) {
        self.account = account; self.calendarID = calendarID; self.name = name; self.color = color
        self.owned = owned; self.shown = shown; self.needsReconnect = needsReconnect
        self.syncToken = syncToken; self.syncedAt = syncedAt; self.fullReadAt = fullReadAt; self.primary = primary
    }
}

/// The fields of an event that Google gives us. All-day events carry `startDay`/`endDay` ("yyyy-MM-dd", the end day
/// exclusive as Google sends it); the cache works out `start`/`end` from them in the app's time zone.
public struct CalEventFields: Equatable {
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var startDay: String?
    public var endDay: String?
    public var title: String
    public var location: String
    public var videoLink: String
    public var description: String
    public var htmlLink: String
    public var recurringID: String?
    public var googleUpdated: Date
    /// The FloatBoard task this event was made from, if any (so it is not offered as a meeting).
    public var fbCard: Int64?
    /// For an instance of a repeating meeting: where the series put it (Google's `originalStartTime`), "yyyy-MM-dd" for an
    /// all-day one, else an ISO time in UTC. Differs from the start when the instance was moved in Google.
    public var originalStart: String? = nil

    public init(start: Date, end: Date, allDay: Bool = false, startDay: String? = nil, endDay: String? = nil,
                title: String, location: String = "", videoLink: String = "", description: String = "",
                htmlLink: String = "", recurringID: String? = nil, googleUpdated: Date, fbCard: Int64? = nil) {
        self.start = start; self.end = end; self.allDay = allDay; self.startDay = startDay; self.endDay = endDay
        self.title = title; self.location = location; self.videoLink = videoLink; self.description = description
        self.htmlLink = htmlLink; self.recurringID = recurringID; self.googleUpdated = googleUpdated; self.fbCard = fbCard
    }
}

/// One change Google reports for a calendar: an event that is new or changed (`fields`), or one that was cancelled.
public struct GoogleEventChange: Equatable {
    public var eventID: String
    public var cancelled: Bool
    public var fields: CalEventFields?

    public init(eventID: String, cancelled: Bool, fields: CalEventFields?) {
        self.eventID = eventID; self.cancelled = cancelled; self.fields = fields
    }
}

/// An event kept on the board. `shortID` is its visible number (E-n) and never changes or gets reused.
public struct CalEvent: Equatable {
    public var shortID: Int64
    public var account: String
    public var calendarID: String
    public var eventID: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var title: String
    public var location: String
    public var videoLink: String
    public var description: String
    public var htmlLink: String
    public var recurringID: String?
    public var googleUpdated: Date
    public var fbCard: Int64?
    /// True once Google reported it cancelled (or a full re-read has not brought it back yet); kept so links to it still resolve.
    public var gone: Bool = false
    /// True only when Google itself reported the event cancelled (deleted). A reset hides events (`gone`) without cancelling them.
    public var cancelled: Bool = false
    /// For an instance of a repeating meeting: where the series put it (midnight of its day in the app's zone for an
    /// all-day one). Differs from `start` when the instance was moved in Google.
    public var originalStart: Date? = nil

    public init(shortID: Int64, account: String, calendarID: String, eventID: String, start: Date, end: Date, allDay: Bool,
                title: String, location: String, videoLink: String, description: String, htmlLink: String,
                recurringID: String?, googleUpdated: Date, fbCard: Int64?, gone: Bool = false, cancelled: Bool = false) {
        self.shortID = shortID; self.account = account; self.calendarID = calendarID; self.eventID = eventID
        self.start = start; self.end = end; self.allDay = allDay; self.title = title; self.location = location
        self.videoLink = videoLink; self.description = description; self.htmlLink = htmlLink; self.recurringID = recurringID
        self.googleUpdated = googleUpdated; self.fbCard = fbCard; self.gone = gone; self.cancelled = cancelled
    }

    /// "E-37".
    public var id: ShortID { ShortID(kind: .event, number: shortID) }
}
