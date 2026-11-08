-- What each group means (helps Claude pick a group), and the user's own triage rules.
ALTER TABLE settings ADD COLUMN group_notes TEXT NOT NULL DEFAULT '{}';
ALTER TABLE settings ADD COLUMN my_rules TEXT NOT NULL DEFAULT '';
