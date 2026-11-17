import AppKit
import FloatBoardCore
import SwiftUI

/// Selected text and the item it was selected in (nil when the text belongs to no item).
struct SelectionContext {
    let text: String
    let source: ShortID?
}

/// What "Make task" opens: the form, filled in from a selection.
struct MakeTaskRequest: Identifiable {
    let id = UUID()
    let selection: String
    let source: ShortID?
}

/// Right-click on selected text, the same everywhere text is shown (features: ground rules): Make task, Make decision
/// (registered by Decisions, hidden while it is off), Copy id link.
@MainActor enum SelectionActions {
    struct Action {
        let id: String
        let title: String
        let module: Module?
        let run: @MainActor (SelectionContext) -> Void
    }
    private static var registered: [Action] = []

    /// Adds (or replaces, by id) an action. Decisions registers "make_decision" with module `.decisions`.
    static func register(_ a: Action) { registered.removeAll { $0.id == a.id }; registered.append(a) }

    /// The built-ins first (Make task, then registered ones such as Make decision, then Copy id link); actions of modules that are off are left out.
    static func available(_ store: Store, ui: UIState, source: ShortID?) -> [Action] {
        let makeTask = Action(id: "make_task", title: "Make task", module: nil) { ctx in
            ui.mode = .expanded
            ui.makeTask = MakeTaskRequest(selection: ctx.text, source: ctx.source)
        }
        var out = [makeTask] + registered.filter { $0.module.map(store.isOn) ?? true }
        if let source {
            out.append(Action(id: "copy_id", title: "Copy id link (\(source.text))", module: nil) { _ in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(source.text, forType: .string)
            })
        }
        return out
    }
}

/// A text view whose right-click menu adds the selection actions above the usual items (Copy, Look Up, …).
final class SelectionTextView: NSTextView {
    var actions: () -> [SelectionActions.Action] = { [] }
    var source: ShortID?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let range = selectedRange()
        guard range.length > 0, let text = (string as NSString?)?.substring(with: range),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return menu }
        let list = MainActor.assumeIsolated { actions() }
        for (i, a) in list.enumerated() {
            let item = NSMenuItem(title: a.title, action: #selector(runAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = SelectionBox(action: a, context: SelectionContext(text: text, source: source))
            menu.insertItem(item, at: i)
        }
        if !list.isEmpty { menu.insertItem(.separator(), at: list.count) }
        return menu
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? SelectionBox else { return }
        MainActor.assumeIsolated { box.action.run(box.context) }
    }

    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else { return super.intrinsicContentSize }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(used.height + textContainerInset.height * 2))
    }

    override func didChangeText() { super.didChangeText(); invalidateIntrinsicContentSize() }
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }
}

private final class SelectionBox: NSObject {
    let action: SelectionActions.Action
    let context: SelectionContext
    init(action: SelectionActions.Action, context: SelectionContext) { self.action = action; self.context = context }
}

/// Read-only text that can be selected, with the selection actions on right-click. Links in it open as usual.
struct SelectableText: NSViewRepresentable {
    let text: AttributedString
    let source: ShortID?
    var fontSize: CGFloat = 12
    @EnvironmentObject var store: Store
    @EnvironmentObject var ui: UIState

    init(_ text: String, source: ShortID?, fontSize: CGFloat = 12) { self.text = AttributedString(text); self.source = source; self.fontSize = fontSize }
    init(attributed: AttributedString, source: ShortID?, fontSize: CGFloat = 12) { self.text = attributed; self.source = source; self.fontSize = fontSize }

    func makeNSView(context: Context) -> SelectionTextView {
        let v = SelectionTextView()
        v.isEditable = false; v.isSelectable = true; v.drawsBackground = false
        v.textContainerInset = .zero; v.textContainer?.lineFragmentPadding = 0
        v.textContainer?.widthTracksTextView = true
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    func updateNSView(_ v: SelectionTextView, context: Context) {
        let s = NSMutableAttributedString(text)
        let all = NSRange(location: 0, length: s.length)
        s.addAttribute(.font, value: NSFont.systemFont(ofSize: fontSize), range: all)
        s.addAttribute(.foregroundColor, value: NSColor.labelColor, range: all)
        if v.attributedString() != s { v.textStorage?.setAttributedString(s); v.invalidateIntrinsicContentSize() }
        v.source = source
        let store = store, ui = ui, source = source
        v.actions = { SelectionActions.available(store, ui: ui, source: source) }
    }
}

/// Editable text with the same right-click actions (for jots, task notes and reviews in the areas).
struct SelectableTextEditor: NSViewRepresentable {
    @Binding var text: String
    let source: ShortID?
    var fontSize: CGFloat = 12
    @EnvironmentObject var store: Store
    @EnvironmentObject var ui: UIState

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> SelectionTextView {
        let v = SelectionTextView()
        v.isEditable = true; v.isRichText = false; v.allowsUndo = true; v.drawsBackground = false
        v.font = .systemFont(ofSize: fontSize)
        v.textContainer?.widthTracksTextView = true
        v.delegate = context.coordinator
        return v
    }

    func updateNSView(_ v: SelectionTextView, context: Context) {
        if v.string != text { v.string = text; v.invalidateIntrinsicContentSize() }
        v.source = source
        let store = store, ui = ui, source = source
        v.actions = { SelectionActions.available(store, ui: ui, source: source) }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ n: Notification) {
            guard let v = n.object as? NSTextView else { return }
            text.wrappedValue = v.string
        }
    }
}
