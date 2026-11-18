import FloatBoardConnectors
import FloatBoardCore
import SwiftUI

/// "Bulk add…": many people at once from WhatsApp or WeChat, from header data only (names, numbers, how many
/// messages, when; never what was said). Read off the main thread; no AI; nothing new goes to the engine.
struct BulkAddSheet: View {
    enum Source: String, CaseIterable { case whatsapp = "WhatsApp", wechat = "WeChat" }
    let close: () -> Void
    /// Pictures and checks: rows given instead of read.
    var preloaded: [Source: [BulkRow]]? = nil
    var startOn: Source = .whatsapp
    @EnvironmentObject var store: Store
    @State private var source: Source = .whatsapp
    @State private var rows: [Source: [BulkRow]] = [:]
    @State private var loading = false
    @State private var problem: String?
    @State private var messagedOnly = true
    @State private var showDismissed = false
    @State private var query = ""
    @State private var picked = Set<String>()
    @State private var tier: PersonTier = .network
    @State private var tag = ""
    @State private var result: String?

    private var shown: [BulkRow] { BulkAdd.visible(rows[source] ?? [], messagedOnly: messagedOnly, showDismissed: showDismissed, query: query) }
    private var pickable: [BulkRow] { shown.filter { !$0.inCircle } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Bulk add to Circle").font(.system(size: 15, weight: .semibold))
                Spacer()
                Picker("", selection: $source) { ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
            }
            FlowLayout(hSpacing: 10, vSpacing: 6) {
                TextField("Search names or numbers", text: $query).textFieldStyle(.roundedBorder).frame(width: 220)
                Toggle(source == .whatsapp ? "People I've messaged" : "People who messaged me", isOn: $messagedOnly).fixedSize()
                    .disabled(source == .wechat)
                Toggle("Show dismissed", isOn: $showDismissed).fixedSize()
                Button("Select all") { picked = Set(pickable.map(\.key)) }.fixedSize()
                Button("Select none") { picked = [] }.fixedSize()
            }
            if source == .wechat {
                Text("WeChat only shows people who have messaged you since FloatBoard started watching: WeChat keeps its messages encrypted, so FloatBoard sees only its notifications on this Mac.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let problem { Text(problem).font(.system(size: 11)).foregroundStyle(.red) }
            ZStack {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(shown) { r in row(r) }
                        if shown.isEmpty && !loading {
                            Text(messagedOnly ? "No one here yet." : "No contacts found.").font(.system(size: 12)).foregroundStyle(.secondary).padding(10)
                        }
                    }
                }
                if loading { ProgressView().controlSize(.small) }
            }
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.03)))
            if let result { Text(result).font(.system(size: 12, weight: .medium)) }
            HStack(spacing: 10) {
                Picker("Tier", selection: $tier) { ForEach(PersonTier.allCases, id: \.self) { Text($0.title).tag($0) } }.frame(width: 170)
                Picker("Tag", selection: $tag) {
                    Text("None").tag("")
                    ForEach(TagRules.fixed, id: \.self) { Text($0).tag($0) }
                }.frame(width: 150)
                Spacer()
                Button("Close") { close() }.keyboardShortcut(.cancelAction)
                Button(picked.isEmpty ? "Add people" : "Add \(picked.count) \(picked.count == 1 ? "person" : "people")") { add() }
                    .keyboardShortcut(.defaultAction).disabled(picked.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 640, height: 600)
        .controlSize(.small)
        .onAppear { source = startOn; load(startOn) }
        .onChange(of: source) { _, s in picked = []; result = nil; load(s) }
    }

    private func row(_ r: BulkRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: picked.contains(r.key) ? "checkmark.square.fill" : "square").foregroundStyle(r.inCircle ? Color.secondary.opacity(0.4) : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.tail)
                Text([r.phone.map(Handles.phoneText) ?? r.handles.first.map { $0.kind == .wechat ? "WeChat" : LIDBook.display(store: store, $0) } ?? "",
                      source == .wechat ? "seen on \(r.messages) day\(r.messages == 1 ? "" : "s")"
                          : (r.messages > 0 ? "\(r.messages) message\(r.messages == 1 ? "" : "s")" : "no messages"),
                      r.last.map { "last \(CircleFmt.f("d MMM yyyy", $0))" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if r.inCircle { Text("In Circle").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
            else if r.dismissed { Text("Dismissed").font(.system(size: 10)).foregroundStyle(.tertiary) }
        }
        .opacity(r.inCircle ? 0.45 : 1)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !r.inCircle else { return }
            if picked.contains(r.key) { picked.remove(r.key) } else { picked.insert(r.key) }
        }
    }

    private func load(_ s: Source) {
        if let preloaded { rows = preloaded.mapValues { BulkAdd.mark($0, store: store) }; return }
        problem = nil
        switch s {
        case .wechat:
            rows[.wechat] = BulkAdd.mark(BulkAdd.wechatRows(store: store), store: store)
        case .whatsapp:
            loading = true
            Task { @MainActor in
                defer { loading = false }
                do {
                    let listing = try await Task.detached { try WhatsAppDirectory.read() }.value
                    let built = BulkAdd.whatsappRows(sessions: listing.sessions, contacts: listing.contacts, known: LIDBook.all(store))
                    rows[.whatsapp] = BulkAdd.mark(built, store: store)
                } catch {
                    problem = (error as? WhatsAppLocal.ReadError)?.description ?? "WhatsApp's data couldn't be read."
                }
            }
        }
    }

    private func add() {
        let chosen = (rows[source] ?? []).filter { picked.contains($0.key) }
        let r = BulkAdd.add(chosen, tier: tier, tag: tag.isEmpty ? nil : tag, store: store)
        result = BulkAdd.summary(r)
        picked = []
        rows[source] = BulkAdd.mark(rows[source] ?? [], store: store)
    }
}
