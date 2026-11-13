# WhatsApp screening

FloatBoard can turn WhatsApp messages that need you into tasks. It is off until you turn it on (Connectors › your
email engine › **Screen WhatsApp for tasks**).

## How it works

1. Every 5 minutes the Mac reads WhatsApp Desktop's own copy of your messages on the Mac
   (`~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite`). It copies the files to a private
   temporary folder and reads the copy, so WhatsApp's database is never opened or locked, and deletes the copy at once.
2. The free rules run on the Mac (nothing leaves it for chats they drop):
   - only chats with unread messages; **archived and hidden chats, status updates, broadcast lists and channels are never read**;
   - **muted chats are read but marked muted**: Claude then applies a stricter rule (only something for you by name,
     money you personally owe, or your own family, booking or safety becomes a task; never urgent);
   - a chat where your message is the newest one (you answered) is not sent;
   - only messages from the last 7 days, at most 30 per chat, and never the same message twice;
   - messages with no words (stickers, reactions, emoji only, "ok", "thanks", a bare photo) are dropped.
3. The chats left go to your engine (`POST /v2/chats`), with up to 3 earlier messages as context. Claude judges each chat
   with the shared chat rulebook (`connectors/email/src/skills/chat-triage.md`) plus your own rules (Settings ›
   **Your own WhatsApp rules**), your groups and your past corrections. At most one task per chat.
4. A task links back to the chat: one-to-one chats open in WhatsApp (on the phone as `wa.me/<number>`); groups open
   WhatsApp. Deleting a wrong task teaches FloatBoard like an email task does.

macOS may ask you to allow FloatBoard in **Full Disk Access**; the Connectors tab shows a button when it is needed.

## Will this get my account banned?

FloatBoard never logs in to WhatsApp, never uses a linked-device slot, never runs WhatsApp Web, never touches the
WhatsApp app and never sends anything. WhatsApp's terms forbid accessing its *Services* through automated or
unauthorised means and reverse engineering them; reading a file on your own Mac involves no WhatsApp service at all,
and WhatsApp cannot see it. It is not an official integration: a WhatsApp update can change the file, in which case
the Connectors tab says the database couldn't be read and nothing is sent.

Rejected: WhatsApp Web automation (Baileys, whatsapp-web.js), which is the automated access the terms forbid and is
banned in practice; the WhatsApp Business API, which only works for business numbers.

## WeChat

Not supported. The Weixin service agreement forbids plug-ins and unauthorised third-party tools (§8.2.1.4), reading or
controlling the app's data or interface (§8.2.1.6) and reverse engineering (§8.2.1.2), with account bans as a penalty
(§8.5.1). WeChat 4.x encrypts its local messages, and web or bot logins would sign out the Mac app. Reading macOS's own
notification history (where WeChat's banners land) is being looked at separately.
