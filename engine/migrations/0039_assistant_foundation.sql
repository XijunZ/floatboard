-- The assistant foundation (docs/superpowers/specs/2026-11-17-foundation-design.md). Jots 0040, Circle 0041, Decisions 0042,
-- Resolutions 0043 follow.
-- Which areas are on, as the Mac last sent them with the board ({"jots":true,...}); NULL = not sent yet (all off).
-- Each area's background jobs check it before they run.
ALTER TABLE settings ADD COLUMN modules TEXT;
-- Fathom meeting metadata (no summary text): the Fathom link, the call's own link, when it was scheduled and who was invited
-- (addresses only), so Jots can attach meeting notes to their calendar event by code.
CREATE TABLE meetings (
  user_id TEXT NOT NULL,
  recap_key TEXT NOT NULL,           -- the meeting's main key (recapKey), e.g. fathom:<share token>
  fathom_url TEXT NOT NULL DEFAULT '',
  meeting_url TEXT NOT NULL DEFAULT '',
  title TEXT NOT NULL DEFAULT '',
  scheduled_start TEXT,              -- ISO, as Fathom gave it
  invitees TEXT NOT NULL DEFAULT '[]', -- JSON list of lower-cased email addresses
  received_at TEXT NOT NULL,
  PRIMARY KEY (user_id, recap_key)
);
CREATE INDEX meetings_received ON meetings(user_id, received_at);
