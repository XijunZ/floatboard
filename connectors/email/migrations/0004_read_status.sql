-- Only unread emails become tasks; finishing a task marks its email read.
ALTER TABLE settings ADD COLUMN unread_only INTEGER NOT NULL DEFAULT 1;
ALTER TABLE settings ADD COLUMN mark_read_on_done INTEGER NOT NULL DEFAULT 1;
