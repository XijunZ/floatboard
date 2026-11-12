import Foundation
import FloatBoardCore

/// One kind of task: features follow what a card has (a source link, a linked email, a meeting link), not what made it.
/// Also the phone payload's `links`.
@MainActor func oneTaskChecks() {
    let now = Date()
    func card(link: String = "", notes: String = "", sourceLink: String = "", connector: String = "", externalID: String = "",
              sourceKey: SourceKey? = nil, aiSummary: String = "", gcalLink: String = "") -> Card {
        Card(id: 1, title: "T", notes: notes, area: "Work", importance: .medium, due: nil, status: .todo, created: now,
             started: nil, done: nil, link: link, gcalLink: gcalLink, source: connector, externalID: externalID,
             sourceLink: sourceLink, sourceKey: sourceKey, aiSummary: aiSummary, connector: connector)
    }

    // Link kinds.
    let meetings = ["https://meet.google.com/abc-defg-hij", "https://zoom.us/j/123", "https://acme.zoom.us/j/123?pwd=x",
                    "https://teams.microsoft.com/l/meetup-join/x", "https://teams.live.com/meet/1", "https://whereby.com/room",
                    "https://acme.webex.com/meet/x"]
    check(meetings.allSatisfy { CardLinks.kind(URL(string: $0)!) == .meeting }
          && CardLinks.kind(URL(string: "https://notzoom.us/j/1")!) == .link
          && CardLinks.kind(URL(string: "https://example.com/zoom.us")!) == .link
          && CardLinks.kind(URL(string: "https://mail.google.com/mail/u/0/#all/abc")!) == .email
          && CardLinks.kind(URL(string: "https://outlook.office.com/mail/inbox/id/x")!) == .email
          && CardLinks.kind(URL(string: "https://fathom.video/calls/1")!) == .link,
          "one_task_link_kinds_by_host")

    // A task typed by the user.
    let typed = card()
    check(!typed.isFromEmailSorting && !typed.teachOnDelete && !typed.canDraftReply && typed.meetingLink == nil
          && typed.otherLink == nil && typed.sourceURL == nil && !typed.showsSourceChip,
          "one_task_user_task_has_no_extra_features")
    // ... gains Join call when it gets a meeting link, and Open link for any other link.
    let withMeeting = card(link: "https://acme.zoom.us/j/123")
    check(withMeeting.meetingLink?.absoluteString == "https://acme.zoom.us/j/123" && withMeeting.otherLink == nil
          && !withMeeting.teachOnDelete, "one_task_user_task_with_meeting_link_shows_join")
    let withLink = card(link: "https://example.com/doc")
    check(withLink.meetingLink == nil && withLink.otherLink?.absoluteString == "https://example.com/doc",
          "one_task_other_link_is_open_link_not_join")
    check(card(notes: "dial in https://meet.google.com/abc-defg-hij please").meetingLink?.host == "meet.google.com"
          && card(link: "javascript:alert(1)").otherLink == nil && card(link: "javascript:alert(1)").meetingLink == nil,
          "one_task_meet_link_in_notes_and_no_script_links")
    // ... and, later, Draft reply and the source chip once an email is linked (a connector, a message id, no external id).
    let linkedByUser = card(sourceLink: "https://mail.google.com/mail/u/0/#all/abc", connector: "email",
                            sourceKey: SourceKey(messageID: "<m1@x>", sentAt: ""))
    check(linkedByUser.canDraftReply && linkedByUser.showsSourceChip && linkedByUser.emailLink != nil
          && !linkedByUser.isFromEmailSorting && !linkedByUser.teachOnDelete,
          "one_task_linked_email_gives_draft_reply_but_no_teach")
    check(!card(connector: "email", sourceKey: SourceKey(messageID: "", sentAt: "")).canDraftReply
          && !card(sourceKey: SourceKey(messageID: "<m1@x>", sentAt: "")).canDraftReply,
          "one_task_draft_reply_needs_a_message_id_and_a_connector")

    // A card made by the email sorting.
    let sorted = card(sourceLink: "https://mail.google.com/mail/u/0/#all/abc", connector: "email", externalID: "email:<m1@x>",
                      sourceKey: SourceKey(messageID: "<m1@x>", sentAt: "2026-11-12T09:00:00.000Z"))
    check(sorted.isFromEmailSorting && sorted.teachOnDelete && sorted.canDraftReply && sorted.showsSourceChip,
          "one_task_connector_card_is_from_email_sorting")
    let sortedNoLink = card(connector: "email", externalID: "email:<m2@x>")
    check(sortedNoLink.showsSourceChip && sortedNoLink.sourceURL == nil, "one_task_connector_card_keeps_chip_without_link")
    check(card(sourceLink: "https://fathom.video/calls/1").showsSourceChip && card(sourceLink: "https://fathom.video/calls/1").emailLink == nil
          && card(sourceLink: "https://fathom.video/calls/1").sourceLabel == "Source",
          "one_task_source_link_alone_shows_chip")
}
