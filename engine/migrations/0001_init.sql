-- FloatBoard engine schema. Every table is scoped by user_id.
CREATE TABLE users (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  key_hash TEXT NOT NULL UNIQUE,
  anthropic_key_enc TEXT,
  telegram_chat_id TEXT,
  link_code TEXT,
  created TEXT NOT NULL
);
CREATE TABLE sources (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  kind TEXT NOT NULL,              -- 'gmail' | 'fathom'
  address TEXT NOT NULL,
  refresh_enc TEXT,
  client_id TEXT,
  client_secret_enc TEXT,
  fathom_key_enc TEXT,
  hook_id TEXT,
  enabled INTEGER NOT NULL DEFAULT 1,
  cursor TEXT,
  last_run TEXT,
  last_error TEXT,
  created TEXT NOT NULL,
  UNIQUE(user_id, kind, address)
);
CREATE TABLE items (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  source_id TEXT,
  message_id TEXT NOT NULL,
  kind TEXT NOT NULL,              -- 'action' | 'summary'
  title TEXT NOT NULL,
  why TEXT,
  sender TEXT,
  subject TEXT,
  link TEXT,
  snippet TEXT,
  due TEXT,
  has_time INTEGER NOT NULL DEFAULT 0,
  importance INTEGER NOT NULL DEFAULT 1,
  group_name TEXT,
  task_ref TEXT,
  summary TEXT,
  critical INTEGER NOT NULL DEFAULT 0,
  alerted INTEGER NOT NULL DEFAULT 0,
  created TEXT NOT NULL,
  UNIQUE(user_id, message_id, kind)
);
CREATE INDEX items_user_created ON items(user_id, created);
CREATE TABLE seen (
  user_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  at TEXT NOT NULL,
  PRIMARY KEY (user_id, message_id)
);
CREATE TABLE feedback (
  user_id TEXT NOT NULL,
  item_id TEXT NOT NULL,
  verdict TEXT NOT NULL,
  created TEXT NOT NULL
);
CREATE TABLE meeting_tasks (
  user_id TEXT NOT NULL,
  task_ref TEXT NOT NULL,
  title TEXT NOT NULL,
  due TEXT,
  meet_link TEXT,
  event_id TEXT,
  PRIMARY KEY (user_id, task_ref)
);
CREATE TABLE settings (
  user_id TEXT PRIMARY KEY,
  ignore_senders TEXT NOT NULL DEFAULT '[]',
  allow_senders TEXT NOT NULL DEFAULT '[]',
  auto_add INTEGER NOT NULL DEFAULT 1,
  critical_hours INTEGER NOT NULL DEFAULT 24,
  alerts_on INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE runs (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  started TEXT NOT NULL,
  finished TEXT,
  processed INTEGER NOT NULL DEFAULT 0,
  error TEXT
);
