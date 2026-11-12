import Foundation
import FloatBoardCore

/// Every link on a task goes to the phone (`links`), with its kind.
@MainActor func phoneLinksChecks() {
    let now = Date()
    func card(link: String = "", sourceLink: String = "", connector: String = "", externalID: String = "",
              aiSummary: String = "", gcalLink: String = "") -> Card {
        Card(id: 1, title: "T", notes: "", area: "Work", importance: .medium, due: nil, status: .todo, created: now,
             started: nil, done: nil, link: link, gcalLink: gcalLink, source: connector, externalID: externalID,
             sourceLink: sourceLink, aiSummary: aiSummary, connector: connector)
    }

    // Phone links: source email, meeting, calendar, summary links; deduped, http(s) only, at most 6.
    let full = card(link: "https://meet.google.com/abc-defg-hij",
                    sourceLink: "https://mail.google.com/mail/u/0/#all/abc", connector: "email", externalID: "email:<m1@x>",
                    aiSummary: "See https://docs.example.com/plan. Also (https://example.org/a) and https://meet.google.com/abc-defg-hij, "
                        + "javascript:alert(1) https://four.example.com https://five.example.com",
                    gcalLink: "https://calendar.google.com/event?eid=1")
    let links = PhoneBoard.links(for: full)
    check(links.map(\.kind) == ["email", "meeting", "link", "link", "link", "link"]
          && links.map(\.url) == ["https://mail.google.com/mail/u/0/#all/abc", "https://meet.google.com/abc-defg-hij",
                                  "https://calendar.google.com/event?eid=1", "https://docs.example.com/plan",
                                  "https://example.org/a", "https://four.example.com"]
          && links[2].label == "calendar" && links.allSatisfy { $0.label == nil || $0.url.contains("calendar") },
          "phone_links_email_meeting_calendar_and_summary")
    let fathom = card(link: "https://example.com/" + String(repeating: "x", count: 2100), sourceLink: "https://fathom.video/calls/1",
                      aiSummary: "a https://s1.example.com b https://s2.example.com c https://s3.example.com d https://s4.example.com")
    let fl = PhoneBoard.links(for: fathom)
    check(fl.map(\.url) == ["https://fathom.video/calls/1", "https://s1.example.com", "https://s2.example.com", "https://s3.example.com"]
          && fl.first?.kind == "link", "phone_links_long_dropped_summary_max_3_fathom_is_link")
    check(PhoneBoard.links(for: card(link: "not a link")).isEmpty, "phone_links_none_for_a_plain_task")
}

/// The payload carries `links`, and the old `link` stays the first one.
@MainActor func oneTaskPayloadChecks(_ store: Store) {
    let now = Date()
    store.add(title: "OT links", area: "Work", importance: .medium, due: nil)
    guard var c = store.cards.last(where: { $0.title == "OT links" }) else { check(false, "one task payload seed"); return }
    c.link = "https://acme.zoom.us/j/9"
    store.update(c)
    let p = PhoneBoard.payload(store: store, now: now).first { $0.id == c.id }
    check(p?.links.map(\.kind) == ["meeting"] && p?.link == "https://acme.zoom.us/j/9", "phone_payload_has_links_and_old_link_first")
    do {
        let obj = try JSONSerialization.jsonObject(with: try PhoneBoard.body(p.map { [$0] } ?? [])) as? [String: Any]
        let l = ((obj?["cards"] as? [[String: Any]])?.first?["links"] as? [[String: Any]])?.first
        check(l.map { Set($0.keys) == ["kind", "url"] && $0["kind"] as? String == "meeting" } ?? false, "phone_payload_links_json_shape")
    } catch { check(false, "phone_payload_links_json_shape: \(error)") }
    store.delete(c)
}
