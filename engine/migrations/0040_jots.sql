-- Jots (docs/superpowers/specs/2026-11-17-jots-design.md §1, §4): the 30-day online copy of jots for the phone, phone
-- captures and meeting notes waiting for the Mac, the phone's jot actions already applied, and the daily nudge.
-- A jot's copy (text encrypted). key: 'J-<n>' (from the Mac), 'phone:<id>' (a phone capture), 'fathom:<key>' (meeting notes),
-- 'action:<id>' (a phone Make task / Make decision for the Mac). mac_id: the Mac's J-n once it has the jot.
-- mac_saved_at: when the Mac last saved this jot's latest version (NULL: never). waiting=1: a change the Mac has not saved.
-- A row is removed 30 days after mac_saved_at, never while waiting or before the Mac has saved it.
CREATE TABLE jot_copies (
  user_id TEXT NOT NULL,
  key TEXT NOT NULL,
  mac_id INTEGER,
  text_enc TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'jot',
  source TEXT NOT NULL DEFAULT 'typed',
  tags TEXT NOT NULL DEFAULT '[]',
  added TEXT NOT NULL,
  updated TEXT NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0,
  mac_saved_at TEXT,
  waiting INTEGER NOT NULL DEFAULT 0,
  rev INTEGER NOT NULL DEFAULT 0,
  recap_key TEXT,
  ref TEXT,                          -- an action row: the key of the jot it was made from
  PRIMARY KEY (user_id, key)
);
CREATE UNIQUE INDEX jot_copies_mac ON jot_copies(user_id, mac_id) WHERE mac_id IS NOT NULL;
CREATE INDEX jot_copies_waiting ON jot_copies(user_id, waiting);
-- Phone jot action ids already applied (a repeat is applied once); kept 7 days.
CREATE TABLE jot_actions_seen (
  user_id TEXT NOT NULL,
  id TEXT NOT NULL,
  at TEXT NOT NULL,
  PRIMARY KEY (user_id, id)
);
-- The daily jot nudge as the Mac last sent it: the time (minutes after midnight in `zone`; NULL = off), the day the Mac
-- showed it, the day the owner last jotted, and today's finished tasks (titles, encrypted) for the prompt.
CREATE TABLE jot_nudges (
  user_id TEXT PRIMARY KEY,
  minutes INTEGER,
  zone TEXT NOT NULL DEFAULT 'Europe/London',
  shown_day TEXT,
  jotted_day TEXT,
  done_enc TEXT,
  updated TEXT NOT NULL
);
