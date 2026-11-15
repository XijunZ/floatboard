-- The user's board groups, so Claude can file each email task into the right one.
ALTER TABLE settings ADD COLUMN groups TEXT NOT NULL DEFAULT '[]';
