-- Sync v2: the engine keeps a record of every board change from any device (kept 1 year), and phone actions carry the
-- phone's own action id and the (clock-corrected) time they were made, so newest change wins per card.
CREATE TABLE board_log (
  id TEXT PRIMARY KEY,              -- UUID (a phone action's log row uses phone_actions.id: a repeat is ignored)
  user_id TEXT NOT NULL,
  device TEXT NOT NULL,             -- "mac", or the phone's app_devices.id
  card_id INTEGER,                  -- NULL for a phone "add" (no Mac id yet)
  kind TEXT NOT NULL,               -- status | add | gone | superseded | skipped
  value TEXT,                       -- status: the new step; add: the title (encrypted); superseded / skipped: the action id and reason
  made_at TEXT NOT NULL,            -- when the change was made, corrected for the sending device's clock
  received_at TEXT NOT NULL
);
CREATE INDEX board_log_card ON board_log(user_id, card_id, made_at);
CREATE INDEX board_log_received ON board_log(received_at);

ALTER TABLE phone_actions ADD COLUMN client_id TEXT;   -- the action id the phone made (unique per user: a repeated send is applied once)
ALTER TABLE phone_actions ADD COLUMN device_id TEXT;   -- app_devices.id of the phone that sent it
ALTER TABLE phone_actions ADD COLUMN made_at TEXT;     -- when it was made on the phone, corrected for the phone's clock
ALTER TABLE phone_actions ADD COLUMN sent_at TEXT;     -- the phone's clock when it sent the batch (as sent)
ALTER TABLE phone_actions ADD COLUMN outcome TEXT;     -- NULL, or why it was not applied: "superseded" or the Mac's skip reason
CREATE UNIQUE INDEX phone_actions_client ON phone_actions(user_id, client_id);
