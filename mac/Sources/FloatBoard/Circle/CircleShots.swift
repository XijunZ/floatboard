import AppKit
import FloatBoardCore
import SwiftUI

/// Dev aid: `FLOATBOARD_CIRCLESHOTS=1 FloatBoard --snapshot <dir>` on a scratch database draws Circle's screens with
/// made-up people (light and dark): the tab with the due list, a person's card, the form, the suggestions and a draft.
@MainActor enum CircleShots {
    static func run(dir: String, store: Store, ui: UIState, google: Google) {
        guard LocalData.isScratchDatabase else { print("CircleShots: scratch database only"); return }
        seed(store)
        func save<V: View>(_ v: V, _ name: String, _ size: CGSize) {
            for scheme in [ColorScheme.light, .dark] {
                let host = NSHostingView(rootView: v.environmentObject(store).environmentObject(ui).environmentObject(google)
                    .frame(width: size.width, height: size.height)
                    .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.97)).environment(\.colorScheme, scheme))
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                host.frame = CGRect(origin: .zero, size: size)
                let w = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                w.isReleasedWhenClosed = false
                w.contentView = host
                w.setFrameOrigin(NSPoint(x: -30000, y: -30000))
                w.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let file = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
                    do { try rep.representation(using: .png, properties: [:])?.write(to: file) } catch { print("ERR: \(name): \(error)") }
                }
                w.close()
            }
        }
        let people = PeopleStore(store: store).people()
        CircleNav.shared.selected = nil
        save(CircleTab(), "circle-tab-due", CGSize(width: 1100, height: 640))
        if let ivy = people.first(where: { $0.name == "Ivy Example" }) {
            CircleNav.shared.selected = ivy.id
            save(CircleTab(), "circle-tab-card", CGSize(width: 1100, height: 900))
            save(PersonForm(request: PersonFormRequest(personID: ivy.id)) { _ in }, "circle-form-edit", CGSize(width: 560, height: 620))
            save(DraftSheet(personID: ivy.id) {}, "circle-draft", CGSize(width: 520, height: 300))
        }
        if let mei = people.first(where: { $0.name == "王美玲" }) {
            CircleNav.shared.selected = mei.id
            save(CircleTab(), "circle-tab-card-chinese", CGSize(width: 1100, height: 700))
        }
        save(PersonForm(request: PersonFormRequest(personID: nil, name: "Nora Example")) { _ in }, "circle-form-add", CGSize(width: 560, height: 620))
        save(SuggestionsSheet(close: {}, add: { _ in }), "circle-suggestions", CGSize(width: 640, height: 560))
        save(WeeklyReviewView {}, "circle-weekly-review", CGSize(width: 520, height: 420))
    }

    /// Made-up people, messages, meetings and updates (example.com addresses only).
    static func seed(_ store: Store) {
        store.setModule(.circle, on: true)
        let c = CircleStore(store: store)
        let now = Date(), day: TimeInterval = 86400
        func add(_ name: String, _ tier: PersonTier, _ tags: [String], _ d: CircleDetails = CircleDetails(), _ hs: [Handle], added: Double = 200) -> Person? {
            c.add(name: name, tier: tier, tags: ItemTags(primary: tags.first, others: Array(tags.dropFirst())), details: d, handles: hs,
                  now: now - added * day).person
        }
        var ivyD = CircleDetails(); ivyD.company = "Acme Capital"; ivyD.role = "Partner"; ivyD.firm = "Acme Capital"; ivyD.focus = "Seed fintech"
        ivyD.howKnown = "Former colleague"; ivyD.notes = "Moved to London in spring; likes long walks."; ivyD.birthday = "1980-04-12"
        let ivy = add("Ivy Example", .network, [TagRules.investor], ivyD, [Handle(kind: .email, value: "ivy@example.com"), Handle(kind: .phone, value: "447700900101"),
                                                                           Handle(kind: .linkedin, value: "linkedin.com/in/ivy-example")])
        var pd = CircleDetails(); pd.purpose = "career"; pd.stage = "in_touch"; pd.company = "Northwind"
        let pat = add("Pat Example", .network, [TagRules.prospect], pd, [Handle(kind: .email, value: "pat@example.com")])
        let sam = add("Sam Example", .close, [], CircleDetails(), [Handle(kind: .phone, value: "447700900102")])
        var famD = CircleDetails(); famD.birthday = Due.dayString(now + 2 * day).replacingOccurrences(of: String(Due.dayString(now).prefix(4)), with: "1960")
        _ = add("Robin Example", .family, [], famD, [Handle(kind: .phone, value: "447700900103")])
        var meiD = CircleDetails(); meiD.language = "Chinese"; meiD.company = "华夏科技"; meiD.notes = "大学同学，现在在上海工作"
        _ = add("王美玲", .close, [], meiD, [Handle(kind: .wechat, value: "王美玲")])
        _ = add("A Very Long Name Example-Hyphenated Surname", .network, [], CircleDetails(), [Handle(kind: .email, value: "long@example.com")])
        if let ivy {
            let e = Handle(kind: .email, value: "ivy@example.com"), w = Handle(kind: .phone, value: "447700900101")
            c.record([ExchangeInput(channel: .gmail, direction: .incoming, at: now - 40 * day, handle: e, name: "Ivy Example", ref: "me@example.com"),
                      ExchangeInput(channel: .gmail, direction: .outgoing, at: now - 38 * day, handle: e, ref: "me@example.com"),
                      ExchangeInput(channel: .whatsapp, direction: .incoming, at: now - 5 * day, handle: w, name: "Ivy")])
            c.applyEngineUpdates([
                EngineUpdate(seq: 1, person: ivy.shortID.text, kind: "news_person", key: "s:n1", title: "Ivy Example joins the board of Beta Payments",
                             detail: "The Paper", url: "https://example.com/n1", at: ISO8601DateFormatter().string(from: now - 3 * day), match: "possible", born: nil, officer: nil),
                EngineUpdate(seq: 2, person: ivy.shortID.text, kind: "news_person", key: "s:n2", title: "Ivy Example wins village bake-off", detail: "Village News",
                             url: "https://example.com/n2", at: ISO8601DateFormatter().string(from: now - 4 * day), match: "unlikely", born: nil, officer: nil),
                EngineUpdate(seq: 3, person: ivy.shortID.text, kind: "news_firm", key: "s:n3", title: "Acme Capital closes its third fund", detail: "Wire",
                             url: "https://example.com/n3", at: ISO8601DateFormatter().string(from: now - 6 * day), match: "possible", born: nil, officer: nil),
                EngineUpdate(seq: 4, person: ivy.shortID.text, kind: "officer_candidate", key: "s:o1", title: "EXAMPLE, Ivy", detail: "London · 2 appointments",
                             url: "", at: nil, match: "", born: "1980-04", officer: "OFF1"),
                EngineUpdate(seq: 5, person: ivy.shortID.text, kind: "officer_candidate", key: "s:o2", title: "EXAMPLE, Ivy Jane", detail: "Leeds · 1 appointment",
                             url: "", at: nil, match: "", born: "1975-09", officer: "OFF2"),
            ], now: now)
            c.setChannel("whatsapp", asOf: now - 300, completeFrom: now - 365 * day, cursor: "1", note: "one-to-one chats only")
            c.setChannel("gmail:me@example.com", asOf: now - 900, completeFrom: now - 200 * day, cursor: "", note: "inbox and Sent")
            c.setChannel("wechat", asOf: now - 300, completeFrom: now - 9 * day, cursor: "", note: Channel.wechat.limits ?? "")
            if let j = JotStore(store: store).create(text: "Coffee with Ivy Example: she is raising a seed fund for fintech", now: now - 20 * day) {
                store.link(j.shortID, ivy.shortID, kind: .related, madeBy: .suggested, actor: .user)
            }
        }
        if let pat { _ = CircleDue.makeTask(store: store, personID: pat.id, now: now - 2 * day) }
        if let sam { c.talked(sam.id, at: now - 3 * day) }
        CircleDue.register()
    }
}

