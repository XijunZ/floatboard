import FloatBoardConnectors
import FloatBoardCore
import SwiftUI

/// A connector's settings, drawn from the field list (schema) it last reported. Saved to the board's database
/// (with a new settings version and a queued "settings" change); the next sync sends them to the connector.
/// `keys` picks which settings this form shows, in order (Settings shows them in different sections); nil shows all.
/// "default_group", "auto_add" and "learned" are the app's own; "*" stands for every engine field no section names.
struct ConnectorSettingsForm: View {
    @EnvironmentObject var store: Store
    let info: ConnectorInfo
    let schema: [SettingField]
    var keys: [String]? = nil
    /// Every key some section shows (so "*" knows what is left over).
    static let placed: Set<String> = ["default_group", "auto_add", "alerts_on", "critical_hours", "mark_read_on_done", "ai_footer",
                                      "group_notes", "my_rules", "chat_rules", "ignore_senders", "allow_senders", "unread_only",
                                      "learned", "learn_at", "model_judge", "model_recap", "model_reply",
                                      "rulebook_email", "rulebook_chat"]

    @State private var draft = ConnectorSettingsDraft()
    @State private var message: String?
    @State private var messageIsError = false

    private var groups: [String] { store.areas.map(\.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(shownKeys, id: \.self) { k in item(k) }
            if schema.isEmpty && (keys ?? []).contains(where: { !ConnectorSettingsDraft.builtIn.contains($0) }) {
                Text("The engine's own settings appear here after its first sync.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack {
                Button("Save settings") { save() }
                Button("Undo changes") { load() }.buttonStyle(.borderless)
                if let message {
                    Text(message).font(.system(size: 11)).foregroundStyle(messageIsError ? Color.red : Color.secondary)
                }
            }
        }
        .onAppear { load() }
        // A sync can bring newer stored settings (e.g. new "learned" lines) or a new field list: fields you
        // haven't edited take the new values; your edits stay.
        .onChange(of: info.settingsJSON) { _, _ in rebase() }
        .onChange(of: schema) { _, _ in rebase() }
    }

    // MARK: Fields

    /// The keys to show, in order: "*" expands to every engine field no section places.
    private var shownKeys: [String] {
        guard let keys else { return ["default_group", "auto_add"] + draft.fields.map(\.key) + ["learned"] }
        return keys.flatMap { k -> [String] in
            k == "*" ? draft.fields.map(\.key).filter { !Self.placed.contains($0) } : [k]
        }
    }

    @ViewBuilder
    private func item(_ k: String) -> some View {
        switch k {
        case "default_group":
            row("New tasks go to", help: "Used when the engine doesn't pick a group.") {
                Picker("", selection: textBinding("default_group")) {
                    ForEach(store.areas) { Text($0.name).tag($0.name) }
                }
                .labelsHidden().frame(width: 200)
            }
        case "auto_add":
            row("Add tasks automatically", help: "Off: suggestions are not added to the board.") {
                Toggle("", isOn: flagBinding("auto_add")).toggleStyle(.switch).labelsHidden()
            }
        case "learned":
            row("What FloatBoard has learned about you",
                help: "Learned from the tasks you change and delete. Edit or remove anything that's wrong; your edits win over later learning.") {
                editor("learned")
            }
            InstructionsHistory(info: info, part: "learned")
        default:
            if let f = draft.fields.first(where: { $0.key == k }) {
                field(f)
                if Instructions.parts.contains(k) { InstructionsHistory(info: info, part: k) }
            }
        }
    }

    @ViewBuilder
    private func field(_ f: SettingField) -> some View {
        switch f.kind {
        case "text":
            row(f.label, help: f.help) { TextField("", text: textBinding(f.key)).textFieldStyle(.roundedBorder).frame(width: 360) }
        case "longtext":
            row(f.label, help: f.help) { editor(f.key) }
        case "list":
            row(f.label, help: (f.help ?? "").lowercased().contains("one per line") ? f.help : [f.help, "One per line."].compactMap { $0 }.joined(separator: " ")) { editor(f.key) }
        case "bool":
            row(f.label, help: f.help) { Toggle("", isOn: flagBinding(f.key)).toggleStyle(.switch).labelsHidden() }
        case "int":
            row(f.label, help: f.help) { TextField("", text: textBinding(f.key)).textFieldStyle(.roundedBorder).frame(width: 90) }
        case "choice":
            row(f.label, help: f.help) {
                Picker("", selection: textBinding(f.key)) {
                    ForEach(f.options ?? [], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 220)
            }
        case "groupNotes":
            row(f.label, help: f.help) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.areas) { a in
                        HStack {
                            Text(a.name).font(.system(size: 11)).frame(width: 120, alignment: .leading)
                            TextField("What belongs in \(a.name)", text: noteBinding(f.key, a.name))
                                .textFieldStyle(.roundedBorder).frame(width: 360)
                        }
                    }
                }
            }
        default:
            row(f.label, help: "This kind of setting (\(f.kind)) can't be edited here yet; change it on the setup page.") { EmptyView() }
        }
    }

    private func row<C: View>(_ label: String, help: String?, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 12, weight: .medium))
            content()
            if let help, !help.isEmpty { Text(help).font(.system(size: 10)).foregroundStyle(.secondary) }
        }
    }

    private func editor(_ key: String) -> some View {
        TextEditor(text: textBinding(key))
            .font(.system(size: 11))
            .frame(width: 480, height: 80)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15)))
    }

    private func textBinding(_ k: String) -> Binding<String> { Binding(get: { draft.text[k] ?? "" }, set: { draft.text[k] = $0 }) }
    private func flagBinding(_ k: String) -> Binding<Bool> { Binding(get: { draft.flags[k] ?? false }, set: { draft.flags[k] = $0 }) }
    private func noteBinding(_ k: String, _ group: String) -> Binding<String> {
        Binding(get: { draft.notes[k]?[group] ?? "" }, set: { draft.notes[k, default: [:]][group] = $0 })
    }

    // MARK: Load and save

    private func load() {
        draft = ConnectorSettingsDraft(settings: info.settings, schema: schema, groups: groups)
        message = nil
    }

    private func rebase() { draft.rebase(stored: info.settings, schema: schema, groups: groups) }

    private func save() {
        let changed: [String: Any]
        do { changed = try draft.changedValues(groups: groups) } catch {
            store.activity("connector:\(info.id)", .warning, "Settings not saved: \(error)")
            message = "\(error)"; messageIsError = true; return
        }
        guard !changed.isEmpty else { message = "Nothing to save."; messageIsError = false; return }
        do {
            try store.saveConnectorSettings(connector: info.id, values: changed)
            draft.markSaved()
            message = "Saved. They'll be sent at the next sync."; messageIsError = false
            NotificationCenter.default.post(name: .floatBoardSyncConnectors, object: nil)
        } catch {
            // saveConnectorSettings has already written the Activity row for refusals; this records the attempt.
            store.activity("connector:\(info.id)", .error, "Could not save settings", detail: "\(error)")
            message = "Couldn't save: \(error)"; messageIsError = true
        }
    }
}
