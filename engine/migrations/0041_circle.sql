-- Circle (docs/superpowers/specs/2026-11-17-circle-design.md): message metadata readers for Gmail and Outlook, the people the
-- Mac asks to follow (Companies House, news, feeds) and what was found, the phone's Circle copy and its actions.
-- Names, addresses and findings are stored encrypted (ENC_KEY). No message text is ever stored.

-- The Companies House API key, sent by the Mac like the other keys (PUT /v2/keys).
ALTER TABLE users ADD COLUMN companies_house_key_enc TEXT;

-- Gmail (inbox and Sent) and Outlook metadata: who (encrypted address and display name), when, which way. Purged 30 days
-- after it was received (the Mac takes it in by seq).
CREATE TABLE circle_exchanges (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL,
  key TEXT NOT NULL,                 -- gmail:<inbox>:<message id>:<n> or owa:<row key>
  channel TEXT NOT NULL,             -- gmail | outlook
  direction TEXT NOT NULL,           -- in | out
  at TEXT NOT NULL,                  -- ISO, when the message was sent
  account TEXT NOT NULL DEFAULT '',  -- the inbox it was seen in
  who_enc TEXT NOT NULL,             -- encrypted JSON {"h": address, "n": display name}
  received_at TEXT NOT NULL,
  UNIQUE (user_id, key)
);
CREATE INDEX circle_exchanges_user ON circle_exchanges(user_id, seq);

-- Each reader's progress: data as of, backfilled back to, its cursor (JSON), and the last problem.
CREATE TABLE circle_readers (
  user_id TEXT NOT NULL,
  reader TEXT NOT NULL,              -- gmail:<address> | outlook
  as_of TEXT,
  complete_from TEXT,
  cursor TEXT NOT NULL DEFAULT '{}',
  note TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (user_id, reader)
);

-- The people the Mac asks to follow for What's new (eligible people only), as one encrypted list.
CREATE TABLE circle_watch (
  user_id TEXT PRIMARY KEY,
  data_enc TEXT NOT NULL,
  updated TEXT NOT NULL
);

-- When each person was last looked up per kind (news, ch, feed): at most weekly.
CREATE TABLE circle_checked (
  user_id TEXT NOT NULL,
  person TEXT NOT NULL,              -- P-n
  kind TEXT NOT NULL,
  checked_at TEXT NOT NULL,
  PRIMARY KEY (user_id, person, kind)
);

-- What was found (officer candidates, appointments, news, posts), encrypted; the Mac takes it in by seq.
CREATE TABLE circle_updates (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL,
  key TEXT NOT NULL,
  person TEXT NOT NULL,
  data_enc TEXT NOT NULL,            -- encrypted JSON {kind, title, detail, url, at, match, born, officer}
  created TEXT NOT NULL,
  UNIQUE (user_id, key)
);
CREATE INDEX circle_updates_user ON circle_updates(user_id, seq);

-- The phone's Circle screen as the Mac last sent it (encrypted), and the phone's actions waiting for the Mac.
CREATE TABLE circle_copy (
  user_id TEXT PRIMARY KEY,
  data_enc TEXT NOT NULL,
  updated TEXT NOT NULL
);
CREATE TABLE circle_actions (
  user_id TEXT NOT NULL,
  id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  person TEXT NOT NULL,
  action TEXT NOT NULL,              -- contacted | talked | snooze
  made_at TEXT NOT NULL,
  received_at TEXT NOT NULL,
  taken INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, id)
);
