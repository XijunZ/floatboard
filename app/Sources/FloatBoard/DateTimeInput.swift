import FloatBoardCore
import SwiftUI

/// Typed date/time entry split into segments (HH:MM or YYYY-MM-DD).
/// Digits fill the active segment and jump to the next once it's complete;
/// ← → move between segments, ↑ ↓ nudge the value, ⌫ deletes the last digit typed.
struct SegmentModel: Equatable {
    struct Spec: Equatable {
        let length: Int
        let range: ClosedRange<Int>
        /// A first digit above this can't start a valid 2-digit value, so it completes the segment at once
        /// (e.g. "9" in the hour → 09).
        let jumpAbove: Int
    }

    let specs: [Spec]
    var values: [Int]
    var active = 0
    var buffer = ""

    static func time(_ d: Date) -> SegmentModel {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return SegmentModel(specs: [Spec(length: 2, range: 0...23, jumpAbove: 2),
                                    Spec(length: 2, range: 0...59, jumpAbove: 5)],
                            values: [c.hour ?? 0, c.minute ?? 0])
    }

    static func date(_ d: Date) -> SegmentModel {
        let c = Calendar.current.dateComponents([.day, .month, .year], from: d)
        return SegmentModel(specs: [Spec(length: 4, range: 2000...2099, jumpAbove: 9),
                                    Spec(length: 2, range: 1...12, jumpAbove: 1),
                                    Spec(length: 2, range: 1...31, jumpAbove: 3)],
                            values: [c.year ?? 2026, c.month ?? 1, c.day ?? 1])
    }

    mutating func digit(_ d: Int) {
        buffer.append(String(d))
        let spec = specs[active]
        if buffer.count >= spec.length || (buffer.count == 1 && spec.length == 2 && d > spec.jumpAbove) {
            commit()
            if active < specs.count - 1 { active += 1 }
        }
    }

    mutating func commit() {
        guard !buffer.isEmpty, var v = Int(buffer) else { buffer = ""; return }
        let spec = specs[active]
        if spec.length == 4 && buffer.count <= 2 { v += 2000 } // "26" → 2026
        values[active] = min(max(v, spec.range.lowerBound), spec.range.upperBound)
        buffer = ""
    }

    mutating func left() { commit(); active = max(0, active - 1) }
    mutating func right() { commit(); active = min(specs.count - 1, active + 1) }
    mutating func select(_ i: Int) { commit(); active = i }

    mutating func step(_ by: Int) {
        commit()
        let r = specs[active].range
        let span = r.upperBound - r.lowerBound + 1
        values[active] = r.lowerBound + ((values[active] - r.lowerBound + by) % span + span) % span
    }

    mutating func backspace() { if !buffer.isEmpty { buffer.removeLast() } }

    /// Shared keyboard handling for the field and the clock/calendar pop-up.
    mutating func handle(_ p: KeyPress) -> KeyPress.Result {
        switch p.key {
        case .leftArrow: left()
        case .rightArrow: right()
        case .upArrow: step(1)
        case .downArrow: step(-1)
        case .delete, .deleteForward: backspace()
        default:
            guard let c = p.characters.first, c.isASCII, let d = c.wholeNumberValue else { return .ignored }
            digit(d)
        }
        return .handled
    }

    func display(_ i: Int) -> String {
        let len = specs[i].length
        if i == active && !buffer.isEmpty {
            return buffer + String(repeating: "–", count: max(0, len - buffer.count))
        }
        return String(format: "%0\(len)d", values[i])
    }

    /// Apply HH:MM to `base`'s day.
    func applyTime(to base: Date) -> Date {
        Calendar.current.date(bySettingHour: values[0], minute: values[1], second: 0, of: base) ?? base
    }

    /// Apply YYYY-MM-DD to `base`, keeping its time of day; day is clamped to the month's length.
    func applyDate(to base: Date) -> Date {
        let cal = Calendar.current
        var c = cal.dateComponents([.hour, .minute, .second], from: base)
        c.year = values[0]; c.month = values[1]; c.day = 1
        guard let first = cal.date(from: c), let days = cal.range(of: .day, in: .month, for: first)?.count else { return base }
        return cal.date(byAdding: .day, value: min(values[2], days) - 1, to: first) ?? base
    }
}

/// Links the add row's controls so ← → can walk through all of them and Enter submits from any.
struct NavChain {
    var current: Binding<String?>
    var move: (String, Int) -> Void
    var submit: () -> Void
}

/// The segmented, keyboard-driven box itself.
struct SegmentedInput: View {
    @Binding var model: SegmentModel
    let separator: String
    /// Show the active-segment highlight even when typing is being routed through the pop-up.
    var highlight = false
    /// Called when the field is clicked (opens the clock/calendar).
    var onActivate: () -> Void = {}
    /// Optional: part of the add row's ← → chain.
    var nav: NavChain? = nil
    var navID = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<model.specs.count, id: \.self) { i in
                if i > 0 { Text(separator).foregroundStyle(.secondary) }
                Text(model.display(i))
                    .monospacedDigit()
                    .padding(.horizontal, 2)
                    .background(RoundedRectangle(cornerRadius: 3)
                        .fill((focused || highlight) && model.active == i ? Color.accentColor.opacity(0.35) : Color.clear))
                    .contentShape(Rectangle())
                    .onTapGesture { model.select(i); focused = true; onActivate() }
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .strokeBorder(focused || highlight ? Color.accentColor : Color.primary.opacity(0.2),
                          lineWidth: focused || highlight ? 1.5 : 1))
        .focusable(interactions: .edit)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            if let nav {
                let last = model.specs.count - 1
                // ← on the first part / → on the last part leaves the box for the neighbouring control.
                if press.key == .leftArrow && model.active == 0 && model.buffer.isEmpty {
                    nav.move(navID, -1); return .handled
                }
                if press.key == .rightArrow && model.active == last && model.buffer.isEmpty {
                    nav.move(navID, 1); return .handled
                }
                if press.key == .return { model.commit(); nav.submit(); return .handled }
            }
            return model.handle(press)
        }
        .onChange(of: focused) { _, now in
            if now { nav?.current.wrappedValue = navID } else { model.commit() }
        }
        .onChange(of: nav?.current.wrappedValue ?? nil) { _, id in
            if nav != nil, id == navID, !focused { focused = true }
        }
        .fixedSize()
    }
}

