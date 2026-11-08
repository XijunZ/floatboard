-- Corrections keep their own subject/sender (so Start over can't erase what was learned), what changed, and
-- whether they've been folded into the user's personal skill (settings.learned).
ALTER TABLE feedback ADD COLUMN subject TEXT;
ALTER TABLE feedback ADD COLUMN sender TEXT;
ALTER TABLE feedback ADD COLUMN detail TEXT;
ALTER TABLE feedback ADD COLUMN consolidated INTEGER NOT NULL DEFAULT 0;
ALTER TABLE settings ADD COLUMN learned TEXT NOT NULL DEFAULT '';
