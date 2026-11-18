import FloatBoardCore
import SwiftUI

/// The Circle tab (P1): everyone in one list with search, tier and tag filters and three sorts; "Due this week" on top;
/// select several to change tier or tags, or two to merge; the person's card on the right.
struct CircleTab: View {
    enum Sort: String, CaseIterable { case due = "Due date", lastTalked = "Last talked", name = "Name" }
    @EnvironmentObject var store: Store
    @ObservedObject private var nav = CircleNav.shared
    @State private var query = ""
    @State private var tiers = CircleTierFilter()
    @State private var tiersLoaded = false
    @State private var tagFilter: Set<String> = []
    @State private var sort: Sort = .due
    @State private var dueOnly = false
    @State private var picked: Set<Int64> = []
    @State private var editing: PersonFormRequest?
    @State private var bulkAdding = false
    @State private var drafting: Int64?
    @State private var bulkProblem: String?

    var body: some View {
        let c = CircleStore(store: store)
        // Worked out once per change (and once a minute for the clocks), not on every keystroke in the search box.
        let snap = CircleSnapshot.current(store: store)
        let clocks = snap.clocks, details = snap.details, handles = snap.handles, all = snap.people
        let due = tiers.visible(snap.due)   // the chips: hidden tiers are neither listed nor counted here (reminders still go out)
        let shown = filtered(all, clocks: clocks, details: details, handles: handles, due: Set(due.map(\.person.id)))
        VStack(alignment: .leading, spacing: 8) {
            toolbar(due: due, count: all.count)
            if !picked.isEmpty { bulkBar(c) }
            HStack(alignment: .top, spacing: 0) {
                list(shown, clocks: clocks, dueIDs: Set(due.filter(\.overdue).map(\.person.id)))
                    .frame(width: 300)
                Divider()
                if let sel = nav.selected {
                    PersonCard(personID: sel, edit: { editing = PersonFormRequest(personID: sel) }, draft: { drafting = sel })
                } else {
                    dueOverview(due)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .sheet(item: $editing) { r in
            PersonForm(request: r) { id in editing = nil; if let id { nav.selected = id } }
        }
        .sheet(item: Binding(get: { drafting.map(DraftTarget.init) }, set: { drafting = $0?.id })) { t in
            DraftSheet(personID: t.id) { drafting = nil }
        }
        .sheet(isPresented: $bulkAdding) { BulkAddSheet(close: { bulkAdding = false }) }
        .sheet(isPresented: $nav.showSuggestions) {
            SuggestionsSheet(close: { nav.showSuggestions = false }, add: { r in nav.showSuggestions = false; editing = r })
        }
        .onChange(of: nav.addRequest?.id) { _, _ in if let r = nav.addRequest { editing = r; nav.addRequest = nil } }
        .onAppear { if let r = nav.addRequest { editing = r; nav.addRequest = nil } }
    }

    private struct DraftTarget: Identifiable { let id: Int64 }

    // MARK: Toolbar and filters

    private func toolbar(due: [DueEntry], count: Int) -> some View {
        let suggestions = CircleSnapshot.current(store: store).suggestionCount
        // The title and count never break mid-word; the controls wrap onto a second line at narrow widths.
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Circle").font(.system(size: 15, weight: .semibold)).fixedSize()
            Text("\(count) people").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
            FlowLayout(hSpacing: 8, vSpacing: 6) {
                Button { dueOnly.toggle(); nav.selected = nil } label: {
                    Label("Due this week \(due.count)", systemImage: "clock").font(.system(size: 12, weight: dueOnly ? .semibold : .regular))
                }.buttonStyle(.bordered).tint(due.contains(where: \.overdue) ? .orange : nil).fixedSize()
                TextField("Search names, companies, handles", text: $query).textFieldStyle(.roundedBorder).frame(width: 220)
                TierToggles(filter: $tiers)
                Menu(tagFilter.isEmpty ? "All tags" : tagFilter.sorted().joined(separator: ", ")) {
                    ForEach(store.tags.map(\.name), id: \.self) { t in
                        Button { if tagFilter.contains(t) { tagFilter.remove(t) } else { tagFilter.insert(t) } } label: {
                            Label(t, systemImage: tagFilter.contains(t) ? "checkmark" : "circle")
                        }
                    }
                    if !tagFilter.isEmpty { Divider(); Button("Clear") { tagFilter = [] } }
                }.frame(width: 120)
                Picker("Sort", selection: $sort) { ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 150)
                Button { bulkAdding = true } label: { Label("Bulk add…", systemImage: "person.3") }.fixedSize()
                    .help("Add many people at once from WhatsApp or WeChat")
                Button { nav.showSuggestions = true } label: { Label(suggestions > 0 ? "Suggestions \(suggestions)" : "Suggestions", systemImage: "person.badge.plus") }.fixedSize()
                Button { editing = PersonFormRequest(personID: nil) } label: { Label("Add", systemImage: "plus") }.keyboardShortcut("n", modifiers: [.command, .shift]).fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.small)
        .onAppear { if !tiersLoaded { tiers = CircleTierFilter.load(store: store); tiersLoaded = true } }
        .onChange(of: tiers) { _, new in if tiersLoaded { new.save(store: store) } }
    }

    private func filtered(_ all: [Person], clocks: [Int64: Clocks], details: [Int64: CircleDetails], handles: [Int64: [Handle]], due: Set<Int64>) -> [Person] {
        var out = all.filter { p in
            if dueOnly && !due.contains(p.id) { return false }
            if !tiers.shows(p.tier) { return false }
            if !tagFilter.isEmpty && !TagFilter.matches(store.itemTags(p.shortID), any: tagFilter) { return false }
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
            let d = details[p.id] ?? CircleDetails()
            return GlobalSearch.matches(([p.name] + p.aliases + [d.company, d.role, d.firm, d.howKnown] + (handles[p.id] ?? []).map(\.value)).joined(separator: " "), query)
        }
        switch sort {
        case .name: break
        case .lastTalked: out.sort { (clocks[$0.id]?.lastConversation ?? .distantPast) > (clocks[$1.id]?.lastConversation ?? .distantPast) }
        case .due: out.sort { (clocks[$0.id]?.dueDate ?? .distantFuture) < (clocks[$1.id]?.dueDate ?? .distantFuture) }
        }
        return out
    }

    // MARK: List

    private func list(_ people: [Person], clocks: [Int64: Clocks], dueIDs: Set<Int64>) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if people.isEmpty {
                    Text(query.isEmpty && tiers.showsAll && tagFilter.isEmpty && !dueOnly ? "No one yet. Add someone, or look at Suggestions." : "No one matches.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(10)
                }
                ForEach(people) { p in
                    let k = clocks[p.id]
                    HStack(spacing: 6) {
                        Button { if picked.contains(p.id) { picked.remove(p.id) } else { picked.insert(p.id) } } label: {
                            Image(systemName: picked.contains(p.id) ? "checkmark.square.fill" : "square").foregroundStyle(.secondary)
                        }.buttonStyle(.plain).help("Select for changing several at once")
                        VStack(alignment: .leading, spacing: 1) {
                            // The name with the person's tags as chips in the same box (board card style); they wrap below a long
                            // name at narrow widths instead of overlapping it.
                            FlowLayout(hSpacing: 4, vSpacing: 2) {
                                HStack(spacing: 4) {
                                    Text(p.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.tail)
                                    if dueIDs.contains(p.id) { Circle().fill(.orange).frame(width: 6, height: 6) }
                                }
                                TierChip(tier: p.tier)   // the tier first, outlined, then the tags
                                ForEach(store.itemTags(p.shortID).all, id: \.self) { t in PersonTagChip(tag: t) }
                            }
                            Text(k?.lastConversation.map { "talked \(CircleFmt.ago($0))" } ?? "no conversation seen")
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(nav.selected == p.id ? Color.accentColor.opacity(0.15) : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { nav.selected = p.id }
                }
            }
        }
    }

    private func bulkBar(_ c: CircleStore) -> some View {
        let ids = Array(picked)
        return HStack(spacing: 8) {
            Text("\(ids.count) selected").font(.system(size: 11, weight: .semibold))
            Menu("Change tier") { ForEach(PersonTier.allCases, id: \.self) { t in Button(t.title) { bulkProblem = c.setTier(ids, t).first } } }.fixedSize()
            PeopleTagMenu(pick: { t in bulkProblem = c.addTags(ids, [t]).first }) { Text("Add tag") }.fixedSize()
            // Remove: the tags the selected people actually have (board groups among them too, so none is stuck).
            let onThem = Array(Set(ids.flatMap { store.itemTags(ShortID(kind: .person, number: $0)).all })).sorted()
            Menu("Remove tag") { ForEach(onThem, id: \.self) { t in Button(t) { bulkProblem = c.removeTags(ids, [t]).first } } }.fixedSize().disabled(onThem.isEmpty)
            if ids.count == 2 {
                Button("Merge") {
                    let s = ids.sorted()
                    bulkProblem = c.merge(kept: s[0], merged: s[1])
                    if bulkProblem == nil { picked = []; nav.selected = s[0] }
                }.help("The older one is kept; Split on their card undoes it")
            }
            Button("Clear") { picked = [] }
            if let bulkProblem { Text(bulkProblem).font(.system(size: 11)).foregroundStyle(.red).lineLimit(1) }
            Spacer()
        }
        .controlSize(.small).padding(6).background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.08)))
    }

    // MARK: Due this week (when no one is selected)

    private func dueOverview(_ due: [DueEntry]) -> some View {
        let c = CircleStore(store: store)
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Due this week").font(.system(size: 14, weight: .semibold))
                Text("People past their interval: reminders for them share the daily limit with decision reviews (Settings › Areas).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if due.isEmpty { Text("No one is due. Nicely done.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8) }
                ForEach(due) { e in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Button(e.person.name) { nav.selected = e.person.id }.buttonStyle(.link).font(.system(size: 13, weight: .medium))
                            Text(([e.person.tier.title, e.clocks.lastConversation.map { "last talked \(CircleFmt.ago($0))" } ?? "no conversation seen",
                                   e.overdue ? "due since \(CircleFmt.f("d MMM", e.clocks.dueDate))" : "due \(CircleFmt.f("EEE d MMM", e.clocks.dueDate))"] + e.context)
                                .joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if e.hasTask { Text("task open").font(.system(size: 10)).foregroundStyle(.secondary) }
                        else { Button("Make task") { _ = CircleDue.makeTask(store: store, personID: e.person.id) } }
                        Button("I contacted them") { c.contacted(e.person.id) }
                        Button { c.snooze(e.person.id) } label: { Image(systemName: "xmark") }.help("Not now: push back one interval")
                    }
                    .controlSize(.small)
                    .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(e.overdue ? 0.05 : 0.025)))
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
