-- Where to find an unreadable message again (retried by id at the start of each run) and what kind it was.
ALTER TABLE judge_attempts ADD COLUMN gmail_id TEXT;
ALTER TABLE judge_attempts ADD COLUMN source_id TEXT;
ALTER TABLE judge_attempts ADD COLUMN kind TEXT NOT NULL DEFAULT 'email';
