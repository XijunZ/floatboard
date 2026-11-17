import FloatBoardCore
import SwiftUI

/// Settings › Areas: each area on or off (nothing is deleted when one goes off), and the reminder budget they share.
struct AreasSection: View {
    @EnvironmentObject var store: Store
    @State private var refusal: String?
    @State private var budget = ReminderSettings()

    var body: some View {
        SettingsBlock(title: "Areas", help: "Each area has its own tab. Switching one off hides its tab and stops its background work; what it holds is kept and comes back when you switch it on.") {
            ForEach(Module.allCases, id: \.self) { m in
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.title)
                        Text(m.blurb + (m.requires.map { " Needs \($0.title)." } ?? "")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Toggle(m.title, isOn: Binding(get: { store.isOn(m) }, set: { refusal = store.setModule(m, on: $0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                .frame(maxWidth: 560)
            }
            if let refusal { Text(refusal).font(.system(size: 11)).foregroundStyle(.red) }
        }
        SettingsBlock(title: "Reminders", help: "Circle's people to contact and Decisions' reviews share one daily limit, and wait for the end of quiet hours. Each is shown once, on this Mac or on your phone. Task due reminders and the daily jot nudge are not counted.") {
            Stepper("At most \(budget.dailyLimit) a day", value: $budget.dailyLimit, in: 0...10).frame(width: 220, alignment: .leading)
            HStack(spacing: 8) {
                Text("Quiet from")
                Picker("", selection: $budget.quietStart) { ForEach(0..<24, id: \.self) { Text(Self.hour($0)).tag($0 * 60) } }.labelsHidden().frame(width: 90)
                Text("to")
                Picker("", selection: $budget.quietEnd) { ForEach(0..<24, id: \.self) { Text(Self.hour($0)).tag($0 * 60) } }.labelsHidden().frame(width: 90)
            }
            .font(.system(size: 12))
        }
        .onAppear { budget = ReminderBudget(store: store).settings }
        .onChange(of: budget) { _, new in if new != ReminderBudget(store: store).settings { ReminderBudget(store: store).save(new) } }
    }

    static func hour(_ h: Int) -> String { String(format: "%02d:00", h) }
}
