import FloatBoardConnectors
import FloatBoardCore
import SwiftUI

/// Opens the add / edit form: `personID` nil adds; `name` and `handles` prefill (a right-clicked name, a suggestion).
struct PersonFormRequest: Identifiable {
    let id = UUID()
    let personID: Int64?
    var name: String = ""
    var handles: [Handle] = []
    var company: String = ""
    var role: String = ""
    var candidateID: Int64? = nil
}

/// The short add / edit form (P2): name, tier, tags, how you know them, company and role, handles, birthday, language, notes;
/// firm and focus for Investor; purpose and stage for Prospect. "Fill from messages" asks Claude (Haiku) to fill empty
/// fields from header names, addresses and phone numbers only; you check before saving.
struct PersonForm: View {
    let request: PersonFormRequest
    let close: (Int64?) -> Void
    @EnvironmentObject var store: Store
    @State private var name = ""
    @State private var aliases = ""
    @State private var tier: PersonTier = .network
    @State private var tags: [String] = []
    @State private var d = CircleDetails()
    @State private var handlesText: [HandleKind: String] = [:]
    @State private var interval = ""
    @State private var problem: String?
    @State private var filling = false
    @State private var filledNote: String?

    private var isInvestor: Bool { tags.contains { $0.caseInsensitiveCompare(TagRules.investor) == .orderedSame } }
    private var isProspect: Bool { tags.contains { $0.caseInsensitiveCompare(TagRules.prospect) == .orderedSame } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.personID == nil ? "Add to Circle" : "Edit \(name)").font(.system(size: 15, weight: .semibold))
            ScrollView {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                    row("Name") { TextField("Full name", text: $name) }
                    row("Also known as") { TextField("Other names, separated by commas", text: $aliases) }
                    row("Tier") {
                        Picker("", selection: $tier) { ForEach(PersonTier.allCases, id: \.self) { Text($0.title).tag($0) } }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                    }
                    row("Tags") { tagRow }
                    row("Get in touch every") {
                        HStack {
                            TextField("days", text: $interval).frame(width: 60)
                            Text("days (empty: \(CircleClock.label(CircleClock.interval(tier: tier, tags: tags, intervalDays: nil))))").foregroundStyle(.secondary)
                        }
                    }
                    row("How you know them") { TextField("e.g. university, former colleague", text: $d.howKnown) }
                    row("Company and role") {
                        HStack { TextField("Company", text: $d.company); TextField("Role", text: $d.role) }
                    }
                    if isInvestor {
                        row("Firm and focus") { HStack { TextField("Firm", text: $d.firm); TextField("Focus", text: $d.focus) } }
                    }
                    if isProspect {
                        row("Purpose and stage") {
                            HStack {
                                Picker("", selection: $d.purpose) {
                                    Text("Choose…").tag("")
                                    ForEach(ProspectPurpose.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                                }.labelsHidden().frame(width: 140)
                                Picker("", selection: $d.stage) {
                                    ForEach(ProspectStage.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                                }.labelsHidden().frame(width: 150)
                            }
                        }
                    }
                    ForEach([HandleKind.phone, .email, .whatsapp, .wechat, .linkedin], id: \.self) { k in
                        row(k == .linkedin ? "LinkedIn URL" : k.title) {
                            TextField(k == .phone || k == .email ? "Several: separate with commas" : "", text: Binding(
                                get: { handlesText[k] ?? "" }, set: { handlesText[k] = $0 }))
                        }
                    }
                    row("Birthday") { TextField("YYYY-MM-DD or MM-DD", text: $d.birthday).frame(width: 160) }
                    row("Language") { TextField("e.g. English, Chinese", text: $d.language).frame(width: 200) }
                    row("Blog or news feed") { TextField("https://… (RSS or Atom)", text: $d.feedURL) }
                    row("Notes") { TextEditor(text: $d.notes).frame(height: 70).overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.15))) }
                }
                .padding(.trailing, 6)
            }
            if let filledNote { Text(filledNote).font(.system(size: 11)).foregroundStyle(.orange) }
            if let problem { Text(problem).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Button(filling ? "Filling…" : "Fill from messages") { fill() }.disabled(filling)
                    .help("Claude fills empty fields from the names, addresses and phone numbers in message headers (no message text). Check before saving.")
                Spacer()
                Button("Cancel") { close(nil) }.keyboardShortcut(.cancelAction)
                Button(request.personID == nil ? "Add" : "Save") { save() }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 560, height: 620)
        .onAppear(perform: load)
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).font(.system(size: 12)).gridColumnAlignment(.trailing)
            content().font(.system(size: 12))
        }
    }

    private var tagRow: some View {
        HStack(spacing: 6) {
            ForEach(tags, id: \.self) { t in
                HStack(spacing: 3) {
                    Circle().fill(store.color(t)).frame(width: 7, height: 7)
                    Text(t)
                    Button { tags.removeAll { $0 == t } } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            Menu {
                ForEach(store.tags.map(\.name).filter { n in !tags.contains(n) }, id: \.self) { n in Button(n) { tags.append(n) } }
            } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).fixedSize()
            if let p = TagRules.problems(tags: tags, tier: tier).first { Text(p).foregroundStyle(.red).font(.system(size: 11)) }
        }
    }

    private func load() {
        let c = CircleStore(store: store)
        if let id = request.personID, let p = PeopleStore(store: store).person(id) {
            name = p.name; aliases = p.aliases.joined(separator: ", "); tier = p.tier; tags = store.itemTags(p.shortID).all
            d = c.details(id)
            interval = d.intervalDays.map(String.init) ?? ""
            for (k, hs) in Dictionary(grouping: c.handles(id), by: \.kind) {
                handlesText[k] = hs.map { $0.kind == .linkedin ? "https://www." + $0.value : $0.value }.joined(separator: ", ")
            }
        } else {
            name = request.name; d.company = request.company; d.role = request.role
            for (k, hs) in Dictionary(grouping: request.handles, by: \.kind) { handlesText[k] = hs.map(\.value).joined(separator: ", ") }
        }
    }

    private var formHandles: [Handle] {
        handlesText.flatMap { k, text in
            text.split(separator: ",").compactMap { raw in Handles.normalize(k, String(raw)).map { Handle(kind: k, value: $0) } }
        }
    }

    private func save() {
        let c = CircleStore(store: store)
        var details = d
        details.intervalDays = Int(interval.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
        let aliasList = aliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let tagSet = ItemTags(primary: tags.first, others: Array(tags.dropFirst()))
        if let id = request.personID, var p = PeopleStore(store: store).person(id) {
            if let why = TagRules.problems(tags: tags, tier: tier).first { problem = why; return }
            p.name = name; p.aliases = aliasList; p.tier = tier
            PeopleStore(store: store).update(p)
            if let why = store.setTags(p.shortID, primary: tagSet.primary, others: tagSet.others, tier: tier) { problem = why; return }
            if let why = c.save(id, details) { problem = why; return }
            let wanted = Set(formHandles)
            for h in c.handles(id) where !wanted.contains(h) { c.removeHandle(id, h) }
            var result = id
            for h in wanted where !c.handles(result).contains(h) {
                switch c.addHandle(result, h) {
                case .refused(let why): problem = why; return
                case .merged(let into): result = into
                default: break
                }
            }
            CircleLinker.run(store: store, person: result)
            close(result)
        } else {
            let r = c.add(name: name, aliases: aliasList, tier: tier, tags: tagSet, details: details, handles: formHandles)
            guard let p = r.person else { problem = r.problem; return }
            if let cand = request.candidateID { c.markCandidateAdded(cand) }
            CircleLinker.run(store: store, person: p.id)
            close(p.id)
        }
    }

    /// contact_form: header names, addresses and phone numbers only (from what the readers saw for these handles).
    private func fill() {
        let hs = formHandles
        var bits: [[String: String]] = hs.map { h in
            ["name": name, "address": h.kind == .email ? h.value : "", "phone": h.kind == .phone ? h.value : ""]
        }
        if let id = request.personID {
            for e in CircleStore(store: store).exchanges(of: id) where !e.name.isEmpty {
                bits.append(["name": e.name, "address": e.handle?.kind == .email ? e.handle!.value : "", "phone": e.handle?.kind == .phone ? e.handle!.value : ""])
            }
        }
        guard !bits.isEmpty, let client = CircleRunner.client(store) else {
            problem = "Add a phone number or email first (and connect FloatBoard's engine in Settings › Mode)."
            return
        }
        filling = true; problem = nil
        Task { @MainActor in
            defer { filling = false }
            do {
                let f = try await client.circleFill(headers: Array(bits.prefix(20)))
                if name.trimmingCharacters(in: .whitespaces).isEmpty { name = f.name }
                if d.company.isEmpty { d.company = f.company }
                if (handlesText[.email] ?? "").isEmpty { handlesText[.email] = f.emails.joined(separator: ", ") }
                if (handlesText[.phone] ?? "").isEmpty { handlesText[.phone] = f.phones.joined(separator: ", ") }
                filledNote = "Filled by Claude from message headers: check before saving."
            } catch {
                problem = "Couldn't fill the form: \((error as? ConnectorError)?.description ?? "\(error)")"
                store.activity("circle", .warning, "Could not fill the contact form", detail: "\(error)")
            }
        }
    }
}
