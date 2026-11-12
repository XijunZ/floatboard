-- Archive old data to the Mac: emails whose items were archived (deleted from the engine after the Mac saved them) leave a
-- tombstone, so the same email never becomes a task again. And the board log keeps the phone's own action id, so a
-- resend of an old action is still ignored after its phone_actions row was purged (7 days).
CREATE TABLE archived_items (
  user_id TEXT NOT NULL,
  message_id TEXT NOT NULL,         -- items.message_id of an archived item (the email's Message-ID, or a recap key)
  archived_at TEXT NOT NULL,
  PRIMARY KEY (user_id, message_id)
);

ALTER TABLE board_log ADD COLUMN client_id TEXT;   -- a phone action's own id (the phone's), NULL for Mac rows
UPDATE board_log SET client_id = (SELECT p.client_id FROM phone_actions p WHERE p.id = board_log.id) WHERE device <> 'mac';
CREATE INDEX board_log_client ON board_log(user_id, client_id);

-- The archive reads a user's rows in id order.
CREATE INDEX board_log_user_id ON board_log(user_id, id);
CREATE INDEX items_user_id ON items(user_id, id);
