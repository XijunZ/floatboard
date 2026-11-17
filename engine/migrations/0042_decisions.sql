-- Decisions (docs/superpowers/specs/2026-11-17-decisions-design.md §8).
-- Your own copy of the Decisions rulebook (Settings › Rules & learning; "Not a decision" adds examples to it). Empty = the
-- built-in one (src/skills/decisions.md).
ALTER TABLE settings ADD COLUMN rulebook_decisions TEXT;
-- The phone's read-only copy of Decisions, as the Mac last sent it (encrypted JSON).
CREATE TABLE decision_copies (
  user_id TEXT PRIMARY KEY,
  data_enc TEXT NOT NULL,
  updated TEXT NOT NULL
);
-- What the phone did on a decision (answer its review, "Not a decision"), waiting for the Mac. client_id = the phone's own
-- id for the action, so a repeat is stored once. payload_enc holds the review's answers (encrypted).
CREATE TABLE decision_actions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  client_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  decision TEXT NOT NULL,
  action TEXT NOT NULL,
  payload_enc TEXT,
  made_at TEXT NOT NULL,
  created TEXT NOT NULL,
  taken INTEGER NOT NULL DEFAULT 0,
  UNIQUE (user_id, client_id)
);
CREATE INDEX decision_actions_waiting ON decision_actions(user_id, taken, made_at);
