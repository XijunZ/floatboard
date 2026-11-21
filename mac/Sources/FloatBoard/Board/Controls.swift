import FloatBoardCore
import SwiftUI

/// A drop-down that opens beside its button (not over it, like macOS pop-up pickers do),
/// with a tick on the current choice and an optional coloured dot per option.
struct Dropdown<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    var title: (T) -> String = { "\($0)" }
    var dot: ((T) -> Color)? = nil
    /// At most this many characters of the chosen value on the button (then "…"); the menu shows every name in full.
    /// The button sizes itself to its text, so this is what bounds its width.
    var labelLimit: Int? = nil

    init(options: [T], selection: Binding<T>, title: @escaping (T) -> String = { "\($0)" }, dot: ((T) -> Color)? = nil, labelLimit: Int? = nil) {
        self.options = options; self._selection = selection; self.title = title; self.dot = dot; self.labelLimit = labelLimit
    }

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { o in
                Button { selection = o } label: {
                    if o == selection { Label(title(o), systemImage: "checkmark") } else { Text(title(o)) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if let dot { Circle().fill(dot(selection)).frame(width: 7, height: 7) }
                Text(labelLimit.map { Self.clipped(title(selection), $0) } ?? title(selection))
            }
        }
        .menuStyle(.button)
        .fixedSize()
    }

    /// `text` cut to `limit` characters with "…" when longer.
    static func clipped(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(max(1, limit - 1))).trimmingCharacters(in: .whitespaces) + "…" : text
    }
}

/// A keyboard-friendly, colour-coded choice button for the add row.
/// Focused: ↑↓ change the value, ←→ move to the neighbouring control, Enter submits.
/// Clicked: shows the list of choices.
struct KeyChip<T: Hashable, F: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let title: (T) -> String
    let color: (T) -> Color
    /// Coloured dot (groups); importance passes false and is shown by its "!" marks instead.
    var dot = true
    var focus: FocusState<F?>.Binding
    let field: F
    var onLeft: () -> Void
    var onRight: () -> Void
    var onSubmit: () -> Void

    private var focused: Bool { focus.wrappedValue == field }

    var body: some View {
        let c = color(selection)
        HStack(spacing: 5) {
            if dot { Circle().fill(c).frame(width: 8, height: 8) }
            Text(title(selection)).foregroundStyle(c)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        // Same language as the cards: group = filled tinted capsule, importance = outlined capsule.
        .background(Capsule().fill(dot ? c.opacity(0.18) : Color.clear))
        .overlay(Capsule().strokeBorder(focused ? Color.accentColor : (dot ? Color.clear : c.opacity(0.6)),
                                        lineWidth: focused ? 2 : 1))
        .fixedSize()
        .contentShape(Rectangle())
        .focusable(interactions: .edit)
        .focused(focus, equals: field)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { step(-1); return .handled }
        .onKeyPress(.downArrow) { step(1); return .handled }
        .onKeyPress(.leftArrow) { onLeft(); return .handled }
        .onKeyPress(.rightArrow) { onRight(); return .handled }
        .onKeyPress(.return) { onSubmit(); return .handled }
        .onTapGesture { focus.wrappedValue = field; showMenu() }
    }

    private func step(_ by: Int) {
        guard let i = options.firstIndex(of: selection), !options.isEmpty else { return }
        selection = options[(i + by + options.count) % options.count]
    }

    private func showMenu() {
        let menu = NSMenu()
        for o in options {
            let item = ClosureMenuItem(title: title(o)) { selection = o }
            item.state = o == selection ? .on : .off
            if dot {
                item.image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
                    NSColor(color(o)).setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill(); return true
                }
            }
            menu.addItem(item)
        }
        // Open just below the pointer, so it never covers the button itself.
        let p = NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: NSPoint(x: p.x - 10, y: p.y - 14), in: nil)
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

extension Notification.Name {
    static let floatBoardResetBoard = Notification.Name("FloatBoardResetBoard")
    static let floatBoardShowGuide = Notification.Name("FloatBoardShowGuide")
    static let floatBoardFocusSearch = Notification.Name("FloatBoardFocusSearch")
    static let floatBoardClearFocus = Notification.Name("FloatBoardClearFocus")
}

/// Lays out items left to right and wraps whole items onto the next line when out of room.
struct FlowLayout: Layout {
    var hSpacing: CGFloat = 8
    var vSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = fitted(v, maxW)
            if x > 0 && x + s.width > maxW { y += rowH + vSpacing; x = 0; rowH = 0 }
            x += s.width + hSpacing
            rowH = max(rowH, s.height)
            widest = max(widest, x - hSpacing)
        }
        return CGSize(width: min(widest, maxW), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = fitted(v, bounds.width)
            if x > bounds.minX && x + s.width > bounds.maxX { y += rowH + vSpacing; x = bounds.minX; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + hSpacing
            rowH = max(rowH, s.height)
        }
    }

    /// An item's own size, but never wider than the row: a long name is then cut (or wrapped) instead of running past the edge.
    private func fitted(_ v: LayoutSubview, _ maxW: CGFloat) -> CGSize {
        let s = v.sizeThatFits(.unspecified)
        guard maxW.isFinite, s.width > maxW else { return s }
        return v.sizeThatFits(ProposedViewSize(width: maxW, height: nil))
    }
}



extension View {
    /// Esc leaves a single-line field (round 38): the cursor and its focus ring go and the keyboard shortcuts work again;
    /// the typed text stays, so clicking back continues it. Not for the toolbar search (its own Esc), sheets or panels.
    func leavesOnEsc(_ also: @escaping () -> Void = {}) -> some View {
        onExitCommand {
            also()
            let w = NSApp.keyWindow ?? NSApp.windows.first { ($0.firstResponder as? NSTextView)?.isFieldEditor == true }
            w?.makeFirstResponder(nil)
        }
    }
}
