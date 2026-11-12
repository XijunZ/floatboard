import FloatBoardCore
import AppKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject var ui: UIState

    var body: some View {
        Group {
            switch ui.mode {
            case .minimized: MinimizedPill()
            default: BannerView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: ui.mode == .minimized ? 12 : 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ui.mode == .minimized ? 12 : 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12)))
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// The default one-line view: every open task in a single row.
struct BannerView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var ui: UIState

    var body: some View {
        let active = ui.bar.sorted(store.cards.filter { $0.status.onBar && !$0.withdrawn }, groupOrder: store.areas.map(\.name))
        HStack(spacing: 8) {
            Grip()
            let problems = store.healthProblems
            if !problems.isEmpty {
                Button {
                    // Errors and backup problems are explained in Activity; when only connectors are involved, the Connectors tab.
                    if problems.contains(where: \.isAppWide) { NotificationCenter.default.post(name: .floatBoardShowActivity, object: "open") }
                    else { ui.tab = .connectors; ui.mode = .expanded }
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .help("Needs attention — click to open " + (problems.contains(where: \.isAppWide) ? "Activity" : "Connectors") + "\n" + problems.map(\.message).joined(separator: "\n"))
            }
            // Overview of everything open, regardless of the bar's filters.
            BarCount(open: store.active)
            Divider().frame(height: 14)
            if ui.quickAdding {
                QuickAddField()
            } else if active.isEmpty {
                Text(store.active.isEmpty ? "No tasks yet. Click + (or press ⌃⌥N) to add one."
                                          : "Nothing matches the bar's filters (≡ → Bar…).")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            } else {
                Marquee(active: ui.hovering) {
                    HStack(spacing: 6) { ForEach(active) { Chip(card: $0) } }
                }
            }
            Divider().frame(height: 14)
            if !ui.quickAdding {
                BarButton("plus", "Quick add a task here (⌃⌥N)") { ui.openAdd() }
            }
            BarButton("rectangle.expand.vertical", "Open full board (due dates, importance, history)") { ui.mode = .expanded }
            BarButton("minus", "Minimise to a small pill") { ui.mode = .minimized }
            BarButton("xmark", "Close (⌃⌥B or menu bar icon to reopen)") { ui.mode = .hidden }
        }
        .padding(.horizontal, 8)
    }
}

/// The count at the left of the bar. Split by step it shows icons in the board's column order (○ to do, ◐ doing,
/// 👁 watch, the last only when there is one); otherwise "7 tasks". The words are in the tooltip.
struct BarCount: View {
    @EnvironmentObject var ui: UIState
    let open: [Card]

    var body: some View {
        let label = ui.bar.countLabel(open)
        Group {
            if ui.bar.splitCount ?? false {
                let n = { (s: Status) in open.filter { $0.status == s }.count }
                HStack(spacing: 8) {
                    part(Status.todo.icon, n(.todo))
                    part(Status.doing.icon, n(.doing))
                    if n(.watch) > 0 { part(Status.watch.icon, n(.watch)) }
                }
            } else {
                Text(label)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .fixedSize()
        .help(label)
    }

    private func part(_ icon: String, _ count: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text("\(count)").monospacedDigit()
        }
    }
}

/// Drag this to move the bar. Position is remembered.
struct Grip: View {
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 22)
            .overlay(DragHandle())
            .help("Menu")
    }
}

