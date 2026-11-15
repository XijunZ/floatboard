-- Reply drafts: FloatBoard's Gmail draft per email card and the exact body it wrote, so a second press updates that
-- draft only while it is unchanged (a user-edited, sent or deleted draft gets a new one instead).
CREATE TABLE drafts (
  user_id TEXT NOT NULL,
  source_mid TEXT NOT NULL,
  gmail_draft_id TEXT,
  body TEXT,
  updated TEXT,
  locked TEXT,  -- set while a draft for this card is being written; a lock older than 3 minutes is stale
  PRIMARY KEY(user_id, source_mid)
);
