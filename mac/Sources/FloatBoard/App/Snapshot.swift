import FloatBoardCore
import AppKit
import SwiftUI

/// Dev aid: `FloatBoard --snapshot <dir>` renders the banner and board to PNGs and exits.
@MainActor
enum Snapshot {
    static func run(dir: String, store: Store, google: Google) {
        let ui = UIState()
        CalendarCache.connectedAccounts = nil // pictures use made-up accounts that are not signed in
        if ProcessInfo.processInfo.environment["FLOATBOARD_CLOCKSHOT"] != nil { ClockShot.run(dir: dir); return }
        if ProcessInfo.processInfo.environment["FLOATBOARD_CIRCLESHOTS"] != nil { CircleShots.run(dir: dir, store: store, ui: ui, google: google); return }
        if ProcessInfo.processInfo.environment["FLOATBOARD_ROUND11SHOTS"] != nil { Round8Shots.run(dir: dir, store: store, ui: ui, google: google, round11: true); return }
        if ProcessInfo.processInfo.environment["FLOATBOARD_ROUND37SHOTS"] != nil { Round37Shots.run(dir: dir, store: store, ui: ui, google: google); return }
        if ProcessInfo.processInfo.environment["FLOATBOARD_ROUND24SHOTS"] != nil { Round24Shots.run(dir: dir, store: store, ui: ui, google: google); return }
        if ProcessInfo.processInfo.environment["FLOATBOARD_ROUND23SHOTS"] != nil { Round23Shots.run(dir: dir, store: store, ui: ui, google: google); return }
        if ProcessInfo.processInfo.environment["FLOATBOARD_ROUND22SHOTS"] != nil { Round22Shots.run(dir: dir); return }
        if ProcessInfo.processInfo.environment["FLOATBOARD_ROUND16SHOTS"] != nil { Round8Shots.run(dir: dir, store: store, ui: ui, google: google, round16: true); return }
        if ProcessInfo.processInfo.environment["FLOATBOARD_ROUND9SHOTS"] != nil { Round8Shots.run(dir: dir, store: store, ui: ui, google: google, round9: true); return }
        if ProcessInfo.processInfo.environment["FLOATBOARD_ROUND8SHOTS"] != nil { Round8Shots.run(dir: dir, store: store, ui: ui, google: google); return }
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
        // Drawn by an off-screen hosting view, as the app lays it out (scroll views, real buttons and pickers), which the
        // image renderer above cannot do.
        func saveLive<V: View>(_ v: V, _ name: String, _ size: CGSize, inWindow: Bool = false, dark: Bool = false) {
            let host = NSHostingView(rootView: v.environmentObject(store).environmentObject(ui).environmentObject(google)
                .frame(width: size.width, height: size.height).background(Color(white: dark ? 0.12 : 0.97))
                .environment(\.colorScheme, dark ? .dark : .light))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = CGRect(origin: .zero, size: size)
            // Lists (AppKit tables) draw their rows only in a window: a borderless one far off screen, closed after.
            var window: NSWindow?
            if inWindow {
                let w = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
                w.isReleasedWhenClosed = false
                w.contentView = host
                w.setFrameOrigin(NSPoint(x: -30000, y: -30000))
                w.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                window = w
            }
            defer { window?.close() }
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return }
            do { try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name)) } catch {
                store.activity("snapshot", .error, "Could not write the snapshot image \(name)", detail: "\(error)")
            }
        }
        // Two Google accounts in their own colours: one shown with its main calendar only (no list permission), one with three
        // calendars. The Calendar page (legend at the bottom left) and Settings › Outputs › Calendar, light and dark.
        // Only on a scratch database: it fills the calendar cache.
        if ProcessInfo.processInfo.environment["FLOATBOARD_CALCOLOURSHOTS"] != nil, LocalData.isScratchDatabase {
            let accounts = seedTwoAccounts(store)
            for dark in [false, true] {
                let suffix = dark ? "-dark" : ""
                saveLive(CalendarView(span: .week).padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading),
                         "cal-colours-week\(suffix).png", CGSize(width: 1100, height: 620), inWindow: true, dark: dark)
                saveLive(ScrollView { CalendarSettingsView(accounts: accounts).padding(14) }, "cal-colours-settings\(suffix).png",
                         CGSize(width: 640, height: 560), inWindow: true, dark: dark)
            }
        }
        // Long titles, overlaps and a busy all-day row in Week view (light and dark), and the hover details. Scratch DB only.
        if ProcessInfo.processInfo.environment["FLOATBOARD_CAL3SHOTS"] != nil, LocalData.isScratchDatabase {
            let accounts = seedTwoAccounts(store)
            let (event, task) = seedLongTitles(store, accounts)
            for dark in [false, true] {
                let suffix = dark ? "-dark" : ""
                saveLive(CalendarView(span: .week).padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading),
                         "cal3-week\(suffix).png", CGSize(width: 1100, height: 680), inWindow: true, dark: dark)
                if let event {
                    saveLive(CalendarItemDetail(content: .event(event), calendar: CalendarCache(store: store).calendars().first { $0.calendarID == event.calendarID })
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor))).padding(10),
                             "cal3-detail-event\(suffix).png", CGSize(width: 290, height: 140), inWindow: true, dark: dark)
                }
                if let task {
                    saveLive(CalendarItemDetail(content: .task(task), calendar: nil)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor))).padding(10),
                             "cal3-detail-task\(suffix).png", CGSize(width: 290, height: 130), inWindow: true, dark: dark)
                }
            }
        }
        // The window's tab bar and Settings with its sections. Only on a scratch database.
        if ProcessInfo.processInfo.environment["FLOATBOARD_UISHOTS"] != nil, LocalData.isScratchDatabase {
            saveLive(TabPicker(tab: .constant(.board)).padding(10), "ui-tabs.png", CGSize(width: 520, height: 44))
            for s in [SettingsSection.general, .bar, .groups] {
                ui.settingsSection = s
                saveLive(SettingsView().padding(12), "ui-settings-\(s.rawValue).png", CGSize(width: 1000, height: 560))
            }
            // Settings › Groups at the smallest window (800 pt wide; the board's 12 pt padding each side), with tasks in
            // "Work" and its delete question open.
            if let work = store.areas.first?.name {
                for t in ["Draft the plan", "Call the bank", "Book the venue"] { store.add(title: t, area: work, importance: .medium, due: nil) }
                ui.settingsSection = .groups
                saveLive(SettingsView().environment(\.groupsSnapshotDeleting, work).padding(.horizontal, 12).padding(.vertical, 10),
                         "ui-settings-groups-800.png", CGSize(width: 800, height: 520), inWindow: true)
            }
            // The same with very long group names (about 80 characters each), the source of the delete and its destination.
            if store.areas.count >= 2 {
                let long1 = "Client onboarding and contract renewals for the northern region accounts team"
                let long2 = "Personal errands, family admin, school paperwork and household maintenance list"
                _ = store.renameArea(store.areas[0], to: long1)
                _ = store.renameArea(store.areas[1], to: long2)
                saveLive(SettingsView().environment(\.groupsSnapshotDeleting, long1).padding(.horizontal, 12).padding(.vertical, 10),
                         "ui-settings-groups-800-long.png", CGSize(width: 800, height: 520), inWindow: true)
            }
            // Settings › Bar in full (tall, in a window so its lists draw their rows).
            ui.settingsSection = .bar
            saveLive(ScrollView { BarSettingsView().padding(12) }, "ui-settings-bar-full.png", CGSize(width: 1000, height: 1100), inWindow: true)
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
            // The tab as the app lays it out (scrolling grid, real buttons; `saveLive`). At a short window height, to see that
            // nothing stretches between the rows.
            for (span, name) in [(CalendarView.Span.week, "calendar-week-live.png"), (.day, "calendar-day-live.png")] {
                saveLive(CalendarView(span: span).padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading), name, CGSize(width: 1000, height: 530))
            }
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
                SettingsBlock(title: "Calendar", help: CalendarSettingsView.help) {
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
        // The assistant foundation: tabs, an area placeholder, tags in the task editor, Make task, the weekly review, search
        // everything and Settings › Areas. Only on a scratch database (it switches areas on and adds made-up items).
        if ProcessInfo.processInfo.environment["FLOATBOARD_FOUNDATIONSHOTS"] != nil, LocalData.isScratchDatabase {
            for m in Module.allCases { store.setModule(m, on: true) }
            saveLive(TabPicker(tab: .constant(.board), tabs: UIState.Tab.visible(store.modules)).padding(10), "foundation-tabs.png", CGSize(width: 640, height: 44))
            store.setModule(.circle, on: false)
            saveLive(TabPicker(tab: .constant(.board), tabs: UIState.Tab.visible(store.modules)).padding(10), "foundation-tabs-circle-off.png", CGSize(width: 640, height: 44))
            saveLive(JotsTab(), "foundation-jots-placeholder.png", CGSize(width: 700, height: 300))
            store.add(title: "Send the revised budget", area: store.areas.first?.name ?? "Personal", importance: .high, due: nil)
            if let t = store.cards.last {
                let id = ShortID(kind: .task, number: t.id)
                store.setTags(id, primary: t.area, others: [TagRules.investor] + store.areas.dropFirst().prefix(1).map(\.name))
                let jot = JotStore(store: store).create(text: "Budget: send the revised numbers to the team by Friday")
                if let jot { store.link(id, jot.shortID, kind: .source, actor: .user) }
                var withNotes = store.card(t.id) ?? t
                withNotes.aiSummary = "From the meeting: agree the revised budget numbers and send them to the team."
                saveLive(EditCardView(draft: withNotes) {}, "foundation-editor-tags.png", CGSize(width: 420, height: 560))
                saveLive(MakeTaskForm(request: MakeTaskRequest(selection: "Send the revised budget to the team\nwith the new numbers", source: jot?.shortID)) {},
                         "foundation-make-task.png", CGSize(width: 440, height: 300))
            }
            saveLive(WeeklyReviewView {}, "foundation-review-empty.png", CGSize(width: 520, height: 420))
            WeeklyReview.register(ReviewSection(id: "sample.decisions", title: "Decisions recorded this week", module: nil, order: 10) { _, _ in
                [ReviewItem(id: "1", item: ShortID(kind: .decision, number: 4), title: "Move the offsite to March", detail: "from J-12"),
                 ReviewItem(id: "2", item: ShortID(kind: .decision, number: 5), title: "Hire a second designer", detail: "from meeting notes")] })
            saveLive(WeeklyReviewView {}, "foundation-review.png", CGSize(width: 520, height: 420))
            saveLive(VStack(alignment: .leading, spacing: 14) { AreasSection() }.padding(12), "foundation-settings-areas.png", CGSize(width: 700, height: 420))
        }
        if ProcessInfo.processInfo.environment["FLOATBOARD_JOTSHOTS"] != nil, LocalData.isScratchDatabase {
            JotsSnapshots.run(dir: dir, store: store, ui: ui, google: google)   // Jots pictures, light and dark
        }
        // Decisions (its own file): FLOATBOARD_DECISIONSHOTS=1, scratch database only.
        if ProcessInfo.processInfo.environment["FLOATBOARD_DECISIONSHOTS"] != nil { DecisionsShots.run(dir: dir, store: store, ui: ui, google: google) }
        ResolutionsSnapshots.run(dir: dir, store: store, ui: ui, google: google)
        save(GuideView().content, "guide.png", CGSize(width: 440, height: 760))
        // ScrollView doesn't render here, so each Settings section is drawn directly.
        for s in SettingsSection.allCases {
            let page = VStack(alignment: .leading, spacing: 14) {
                Text(s.title).font(.system(size: 15, weight: .semibold))
                switch s {
                case .general: GeneralSection()
                case .bar: BarSettingsView()
                case .groups: GroupsView()
                case .areas: AreasSection()
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
    /// Long titles as the owner's week has them, overlapping meetings, and five all-day items on one day. Returns one long
    /// event and one long task for the detail pictures.
    private static func seedLongTitles(_ store: Store, _ accounts: [String]) -> (CalEvent?, Card?) {
        let cal = AppTime.calendar
        let cache = CalendarCache(store: store)
        let monday = CalendarLayout.weekStart(containing: Date())
        func day(_ d: Int) -> Date { cal.date(byAdding: .day, value: d, to: monday)! }
        func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: day(d))! }
        func ev(_ id: String, _ t: String, _ d: Int, _ h: Int, _ m: Int, _ mins: Int) -> GoogleEventChange {
            GoogleEventChange(eventID: id, cancelled: false, fields: CalEventFields(start: at(d, h, m), end: at(d, h, m).addingTimeInterval(Double(mins) * 60),
                                                                                  title: t, googleUpdated: Date()))
        }
        let f = DateFormatter(); f.timeZone = AppTime.zone; f.dateFormat = "yyyy-MM-dd"
        func allDay(_ id: String, _ t: String, _ d: Int) -> GoogleEventChange {
            GoogleEventChange(eventID: id, cancelled: false, fields: CalEventFields(start: day(d), end: day(d + 1), allDay: true,
                startDay: f.string(from: day(d)), endDay: f.string(from: day(d + 1)), title: t, googleUpdated: Date()))
        }
        let a = accounts[0], b = accounts[1]
        cache.apply(account: a, calendarID: CalendarCache.primaryAlias, changes: [
            ev("l1", "English with Ms Patel: reading and comprehension practice", 0, 11, 0, 60),
            ev("l2", "Interview: senior data engineer, second round with the platform team", 2, 13, 0, 60),
            ev("l3", "Legal review of the supplier contract", 2, 13, 0, 45),
            ev("l4", "Investor update call", 2, 13, 30, 60),
            allDay("d1", "W11 — International week at school", 1)], nextToken: nil)
        cache.apply(account: b, calendarID: "family", changes: [
            ev("l5", "School drop-off and parents' evening sign-up", 1, 15, 0, 30),
            allDay("d2", "Grandma visiting", 1), allDay("d3", "Bin collection", 1), allDay("d4", "Book fair", 1)], nextToken: nil)
        let area = store.areas.first?.name ?? "Work"
        store.add(title: "Reply to the landlord about the boiler service and the window repair", area: area, importance: .high,
                  due: at(3, 16, 0), dueHasTime: true)
        let task = store.cards.last
        store.add(title: "Apply for the summer holiday club places", area: area, importance: .medium, due: day(1))
        store.add(title: "A very long task title that would be cut to one letter in a narrow column", area: area, importance: .low,
                  due: at(2, 13, 15), dueHasTime: true)
        let event = cache.event(account: a, calendarID: CalendarCache.primaryAlias, eventID: "l2")
        return (event, task)
    }

    /// Two made-up accounts for the account-colour pictures; returns them in connection order.
    private static func seedTwoAccounts(_ store: Store) -> [String] {
        let cal = AppTime.calendar
        let cache = CalendarCache(store: store)
        let alex = "alex@example.com", sam = "sam.longer-name@example.org"
        cache.upsertCalendars(account: alex, [CalCalendar(account: alex, calendarID: CalendarCache.primaryAlias, name: "Main calendar",
                                                          color: AccountColors.fallback, owned: true, shown: true, primary: true)])
        cache.upsertCalendars(account: sam, [
            CalCalendar(account: sam, calendarID: sam, name: "Sam", color: "#4986e7", owned: true, shown: true, primary: true),
            CalCalendar(account: sam, calendarID: "family", name: "Family", color: "#16a765", owned: false, shown: true),
            CalCalendar(account: sam, calendarID: "team", name: "Team", color: "#cd74e6", owned: false, shown: true)])
        CalendarListAttempts.record(alex, .mainOnly)
        CalendarListAttempts.record(sam, .listed)
        _ = store.accountColors(for: [alex, sam])
        let monday = CalendarLayout.weekStart(containing: Date())
        func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
            cal.date(bySettingHour: h, minute: m, second: 0, of: cal.date(byAdding: .day, value: d, to: monday)!)!
        }
        func ev(_ id: String, _ t: String, _ d: Int, _ h: Int, _ m: Int, _ mins: Int) -> GoogleEventChange {
            GoogleEventChange(eventID: id, cancelled: false, fields: CalEventFields(start: at(d, h, m), end: at(d, h, m).addingTimeInterval(Double(mins) * 60),
                                                                                  title: t, googleUpdated: Date()))
        }
        cache.apply(account: alex, calendarID: CalendarCache.primaryAlias, changes: [
            ev("a1", "Standup", 0, 9, 0, 30), ev("a2", "Client call", 1, 10, 0, 60), ev("a3", "Standup", 2, 9, 0, 30),
            ev("a4", "Quarterly review", 3, 14, 0, 90), ev("a5", "Standup", 4, 9, 0, 30)], nextToken: nil)
        cache.apply(account: sam, calendarID: sam, changes: [ev("s1", "Dentist", 1, 8, 30, 45), ev("s2", "Gym", 3, 7, 0, 60)], nextToken: nil)
        cache.apply(account: sam, calendarID: "family", changes: [ev("f1", "School pick-up", 0, 8, 0, 30), ev("f2", "Swimming lesson", 2, 7, 30, 60)], nextToken: nil)
        cache.apply(account: sam, calendarID: "team", changes: [ev("t1", "Hackathon planning", 4, 10, 0, 90)], nextToken: nil)
        return [alex, sam]
    }

    static func seedCalendar(_ store: Store) {
        let cal = AppTime.calendar
        let cache = CalendarCache(store: store)
        let account = "me@example.com"
        cache.upsertCalendars(account: account, [
            CalCalendar(account: account, calendarID: account, name: "Work", color: "#4285f4", owned: true, shown: true, primary: true),
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
