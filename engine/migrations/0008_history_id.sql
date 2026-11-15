-- Gmail's historyId of the message when the engine read it. Before marking an email read for a finished task,
-- the engine compares it with the current one: if the message changed since (e.g. marked unread again on
-- another device), it is left alone. NULL for rows made before this migration (marked read as before).
ALTER TABLE items ADD COLUMN history_id TEXT;
