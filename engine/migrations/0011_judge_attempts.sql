-- Messages whose Claude answer couldn't be read: counted per message; after 3 tries the message is given up on
-- (shown in /v2/status needs_attention) and marked seen. Rows older than 30 days are pruned by the run.
CREATE TABLE judge_attempts (
  user_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  subject TEXT,
  link TEXT,
  updated TEXT NOT NULL,
  PRIMARY KEY (user_id, message_id)
);
