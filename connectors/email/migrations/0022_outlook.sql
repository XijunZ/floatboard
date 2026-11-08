-- Outlook on the web (Chrome extension, connectors/outlook-web). One source per user with kind='outlook_web':
-- address = the mailbox (empty until the first send), hook_id = SHA-256 of the ingest token (shown once, never stored in
-- clear), last_run = the last time the extension reported.
-- Each unread row the extension read, stored once (by its key) until the triage run has judged it.
CREATE TABLE outlook_rows (
  user_id TEXT NOT NULL,
  source_id TEXT NOT NULL,
  row_key TEXT NOT NULL,           -- owa:<rowId>:<receivedISO>
  from_name TEXT NOT NULL DEFAULT '',
  from_addr TEXT,
  subject TEXT NOT NULL DEFAULT '',
  preview TEXT NOT NULL DEFAULT '', -- what Outlook shows in the list: the only text the classifier sees
  received TEXT NOT NULL,          -- ISO UTC
  processed INTEGER NOT NULL DEFAULT 0,
  processed_at TEXT,               -- pruned 30 days after this
  created TEXT NOT NULL,
  PRIMARY KEY (user_id, row_key)
);
CREATE INDEX outlook_rows_waiting ON outlook_rows(source_id, processed, received);
