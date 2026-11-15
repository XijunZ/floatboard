-- Every "missed:" / number message from a linked chat is stored before it is processed, so nothing is lost if
-- Gmail or Telegram fails; the hourly run retries rows still unprocessed (processed: 0 waiting, 1 done, 2 gave up).
CREATE TABLE telegram_inbox (
  update_id INTEGER PRIMARY KEY,
  user_id TEXT NOT NULL,
  chat_id TEXT NOT NULL,
  text TEXT NOT NULL,
  received TEXT NOT NULL,
  processed INTEGER NOT NULL DEFAULT 0,
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  last_try TEXT,
  pending_created TEXT        -- for a number reply: the pending choice that existed when it arrived
);
CREATE INDEX telegram_inbox_pending ON telegram_inbox(user_id, processed, received);
