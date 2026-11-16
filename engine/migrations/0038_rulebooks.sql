-- Your own copy of each rulebook (Settings › Rules & learning): empty means the built-in one (src/skills/*.md).
ALTER TABLE settings ADD COLUMN rulebook_email TEXT;
ALTER TABLE settings ADD COLUMN rulebook_chat TEXT;
