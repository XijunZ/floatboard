import Foundation
import FloatBoardCore
import FloatBoardConnectors
import SQLite3

/// "Link an email": a task the user made gets an email from a search (on the Mac, or queued on the phone), which
/// switches the email features on (Draft reply, Open email) but never the teach choices; the email sorting's own tasks
/// are never changed. Also the engine search client.
@MainActor func linkEmailChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-link-\(UUID().uuidString)")
    let store: Store
    do {
        let db = try DB(url: root.appendingPathComponent("link.sqlite"))
        try db.run("INSERT INTO connectors(id,name,base_url,settings_json,settings_version) VALUES('email','email','https://engine.test','{}',1)")
        store = Store(db: db)
    } catch { check(false, "link setup: \(error)"); return }
    let email = LinkedEmail(account: "me@example.com", gmailID: "g1a2", messageID: "<m1@mail>", sentAt: "2026-11-10T09:00:00.000Z",
                            subject: "Invoice 12", from: "Acme <ap@acme.test>")
    func newest(_ title: String) -> Card? { store.cards.last { $0.title == title } }
    func outbox() -> [(kind: String, payload: [String: String])] {
        let rows = (try? store.db.query("SELECT kind,payload_json FROM outbox ORDER BY created, rowid") { (DB.text($0, 0), DB.text($0, 1)) }) ?? [] // try?-ok: a failed query fails the check
        return rows.map { ($0.0, ((try? JSONSerialization.jsonObject(with: Data($0.1.utf8))) as? [String: String]) ?? [:]) } // try?-ok: bad json fails the check
    }

    // On the Mac: link, then the email features follow the existing rules.
    store.add(title: "Pay the invoice", area: "Work", importance: .medium, due: nil)
    guard let mine = newest("Pay the invoice") else { check(false, "link card"); return }
    check(mine.canLinkEmail && !mine.emailLinkedByUser, "link_email_offered_on_a_user_task")
    do { try store.linkEmail(cardID: mine.id, connector: "email", email: email) } catch { check(false, "link_email_on_mac: \(error)") }
    let linked = store.card(mine.id)
    check(linked?.canDraftReply == true && linked?.emailLink?.absoluteString == "https://mail.google.com/mail/u/me@example.com/#all/g1a2"
          && linked?.sourceKey == SourceKey(messageID: "<m1@mail>", sentAt: "2026-11-10T09:00:00.000Z")
          && linked?.externalID == "" && linked?.teachOnDelete == false && linked?.emailLinkedByUser == true
          && linked?.canLinkEmail == false && linked?.sourceLabel == "Acme",
          "link_email_on_mac_switches_on_draft_reply_and_open_email")
    check(PhoneBoard.card(for: linked!, color: nil, calendar: .current).email == "user"
          && PhoneBoard.links(for: linked!).first == BoardLink(kind: "email", url: "https://mail.google.com/mail/u/me@example.com/#all/g1a2"),
          "link_email_reaches_the_phone_as_user_linked")
    // A second link is refused while one is there.
    do { try store.linkEmail(cardID: mine.id, connector: "email", email: email); check(false, "link_email_twice_refused") }
    catch { check((error as? EmailLinkError) == .alreadyLinked, "link_email_twice_refused") }
    // Edits on a linked task are not lessons for the sorting; done still tells the engine (mark read), with the inbox.
    var edited = store.card(mine.id)!
    edited.title = "Pay the invoice today"
    store.update(edited)
    check(!outbox().contains { $0.kind == "changed" }, "link_email_edits_teach_nothing")
    store.move(store.card(mine.id)!, to: .done)
    let done = outbox().first { $0.kind == "done" }
    check(done?.payload["account"] == "me@example.com" && done?.payload["gmail_id"] == "g1a2" && done?.payload["source_mid"] == "<m1@mail>",
          "link_email_done_carries_the_inbox_for_mark_read")
    check(ConnectorClient.payloadKeys.contains("account") && ConnectorClient.payloadKeys.contains("gmail_id"), "link_email_payload_keys_sent")
    // A reply draft request names the inbox too.
    store.move(store.card(mine.id)!, to: .todo)
    var withNotes = store.card(mine.id)!
    withNotes.notes = "Paid on Friday"
    store.update(withNotes)
    do {
        try store.requestReplyDraft(cardID: mine.id)
        check(outbox().last { $0.kind == "draft_reply" }?.payload["account"] == "me@example.com", "link_email_draft_request_names_the_inbox")
    } catch { check(false, "link_email_draft_request_names_the_inbox: \(error)") }

    // Remove the link: the features switch off again.
    do { try store.unlinkEmail(cardID: mine.id) } catch { check(false, "unlink_email: \(error)") }
    let unlinked = store.card(mine.id)
    check(unlinked?.canDraftReply == false && unlinked?.emailLink == nil && unlinked?.connector == "" && unlinked?.sourceKey == nil
          && unlinked?.canLinkEmail == true && unlinked?.replyDraftState == nil && unlinked?.sourceMeta.isEmpty == true,
          "unlink_email_switches_the_email_features_off")

    // Never on a task the email sorting made.
    store.seedCard(title: "Sorted", source: "email", externalID: "email:<s1@mail>")
    guard let sorted = store.card(externalID: "email:<s1@mail>") else { check(false, "sorted card"); return }
    check(!sorted.canLinkEmail && !sorted.emailLinkedByUser, "link_email_not_offered_on_sorting_card")
    do { try store.linkEmail(cardID: sorted.id, connector: "email", email: email); check(false, "link_email_refuses_sorting_card") }
    catch { check((error as? EmailLinkError) == .fromEmailSorting && store.card(sorted.id)?.sourceKey?.messageID == "<s1@mail>", "link_email_refuses_sorting_card") }
    do { try store.unlinkEmail(cardID: sorted.id); check(false, "unlink_email_refuses_sorting_card") }
    catch { check((error as? EmailLinkError) == .notLinkedByUser && store.card(sorted.id)?.connector == "email", "unlink_email_refuses_sorting_card") }
    check(PhoneBoard.card(for: sorted, color: nil, calendar: .current).email == "sorting"
          && PhoneBoard.card(for: store.card(mine.id)!, color: nil, calendar: .current).email == nil,
          "link_email_phone_marker_says_who_linked")
    // An email that is already on another task is refused (one task per email).
    store.add(title: "Second", area: "Work", importance: .medium, due: nil)
    if let second = newest("Second") {
        var sortedEmail = email; sortedEmail.messageID = "<s1@mail>"; sortedEmail.sentAt = nil
        do { try store.linkEmail(cardID: second.id, connector: "email", email: sortedEmail); check(false, "link_email_refuses_an_email_on_another_task") }
        catch { check((error as? EmailLinkError) == .linkedElsewhere && store.card(second.id)?.sourceKey == nil, "link_email_refuses_an_email_on_another_task") }
    }
    // A bad email is refused before anything is written.
    var bad = email; bad.gmailID = "../x"
    do { try store.linkEmail(cardID: mine.id, connector: "email", email: bad); check(false, "link_email_refuses_bad_ids") }
    catch { check((error as? EmailLinkError) == .badEmail && store.card(mine.id)?.sourceKey == nil, "link_email_refuses_bad_ids") }

    // From the phone: a queued link_email applied by the Mac makes Draft reply appear; unlink takes it away.
    store.add(title: "Phone linked", area: "Work", importance: .medium, due: nil)
    guard let phoneCard = newest("Phone linked") else { check(false, "phone card"); return }
    let linkAction = PhoneAction(id: "e1", clientID: "link-1", cardID: phoneCard.id, action: "link_email",
                                 email: PhoneEmail(messageID: "<p1@mail>", gmailID: "p1", account: "me@example.com", sentAt: "2026-11-11T08:00:00.000Z"))
    var r = store.applyPhoneActions([linkAction], connector: "email")
    let fromPhone = store.card(phoneCard.id)
    check(r.applied == ["e1"] && fromPhone?.canDraftReply == true && fromPhone?.connector == "email"
          && fromPhone?.emailLink?.absoluteString == "https://mail.google.com/mail/u/me@example.com/#all/p1"
          && fromPhone?.sourceKey?.sentAt == "2026-11-11T08:00:00.000Z" && fromPhone?.teachOnDelete == false,
          "phone_link_email_applied_by_mac_gives_draft_reply")
    r = store.applyPhoneActions([linkAction], connector: "email")
    check(r.applied == ["e1"] && store.card(phoneCard.id)?.sourceKey?.messageID == "<p1@mail>", "phone_link_email_applies_once")
    // Relinking a sorting card from the phone is refused (skipped, the card unchanged).
    let relink = PhoneAction(id: "e2", clientID: "link-2", cardID: sorted.id, action: "link_email",
                             email: PhoneEmail(messageID: "<p2@mail>", gmailID: "p2", account: "me@example.com", sentAt: nil))
    r = store.applyPhoneActions([relink, PhoneAction(id: "e3", clientID: "unlink-3", cardID: sorted.id, action: "unlink_email")], connector: "email")
    check(r.applied.isEmpty && r.skipped.map(\.id) == ["e2", "e3"] && r.skipped.allSatisfy { $0.reason == "not allowed" }
          && store.card(sorted.id)?.sourceKey?.messageID == "<s1@mail>" && store.card(sorted.id)?.externalID == "email:<s1@mail>",
          "phone_link_email_refuses_relinking_a_sorting_card")
    // A link with no email is invalid; unlink from the phone removes a user link.
    r = store.applyPhoneActions([PhoneAction(id: "e4", clientID: "link-4", cardID: phoneCard.id, action: "link_email"),
                                 PhoneAction(id: "e5", clientID: "unlink-5", cardID: phoneCard.id, action: "unlink_email")], connector: "email")
    check(r.skipped.map(\.id) == ["e4"] && r.applied == ["e5"] && store.card(phoneCard.id)?.canDraftReply == false,
          "phone_unlink_email_applied_and_bad_link_skipped")
    // The engine's action decodes with its email.
    let json = #"{"id":"x","client_id":"c","card_id":7,"action":"link_email","title":null,"group":null,"created":"2026-11-12T09:00:00.000Z","made_at":"2026-11-12T09:00:00.000Z","email":{"message_id":"<a@b>","gmail_id":"g9","account":"me@example.com","sent_at":null}}"#
    let decoded = try? JSONDecoder().decode(PhoneAction.self, from: Data(json.utf8)) // try?-ok: nil fails the check
    check(decoded?.email == PhoneEmail(messageID: "<a@b>", gmailID: "g9", account: "me@example.com", sentAt: nil), "phone_link_email_action_decodes")

    // The search client: the query goes as q, results and per-inbox errors come back.
    let engine = FakeEngine { _, path, _ in
        guard path == "/v2/emails/search" else { return (404, "{}") }
        return (200, #"{"results":[{"account":"me@example.com","gmail_id":"g1","message_id":"<m1@mail>","subject":"Invoice","from":"Acme <ap@acme.test>","date":"Tue, 10 Nov 2026 09:00:00 +0000","sent_at":"2026-11-10T09:00:00.000Z"}],"errors":[{"account":"old@example.com","error":"Reconnect it."}]}"#)
    }
    do {
        let found = try await engine.client().searchEmails("invoice from acme")
        check(found.results.count == 1 && found.results[0].linked == LinkedEmail(account: "me@example.com", gmailID: "g1", messageID: "<m1@mail>",
              sentAt: "2026-11-10T09:00:00.000Z", subject: "Invoice", from: "Acme <ap@acme.test>")
              && found.errors.first?.account == "old@example.com" && engine.requests.first?.query == "q=invoice%20from%20acme",
              "email_search_client_reads_results_and_errors")
    } catch { check(false, "email_search_client_reads_results_and_errors: \(error)") }
    let old = FakeEngine { _, _, _ in (404, #"{"error":"not found"}"#) }
    do { _ = try await old.client().searchEmails("x"); check(false, "email_search_old_engine_says_update") }
    catch { check("\(error)".contains("Update the engine"), "email_search_old_engine_says_update") }
}
