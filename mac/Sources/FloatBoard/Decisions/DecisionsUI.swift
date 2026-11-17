import FloatBoardConnectors
import FloatBoardCore
import SwiftUI

/// What "Make decision" opens: the form, filled in from a selection.
struct MakeDecisionRequest: Identifiable {
    let id = UUID()
    let selection: String
    let source: ShortID?
}

/// The Decisions area's app state: the selected decision, the open form and review, and the last "Not a decision" (Undo).
@MainActor final class DecisionsUI: ObservableObject {
    static let shared = DecisionsUI()
    @Published var selected: Int64?
    @Published var make: MakeDecisionRequest?
    @Published var review: ReviewTarget?
    @Published var dismissed: Int64?

    struct ReviewTarget: Identifiable { let id: Int64 }

    /// "Not a decision" with an Undo bar.
    func notADecision(_ id: Int64, store: Store) {
        DecisionStore(store: store).notADecision(id)
        if selected == id { selected = nil }
        dismissed = id
        objectWillChange.send()
    }

    func undoDismiss(store: Store) {
        guard let id = dismissed else { return }
        DecisionStore(store: store).undoNotADecision(id)
        dismissed = nil
    }
}

/// Launch: registrations with the foundation (selection action, weekly review rows, search, phone step) and the area's
/// timer (review reminders inside the budget, the weekly screening when due).
@MainActor enum DecisionsApp {
    private static var timer: Timer?

    static func start(store: Store, ui: UIState) {
        DecisionsArea.registerCore()
        DecisionsEngine.register()
        SelectionActions.register(.init(id: "make_decision", title: "Make decision", module: .decisions) { ctx in
            ui.mode = .expanded
            DecisionsUI.shared.make = MakeDecisionRequest(selection: ctx.text, source: ctx.source)
        })
        // The phone's "Make decision" on a jot (Jots §4) opens the same form on the Mac, filled from the jot's text and
        // linked to it. While Decisions is off, or another Make decision form is open, it stays waiting on the engine.
        JotActions.makeDecision = { store, text, source in
            guard store.isOn(.decisions), DecisionsUI.shared.make == nil else { return false }
            ui.mode = .expanded
            DecisionsUI.shared.make = MakeDecisionRequest(selection: text, source: source)
            store.activity("decisions", .info, "Make decision from the phone: the form is open", detail: source.text)
            return true
        }
        GlobalSearchOpen.handlers[.decision] = { id in
            ui.tab = .decisions
            DecisionsUI.shared.selected = id.number
        }
        WeeklyReviewRows.views[DecisionReviews.recordedSection] = { AnyView(DecisionReviewRow(item: $0, kind: .recorded)) }
        WeeklyReviewRows.views[DecisionReviews.maybeSection] = { AnyView(DecisionReviewRow(item: $0, kind: .maybe)) }
        WeeklyReviewRows.views[DecisionReviews.reviewsSection] = { AnyView(DecisionReviewRow(item: $0, kind: .review)) }
        WeeklyReview.onNudge { tick(store: store) }
        // Switching Decisions off stops its jobs (each run also checks the switch); on again: catch up at once.
        ModuleHooks.onChange(.decisions) { on in if on { tick(store: store) } }
        let t = Timer(timeInterval: 10 * 60, repeats: true) { _ in MainActor.assumeIsolated { tick(store: store) } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { tick(store: store) }
    }

    /// Reviews into the budget; the weekly screening when it is due (weekly batch only, never per jot).
    static func tick(store: Store, now: Date = Date()) {
        guard store.isOn(.decisions) else { return }
        DecisionReviews.askBudget(store: store, now: now)
        guard DecisionScreening.isDue(now: now, lastRun: DecisionScreening.lastRun(store: store)), let (id, client) = DecisionsEngine.client(store: store) else { return }
        Task { @MainActor in await DecisionsEngine.screenIfDue(store: store, connector: id, client: client, now: now) }
    }
}

/// The form and review sheets, shown over the expanded board wherever they were asked for.
struct DecisionSheets: ViewModifier {
    @ObservedObject var dui = DecisionsUI.shared
    func body(content: Content) -> some View {
        content
            .sheet(item: $dui.make) { req in MakeDecisionForm(request: req) { dui.make = nil } }
            .sheet(item: $dui.review) { t in DecisionReviewSheet(decisionID: t.id) { dui.review = nil } }
    }
}

extension View {
    func decisionSheets() -> some View { modifier(DecisionSheets()) }
}

/// "Marked not a decision · Undo" after "Not a decision".
struct DecisionUndoBar: View {
    @ObservedObject var dui = DecisionsUI.shared
    @EnvironmentObject var store: Store

    var body: some View {
        if let id = dui.dismissed {
            HStack(spacing: 10) {
                Text("D-\(id) marked not a decision").lineLimit(1)
                Button("Undo") { dui.undoDismiss(store: store) }.buttonStyle(.borderedProminent).controlSize(.small)
                Button { dui.dismissed = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
            .shadow(radius: 6, y: 2)
            .padding(.bottom, 16)
            .task(id: id) {
                try? await Task.sleep(for: .seconds(Store.undoBarSeconds)) // try?-ok: cancelled when another dismissal replaces this bar
                if !Task.isCancelled && dui.dismissed == id { dui.dismissed = nil }
            }
        }
    }
}
