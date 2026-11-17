import Foundation

/// D6 reviews (features §4, §9): one review per decision, 30 / 90 / 180 days after its recorded date, asked inside the
/// shared reminder budget; the answer is saved as a jot linked review-of. Also the Decisions sections of the weekly review (D4).
@MainActor public enum DecisionReviews {
    public static let snoozeDays = 7

    /// Decisions whose review is due by `date`: scheduled, live, decided or tentative. Oldest due first.
    public static func due(store: Store, by date: Date) -> [Decision] {
        DecisionStore(store: store).all().filter { d in
            d.reviewState == .scheduled && (d.status == .decided || d.status == .tentative) && (d.reviewDue.map { $0 <= date } ?? false)
        }.sorted { ($0.reviewDue ?? .distantPast, $0.id) < ($1.reviewDue ?? .distantPast, $1.id) }
    }

    /// The reminder's words.
    public static func reminderText(_ d: Decision) -> String { "Review \(d.shortID.text): \(d.text) — what happened?" }

    /// Asks the shared budget for each due review not yet reminded (checked every 10 minutes while Decisions is on). One
    /// reminder per review ("once each"): once granted it is not asked again; the review then stays on the weekly review page
    /// until answered, snoozed (which reminds once more) or turned off. Over the day's limit or in quiet hours: asked again then.
    @discardableResult
    public static func askBudget(store: Store, now: Date = Date()) -> [ReminderGrant] {
        guard store.isOn(.decisions) else { return [] }
        let budget = ReminderBudget(store: store)
        var out: [ReminderGrant] = []
        for d in due(store: store, by: now) where (d.reviewAskAfter ?? .distantPast) <= now {
            let g = budget.request(kind: .decisionReview, itemID: d.shortID, text: reminderText(d), now: now)
            out.append(g)
            let next: Date
            switch g {
            case .granted, .duplicate: next = remindedMark
            case .deferred(let until): next = until
            }
            store.perform { try store.db.run("UPDATE decisions SET review_ask_after=? WHERE id=?", [next, d.id]) }
        }
        return out
    }

    /// `review_ask_after` once the review's reminder was granted: never asked again (until a snooze clears it).
    static let remindedMark = Date(timeIntervalSince1970: 32_503_680_000)   // year 3000

    /// The review jot's text: a heading naming the decision, then the two answers.
    public static func reviewText(_ d: Decision, happened: String, sound: String) -> String {
        """
        Review of \(d.shortID.text): \(d.text)
        What happened? \(happened.trimmingCharacters(in: .whitespacesAndNewlines))
        Was the thinking sound? \(sound.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    /// Saves the answer as a jot (through JotStore), linked review-of the decision (auto), and marks the review done.
    /// A review already answered is not answered again (nil): the phone may send the same answer twice.
    @discardableResult
    public static func answer(_ id: Int64, happened: String, sound: String, source: ItemSource = .typed, store: Store, now: Date = Date()) -> Jot? {
        guard let d = DecisionStore(store: store).decision(id), !d.deleted, d.reviewState != .done else { return nil }
        guard !(happened + sound).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let jot = JotStore(store: store).create(text: reviewText(d, happened: happened, sound: sound), source: source, now: now) else { return nil }
        // The heading names D-n, which JotStore links as a typed id (related, manual); the link is the review's own instead.
        store.unlink(jot.shortID, d.shortID)
        store.link(jot.shortID, d.shortID, kind: .reviewOf, madeBy: .auto, actor: .connector("decisions"), now: now)
        let tags = store.itemTags(d.shortID)
        if let p = tags.all.first { store.setTags(jot.shortID, primary: p, others: Array(tags.all.dropFirst()), now: now) }
        store.perform { try store.db.run("UPDATE decisions SET review_state='done', reviewed=?, updated=? WHERE id=?", [now, now, id]) }
        return jot
    }

    /// Snooze: the review comes back `snoozeDays` days from now (or from its date, if that is later).
    public static func snooze(_ id: Int64, store: Store, now: Date = Date()) {
        guard let d = DecisionStore(store: store).decision(id) else { return }
        let from = max(now, d.reviewDue ?? now)
        let next = AppTime.calendar.date(byAdding: .day, value: snoozeDays, to: from) ?? from.addingTimeInterval(Double(snoozeDays) * 86400)
        store.perform { try store.db.run("UPDATE decisions SET review_due=?, review_ask_after=NULL, review_state='scheduled', updated=? WHERE id=?", [next, now, id]) }
    }

    /// Turns this decision's review off, or back on (scheduled at its date).
    public static func setOn(_ id: Int64, _ on: Bool, store: Store, now: Date = Date()) {
        store.perform {
            try store.db.run("UPDATE decisions SET review_state=?, updated=? WHERE id=? AND review_state<>'done'",
                             [on ? DecisionReviewState.scheduled.rawValue : DecisionReviewState.off.rawValue, now, id])
        }
    }

    /// "Check in with <name> about how it went" for each person linked to the decision (code, D7).
    public static func checkInTitles(_ id: Int64, store: Store) -> [(Person, String)] {
        DecisionStore(store: store).people(of: id).map { ($0, "Check in with \($0.name) about how it went") }
    }

    // MARK: Weekly review sections (D4)

    public static let recordedSection = "decisions.recorded", maybeSection = "decisions.maybe", reviewsSection = "decisions.reviews"

    /// Decisions recorded into FloatBoard this week (not Maybe), newest first.
    public static func recordedThisWeek(store: Store, week: DateInterval) -> [Decision] {
        DecisionStore(store: store).all().filter { $0.status != .maybe && week.contains($0.added) }.sorted { ($0.added, $0.id) > ($1.added, $1.id) }
    }

    /// Every open Maybe item (they stay until recorded or dismissed).
    public static func maybe(store: Store) -> [Decision] { DecisionStore(store: store).all().filter { $0.status == .maybe } }

    public static func registerSections() {
        WeeklyReview.register(ReviewSection(id: recordedSection, title: "Decisions recorded this week", module: .decisions, order: 10) { store, week in
            recordedThisWeek(store: store, week: week).map { d in
                ReviewItem(id: d.shortID.text, item: d.shortID, title: d.text,
                           detail: [d.foundByClaude ? "found by Claude" : "by you", "from \(d.sourceLabel)",
                                    d.needsPrediction ? "add expected outcome and confidence" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
            }
        })
        WeeklyReview.register(ReviewSection(id: maybeSection, title: "Maybe decisions", module: .decisions, order: 20) { store, _ in
            maybe(store: store).map { ReviewItem(id: $0.shortID.text, item: $0.shortID, title: $0.text, detail: "from \($0.sourceLabel)") }
        })
        WeeklyReview.register(ReviewSection(id: reviewsSection, title: "Decision reviews due", module: .decisions, order: 30) { store, week in
            due(store: store, by: week.end).map { d in
                ReviewItem(id: d.shortID.text, item: d.shortID, title: d.text,
                           detail: "\(d.type.title) · due \(Fmt.short(d.reviewDue ?? Date()))")
            }
        })
    }
}
