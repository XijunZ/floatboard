-- "missed: <words>" from Telegram: when several emails match, the candidates wait here (30 minutes) for the user's number.
CREATE TABLE missed_pending (
  user_id TEXT PRIMARY KEY,
  candidates_json TEXT NOT NULL,
  created TEXT NOT NULL
);
