import AppKit
import FloatBoardConnectors
import FloatBoardCore
import SwiftUI
import UniformTypeIdentifiers

/// P9: a short draft in your voice from your notes and the last few messages (WhatsApp read on this Mac on request; Gmail
/// read by the engine). You edit it, then one tap opens WhatsApp or Gmail with it. Never sent automatically; nothing kept.
struct DraftSheet: View {
    let personID: Int64
    let close: () -> Void
    @EnvironmentObject var store: Store
    @State private var text = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var channel = "whatsapp"

    var body: some View {
        let c = CircleStore(store: store)
        let p = PeopleStore(store: store).person(personID)
        let hs = c.handles(personID)
        let phone = hs.first { $0.kind == .phone }?.value, email = hs.first { $0.kind == .email }?.value
        VStack(alignment: .leading, spacing: 10) {
            Text("Draft a message to \(p?.name ?? "them")").font(.system(size: 15, weight: .semibold))
            Picker("", selection: $channel) {
                if phone != nil { Text("WhatsApp").tag("whatsapp") }
                if email != nil { Text("Email").tag("email") }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
            TextEditor(text: $text).font(.system(size: 13)).frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.15)))
            Text("Written by Claude (Haiku) from your notes and the last few messages, sent only for this draft and not kept. Check it; it is never sent by itself.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let problem { Text(problem).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Button(busy ? "Writing…" : (text.isEmpty ? "Write a draft" : "Write again")) { write(phone: phone, email: email) }.disabled(busy || (phone == nil && email == nil))
                Spacer()
                Button("Close", action: close).keyboardShortcut(.cancelAction)
                if channel == "whatsapp", let phone {
                    Button("Open in WhatsApp") { open("whatsapp://send?phone=\(phone)&text=\(enc(text))") }.disabled(text.isEmpty)
                }
                if channel == "email", let email {
                    Button("Open in Gmail") { open("https://mail.google.com/mail/?view=cm&to=\(enc(email))&body=\(enc(text))") }.disabled(text.isEmpty)
                }
            }
            if phone == nil && email == nil { Text("Add a phone number or an email first.").font(.system(size: 11)).foregroundStyle(.orange) }
        }
        .padding(16).frame(width: 520)
        .onAppear { if phone == nil { channel = "email" } }
    }

    private func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
    private func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) }; close() }

    private func write(phone: String?, email: String?) {
        guard let p = PeopleStore(store: store).person(personID) else { return }
        guard let client = CircleRunner.client(store) else { problem = "Connect FloatBoard's engine (Settings › Mode) to write drafts."; return }
        let d = CircleStore(store: store).details(personID)
        var messages: [(direction: String, at: String, text: String)] = []
        if channel == "whatsapp", let phone,
           store.connectors.contains(where: { WhatsAppSync.isOn(connector: $0.id, store: store) }) {
            do {
                let iso = ISO8601DateFormatter()
                messages = try CircleWhatsAppReader.lastMessages(phone: phone).map { ($0.direction, iso.string(from: $0.at), $0.text) }
            } catch { store.activity("circle", .warning, "Could not read the last WhatsApp messages for a draft", detail: "\(error)") }
        }
        busy = true; problem = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                text = try await client.circleDraft(name: p.name, language: d.language, notes: d.notes, howKnown: d.howKnown, channel: channel, messages: messages)
            } catch {
                problem = (error as? ConnectorError)?.description ?? "\(error)"
            }
        }
    }
}

/// Suggestions (P3, P4, P11): people from two-way conversations, from the LinkedIn and Google Contacts exports (added one by
/// one, never in bulk), possible duplicates, and the imports themselves.
struct SuggestionsSheet: View {
    let close: () -> Void
    let add: (PersonFormRequest) -> Void
    @EnvironmentObject var store: Store
    @State private var message: String?
    @State private var months = 12

    var body: some View {
        let c = CircleStore(store: store)
        let conv = c.conversationSuggestions(), cands = c.candidates(), dups = c.mergeSuggestions()
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Suggestions").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Import LinkedIn export…") { importFile(linkedIn: true) }
                Button("Import Google Contacts…") { importFile(linkedIn: false) }
            }
            if let message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section("From your conversations (replies both ways)", empty: conv.isEmpty) {
                        ForEach(conv) { s in
                            row(s.name.isEmpty ? s.handle.value : s.name,
                                "\(s.channels.map(\.title).joined(separator: ", ")) · \(s.exchanges) days of messages · last \(CircleFmt.ago(s.last))") {
                                Button("Add") { add(PersonFormRequest(personID: nil, name: s.name, handles: [s.handle])) }
                                Button("Not now") { c.dismiss(s.key) }
                            }
                        }
                    }
                    section("From your imports", empty: cands.isEmpty) {
                        ForEach(cands) { s in
                            row(s.name, [s.role, s.company, s.source == "linkedin" ? "LinkedIn" : "Google Contacts"].filter { !$0.isEmpty }.joined(separator: " · ")) {
                                Button("Add") { add(PersonFormRequest(personID: nil, name: s.name, handles: s.handles, company: s.company, role: s.role, candidateID: s.id)) }
                                Button("Dismiss") { c.dismissCandidate(s.id) }
                            }
                        }
                    }
                    section("Possibly the same person", empty: dups.isEmpty) {
                        ForEach(dups) { m in
                            let a = PeopleStore(store: store).person(m.a)?.name ?? "P-\(m.a)", b = PeopleStore(store: store).person(m.b)?.name ?? "P-\(m.b)"
                            row("\(a) and \(b)", m.reason) {
                                Button("Merge") { if let why = c.merge(kept: m.a, merged: m.b) { message = why } }
                                Button("Not the same") { c.dismiss(m.key) }
                            }
                        }
                    }
                }
            }
            HStack {
                Stepper("Readers look back \(months) months the first time", value: $months, in: 1...60) { _ in c.setBackfillMonths(months) }
                    .font(.system(size: 11))
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 640, height: 560)
        .onAppear { months = c.backfillMonths }
    }

    private func section<C: View>(_ title: String, empty: Bool, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if empty { Text("None").font(.system(size: 11)).foregroundStyle(.tertiary) } else { content() }
        }
    }

    private func row<B: View>(_ title: String, _ detail: String, @ViewBuilder buttons: () -> B) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer()
            buttons().controlSize(.small)
        }
    }

    private func importFile(linkedIn: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = linkedIn ? "Choose Connections.csv from your LinkedIn data export" : "Choose the CSV exported from Google Contacts"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let c = CircleStore(store: store)
            let r: ImportSummary
            if linkedIn {
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) // try?-ok: no file date = today is used
                let date = (attrs?[.modificationDate] as? Date).map { Due.dayString($0) }
                r = c.importLinkedIn(text, exportDate: date)
            } else {
                r = c.importGoogleContacts(text)
            }
            message = "\(r.rows) rows read: \(r.candidates) new suggestions, \(r.attached) matched people by email or phone" + (linkedIn ? ", \(r.changes) job changes." : ".")
        } catch {
            message = "Couldn't read that file: \(error.localizedDescription)"
            store.activity("circle", .error, "Could not import a contacts file", detail: "\(error)")
        }
    }
}
