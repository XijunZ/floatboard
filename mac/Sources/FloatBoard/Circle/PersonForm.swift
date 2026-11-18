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
    /// WhatsApp ids that are not a number (a linked id "<digits>@lid"): kept and saved, shown in words, removable.
    @State private var chatIDs: [Handle] = []
    @State private var interval = ""
    @State private var problem: String?
    @State private var filling = false
    @State private var filledNote: String?

    private var isInvestor: Bool { tags.contains { $0.caseInsensitiveCompare(TagRules.investor) == .orderedSame } }
    private var isProspect: Bool { tags.contains { $0.caseInsensitiveCompare(TagRules.prospect) == .orderedSame } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.personID == nil ? "Add to Circle" : "Edit \(name)").font(.system(size: 15, weight: .semibold))
            // The name stays in view above the scrolling fields (owner's report: it scrolled away).
            HStack(spacing: 10) {
                Text("Name").foregroundStyle(.secondary).font(.system(size: 12)).frame(width: labelWidth, alignment: .trailing)
                TextField("Full name", text: $name).font(.system(size: 12))
            }
            .padding(.trailing, 6)
            ScrollView {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
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
                            VStack(alignment: .leading, spacing: 4) {
                                TextField(k == .phone || k == .email ? "Several: separate with commas" : (k == .whatsapp ? "Number" : ""), text: Binding(
                                    get: { handlesText[k] ?? "" }, set: { handlesText[k] = $0 }))
                                if k == .whatsapp {
                                    ForEach(chatIDs, id: \.self) { h in
                                        HStack(spacing: 4) {
                                            Image(systemName: "message").foregroundStyle(.secondary)
                                            Text(LIDBook.display(store: store, h)).foregroundStyle(.secondary)
                                            Button { chatIDs.removeAll { $0 == h } } label: { Image(systemName: "xmark.circle.fill") }
                                                .buttonStyle(.borderless).help("Remove this WhatsApp contact from the person")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    row("Birthday") { TextField("YYYY-MM-DD or MM-DD", text: $d.birthday).frame(width: 160) }
                    row("Language") { TextField("e.g. English, Chinese", text: $d.language).frame(width: 200) }
                    row("Blog or news feed") { TextField("https://… (RSS or Atom)", text: $d.feedURL) }
                    // A TextEditor has no first text baseline the grid can line up with: its label is top-aligned instead, so it
                    // never runs into the row above (owner's report: "Blog or news feed" and "Notes" overlapped).
                    GridRow(alignment: .top) {
                        Text("Notes").foregroundStyle(.secondary).font(.system(size: 12)).gridColumnAlignment(.trailing).padding(.top, 4)
                        TextEditor(text: $d.notes).font(.system(size: 12)).frame(height: 70)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.15)))
                    }
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

    private let labelWidth: CGFloat = 118

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).font(.system(size: 12)).frame(minWidth: labelWidth, alignment: .trailing).gridColumnAlignment(.trailing)
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
            PeopleTagMenu(except: tags, pick: { n in tags.append(n) }) { Image(systemName: "plus") }.menuStyle(.borderlessButton).fixedSize()
            if let p = TagRules.problems(tags: tags, tier: tier).first { Text(p).foregroundStyle(.red).font(.system(size: 11)) }
        }
    }

    private func load() {
        let c = CircleStore(store: store)
        if let id = request.personID, let p = PeopleStore(store: store).person(id) {
            name = p.name; aliases = p.aliases.joined(separator: ", "); tier = p.tier; tags = store.itemTags(p.shortID).all
            d = c.details(id)
            interval = d.intervalDays.map(String.init) ?? ""
            let (ids, rest) = Self.splitChatIDs(c.handles(id))
            chatIDs = ids
            for (k, hs) in Dictionary(grouping: rest, by: \.kind) {
                handlesText[k] = hs.map { $0.kind == .linkedin ? "https://www." + $0.value : ($0.kind == .phone ? Handles.phoneText($0.value) : $0.value) }.joined(separator: ", ")
            }
        } else {
            name = request.name; d.company = request.company; d.role = request.role
            // A suggestion's handles: a WhatsApp chat id becomes a phone when it is one, else a "WhatsApp contact" line;
            // never a raw id in a text field.
            let normalized = request.handles.map { h in h.kind == .whatsapp ? (Handles.fromWhatsApp(h.value) ?? h) : h }
            let (ids, rest) = Self.splitChatIDs(normalized)
            chatIDs = ids
            for (k, hs) in Dictionary(grouping: rest, by: \.kind) { handlesText[k] = hs.map { $0.kind == .phone ? Handles.phoneText($0.value) : $0.value }.joined(separator: ", ") }
        }
    }

    private var formHandles: [Handle] { ContactFormFields.handles(handlesText).handles + chatIDs }

    /// WhatsApp handles that are ids rather than numbers, apart from the rest.
    static func splitChatIDs(_ hs: [Handle]) -> (ids: [Handle], rest: [Handle]) {
        (hs.filter { $0.kind == .whatsapp && $0.value.contains("@") }, hs.filter { !($0.kind == .whatsapp && $0.value.contains("@")) })
    }

    private func save() {
        // A phone number, address or profile that can't be read is reported, never dropped silently.
        let typed = ContactFormFields.handles(handlesText)
        if !typed.unreadable.isEmpty {
            problem = "Not a phone number, email address or profile FloatBoard can read: " + typed.unreadable.joined(separator: ", ") + ". Fix or remove it, then save."
            return
        }
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
            guard let p = r.person else { problem = r.problem ?? "Couldn't add this person; see Activity for why."; return }
            if let cand = request.candidateID { c.markCandidateAdded(cand) }
            CircleLinker.run(store: store, person: p.id)
            close(p.id)
        }
    }

    /// contact_form: what FloatBoard already has on this Mac for the typed phone numbers, emails and WhatsApp numbers (and the
    /// person's own handles when editing): header names, addresses and numbers only, never message text (CircleFillHeaders).
    /// Nothing found: said so, and Claude isn't asked. The note lists the fields Claude actually changed.
    private func fill() {
        filledNote = nil; problem = nil
        let typed = ContactFormFields.handles(handlesText)
        let lookFor = typed.handles + chatIDs
        guard !lookFor.isEmpty || request.personID != nil else { problem = "Add a phone number, email or WhatsApp number first."; return }
        let lids = chatIDs.filter(Handles.isLinkedID).map(\.value)
        filling = true
        Task { @MainActor in
            defer { filling = false }
            var notes: [String] = []
            // 1. A WhatsApp linked id: WhatsApp's own contact list on this Mac gives the number and names (no Claude; read off
            //    the main thread; nothing leaves the Mac).
            if !lids.isEmpty {
                let fresh = await Task.detached { WhatsAppContacts.resolve(lids) }.value
                LIDBook.save(store: store, fresh)
                let resolved = lids.compactMap { lid in fresh[lid] ?? LIDBook.phone(store: store, lid).map { ResolvedContact(phone: $0, name: "", business: "") } }
                var fields = currentFields()
                notes.append(LIDFill.apply(&fields, resolved: resolved, records: CircleFillHeaders.records(store: store, handles: chatIDs)))
                apply(fields)
            }
            // 2. Claude (Haiku) only for what message headers can add, and only for fields still empty.
            let headers: [FillHeader]
            do { headers = try CircleFillHeaders.find(store: store, handles: ContactFormFields.handles(handlesText).handles + chatIDs, personID: request.personID) } catch {
                problem = "Couldn't read your messages' details: \(error)"
                store.activity("circle", .error, "Could not read message headers for the contact form", detail: "\(error)")
                return
            }
            let f0 = currentFields()
            let stillEmpty = [f0.name, f0.company, f0.emails, f0.phones].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !headers.isEmpty, stillEmpty else {
                if notes.isEmpty { problem = "No messages found for these numbers or addresses yet." } else { filledNote = notes.joined(separator: " ") }
                return
            }
            guard let client = CircleRunner.client(store) else {
                if notes.isEmpty { problem = "Connect FloatBoard's engine in Settings › Mode to fill the form." } else { filledNote = notes.joined(separator: " ") }
                return
            }
            do {
                let f = try await client.circleFill(headers: headers.prefix(CircleFillHeaders.cap).map(\.dictionary))
                var fields = currentFields()
                let changed = f.fill(&fields)
                apply(fields)
                notes.append(ContactFormFields.note(changed) ?? "Claude found nothing more to add from the message headers.")
                filledNote = notes.joined(separator: " ")
            } catch {
                if !notes.isEmpty { filledNote = notes.joined(separator: " ") }
                problem = "Couldn't fill the form: \((error as? ConnectorError)?.description ?? "\(error)")"
                store.activity("circle", .warning, "Could not fill the contact form", detail: "\(error)")
            }
        }
    }

    private func currentFields() -> ContactFormFields {
        ContactFormFields(name: name, company: d.company, emails: handlesText[.email] ?? "", phones: handlesText[.phone] ?? "", whatsapp: handlesText[.whatsapp] ?? "")
    }

    private func apply(_ f: ContactFormFields) {
        name = f.name; d.company = f.company; handlesText[.email] = f.emails; handlesText[.phone] = f.phones; handlesText[.whatsapp] = f.whatsapp
    }
}
