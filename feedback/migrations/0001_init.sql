-- One row per message from Help › Send Feedback… Kept until the maintainer deletes it.
CREATE TABLE feedback (
  id TEXT PRIMARY KEY,
  install_id TEXT NOT NULL,       -- random per install; never linked to a name
  received TEXT NOT NULL,
  text TEXT NOT NULL,
  app_version TEXT,
  os TEXT,
  diagnostics TEXT,               -- only when the person ticked "Include diagnostics"
  issue_url TEXT,                 -- the private GitHub issue, once filed
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT
);
CREATE INDEX feedback_install ON feedback(install_id, received);
CREATE INDEX feedback_unfiled ON feedback(issue_url) WHERE issue_url IS NULL;
-- Small facts: consecutive GitHub failures, and whether the maintainer was alerted about them.
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
