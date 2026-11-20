import Foundation
import FloatBoardCore

/// Time zone picker: zones grouped by winter offset, summer time automatic, and turning it off for a place.
@MainActor func timeZoneChecks(_ store: Store) {
    let winter = ISO8601DateFormatter().date(from: "2026-01-15T12:00:00Z")!
    let summer = ISO8601DateFormatter().date(from: "2026-07-15T12:00:00Z")!
    let london = TimeZone(identifier: "Europe/London")!, berlin = TimeZone(identifier: "Europe/Berlin")!
    let shanghai = TimeZone(identifier: "Asia/Shanghai")!, adelaide = TimeZone(identifier: "Australia/Adelaide")!

    check(AppTime.standardOffset(london, at: summer) == 0 && AppTime.standardOffset(berlin, at: summer) == 3600
          && AppTime.standardOffset(london, at: winter) == 0, "tz_winter_offset_ignores_summer_time")
    check(AppTime.offsetLabel(0) == "UTC+0" && AppTime.offsetLabel(3600) == "UTC+1" && AppTime.offsetLabel(-18000) == "UTC−5"
          && AppTime.offsetLabel(19800) == "UTC+5:30", "tz_offset_labels")
    check(AppTime.hasSummerTime(london, at: winter) && !AppTime.hasSummerTime(shanghai, at: winter), "tz_summer_time_only_where_clocks_change")

    for d in [winter, summer] {
        let g = AppTime.groups(at: d)
        let zero = g.first { $0.label == "UTC+0" }, one = g.first { $0.label == "UTC+1" }
        check(zero?.zones.contains("Europe/London") == true && one?.zones.contains("Europe/Berlin") == true
              && g.first { $0.label == "UTC+8" }?.zones.contains("Asia/Shanghai") == true
              && g.map(\.offset) == g.map(\.offset).sorted(), "tz_groups_by_winter_offset_west_to_east_\(d == winter ? "winter" : "summer")")
    }
    check(AppTime.groups(matching: "+1").map(\.label) == ["UTC+1"] && AppTime.groups(matching: "shanghai").flatMap(\.zones) == ["Asia/Shanghai"],
          "tz_search_by_offset_or_name")
    check(AppTime.winterOnlyZone(for: berlin) == "Etc/GMT-1" && AppTime.winterOnlyZone(for: london) == "Etc/GMT"
          && AppTime.winterOnlyZone(for: TimeZone(identifier: "America/New_York")!) == "Etc/GMT+5"
          && AppTime.winterOnlyZone(for: adelaide) == nil, "tz_winter_only_zone_names")

    let savedPlace = AppTime.place(from: store.db)
    defer { try? AppTime.save(place: savedPlace, summerTime: !AppTime.summerTimeOff(place: savedPlace), to: store.db) } // try?-ok: restoring the checks' own scratch setting

    try? AppTime.save(place: "Europe/Berlin", summerTime: true, to: store.db) // try?-ok: result checked below
    check(AppTime.setting == "Europe/Berlin" && AppTime.place(from: store.db) == "Europe/Berlin"
          && !AppTime.summerTimeOff(place: "Europe/Berlin"), "tz_summer_on_saves_the_place_itself")
    try? AppTime.save(place: "Europe/Berlin", summerTime: false, to: store.db) // try?-ok: result checked below
    check(AppTime.setting == "Etc/GMT-1" && AppTime.zone.secondsFromGMT(for: summer) == 3600
          && AppTime.place(from: store.db) == "Europe/Berlin" && AppTime.summerTimeOff(place: "Europe/Berlin"),
          "tz_summer_off_stays_at_winter_offset_and_remembers_place")
    try? AppTime.save(place: "Asia/Shanghai", summerTime: false, to: store.db) // try?-ok: result checked below
    check(AppTime.setting == "Asia/Shanghai" && AppTime.place(from: store.db) == "Asia/Shanghai", "tz_summer_off_ignored_without_summer_time")
    try? AppTime.save(place: "Australia/Adelaide", summerTime: false, to: store.db) // try?-ok: result checked below
    check(AppTime.setting == "Australia/Adelaide", "tz_summer_kept_when_no_fixed_winter_zone")
    try? AppTime.save(place: AppTime.macSetting, summerTime: false, to: store.db) // try?-ok: result checked below
    check(AppTime.setting == AppTime.macSetting && AppTime.place(from: store.db) == AppTime.macSetting, "tz_follow_mac_unaffected")
}
