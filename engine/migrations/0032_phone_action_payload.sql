-- "Link an email" from the phone: a link_email action carries the email it attaches (JSON: message_id, gmail_id,
-- account, sent_at) for the Mac to apply. Empty for every other action.
ALTER TABLE phone_actions ADD COLUMN payload TEXT;
