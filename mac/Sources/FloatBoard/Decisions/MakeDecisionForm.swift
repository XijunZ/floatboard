import FloatBoardConnectors
import FloatBoardCore
import SwiftUI

/// "Make decision" on selected text (features §4 D2): a 4-field form (decision, why, expected outcome, confidence), with type
/// and alternatives below. It opens filled in by code from the selection; Claude (Haiku: the selected text, and the note around it only for the decision line and why) then
/// fills the fields you have not touched. Save records it, linked to where the text came from.
struct MakeDecisionForm: View {
    let request: MakeDecisionRequest
    var close: () -> Void
    @EnvironmentObject var store: Store
    @State private var text = ""
    @State private var why = ""
    @State private var expected = ""
    @State private var confidence: Confidence?
    @State private var type: DecisionType = .operational
    @State private var alternatives = ""
    @State private var touched: Set<String> = []
    @State private var filling = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Make decision").font(.system(size: 13, weight: .semibold))
                Spacer()
                if filling { ProgressView().controlSize(.small); Text("Claude is filling in…").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            labelled("Decision") { TextField("What was decided", text: tracked($text, "text"), axis: .vertical).lineLimit(1...3) }
            labelled("Why") { TextField("not recorded", text: tracked($why, "why"), axis: .vertical).lineLimit(1...3) }
            labelled("Expected outcome") { TextField("what you expect to happen", text: tracked($expected, "expected"), axis: .vertical).lineLimit(1...3) }
            labelled("Confidence") {
                Picker("", selection: Binding(get: { confidence }, set: { confidence = $0; touched.insert("confidence") })) {
                    Text("Not set").tag(Confidence?.none)
                    ForEach(Confidence.allCases, id: \.self) { Text($0.title).tag(Confidence?.some($0)) }
                }.labelsHidden().pickerStyle(.segmented)
            }
            HStack(spacing: 8) {
                Text("Type").foregroundStyle(.secondary)
                Dropdown(options: DecisionType.allCases, selection: Binding(get: { type }, set: { type = $0; touched.insert("type") }), title: { $0.title })
                Text("review after \(type.reviewDays) days").foregroundStyle(.tertiary)
            }
            .font(.system(size: 11))
            TextField("Alternatives considered (optional)", text: tracked($alternatives, "alternatives"), axis: .vertical).lineLimit(1...2)
                .textFieldStyle(.roundedBorder).font(.system(size: 11))
            if let s = request.source, let item = store.item(s) {
                Text("Links back to \(s.text) · \(item.title)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Make decision") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(14)
        .frame(width: 460)
        .onAppear { codeFill() }
        .task { await claudeFill() }
    }

    private func labelled<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            c().font(.system(size: 12))
        }
    }

    /// A field binding that remembers you edited it (Claude then leaves it alone).
    private func tracked(_ b: Binding<String>, _ name: String) -> Binding<String> {
        Binding(get: { b.wrappedValue }, set: { b.wrappedValue = $0; touched.insert(name) })
    }

    /// By code, at once: the selection's first line; why not recorded until Claude finds one in the text.
    private func codeFill() {
        let first = request.selection.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        text = String(first.prefix(200))
    }

    private func claudeFill() async {
        guard let (_, client) = DecisionsEngine.client(store: store) else { note = "Filled in from the selection (no engine connected for Claude)."; return }
        filling = true
        defer { filling = false }
        let context = request.source.flatMap { $0.kind == .jot ? JotStore(store: store).jot($0.number)?.text : nil } ?? ""
        do {
            let f = try await client.fillDecision(selection: request.selection, context: context)
            if !touched.contains("text"), !f.decision.isEmpty { text = f.decision }
            if !touched.contains("why"), f.why.caseInsensitiveCompare(DecisionDraft.notRecorded) != .orderedSame { why = f.why }
            if !touched.contains("expected") { expected = f.expected }
            if !touched.contains("confidence") { confidence = f.confidence }
            if !touched.contains("type") { type = f.type }
            if !touched.contains("alternatives") { alternatives = f.alternatives }
            note = "Filled in by Claude from the selected text (the note around it only for the decision and why): check before saving."
        } catch {
            note = "Claude couldn't fill this in; filled in from the selection."
            store.activity("decisions", .warning, "Couldn't fill the decision form", detail: "\(error)")
        }
    }

    private func save() {
        let source = request.source
        let draft = DecisionDraft(text: text, quote: request.selection.trimmingCharacters(in: .whitespacesAndNewlines), why: why, expected: expected,
                                  confidence: confidence, alternatives: alternatives, type: type, source: .typed, sourceItem: source)
        // Not saved (the write failed; it is in Activity): the form stays open with every field.
        guard let d = DecisionStore(store: store).record(draft) else { note = "Couldn't save the decision (see Activity). Your fields are still here; try again."; return }
        DecisionsUI.shared.selected = d.id
        close()
        if let (_, client) = DecisionsEngine.client(store: store) {
            Task { @MainActor in await DecisionsEngine.suggest(for: [d.id], store: store, client: client) }
        }
    }
}
