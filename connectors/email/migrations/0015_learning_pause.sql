-- A learning result that was refused (it would have removed most learned preferences) pauses learning: it is retried
-- only after new corrections arrive (feedback rowid above learn_paused_rowid) or 24 hours later. NULL = not paused.
ALTER TABLE settings ADD COLUMN learn_paused_at TEXT;
ALTER TABLE settings ADD COLUMN learn_paused_rowid INTEGER;
