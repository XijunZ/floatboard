import FloatBoardCore
import AppKit
import SwiftUI

/// Dev aid: `FloatBoard --snapshot <dir>` renders the banner and board to PNGs and exits.
@MainActor
enum Snapshot {
    static func run(dir: String, store: Store, google: Google) {
        let ui = UIState()
        if ProcessInfo.processInfo.environment["FLOATBOARD_BARTEST"] != nil {
            let open = store.cards.filter { $0.status != .done }
            let groups = store.areas.map(\.name)
            var c = BarConfig()
            print("DEFAULT:", c.sorted(open, groupOrder: groups).map { "\($0.title.prefix(18))[\($0.importance.marks) \($0.due.map(Fmt.short) ?? "-")]" }.joined(separator: " | "))
            c.sort.move(fromOffsets: IndexSet(integer: 2), toOffset: 0) // importance first
            print("IMPORTANCE FIRST:", c.sorted(open, groupOrder: groups).map { "\($0.title.prefix(18))[\($0.importance.marks) \($0.due.map(Fmt.short) ?? "-")]" }.joined(separator: " | "))
            print("ORDER KEYS:", c.sort.filter(\.on).map(\.key.rawValue))
            for (sf, df) in [(BarConfig.StatusFilter.doing, BarConfig.DueFilter.any), (.todo, .any), (.both, .today), (.both, .hasDue)] {
                var f = BarConfig(); f.statusFilter = sf; f.dueFilter = df
                print("\(sf.title) / \(df.title):", f.sorted(open, groupOrder: groups).map { "\($0.title.prefix(14))[\($0.status.rawValue) \($0.due.map(Fmt.short) ?? "-")]" }.joined(separator: " | "))
            }
        }
        if ProcessInfo.processInfo.environment["FLOATBOARD_GCALTEST"] != nil {
            for c in store.cards { print(c.title.prefix(30), "|", c.due.map(Fmt.due) ?? "-", "|", c.googleCalendarURL?.absoluteString ?? "no due date") }
            var c = store.cards[0]; c.notes = "Agenda: plan the week. Call: https://meet.google.com/abc-defg-hij"
            print("meet from notes:", c.meetLink?.absoluteString ?? "none")
        }
        if ProcessInfo.processInfo.environment["FLOATBOARD_INPUTTEST"] != nil {
            let cal = Calendar.current
            let base = cal.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 0, minute: 0))!
            func run(_ m: inout SegmentModel, _ keys: String) {
                for k in keys {
                    switch k { case "<": m.left(); case ">": m.right(); case "^": m.step(1); case "v": m.step(-1); case "x": m.backspace()
                    default: m.digit(k.wholeNumberValue!) }
                }
                m.commit()
            }
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            let g = DateFormatter(); g.dateFormat = "yyyy-MM-dd"
            for keys in ["1430", "930", "9", "1430<<09", "2>", "23^", "00v", "1x45"] {
                var m = SegmentModel.time(base); run(&m, keys); print("time", keys.padding(toLength: 10, withPad: " ", startingAt: 0), "->", f.string(from: m.applyTime(to: base)))
            }
            for keys in ["20261225", "2026117", "20260231", "2027035", "26>12>4", "2026^"] {
                var m = SegmentModel.date(base); run(&m, keys); print("date", keys.padding(toLength: 10, withPad: " ", startingAt: 0), "->", g.string(from: m.applyDate(to: base)))
            }
        }
        if ProcessInfo.processInfo.environment["FLOATBOARD_TIMETEST"] != nil {
            let cal = Calendar.current
            let today = Date()
            let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
            let t1530 = cal.date(bySettingHour: 15, minute: 30, second: 0, of: today)!
            let t0900 = cal.date(bySettingHour: 9, minute: 0, second: 0, of: today)!
            store.add(title: "Tomorrow date-only", area: "Personal", importance: .high, due: Due.combine(day: tomorrow, time: nil))
            store.add(title: "Today date-only", area: "Personal", importance: .high, due: Due.combine(day: today, time: nil))
            store.add(title: "Meeting tomorrow 15:30", area: "Acme", importance: .low, due: Due.combine(day: tomorrow, time: t1530))
            store.add(title: "Meeting today 09:00", area: "Acme", importance: .low, due: Due.combine(day: today, time: t0900))
            store.add(title: "No due", area: "Acme", importance: .high, due: nil)
            for c in store.active {
                print(c.title, "|", c.due.map(Fmt.due) ?? "-", "| overdue:", c.isOverdue)
            }
        }
        if ProcessInfo.processInfo.environment["FLOATBOARD_GROUPTEST"] != nil {
            let day: TimeInterval = 86400
            store.add(title: "No due todo high", area: "Acme", importance: .high, due: nil)
            store.add(title: "Due in 5d todo", area: "Personal", importance: .low, due: Date().addingTimeInterval(5 * day))
            store.add(title: "Doing no due", area: "Acme", importance: .medium, due: nil)
            store.add(title: "Due tomorrow doing", area: "Garden", importance: .low, due: Date().addingTimeInterval(day))
            store.add(title: "Todo no due low", area: "Personal", importance: .low, due: nil)
            for c in store.cards where c.title.hasPrefix("Doing") || c.title.hasSuffix("doing") { store.move(c, to: .doing) }
            print("ORDER:", store.active.map(\.title).joined(separator: " | "))
            print("add dup:", store.addArea("acme") ?? "ok")
            print("add Hobbies:", store.addArea("Hobbies") ?? "ok")
            if let p = store.areas.first(where: { $0.name == "Personal" }) { print("rename:", store.renameArea(p, to: "Home") ?? "ok") }
            if let f = store.areas.first(where: { $0.name == "Hobbies" }) { store.moveArea(f, by: -1) }
            if let m = store.areas.first(where: { $0.name == "Acme" }) { store.deleteArea(m, moveTasksTo: "Home") }
            print("GROUPS:", store.areas.map { "\($0.name)=\($0.colorHex)" }.joined(separator: ", "))
            print("CARDS:", store.cards.map { "\($0.title)->\($0.area)" }.joined(separator: " | "))
            print("shift Home+1:", store.shift("Home", by: 1), " shift first-1:", store.shift(store.areas[0].name, by: -1))
            print("ERR:", store.lastError ?? "none")
        }
        if ProcessInfo.processInfo.environment["FLOATBOARD_SELFTEST"] != nil {
            store.add(title: "Selftest card", area: "Garden", importance: .high, due: nil)
            if let c = store.cards.last { store.move(c, to: .doing) }
            if let c = store.cards.last { store.move(c, to: .done) }
        }
        func save<V: View>(_ v: V, _ name: String, _ size: CGSize) {
            let view = v.environmentObject(store).environmentObject(ui).environmentObject(google)
                .frame(width: size.width, height: size.height)
                .background(Color(white: 0.97)).environment(\.colorScheme, .light)
            let r = ImageRenderer(content: view); r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                do { try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name)) } catch {
                    print("ERR: could not write \(name): \(error)")
                    store.activity("snapshot", .error, "Could not write the snapshot image \(name)", detail: "\(error)")
                }
            }
        }
        let backdrop = LinearGradient(colors: [.blue, .orange, .green], startPoint: .leading, endPoint: .trailing)
        save(RootView().background(backdrop), "banner.png", CGSize(width: 900, height: 30))
        ui.quickAdding = true
        save(RootView().background(backdrop), "quickadd.png", CGSize(width: 900, height: 30))
        ui.quickAdding = false
        save(ExpandedView(), "board.png", CGSize(width: 1500, height: 600))
        ui.search = ProcessInfo.processInfo.environment["FLOATBOARD_SEARCH"] ?? ""
        let cols = HStack(alignment: .top, spacing: 10) {
            ForEach(Status.allCases) { st in
                VStack(alignment: .leading, spacing: 6) {
                    Text(st.title).font(.system(size: 12, weight: .semibold))
                    ForEach(store.cards(in: st)) { CardView(card: $0) }
                    Spacer()
                }.padding(8).frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }
        }.padding(12)
        save(cols, "cards.png", CGSize(width: 1200, height: 560))
        // Only on a scratch database: rendering editors can save cards.
        if ProcessInfo.processInfo.environment["FLOATBOARD_EDITSHOTS"] != nil, LocalData.isScratchDatabase {
            for c in store.cards { save(EditCardView(draft: c) {}, "edit-\(c.id).png", CGSize(width: 420, height: 330)) }
        }
        save(GuideView().content, "guide.png", CGSize(width: 440, height: 760))
        // ScrollView doesn't render here, so the connector cards and their settings forms are drawn directly.
        let connectorList = VStack(alignment: .leading, spacing: 12) {
            ForEach(store.connectors) { c in
                ConnectorCard(info: c)
                ConnectorSettingsForm(info: c, schema: ConnectorHealth.status(c, store: store)?.schema ?? [])
            }
            Spacer()
        }.padding(12)
        save(connectorList, "connectors.png", CGSize(width: 900, height: 900))
    }
}
