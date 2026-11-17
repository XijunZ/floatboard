import Foundation

/// The three clocks per person and the due rule (features §9 Circle), worked out by code from metadata only.
/// - last conversation: an exchange with one in the other direction within 14 days (any channels), a meeting both accepted,
///   or "We talked";
/// - last heard from: the latest incoming message; last outreach: the latest outgoing message or "I contacted them";
/// - due: the interval has passed since the last conversation (else since the person was added), not snoozed, and no
///   outreach in the last 7 days.
public enum CircleClock {
    public static let conversationWindow: TimeInterval = 14 * 86400
    public static let outreachQuiet: TimeInterval = 7 * 86400

    /// The tier's default (Family 1 month, Close friend 2 weeks, Network 3 months), or the person's own days; Investor caps
    /// it at 3 months (`TagRules.intervalCapMonths`).
    public static func interval(tier: PersonTier, tags: [String], intervalDays: Int?) -> DateComponents {
        let base: DateComponents
        if let d = intervalDays, d > 0 { base = DateComponents(day: d) }
        else {
            switch tier {
            case .family: base = DateComponents(month: 1)
            case .close: base = DateComponents(day: 14)
            case .network: base = DateComponents(month: 3)
            }
        }
        guard let cap = TagRules.intervalCapMonths(tags: tags) else { return base }
        if let m = base.month, m <= cap { return base }
        if let d = base.day, d <= cap * 28 { return base }
        return DateComponents(month: cap)
    }

    public static func add(_ c: DateComponents, to d: Date) -> Date { AppTime.calendar.date(byAdding: c, to: d) ?? d }

    /// A short label: "2 weeks", "1 month", "45 days".
    public static func label(_ c: DateComponents) -> String {
        if let m = c.month { return m == 1 ? "1 month" : "\(m) months" }
        if let d = c.day { return d % 7 == 0 ? (d == 7 ? "1 week" : "\(d / 7) weeks") : "\(d) days" }
        return ""
    }

    public static func clocks(exchanges: [Exchange], added: Date, tier: PersonTier, tags: [String], intervalDays: Int?,
                              snoozedUntil: Date?, now: Date) -> Clocks {
        let live = exchanges.filter { !$0.ignored && $0.at <= now }
        let ins = live.filter { $0.direction == .incoming }.map(\.at)
        let outs = live.filter { $0.direction == .outgoing }.map(\.at)
        var conversation: Date?, via: Channel?
        // A meeting (or "We talked") is a conversation by itself.
        if let m = live.filter({ $0.direction == .met }).max(by: { $0.at < $1.at }) { conversation = m.at; via = m.channel }
        // The latest message that has one going the other way within 14 days.
        for e in live.filter({ $0.direction != .met }).sorted(by: { $0.at > $1.at }) {
            if let c = conversation, c >= e.at { break }
            let other = e.direction == .incoming ? outs : ins
            if other.contains(where: { abs($0.timeIntervalSince(e.at)) <= conversationWindow }) { conversation = e.at; via = e.channel; break }
        }
        let interval = interval(tier: tier, tags: tags, intervalDays: intervalDays)
        let dueDate = add(interval, to: conversation ?? added)
        let outreach = outs.max()
        let snoozed = snoozedUntil.map { $0 > now } ?? false
        let reachedOut = outreach.map { now.timeIntervalSince($0) < outreachQuiet } ?? false
        return Clocks(lastConversation: conversation, conversationVia: via, lastHeard: ins.max(), lastOutreach: outreach,
                      snoozedUntil: snoozed ? snoozedUntil : nil, dueDate: dueDate, due: dueDate <= now && !snoozed && !reachedOut,
                      interval: interval)
    }
}