/// One-line add box inside the banner: type, Enter to add (stays open for the next one), Esc to finish.
struct QuickAddField: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var ui: UIState
    /// Last group picked here; empty (or a group that no longer exists) means the board's first group.
    @AppStorage("quickArea") private var areaRaw = ""
    @FocusState private var focused: Bool

    var body: some View {
        let area = store.resolve(areaRaw)
        HStack(spacing: 6) {
            Menu {
                ForEach(store.areas) { a in Button(a.name) { areaRaw = a.name } }
                Divider()
                Button("Manage groups…") { ui.tab = .groups; ui.quickAdding = false; ui.mode = .expanded }
            } label: {
                HStack(spacing: 4) {
                    Circle().fill(store.color(area)).frame(width: 7, height: 7)
                    Text(area).font(.system(size: 11))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Group for the new task (↑↓ to switch)")
            TextField("New task: ↑↓ change group, Enter to add, Esc to finish", text: $ui.quickDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                .onSubmit {
                    store.add(title: ui.quickDraft, area: area, importance: .medium, due: nil)
                    ui.quickDraft = ""
                    focused = true
                }
                .onExitCommand { ui.quickAdding = false }
                .onKeyPress(.upArrow) { areaRaw = store.shift(area, by: -1); return .handled }
                .onKeyPress(.downArrow) { areaRaw = store.shift(area, by: 1); return .handled }
            BarButton("checkmark", "Done adding") {
                if !ui.quickDraft.trimmingCharacters(in: .whitespaces).isEmpty {
                    store.add(title: ui.quickDraft, area: area, importance: .medium, due: nil)
                }
                ui.quickAdding = false
            }
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true } }
    }
}

struct Chip: View {
    @EnvironmentObject var ui: UIState
    @EnvironmentObject var store: Store
    let card: Card

    private static let monthDay: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd"; return f
    }()

    @ViewBuilder private func field(_ f: BarConfig.Field) -> some View {
        switch f {
        case .groupDot:
            Circle().fill(store.color(card.area)).frame(width: 7, height: 7)
        case .title:
            Text(card.title).lineLimit(1)
        case .dueDate:
            if let due = card.due {
                Text(Self.monthDay.string(from: due)).monospacedDigit()
                    .foregroundStyle(card.isOverdue ? Color.red : Color.secondary)
            }
        case .dueTime:
            if let due = card.due, card.dueHasTime {
                Text(Fmt.clock(due)).monospacedDigit()
                    .foregroundStyle(card.isOverdue ? Color.red : Color.secondary)
            }
        case .importance:
            Text(card.importance.marks)
                .font(.system(size: 11, weight: card.importance.weight, design: .rounded))
                .foregroundStyle(card.importance.color)
        case .groupName:
            Text(card.area).foregroundStyle(store.color(card.area))
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(ui.bar.shownFields) { field($0) }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(Capsule().fill(UrgencyStyle.fill(card.urgency, neutral: Color.primary.opacity(0.08))))
        .overlay {
            if card.urgency == .overdue {
                Capsule().strokeBorder(UrgencyStyle.ringColor, style: UrgencyStyle.ringStyle)
            } else if let tint = UrgencyStyle.tint(card.urgency) {
                Capsule().strokeBorder(tint, lineWidth: 1)
            }
        }
        .contentShape(Capsule())
        .onTapGesture { ui.mode = .expanded }
        .help(card.title)
    }
}

/// Shows content in one row; if it's wider than the space, it scrolls sideways while hovered.
struct Marquee<Content: View>: View {
    var active: Bool
    var speed: Double = 45 // points per second
    var gap: CGFloat = 48
    @ViewBuilder var content: () -> Content

    @State private var contentWidth: CGFloat = 0
    @State private var start = Date()

    var body: some View {
        GeometryReader { geo in
            let overflow = contentWidth > geo.size.width + 0.5
            ZStack(alignment: .leading) {
                content().fixedSize().hidden()
                    .background(GeometryReader { p in
                        Color.clear.preference(key: WidthKey.self, value: p.size.width)
                    })
                if overflow && active {
                    TimelineView(.animation) { tl in
                        let cycle = Double(contentWidth + gap)
                        let x = (tl.date.timeIntervalSince(start) * speed).truncatingRemainder(dividingBy: cycle)
                        HStack(spacing: gap) { content(); content() }
                            .fixedSize()
                            .offset(x: -CGFloat(x))
                    }
                } else {
                    content().fixedSize()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .clipped()
            .mask(
                LinearGradient(stops: [
                    .init(color: overflow && active ? .clear : .black, location: 0),
                    .init(color: .black, location: 0.025),
                    .init(color: .black, location: 0.95),
                    .init(color: overflow ? .clear : .black, location: 1),
                ], startPoint: .leading, endPoint: .trailing)
            )
        }
        .onPreferenceChange(WidthKey.self) { contentWidth = $0 }
        .onChange(of: active) { _, now in if now { start = Date() } }
    }
}

private struct WidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct MinimizedPill: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var ui: UIState

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checklist")
            Text("\(store.active.count)").font(.system(size: 12, weight: .semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { ui.mode = .banner }
        .help("Show FloatBoard")
    }
}

struct BarButton: View {
    let symbol: String
    let tip: String
    let action: () -> Void
    init(_ symbol: String, _ tip: String, action: @escaping () -> Void) {
        self.symbol = symbol; self.tip = tip; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(tip)
    }
}