/// Round 8 pictures (`FLOATBOARD_ROUND8SHOTS=1 FloatBoard --snapshot <dir>`, scratch database only): the Add form with a
/// WhatsApp contact that shares no number, the person pane's tag row and its + menu, and the people list with tag chips.
@MainActor enum Round8Shots {
    static func run(dir: String, store: Store, ui: UIState, google: Google, round9: Bool = false) {
        guard LocalData.isScratchDatabase else { print("Round8Shots: scratch database only"); return }
        store.setModule(.circle, on: true)
        let c = CircleStore(store: store), now = Date()
        _ = PeopleTags.add(store: store, "Board member"); _ = PeopleTags.add(store: store, "Advisor")
        func add(_ name: String, _ tier: PersonTier, _ tags: [String], _ hs: [Handle] = []) -> Person? {
            c.add(name: name, tier: tier, tags: ItemTags(primary: tags.first, others: Array(tags.dropFirst())), details: CircleDetails(), handles: hs,
                  now: now.addingTimeInterval(-90 * 86400)).person
        }
        _ = add("Ada Example", .close, [])
        let ben = add("Ben Example", .network, ["Investor"], [Handle(kind: .email, value: "ben@example.com")])
        _ = add("Carolina Montgomery-Fitzwilliam Example", .network, ["Investor", "Board member", "Advisor"])
        _ = add("王美玲", .close, ["Advisor"])
        _ = add("Dan Example", .network, ["Investor", "Board member", "Advisor"])
        func save<V: View>(_ v: V, _ name: String, _ size: CGSize) {
            for scheme in [ColorScheme.light, .dark] {
                let host = NSHostingView(rootView: v.environmentObject(store).environmentObject(ui).environmentObject(google)
                    .frame(width: size.width, height: size.height)
                    .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.97)).environment(\.colorScheme, scheme))
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                host.frame = CGRect(origin: .zero, size: size)
                let w = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                w.isReleasedWhenClosed = false
                w.contentView = host
                w.setFrameOrigin(NSPoint(x: -30000, y: -30000))
                w.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let file = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
                    do { try rep.representation(using: .png, properties: [:])?.write(to: file) } catch { print("ERR: \(name): \(error)") }
                }
                w.close()
            }
        }
        if round9 {
            // Round 9: the list with tier chips and the person pane, at the app's minimum width (800) and a normal one.
            for w in [800, 1100] {
                CircleNav.shared.selected = nil
                save(CircleTab(), "round9-list-\(w)", CGSize(width: w, height: 460))
                CircleNav.shared.selected = ben?.id
                save(CircleTab(), "round9-person-\(w)", CGSize(width: w, height: 460))
            }
            return
        }
        let form = PersonFormRequest(personID: nil, name: "Lin Example",
                                     handles: [Handle(kind: .phone, value: "447700900111"), Handle(kind: .whatsapp, value: "98765432101234@lid")])
        save(PersonForm(request: form) { _ in }, "round8-form-add", CGSize(width: 560, height: 620))
        CircleNav.shared.selected = ben?.id
        save(CircleTab(), "round8-person-tags", CGSize(width: 1000, height: 560))
        // A menu can't be drawn open off screen: its items are drawn as the menu shows them, next to the tag row.
        save(MenuPicture(items: PeopleTags.offered(store: store).filter { $0 != "Investor" } + ["New tag…"]), "round8-tag-menu", CGSize(width: 220, height: 160))
        CircleNav.shared.selected = nil
        save(CircleTab(), "round8-list-narrow", CGSize(width: 860, height: 440))
    }

    /// The + menu's items, drawn like a macOS menu.
    struct MenuPicture: View {
        let items: [String]
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, t in
                    if t == "New tag…" && i > 0 { Divider().padding(.vertical, 3) }
                    Text(t).font(.system(size: 13)).padding(.horizontal, 12).padding(.vertical, 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(i == 0 ? Color.accentColor : Color.clear).foregroundStyle(i == 0 ? Color.white : Color.primary)
                }
            }
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.15)))
            .padding(10)
        }
    }
}
