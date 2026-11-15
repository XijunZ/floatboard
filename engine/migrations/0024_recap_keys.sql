-- Every id a meeting recap carried (Fathom share token, Fathom call numbers), so the same meeting arriving another way
-- (webhook, hourly catch-up, or the recap email) is recognised as a duplicate even when the two carry different ids.
CREATE TABLE recap_keys (
  user_id TEXT NOT NULL,
  key TEXT NOT NULL,
  created TEXT NOT NULL,
  PRIMARY KEY (user_id, key)
);
