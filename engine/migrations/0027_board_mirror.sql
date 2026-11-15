-- Board copy for the phone (the Mac pushes it) and the changes the phone queues for the Mac.
CREATE TABLE board_snapshots (
  user_id TEXT PRIMARY KEY,
  data_enc TEXT NOT NULL,           -- encrypted JSON { cards: [...] }
  updated TEXT NOT NULL
);

CREATE TABLE phone_actions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  card_id INTEGER,                  -- NULL for "add"
  action TEXT NOT NULL,             -- todo | doing | watch | done | add
  title TEXT,                       -- for "add"
  group_name TEXT,                  -- for "add"
  created TEXT NOT NULL,
  taken INTEGER NOT NULL DEFAULT 0  -- 1 once the Mac has applied and acked it
);
CREATE INDEX phone_actions_user ON phone_actions(user_id, taken, created);
