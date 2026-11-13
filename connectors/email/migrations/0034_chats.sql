-- Chat messages screened for tasks (WhatsApp, read by the Mac from WhatsApp Desktop's own copy on the Mac).
-- One source per user and app (kind='whatsapp', created on the first send). Each row is one chat's unread messages
-- since the last send, stored once (by its key) until the triage run has judged it. Pruned 30 days after judging.
CREATE TABLE chat_rows (
  user_id TEXT NOT NULL,
  source_id TEXT NOT NULL,
  row_key TEXT NOT NULL,            -- wa:<chat id>:<newest message id>
  app TEXT NOT NULL,                -- 'whatsapp'
  chat_name TEXT NOT NULL DEFAULT '',
  is_group INTEGER NOT NULL DEFAULT 0,
  senders TEXT NOT NULL DEFAULT '', -- who wrote the unread messages, comma-separated
  transcript TEXT NOT NULL,         -- "[time] Name: text" lines; the only text the classifier sees
  link TEXT NOT NULL DEFAULT '',    -- opens the chat in the app where possible
  received TEXT NOT NULL,           -- newest message, ISO UTC
  processed INTEGER NOT NULL DEFAULT 0,
  processed_at TEXT,
  created TEXT NOT NULL,
  PRIMARY KEY (user_id, row_key)
);
CREATE INDEX chat_rows_waiting ON chat_rows(source_id, processed, received);
-- The person's own rules for chats (what becomes a task), on top of the shared chat rulebook.
ALTER TABLE settings ADD COLUMN chat_rules TEXT NOT NULL DEFAULT '';