/// Pop-up content (clock or calendar). While open it takes keyboard focus, so it forwards
/// digits and arrows to the same model: you can keep typing without closing it.
struct PickerPopover<Content: View>: View {
    @Binding var model: SegmentModel
    var close: () -> Void
    @ViewBuilder var content: () -> Content
    @FocusState private var focused: Bool

    var body: some View {
        content()
            .padding(10)
            .focusable(interactions: .edit)
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { p in
                if p.key == .escape || p.key == .return || p.key == .tab { model.commit(); close(); return .handled }
                return model.handle(p)
            }
            .onAppear { DispatchQueue.main.async { focused = true } }
            // After dragging the clock hands / clicking a day, take keyboard focus back.
            .onChange(of: model.values) { _, _ in focused = true }
    }
}

/// HH:MM you can type; clicking it opens a clock face (drag the hands) right away.
struct TimeInput: View {
    @Binding var time: Date
    var nav: NavChain? = nil
    var navID = "time"
    @State private var model = SegmentModel.time(Date())
    @State private var showClock = false

    var body: some View {
        HStack(spacing: 3) {
            SegmentedInput(model: $model, separator: ":", highlight: showClock, onActivate: { showClock = true },
                           nav: nav, navID: navID)
                .popover(isPresented: $showClock, arrowEdge: .bottom) {
                    PickerPopover(model: $model, close: { showClock = false }) {
                        DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                    }
                }
        }
        .onAppear { model = .time(time) }
        .onChange(of: model.values) { _, _ in time = model.applyTime(to: time) }
        .onChange(of: time) { _, t in
            let fresh = SegmentModel.time(t)
            if fresh.values != model.values { model.values = fresh.values }
        }
    }
}

/// YYYY-MM-DD you can type; clicking it opens a calendar right away.
struct DateInput: View {
    @Binding var date: Date
    var nav: NavChain? = nil
    var navID = "date"
    @State private var model = SegmentModel.date(Date())
    @State private var showCalendar = false

    var body: some View {
        HStack(spacing: 3) {
            SegmentedInput(model: $model, separator: "-", highlight: showCalendar, onActivate: { showCalendar = true },
                           nav: nav, navID: navID)
                .popover(isPresented: $showCalendar, arrowEdge: .bottom) {
                    PickerPopover(model: $model, close: { showCalendar = false }) {
                        DatePicker("", selection: $date, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                    }
                }
        }
        .onAppear { model = .date(date) }
        .onChange(of: model.values) { _, _ in date = model.applyDate(to: date) }
        .onChange(of: date) { _, d in
            let fresh = SegmentModel.date(d)
            if fresh.values != model.values { model.values = fresh.values }
        }
    }
}

/// Checkbox that works from the keyboard: Space ticks/unticks, ← → move along the chain, Enter submits.
struct FocusCheck: View {
    let label: String
    @Binding var isOn: Bool
    var nav: NavChain? = nil
    var navID = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            Text(label)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(focused ? Color.accentColor : Color.clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle(); focused = true }
        .focusable(interactions: .edit)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.space) { isOn.toggle(); return .handled }
        .onKeyPress(.leftArrow) { nav?.move(navID, -1); return .handled }
        .onKeyPress(.rightArrow) { nav?.move(navID, 1); return .handled }
        .onKeyPress(.return) { nav?.submit(); return .handled }
        .onChange(of: focused) { _, now in if now { nav?.current.wrappedValue = navID } }
        .onChange(of: nav?.current.wrappedValue ?? nil) { _, id in
            if nav != nil, id == navID, !focused { focused = true }
        }
        .fixedSize()
    }
}

/// Button that works from the keyboard: Space/Enter press it, ← moves back along the chain.
struct FocusButton: View {
    let title: String
    var enabled = true
    var nav: NavChain? = nil
    var navID = ""
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(enabled ? Color.white : Color.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(Capsule().fill(enabled ? Color.accentColor : Color.primary.opacity(0.1)))
            .overlay(Capsule().strokeBorder(focused ? Color.primary.opacity(0.6) : Color.clear, lineWidth: 2))
            .contentShape(Rectangle())
            .onTapGesture { if enabled { action() } }
            .focusable(interactions: .edit)
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.space) { if enabled { action() }; return .handled }
            .onKeyPress(.return) { if enabled { action() }; return .handled }
            .onKeyPress(.leftArrow) { nav?.move(navID, -1); return .handled }
            .onChange(of: focused) { _, now in if now { nav?.current.wrappedValue = navID } }
            .onChange(of: nav?.current.wrappedValue ?? nil) { _, id in
                if nav != nil, id == navID, !focused { focused = true }
            }
            .fixedSize()
    }
}
