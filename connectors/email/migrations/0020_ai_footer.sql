-- Per person: end reply drafts with an italic "Assisted by AI" line (off by default).
ALTER TABLE settings ADD COLUMN ai_footer INTEGER NOT NULL DEFAULT 0;
