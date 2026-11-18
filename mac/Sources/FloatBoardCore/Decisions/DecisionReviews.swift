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
        do {
            if case .saved(let jot) = try answerOrThrow(id, happened: happened, sound: sound, source: source, store: store, now: now) { return jot }
            return nil
        } catch {
            store.activity("decisions", .error, "Could not save a decision review", detail: "\(error)")
            return nil
        }
    }

    /// What became of an answer: saved, already answered (a repeat), or one that can never be saved (empty, or the decision is
    /// gone). Throws when it couldn't be read or written; nothing is changed then.
    public enum AnswerOutcome: Equatable { case saved(Jot), alreadyAnswered, invalid(String) }

    /// `answer` as one transaction: the review jot (linked review-of the decision first, so the D-n its heading names never
    /// replaces that link), its tags and the decision's review state are written together or not at all.
    /// `keepLater`: an answer arriving after the review was done (the phone's, typed before it knew) is kept as another
    /// review when its words differ; otherwise a done review is not answered again.
    public static func answerOrThrow(_ id: Int64, happened: String, sound: String, source: ItemSource = .typed, store: Store,
                                     now: Date = Date(), keepLater: Bool = false) throws -> AnswerOutcome {
        guard let d = try DecisionStore(store: store).decisionOrThrow(id) else { return .invalid("decision not found") }
        if d.deleted { return .invalid("decision removed") }
        guard !(happened + sound).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .invalid("empty answer") }
        let js = JotStore(store: store)
        let text = reviewText(d, happened: happened, sound: sound)
        if d.reviewState == .done && !keepLater { return .alreadyAnswered }
        if d.reviewState == .done {
            // Answered already: the same words again are a repeat; different words are kept as another review (never dropped).
            let existing = store.itemLinks(of: d.shortID).filter { $0.kind == .reviewOf && !$0.isSubject && $0.other.kind == .jot }
            for l in existing where try js.jotOrThrow(l.other.number)?.text == text { return .alreadyAnswered }
        }
        let n = try store.performThrowing { () -> Int64 in
            let n = try js.createRow(text: text, source: source, now: now,
                                     linkFirst: [(d.shortID, .reviewOf, .auto)], actor: .connector("decisions"))
            let tags = store.itemTags(d.shortID)
            if let p = tags.all.first { try store.setTagsRow(ShortID(kind: .jot, number: n), primary: p, others: Array(tags.all.dropFirst()), now: now) }
            try store.db.run("UPDATE decisions SET review_state='done', reviewed=?, updated=? WHERE id=?", [now, now, id])
            return n
        }
        guard let jot = try js.jotOrThrow(n) else { throw DBError.sql("the review jot was not found after saving") }
        return .saved(jot)
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
