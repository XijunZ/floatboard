-- Due reminders for every task on the board copy: one row per reminder sent, so each (user, task, due value) is
-- reminded once. Rows older than 30 days are deleted by the hourly cron.
CREATE TABLE due_alerts_sent (
  user_id TEXT NOT NULL,
  card_id INTEGER NOT NULL,         -- the Mac's task id
  due TEXT NOT NULL,                -- the due value as the board copy holds it (a new due is a new reminder)
  sent_at TEXT NOT NULL,
  PRIMARY KEY (user_id, card_id, due)
);
CREATE INDEX due_alerts_sent_at ON due_alerts_sent(sent_at);
