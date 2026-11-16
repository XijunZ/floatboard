import FloatBoardConnectors
import FloatBoardCore

extension CalendarSender {
    /// The sender wired to the connected Google accounts.
    convenience init(store: Store, google: Google) {
        self.init(store: store, apiFor: { google.calendarAPI(for: $0) }, isConnected: { google.hasSignIn($0) })
    }
}
