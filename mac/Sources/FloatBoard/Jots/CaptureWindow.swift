import AppKit
import FloatBoardCore
import SwiftUI

/// The capture window (J1, J2, J8): small and quiet, from anywhere with ⌃⌥J or ✎ on the bar. ⌘↩ saves the jot; Esc closes
/// and keeps the draft for next time. macOS dictation works in it (fn fn). "Jot about this" on a task opens it linked to the
/// task: the jot gets the task's tags and a link to it.
@MainActor final class CaptureController: NSObject, NSWindowDelegate {
    static weak var shared: CaptureController?
    private let store: Store
    private let ui: UIState
    private var panel: FloatingPanel?
    let model = CaptureModel()

    init(store: Store, ui: UIState) {
        self.store = store; self.ui = ui
        super.init()
        Self.shared = self
    }

    /// Opens the window (or brings it forward), linked to `task` when given.
    func show(task: Int64?) {
        guard store.isOn(.jots) else { return }
        if let task { model.task = task } else if panel?.isVisible != true { model.task = model.savedTask }
        model.restoreDraftIfEmpty()
        let p = panel ?? makePanel()
        panel = p
        if !p.isVisible { p.center(); p.setFrameOrigin(NSPoint(x: p.frame.minX, y: p.frame.minY + 120)) }
        NSApp.activate()
        p.makeKeyAndOrderFront(nil)
        model.focus += 1
    }

    func close() {
        model.keepDraft()
        panel?.orderOut(nil)
    }

    private func makePanel() -> FloatingPanel {
        let p = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 210),
                              styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.minSize = NSSize(width: 340, height: 160)
        p.contentView = NSHostingView(rootView: CaptureView(model: model, save: { [weak self] in self?.save() }, close: { [weak self] in self?.close() })
            .environmentObject(store).environmentObject(ui))
        return p
    }

    func windowWillClose(_ notification: Notification) { model.keepDraft() }

    private func save() {
        let text = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let jot = model.save(store: store) {
            model.saved = "Saved as \(jot.shortID.text)"
            panel?.orderOut(nil)
        }
    }
}

/// What the capture window holds: the text, the linked task, and the draft kept when it closes.
@MainActor final class CaptureModel: ObservableObject {
    @Published var text = ""
    @Published var task: Int64?
    @Published var saved: String?
    @Published var focus = 0
    static let draftKey = "jotDraft", taskKey = "jotDraftTask"

    var savedTask: Int64? { (UserDefaults.standard.object(forKey: Self.taskKey) as? NSNumber)?.int64Value }

    func restoreDraftIfEmpty() {
        if text.isEmpty { text = UserDefaults.standard.string(forKey: Self.draftKey) ?? "" }
    }

    func keepDraft() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(t.isEmpty ? nil : text, forKey: Self.draftKey)
        UserDefaults.standard.set(t.isEmpty ? nil : task.map { NSNumber(value: $0) }, forKey: Self.taskKey)
    }

    /// Saves the jot (typed or dictated), with the linked task's tags and a link to it. Clears the draft.
    func save(store: Store, now: Date = Date()) -> Jot? {
        guard let jot = JotStore(store: store).capture(text, aboutTask: task, now: now) else { return nil }
        text = ""; task = nil
        UserDefaults.standard.removeObject(forKey: Self.draftKey)
        UserDefaults.standard.removeObject(forKey: Self.taskKey)
        return jot
    }
}

struct CaptureView: View {
    @ObservedObject var model: CaptureModel
    let save: () -> Void
    let close: () -> Void
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let t = model.task, let task = store.item(ShortID(kind: .task, number: t)) {
                HStack(spacing: 5) {
                    Image(systemName: "link").foregroundStyle(.secondary)
                    Text("About T-\(t) · \(task.title)").lineLimit(1)
                    Button { model.task = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Not about this task")
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            CaptureTextView(text: $model.text, focus: model.focus)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 8) {
                Text("⌘↩ save · Esc close (keeps the draft) · fn fn to dictate").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button("Close", action: close).keyboardShortcut(.cancelAction).controlSize(.small)
                Button("Save", action: save).keyboardShortcut(.return, modifiers: .command).controlSize(.small)
                    .disabled(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(EdgeInsets(top: 26, leading: 12, bottom: 10, trailing: 12))
    }
}

/// A plain-text editor that takes the keyboard when the window opens (dictation and spelling work as in any Mac text view).
struct CaptureTextView: NSViewRepresentable {
    @Binding var text: String
    let focus: Int

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        if let tv = scroll.documentView as? NSTextView {
            tv.isRichText = false; tv.allowsUndo = true; tv.drawsBackground = false
            tv.font = .systemFont(ofSize: 14)
            tv.isAutomaticQuoteSubstitutionEnabled = false
            tv.delegate = context.coordinator
            tv.string = text
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
        if context.coordinator.focus != focus {
            context.coordinator.focus = focus
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv); tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0)) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var focus = -1
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ n: Notification) { if let v = n.object as? NSTextView { text.wrappedValue = v.string } }
    }
}
