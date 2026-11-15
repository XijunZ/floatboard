-- Watch: who a task waits on. The sender's display name travels with each proposal (items.sender already holds the
-- address), so the Mac can suggest the person. Reply detection writes a `watch_reply` phone action (payload: person,
-- via), and chase reminders reuse due_alerts_sent with due = "chase:<since>:<n>".
ALTER TABLE items ADD COLUMN sender_name TEXT;
