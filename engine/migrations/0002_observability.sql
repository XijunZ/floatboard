-- Per-run statistics and a per-message decision trace (kept 7 days).
ALTER TABLE runs ADD COLUMN stopped TEXT;
ALTER TABLE runs ADD COLUMN stats TEXT;
ALTER TABLE runs ADD COLUMN calls INTEGER NOT NULL DEFAULT 0;
ALTER TABLE runs ADD COLUMN ms INTEGER NOT NULL DEFAULT 0;
CREATE TABLE run_events (
  run_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  at TEXT NOT NULL,
  source TEXT,
  sender TEXT,
  subject TEXT,
  decision TEXT NOT NULL,
  detail TEXT
);
CREATE INDEX run_events_run ON run_events(run_id);
CREATE INDEX runs_user_started ON runs(user_id, started);
