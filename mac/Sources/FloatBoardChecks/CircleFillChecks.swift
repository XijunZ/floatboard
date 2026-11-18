import Foundation
import FloatBoardConnectors
import FloatBoardCore

/// Round 8 (owner's report on the Add to Circle form): "Fill from messages" looks up what FloatBoard already has for the
/// typed phone numbers, emails and WhatsApp numbers (header names, addresses and numbers only), says so when there is
/// nothing, and says which fields Claude changed; Add with a name, phone, WhatsApp and notes saves the person.
@MainActor func circleFillChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-circle-fill-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    let s: Store
    do { s = Store(db: try DB(url: root.appendingPathComponent("fill.sqlite"))) } catch { check(false, "fill setup: \(error)"); return }
    s.setModule(.circle, on: true)
    let now = Date(timeIntervalSince1970: 1_794_391_200)
    // An imported email card from Anna and a WhatsApp card from Ben (bodies in the title/notes must never travel).
    s.seedCard(title: "Secret body text: the merger is off", area: "Work", importance: .medium, source: "email", externalID: "email:a1")
    s.seedCard(title: "WhatsApp body: meet at the bank vault", area: "Work", importance: .medium, source: "whatsapp", externalID: "wa:b1")
    guard let anna = s.card(externalID: "email:a1"), let ben = s.card(externalID: "wa:b1") else { check(false, "fill cards"); return }
    s.performForTest {
        try s.db.run("UPDATE cards SET notes='Private notes', source_mid='<m1@x>', source_meta=? WHERE id=?",
                     [#"{"sender":"Anna Example <anna@northwind.example>","sender_name":"Anna Example","why":"Body excerpt: asks about the merger"}"#, anna.id])
        try s.db.run("UPDATE cards SET source_mid='wa:447700900123@s.whatsapp.net:ABC', source_meta=? WHERE id=?",
                     [#"{"sender_name":"Ben Example","why":"Body excerpt: the vault"}"#, ben.id])
    }
    // A Circle reader saw Cara on WhatsApp (metadata only).
    CircleStore(store: s).record([ExchangeInput(channel: .whatsapp, direction: .incoming, at: now, handle: Handle(kind: .phone, value: "447700900456"), name: "Cara Example")], now: now)

    func find(_ hs: [Handle]) -> [FillHeader] {
        do { return try CircleFillHeaders.find(store: s, handles: hs, personID: nil) } catch { check(false, "fill find: \(error)"); return [] }
    }
    let byEmail = find([Handle(kind: .email, value: "anna@northwind.example")])
    check(byEmail == [FillHeader(name: "Anna Example", address: "anna@northwind.example", phone: "")], "fill_finds_the_email_sender_header")
    let byWhatsApp = find([Handle(kind: .whatsapp, value: "+44 7700 900123")])
    check(byWhatsApp == [FillHeader(name: "Ben Example", address: "", phone: "447700900123")], "fill_finds_a_whatsapp_number_by_its_digits")
    let byPhone = find([Handle(kind: .phone, value: "447700900456")])
    check(byPhone == [FillHeader(name: "Cara Example", address: "", phone: "447700900456")], "fill_finds_what_a_circle_reader_saw")
    check(find([Handle(kind: .phone, value: "447700900999")]).isEmpty && find([]).isEmpty, "fill_finds_nothing_for_unknown_handles")
    // Headers only: nothing from titles, notes or the "why" excerpt can be in what is sent.
    let all = find([Handle(kind: .email, value: "anna@northwind.example"), Handle(kind: .whatsapp, value: "+44 7700 900123"), Handle(kind: .phone, value: "447700900456")])
    let text = all.map { "\($0.name) \($0.address) \($0.phone)" }.joined(separator: " ")
    check(all.count == 3 && !text.contains("Secret") && !text.contains("vault") && !text.contains("Body") && !text.contains("Private"), "fill_headers_carry_no_body_text")
    // The request to the engine holds only name, address and phone per header.
    final class Box: @unchecked Sendable { var body: [String: Any] = [:] }
    let box = Box()
    let client = ConnectorClient(baseURL: URL(string: "https://engine.test")!, key: "k") { req in
        if let b = req.httpBody, let j = try? JSONSerialization.jsonObject(with: b) as? [String: Any] { box.body = j } // try?-ok: empty fails below
        return (Data(#"{"name":"Anna Example","emails":["anna@northwind.example"],"phones":[],"company":"Northwind"}"#.utf8),
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let answer = try? await client.circleFill(headers: all.map(\.dictionary)) // try?-ok: nil fails below
    let sent = box.body["headers"] as? [[String: String]] ?? []
    check(answer != nil && sent.count == 3 && sent.allSatisfy { Set($0.keys) == ["name", "address", "phone"] } && Set(box.body.keys) == ["headers"],
          "fill_request_holds_only_header_names_addresses_and_numbers")
    // Applying the answer: only empty fields; the note lists what changed (nothing changed: no "Filled by Claude").
    if let answer {
        var form = ContactFormFields(name: "", company: "", emails: "anna@northwind.example", phones: "")
        let changed = answer.fill(&form)
        check(changed == ["name", "company"] && form.name == "Anna Example" && form.company == "Northwind" && form.emails == "anna@northwind.example",
              "fill_changes_only_empty_fields_and_says_which")
        var same = ContactFormFields(name: "Anna Example", company: "Northwind", emails: "anna@northwind.example", phones: "")
        check(answer.fill(&same).isEmpty, "fill_reports_no_change_when_nothing_changed")
        check(ContactFormFields.note(changed) == "Filled by Claude from message headers: name, company. Check before saving." && ContactFormFields.note([]) == nil,
              "fill_note_names_the_changed_fields")
    }
    // (7) A WhatsApp linked id (<digits>@lid) is a WhatsApp handle, never a phone; it finds its chat's headers, and the real
    // phone number when a header has one; the form shows it in words, never the raw id.
    s.seedCard(title: "WhatsApp body: lid chat", area: "Work", importance: .medium, source: "whatsapp", externalID: "wa:lid1")
    if let lidCard = s.card(externalID: "wa:lid1") {
        s.performForTest {
            try s.db.run("UPDATE cards SET source_mid='wa:98765432101234@lid:XYZ', source_meta=? WHERE id=?",
                         [#"{"sender":"+44 7700 900111","sender_name":"Lid Example","why":"Body excerpt"}"#, lidCard.id])
        }
    }
    CircleStore(store: s).record([ExchangeInput(channel: .whatsapp, direction: .incoming, at: now, handle: Handle(kind: .whatsapp, value: "98765432101234@lid"), name: "Lid Example")], now: now)
    check(Handles.normalize(.phone, "98765432101234@lid") == nil && Handles.normalize(.whatsapp, "98765432101234@LID") == "98765432101234@lid"
          && ContactFormFields.handles([.whatsapp: "98765432101234@lid"]).handles == [Handle(kind: .whatsapp, value: "98765432101234@lid")],
          "whatsapp_linked_id_is_a_whatsapp_handle_not_a_phone")
    let byLid = find([Handle(kind: .whatsapp, value: "98765432101234@lid")])
    check(byLid.contains(FillHeader(name: "Lid Example", address: "", phone: "447700900111")) && byLid.allSatisfy { $0.name == "Lid Example" }
          && !byLid.contains { $0.phone.contains("@") || $0.address.contains("@lid") }, "fill_finds_a_linked_id_chat_and_its_real_number")
    check(Handles.display(Handle(kind: .whatsapp, value: "98765432101234@lid")) == "WhatsApp contact (no number shared)"
          && Handles.display(Handle(kind: .phone, value: "447700900123")) == "447700900123", "linked_id_is_shown_in_words")
    // Add with a name, a phone, a WhatsApp number and notes saves the person with both handles and the notes.
    let typed = ContactFormFields.handles([.phone: "07700 900789", .whatsapp: "+44 7700 900789"])
    var det = CircleDetails(); det.notes = "Met at the conference"
    let r = CircleStore(store: s).add(name: "Dan Example", tier: .network, tags: ItemTags(primary: nil, others: []), details: det, handles: typed.handles, now: now)
    check(typed.unreadable.isEmpty && r.person != nil && r.problem == nil
          && CircleStore(store: s).details(r.person!.id).notes == "Met at the conference" && CircleStore(store: s).handles(r.person!.id).count == 2,
          "add_with_name_phone_whatsapp_and_notes_saves_the_person")
    // A handle that can't be read is reported, never dropped silently.
    let bad = ContactFormFields.handles([.phone: "12345", .email: "not-an-address"])
    check(bad.handles.isEmpty && bad.unreadable == ["12345", "not-an-address"], "unreadable_handles_are_reported")
}

/// Round 8 (5): people are tagged with Investor, Prospect and tags already on people, not the board's groups; "New tag…" makes
/// a tag that is not a board group. Tags already on a person stay; the fixed-tag and tier rules still hold.
@MainActor func peopleTagChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-people-tags-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    let s: Store
    do { s = Store(db: try DB(url: root.appendingPathComponent("tags.sqlite"))) } catch { check(false, "people tags setup: \(error)"); return }
    s.setModule(.circle, on: true)
    _ = s.addArea("Learning"); _ = s.addArea("Productivity")
    let c = CircleStore(store: s), none = ItemTags(primary: nil, others: [])
    guard let ann = c.add(name: "Ann Example", tier: .network, tags: ItemTags(primary: "Learning", others: []), details: CircleDetails(), handles: []).person,
          let bo = c.add(name: "Bo Example", tier: .family, tags: none, details: CircleDetails(), handles: []).person else { check(false, "people tags people"); return }
    check(PeopleTags.offered(store: s) == ["Investor", "Prospect", "Learning"], "people_tag_menu_offers_fixed_tags_and_tags_used_on_people_only")
    check(s.itemTags(ann.shortID).all == ["Learning"], "a_board_tag_already_on_a_person_stays")
    check(PeopleTags.add(store: s, "Board member") == nil && !s.areas.contains { $0.name == "Board member" } && s.tags.contains { $0.name == "Board member" }
          && PeopleTags.add(store: s, "learning") != nil, "new_people_tag_is_not_a_board_group_and_names_stay_unique")
    check(c.addTags([ann.id], ["Board member"]).isEmpty && PeopleTags.offered(store: s) == ["Investor", "Prospect", "Learning", "Board member"],
          "a_new_people_tag_is_offered_once_used")
    check(c.addTags([bo.id], [TagRules.prospect]).first == "Bo Example: Prospect can't be used on Family." && s.itemTags(bo.shortID).all.isEmpty,
          "tier_rule_still_refuses_prospect_on_family")
    check(PeopleTags.addTo(store: s, person: bo.id, TagRules.investor) == nil && s.itemTags(bo.shortID).all == ["Investor"]
          && PeopleTags.removeFrom(store: s, person: bo.id, TagRules.investor) == nil && s.itemTags(bo.shortID).all.isEmpty, "one_person_tagged_and_untagged_directly")
}

/// Round 9 (3): a chip's text colour in light mode. Light colours (contrast under 3:1 on white: yellow, cyan, green, orange)
/// are darkened until they reach 4.5:1; every other colour is left exactly as it was.
func chipInkChecks() {
    let yellow = ChipInk.lightModeHex("#FFD60A"), cyan = ChipInk.lightModeHex("#40C8E0")
    check(ChipInk.contrastOnWhite(yellow) >= 4.5 && ChipInk.contrastOnWhite(cyan) >= 4.5 && yellow != "#FFD60A", "light_chip_colours_are_darkened_to_4_5")
    check(["#0A84FF", "#BF5AF2", "#FF453A", "#5E5CE6", "#8E8E93"].allSatisfy { ChipInk.lightModeHex($0) == $0 }, "other_chip_colours_are_unchanged")
    check(ChipInk.hue(yellow) == ChipInk.hue("#FFD60A"), "darkened_chip_keeps_its_hue")
}
