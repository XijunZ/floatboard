import AppKit
import FloatBoardConnectors
import FloatBoardCore
import SwiftUI

/// One person's card (P1–P13): who they are, the three clocks, what each channel can see ("data as of"), the actions,
/// prospect stage and their open tasks, What's new, Companies House, LinkedIn, Chinese contacts, merges and the timeline.
struct PersonCard: View {
    let personID: Int64
    var edit: () -> Void = {}
    var draft: () -> Void = {}
    @EnvironmentObject var store: Store
    @EnvironmentObject var ui: UIState
    @State private var showSetAside = false
    @State private var confirmDelete = false
    @State private var tagProblem: String?

    var body: some View {
        let c = CircleStore(store: store)
        if let p = PeopleStore(store: store).person(personID), !p.deleted {
            let d = c.details(p.id), k = c.clocks(p), hs = c.handles(p.id), tags = store.itemTags(p.shortID).all
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(p, d, tags)
                    clocks(k)
                    actions(p, hs)
                    channels(c, hs)
                    if tags.contains(where: { $0.caseInsensitiveCompare(TagRules.prospect) == .orderedSame }) { prospect(p, d, c) }
                    whatsNew(p, d, c, tags)
                    if !hs.isEmpty { handles(hs) }
                    merges(c, p)
                    timeline(p)
                    LinkChips(item: p.shortID, except: [.event])
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .confirmationDialog("Delete \(p.name)?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) { PeopleStore(store: store).delete(p.id); CircleNav.shared.selected = nil }
            } message: { Text("Their links are hidden, not removed; Circle keeps the record.") }
        } else {
            Text("Pick someone on the left.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Parts

    private func header(_ p: Person, _ d: CircleDetails, _ tags: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(p.name).font(.system(size: 18, weight: .semibold)).textSelection(.enabled)
                Text(p.shortID.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                Spacer()
                Button("Draft", action: draft).help("A short draft in your voice from your notes and the last few messages; never sent by itself")
                Button("Edit", action: edit)
                Button { confirmDelete = true } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete")
            }
            HStack(spacing: 6) {
                Text(p.tier.title).font(.system(size: 11, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                // The person's tags right here (owner, round 8): ✕ takes one off, + adds one to this person, no selecting first.
                ForEach(tags, id: \.self) { t in
                    PersonTagChip(tag: t, size: 11) { tagProblem = PeopleTags.removeFrom(store: store, person: p.id, t) }
                }
                PeopleTagMenu(except: tags, pick: { t in tagProblem = PeopleTags.addTo(store: store, person: p.id, t) }) {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton).fixedSize().help("Add a tag to \(p.name)")
                let line = [d.role, d.company].filter { !$0.isEmpty }.joined(separator: " at ")
                if !line.isEmpty { Text(line).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            if let tagProblem { Text(tagProblem).font(.system(size: 11)).foregroundStyle(.red) }
            if !d.howKnown.isEmpty { Text("How you know them: \(d.howKnown)").font(.system(size: 12)).foregroundStyle(.secondary) }
            if !d.notes.isEmpty { Text(d.notes).font(.system(size: 12)).textSelection(.enabled) }
            if let b = CircleDue.birthdayContext(d.birthday, now: Date()) { Label(b, systemImage: "gift").font(.system(size: 12)) }
        }
    }

    private func clocks(_ k: Clocks) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 4) {
            GridRow {
                clock("Last talked", k.lastConversation.map { CircleFmt.ago($0) + (k.conversationVia == .calendar ? " (met)" : k.conversationVia.map { " · \($0.title)" } ?? "") } ?? "not seen")
                clock("Last heard from", k.lastHeard.map { CircleFmt.ago($0) } ?? "not seen")
                clock("Last outreach", k.lastOutreach.map { CircleFmt.ago($0) } ?? "not seen")
                if let s = k.snoozedUntil { clock("Snoozed until", CircleFmt.f("d MMM", s)) }
                else { clock(k.due ? "Due since" : "Due", CircleFmt.f("d MMM", k.dueDate), warn: k.due) }
                clock("Every", CircleClock.label(k.interval))
            }
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private func clock(_ label: String, _ value: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 13, weight: .medium)).foregroundStyle(warn ? .orange : .primary)
        }
    }

    private func actions(_ p: Person, _ hs: [Handle]) -> some View {
        let c = CircleStore(store: store)
        return HStack(spacing: 8) {
            Button("I contacted them") { c.contacted(p.id) }.help("A call, a meeting, or a message FloatBoard can't see (Outlook, WeChat)")
            Button("We talked") { c.talked(p.id) }.help("A call or meeting: counts as a conversation")
            Button("Snooze") { c.snooze(p.id) }.help("Push back one interval")
            Menu("Make task") {
                Button("Message \(p.name)") { _ = CircleDue.makeTask(store: store, personID: p.id) }
                Button("Message \(p.name), with a calendar slot tomorrow 10:00") {
                    let cal = AppTime.calendar
                    let slot = cal.date(bySettingHour: 10, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: Date()) ?? Date())
                    _ = CircleDue.makeTask(store: store, personID: p.id, slot: slot)
                }
            }.fixedSize()
            Spacer()
        }
        .controlSize(.small)
    }

    private func channels(_ c: CircleStore, _ hs: [Handle]) -> some View {
        let all = c.channels()
        return VStack(alignment: .leading, spacing: 2) {
            Text("Data as of").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            if all.isEmpty { Text("No reader has run yet.").font(.system(size: 11)).foregroundStyle(.secondary) }
            ForEach(all, id: \.channel) { ch in
                let name = ch.channel.hasPrefix("gmail:") ? "Gmail \(ch.channel.dropFirst(6))" : (Channel(rawValue: ch.channel)?.title ?? ch.channel)
                let back = ch.completeFrom.map { ", complete back to \(CircleFmt.f("d MMM yyyy", $0))" } ?? ""
                Text("\(name): \(ch.asOf.map { CircleFmt.ago($0) } ?? "never")\(back)\(ch.note.isEmpty ? "" : " · \(ch.note)")")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            if !hs.contains(where: { $0.kind == .phone || $0.kind == .email || $0.kind == .wechat }) {
                Text("No phone, email or WeChat for them: messages can't be matched. Add one with Edit.").font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
    }

    private func prospect(_ p: Person, _ d: CircleDetails, _ c: CircleStore) -> some View {
        let tasks = store.links(of: p.shortID).filter { $0.kind == .task }.compactMap { store.card($0.number) }.filter { $0.status != .done }
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Prospect")
            HStack {
                Text(ProspectPurpose(rawValue: d.purpose)?.title ?? "No purpose yet").font(.system(size: 12))
                Picker("Stage", selection: Binding(get: { d.stage }, set: { new in
                    var n = c.details(p.id); n.stage = new
                    if let why = c.save(p.id, n) { store.activity("circle", .warning, why) }
                })) { ForEach(ProspectStage.allCases, id: \.self) { Text($0.title).tag($0.rawValue) } }
                    .frame(width: 220)
                if let at = d.stageAt { Text("since \(CircleFmt.f("d MMM", at))").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Text("Open tasks from their messages").font(.system(size: 11)).foregroundStyle(.secondary)
            if tasks.isEmpty { Text("None").font(.system(size: 11)).foregroundStyle(.tertiary) }
            ForEach(tasks, id: \.id) { t in
                Button { ui.tab = .board; ui.search = "T-\(t.id)" } label: { Label(t.title, systemImage: "checkmark.circle") }
                    .buttonStyle(.link).font(.system(size: 12))
            }
        }
    }

    private func whatsNew(_ p: Person, _ d: CircleDetails, _ c: CircleStore, _ tags: [String]) -> some View {
        let wants = c.wantsUpdates(p, d)
        let ups = c.updates(p.id, includeSetAside: showSetAside)
        let aside = c.setAsideCount(p.id)
        let li = c.handles(p.id).first { $0.kind == .linkedin }
        let chinese = c.isChineseContact(p, d, handles: c.handles(p.id))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle("What's new")
                Spacer()
                if wants {
                    Toggle("Mute news", isOn: Binding(get: { d.newsMuted }, set: { c.setNewsMuted(p.id, $0) })).toggleStyle(.checkbox).font(.system(size: 11))
                } else {
                    Button(p.tier == .family ? "Follow anyway" : "Follow updates") {
                        var n = c.details(p.id); n.updatesOn = true; c.save(p.id, n)
                    }.controlSize(.small).help("Updates are for Investor and Prospect people, not Family; others on request")
                }
            }
            if let status = c.linkedInStatus(p.id) { Text("LinkedIn: \(status)").font(.system(size: 11)).foregroundStyle(.secondary) }
            ForEach(ups) { u in updateRow(u, c) }
            if ups.isEmpty && wants { Text("Nothing yet.").font(.system(size: 11)).foregroundStyle(.tertiary) }
            if aside > 0 && !showSetAside {
                Button("\(aside) set aside by Claude as probably someone else · Show") { showSetAside = true }.buttonStyle(.link).font(.system(size: 11))
            }
            officers(p, d, c)
            if let li, wants {
                HStack(spacing: 6) {
                    Link("LinkedIn profile", destination: URL(string: "https://www." + li.value) ?? URL(string: "https://www.linkedin.com")!).font(.system(size: 12))
                    Text("Posts aren't read automatically: turn on LinkedIn's bell (\"notify me about posts\") on their profile.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if chinese {
                HStack(spacing: 8) {
                    Text("No automatic sources for Chinese contacts. Last checked: \(d.manualChecked.map { CircleFmt.ago($0) } ?? "never")").font(.system(size: 11)).foregroundStyle(.secondary)
                    let q = ([p.name, d.company].filter { !$0.isEmpty }.joined(separator: " ")).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    if let u = URL(string: "https://www.baidu.com/s?wd=\(q)") { Link("Baidu", destination: u).font(.system(size: 11)) }
                    if let u = URL(string: "https://www.qcc.com/web/search?key=\(q)") { Link("Qichacha", destination: u).font(.system(size: 11)) }
                    Button("Checked today") { c.markChecked(p.id) }.controlSize(.small)
                }
            }
        }
    }

    private func updateRow(_ u: CircleUpdate, _ c: CircleStore) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(u.kind.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                if let url = URL(string: u.url), !u.url.isEmpty { Link(u.title, destination: url).font(.system(size: 12)) } else { Text(u.title).font(.system(size: 12)) }
                Text(([u.detail] + [u.at.map { CircleFmt.f("d MMM yyyy", $0) } ?? ""]).filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer()
            if u.kind.isNews {
                switch u.verdict {
                case .none:
                    Text(u.match == "unlikely" ? "set aside" : "possible").font(.system(size: 10)).foregroundStyle(.orange)
                    Button("Right") { c.setVerdict(u.id, .right) }.controlSize(.mini)
                    Button("Wrong") { c.setVerdict(u.id, .wrong) }.controlSize(.mini)
                case .right: Text("right").font(.system(size: 10)).foregroundStyle(.green)
                case .wrong: Text("wrong").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func officers(_ p: Person, _ d: CircleDetails, _ c: CircleStore) -> some View {
        let cands = c.officerCandidates(p.id)
        return VStack(alignment: .leading, spacing: 4) {
            if !d.officerID.isEmpty {
                HStack {
                    Text("Companies House: \(d.officerName)").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Not them") { c.unlinkOfficer(p.id) }.controlSize(.mini)
                }
            } else if !cands.isEmpty {
                Text("Companies House: is one of these them? Nothing is linked until you confirm.").font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(cands) { o in
                    HStack(spacing: 6) {
                        Text(o.name).font(.system(size: 12))
                        Text([o.born.isEmpty ? "" : "born \(o.born)", o.detail].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(.tertiary)
                        if o.bornMatches { Text("birth month matches").font(.system(size: 10)).foregroundStyle(.green) }
                        Spacer()
                        Button("This is them") { c.confirmOfficer(p.id, o) }.controlSize(.mini)
                    }
                }
            }
        }
    }

    private func handles(_ hs: [Handle]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle("Handles")
            ForEach(hs, id: \.self) { h in
                HStack(spacing: 6) {
                    Text(h.kind.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                    if let l = Handles.chatLink(h), let u = URL(string: l) { Link(LIDBook.display(store: store, h), destination: u).font(.system(size: 12)) }
                    else { Text(LIDBook.display(store: store, h)).font(.system(size: 12)).textSelection(.enabled) }
                }
            }
        }
    }

    private func merges(_ c: CircleStore, _ p: Person) -> some View {
        let ms = c.merges(of: p.id)
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(ms) { m in
                HStack {
                    Text("\(m.auto ? "Merged automatically (same phone or email)" : "Merged") with \(PeopleStore(store: store).person(m.merged)?.name ?? "P-\(m.merged)") on \(CircleFmt.f("d MMM", m.at))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Split") { c.split(m.id) }.controlSize(.mini)
                }
            }
        }
    }

    private func timeline(_ p: Person) -> some View {
        let rows = CircleTimeline.rows(store: store, personID: p.id, limit: 60)
        return VStack(alignment: .leading, spacing: 3) {
            sectionTitle("Timeline")
            if rows.isEmpty { Text("Nothing yet: messages, meetings and linked items show here.").font(.system(size: 11)).foregroundStyle(.tertiary) }
            ForEach(rows) { r in
                HStack(spacing: 8) {
                    Text(CircleFmt.f("d MMM yyyy", r.at)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 82, alignment: .leading)
                    Image(systemName: icon(r)).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                    Button { open(r) } label: { Text(r.title).strikethrough(r.ignored).lineLimit(1) }
                        .buttonStyle(.plain).font(.system(size: 12)).disabled(r.link == nil && r.item == nil)
                    Text(r.detail).font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                    if r.channel == .calendar, let x = r.exchangeID {
                        Button(r.ignored ? "We did meet" : "Didn't meet") { CircleStore(store: store).setIgnored(x, !r.ignored) }.controlSize(.mini)
                    }
                }
            }
        }
    }

    private func icon(_ r: TimelineRow) -> String {
        switch r.direction {
        case .incoming: return "arrow.down.left"
        case .outgoing: return "arrow.up.right"
        case .met: return "person.2"
        case nil: return r.item?.kind == .jot ? "note.text" : r.item?.kind == .task ? "checkmark.circle" : "link"
        }
    }

    private func open(_ r: TimelineRow) {
        if let l = r.link, let u = URL(string: l) { NSWorkspace.shared.open(u); return }
        guard let id = r.item else { return }
        switch id.kind {
        case .task: ui.tab = .board; ui.search = id.text
        case .event: ui.calendarFocus = CalendarCache(store: store).kept(shortID: id.number)?.start; ui.tab = .calendar
        default: GlobalSearchOpen.handlers[id.kind]?(id)
        }
    }

    private func sectionTitle(_ t: String) -> some View { Text(t).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }
}
