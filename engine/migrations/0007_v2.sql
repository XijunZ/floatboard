-- /v2 contract: when the email was sent (identical in every inbox), events from the app, versioned settings.
ALTER TABLE items ADD COLUMN sent_at TEXT;          -- NULL for rows made before this migration
CREATE TABLE app_events (
  uuid TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  payload TEXT NOT NULL,
  received TEXT NOT NULL,
  processed INTEGER NOT NULL DEFAULT 0,
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT
);
CREATE INDEX app_events_user_pending ON app_events(user_id, processed, received);
ALTER TABLE settings ADD COLUMN settings_version INTEGER NOT NULL DEFAULT 0;
ALTER TABLE settings ADD COLUMN learn_at INTEGER;   -- 50 | 100; NULL = engine default
ALTER TABLE run_events ADD COLUMN trace TEXT;       -- item id or event uuid (filled in later)
-- Learning from the app's events: what the original email said (<=1,500 chars), and which event produced the row (once only).
ALTER TABLE feedback ADD COLUMN excerpt TEXT;
ALTER TABLE feedback ADD COLUMN event_uuid TEXT;
CREATE UNIQUE INDEX feedback_event ON feedback(event_uuid);
