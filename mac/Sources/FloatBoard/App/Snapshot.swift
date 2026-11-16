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
            for c in store.cards { print(c.title.prefix(30), "|", c.due.map { Fmt.due($0, hasTime: c.dueHasTime) } ?? "-", "|", c.googleCalendarURL?.absoluteString ?? "no due date") }
            var c = store.cards[0]; c.notes = "Agenda: plan the week. Call: https://meet.google.com/abc-defg-hij"
            print("meet from notes:", c.meetLink?.absoluteString ?? "none")
        }
        if ProcessInfo.processInfo.environment["FLOATBOARD_INPUTTEST"] != nil {
            let cal = AppTime.calendar
            let base = cal.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 0, minute: 0))!
            func run(_ m: inout SegmentModel, _ keys: String) {
                for k in keys {
                    switch k { case "<": m.left(); case ">": m.right(); case "^": m.step(1); case "v": m.step(-1); case "x": m.backspace()
                    default: m.digit(k.wholeNumberValue!) }
                }
                m.commit()
            }
            let f = DateFormatter(); f.timeZone = AppTime.zone; f.dateFormat = "HH:mm"
            let g = DateFormatter(); g.timeZone = AppTime.zone; g.dateFormat = "yyyy-MM-dd"
            for keys in ["1430", "930", "9", "1430<<09", "2>", "23^", "00v", "1x45"] {
                var m = SegmentModel.time(base); run(&m, keys); print("time", keys.padding(toLength: 10, withPad: " ", startingAt: 0), "->", f.string(from: m.applyTime(to: base)))
            }
            for keys in ["20261225", "2026117", "20260231", "2027035", "26>12>4", "2026^"] {
                var m = SegmentModel.date(base); run(&m, keys); print("date", keys.padding(toLength: 10, withPad: " ", startingAt: 0), "->", g.string(from: m.applyDate(to: base)))
            }
        }
        if ProcessInfo.processInfo.environment["FLOATBOARD_TIMETEST"] != nil {
            let cal = AppTime.calendar
            let today = Date()
            let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
            let t1530 = cal.date(bySettingHour: 15, minute: 30, second: 0, of: today)!
            let t0900 = cal.date(bySettingHour: 9, minute: 0, second: 0, of: today)!
            store.add(title: "Tomorrow date-only", area: "Personal", importance: .high, due: Due.combine(day: tomorrow, time: nil))
            store.add(title: "Today date-only", area: "Personal", importance: .high, due: Due.combine(day: today, time: nil))
            store.add(title: "Meeting tomorrow 15:30", area: "Acme", importance: .low, due: Due.combine(day: tomorrow, time: t1530), dueHasTime: true)
            store.add(title: "Meeting today 09:00", area: "Acme", importance: .low, due: Due.combine(day: today, time: t0900), dueHasTime: true)
            store.add(title: "No due", area: "Acme", importance: .high, due: nil)
            for c in store.active {
                print(c.title, "|", c.due.map { Fmt.due($0, hasTime: c.dueHasTime) } ?? "-", "| overdue:", c.isOverdue)
            }
        }
        if ProcessInfo.processInfo.environment["FLOATBOARD_GROUPTEST"] != nil {
            let day: TimeInterval = 86400
            store.add(title: "No due todo high", area: "Acme", importance: .high, due: nil)
            store.add(title: "Due in 5d todo", area: "Personal", importance: .low, due: Date().addingTimeInterval(5 * day), dueHasTime: true)
            store.add(title: "Doing no due", area: "Acme", importance: .medium, due: nil)
            store.add(title: "Due tomorrow doing", area: "Garden", importance: .low, due: Date().addingTimeInterval(day), dueHasTime: true)
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
        let wasSplit = ui.bar.splitCount
        ui.bar.splitCount = true
        save(RootView().background(backdrop), "banner-split.png", CGSize(width: 900, height: 30))
        ui.bar.splitCount = wasSplit
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
            for c in store.cards { save(EditCardView(draft: c) {}, "edit-\(c.id).png", CGSize(width: 420, height: 400)) }
        }
        // Calendar Day and Week with made-up events and tasks. Only on a scratch database: it fills the calendar cache and the board.
        if ProcessInfo.processInfo.environment["FLOATBOARD_CALSHOTS"] != nil, LocalData.isScratchDatabase {
            seedCalendar(store)
            // The bar with a made-up meeting 20 minutes away: with a video link (Join), without one, and with a long title.
            let soon = Date().addingTimeInterval(20 * 60)
            for (name, title, link) in [("bar-meeting.png", "Design sync", "https://meet.example.com/abc"),
                                        ("bar-meeting-nolink.png", "Dentist", ""),
                                        ("bar-meeting-long.png", "Quarterly planning review with the whole leadership team", "https://meet.example.com/abc")] {
                let f = CalEventFields(start: soon, end: soon.addingTimeInterval(1800), title: title, videoLink: link, googleUpdated: Date())
                CalendarCache(store: store).apply(account: "me@example.com", calendarID: "me@example.com",
                                                  changes: [GoogleEventChange(eventID: "bar", cancelled: false, fields: f)], nextToken: nil)
                ui.refreshMeeting(store: store)
                save(RootView().background(backdrop), name, CGSize(width: 900, height: 30))
            }
            CalendarCache(store: store).apply(account: "me@example.com", calendarID: "me@example.com",
                                              changes: [GoogleEventChange(eventID: "bar", cancelled: true, fields: nil)], nextToken: nil)
            ui.refreshMeeting(store: store)
            let cal0 = AppTime.calendar
            let cache = CalendarCache(store: store)
            let hours = 8...18
            save(CalendarView(span: .day, snapshotHours: hours).padding(12), "calendar-day.png", CGSize(width: 1100, height: 640))
            save(CalendarView(span: .week, snapshotHours: hours).padding(12), "calendar-week.png", CGSize(width: 1100, height: 640))
            // Links between made-up tasks and meetings: the editor, the event panel and a card with its meeting count.
            let events = cache.events(from: cal0.startOfDay(for: Date()), to: Date().addingTimeInterval(7 * 86400))
            if let planning = events.first(where: { $0.title == "Planning" }), let review = events.first(where: { $0.title == "Design sync" }),
               let deck = store.cards.first(where: { $0.title == "Send the deck to the team" }),
               let venue = store.cards.first(where: { $0.title == "Book the venue" }) {
                let d = ShortID(kind: .task, number: deck.id), v = ShortID(kind: .task, number: venue.id)
                store.link(d, planning.id, actor: .user); store.link(d, review.id, actor: .user); store.link(v, planning.id, actor: .user)
                if let done = store.card(venue.id) { store.move(done, to: .done) }
                let edits = CalendarEdits()
                let cal = CalCalendar(account: planning.account, calendarID: planning.calendarID, name: "Work", color: "#4285f4", owned: true, shown: true)
                save(EventPanel(event: planning, calendar: cal, waiting: false).environmentObject(edits).environment(\.calendarSnapshot, true),
                     "link-event-panel.png", CGSize(width: 340, height: 330))
                if let fresh = store.card(deck.id) {
                    save(EditCardView(draft: fresh) {}, "link-editor.png", CGSize(width: 420, height: 520))
                    save(CardView(card: fresh).padding(12), "link-card.png", CGSize(width: 340, height: 130))
                }
            }
        }
        // Settings › Calendar in each state, with made-up accounts. Only on a scratch database: it fills the calendar cache.
        if ProcessInfo.processInfo.environment["FLOATBOARD_CALSETTINGSSHOTS"] != nil, LocalData.isScratchDatabase {
            let cache = CalendarCache(store: store)
            let a = "alex@example.com", b = "sam@example.org"
            func page(_ accounts: [String]) -> some View {
                SettingsBlock(title: "Calendar", help: "Switch on the calendars to show in the Calendar tab and the bar. Tasks you put on the calendar go to the default account.") {
                    CalendarSettingsView(accounts: accounts).environment(\.calendarSnapshot, true)
                }.padding(12).frame(width: 640, alignment: .topLeading).fixedSize(horizontal: false, vertical: true)
            }
            save(page([]), "settings-calendar-none.png", CGSize(width: 640, height: 260))
            // Just connected: the first calendar list has not come back yet.
            save(page([a]), "settings-calendar-loading.png", CGSize(width: 640, height: 260))
            // The list was refused (the permission to list calendars is missing).
            CalendarListAttempts.record(a, .needsReconnect)
            save(page([a]), "settings-calendar-reconnect.png", CGSize(width: 640, height: 260))
            CalendarListAttempts.record(a, .listed); CalendarListAttempts.record(b, .listed)
            cache.upsertCalendars(account: a, [
                CalCalendar(account: a, calendarID: a, name: "Work", color: "#4285f4", owned: true, shown: true),
                CalCalendar(account: a, calendarID: "home", name: "Home", color: "#33b679", owned: true, shown: true),
                CalCalendar(account: a, calendarID: "hol", name: "Holidays", color: "#f4511e", owned: false, shown: false)])
            cache.upsertCalendars(account: b, [
                CalCalendar(account: b, calendarID: b, name: "Sam", color: "#8e24aa", owned: true, shown: true),
                CalCalendar(account: b, calendarID: "club", name: "Chess club", color: "#039be5", owned: false, shown: false)])
            save(page([a, b]), "settings-calendar-two.png", CGSize(width: 640, height: 420))
            // One calendar that Google refused: its account asks to reconnect.
            cache.setNeedsReconnect(account: b, calendarID: "club", true)
            store.setDefaultCalendarAccount(b)
            save(page([a, b]), "settings-calendar-two-reconnect.png", CGSize(width: 640, height: 420))
        }
        save(GuideView().content, "guide.png", CGSize(width: 440, height: 760))
        // ScrollView doesn't render here, so each Settings section is drawn directly.
        for s in SettingsSection.allCases {
            let page = VStack(alignment: .leading, spacing: 14) {
                Text(s.title).font(.system(size: 15, weight: .semibold))
                switch s {
                case .general: GeneralSection()
                case .mode: ModeSection()
                case .connections: ConnectionsSection()
                case .rules: RulesSection()
                case .keys: KeysSection()
                }
                Spacer(minLength: 0)
            }.padding(12).frame(width: 800, alignment: .topLeading).fixedSize(horizontal: false, vertical: true)
            save(page, "settings-\(s.rawValue).png", CGSize(width: 800, height: 900))
        }
    }

    /// Made-up calendars, events and tasks for the Calendar pictures (this week, around today).
    private static func seedCalendar(_ store: Store) {
        let cal = AppTime.calendar
        let cache = CalendarCache(store: store)
        let account = "me@example.com"
        cache.upsertCalendars(account: account, [
            CalCalendar(account: account, calendarID: account, name: "Work", color: "#4285f4", owned: true, shown: true),
            CalCalendar(account: account, calendarID: "home", name: "Home", color: "#33b679", owned: true, shown: true),
            CalCalendar(account: account, calendarID: "hol", name: "Holidays", color: "#f4511e", owned: false, shown: true)])
        let monday = CalendarLayout.weekStart(containing: Date())
        let today = cal.startOfDay(for: Date())
        func at(_ day: Date, _ h: Int, _ m: Int = 0) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: day)! }
        func dayOffset(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: monday)! }
        func timed(_ title: String, _ day: Date, _ h: Int, _ m: Int, minutes: Int, link: String = "") -> CalEventFields {
            let s = at(day, h, m)
            return CalEventFields(start: s, end: s.addingTimeInterval(Double(minutes) * 60), title: title, videoLink: link, googleUpdated: Date())
        }
        func change(_ id: String, _ f: CalEventFields) -> GoogleEventChange { GoogleEventChange(eventID: id, cancelled: false, fields: f) }
        let f = DateFormatter(); f.timeZone = AppTime.zone; f.dateFormat = "yyyy-MM-dd"
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        let holiday = CalEventFields(start: today, end: tomorrow, allDay: true, startDay: f.string(from: today), endDay: f.string(from: tomorrow),
                                     title: "Office closed", googleUpdated: Date())
        cache.apply(account: account, calendarID: account, changes: [
            change("w1", timed("Standup", today, 9, 0, minutes: 30, link: "https://meet.example.com/a")),
            change("w2", timed("Quarterly review prep", today, 9, 15, minutes: 60)),
            change("w3", timed("Design sync", today, 11, 0, minutes: 60)),
            change("w4", timed("Planning", today, 14, 0, minutes: 90)),
            change("w5", timed("Standup", dayOffset(1), 9, 0, minutes: 30)),
            change("w6", timed("Roadmap workshop", dayOffset(1), 10, 0, minutes: 120)),
            change("w7", timed("1:1", dayOffset(3), 13, 30, minutes: 30)),
            change("w8", timed("Team lunch", dayOffset(4), 12, 0, minutes: 60)),
            change("w9", timed("Board of nobody", today, 16, 30, minutes: 45))], nextToken: nil)
        cache.apply(account: account, calendarID: "home", changes: [
            change("h1", timed("Dentist", dayOffset(2), 8, 30, minutes: 45)),
            change("h2", timed("School pick-up", today, 15, 45, minutes: 30))], nextToken: nil)
        cache.apply(account: account, calendarID: "hol", changes: [change("x1", holiday)], nextToken: nil)
        store.add(title: "Send the deck to the team", area: "Personal", importance: .high, due: at(today, 15, 0), dueHasTime: true)
        store.add(title: "Renew the parking permit", area: "Acme", importance: .medium, due: today)
        store.add(title: "Book the venue", area: "Garden", importance: .low, due: cal.date(byAdding: .day, value: 2, to: today))
        store.add(title: "Reply to the supplier", area: "Acme", importance: .medium, due: cal.date(byAdding: .day, value: 5, to: today))
        // A task that has an event: it shows once, as the task.
        store.add(title: "Call the accountant", area: "Personal", importance: .medium, due: at(dayOffset(3), 10, 0), dueHasTime: true)
        if let t = store.cards.last {
            cache.apply(account: account, calendarID: account, changes: [
                change("lk1", timed("Call the accountant", dayOffset(3), 10, 0, minutes: 30))], nextToken: nil)
            do { try store.db.run("UPDATE cards SET gcal_account=?, gcal_calendar=?, gcal_event=? WHERE id=?", [account, account, "lk1", t.id]) } catch {
                print("ERR: could not link the sample task: \(error)")
            }
            store.reload()
        }
    }
}
