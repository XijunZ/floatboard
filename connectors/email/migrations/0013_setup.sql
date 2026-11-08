-- Engine setup page (/setup): sign-in sessions, Google OAuth states, sign-in rate limit, each user's own Google Cloud
-- Web client, and a log of every setup outcome. Secrets are only ever stored encrypted (or hashed) and never logged.
CREATE TABLE setup_sessions (
  id_hash TEXT PRIMARY KEY,          -- sha256 of the cookie value
  kind TEXT NOT NULL,                -- 'user' | 'admin'
  user_id TEXT,                      -- NULL for admin sessions
  csrf TEXT NOT NULL,                -- per-session token required in every POST form
  key_enc TEXT,                      -- the user key (AES-GCM), only to build the Connect link during the session
  expires TEXT NOT NULL,
  created TEXT NOT NULL
);
CREATE INDEX setup_sessions_expires ON setup_sessions(expires);
CREATE TABLE oauth_states (
  state_hash TEXT PRIMARY KEY,       -- sha256 of the state sent to Google; deleted when used
  user_id TEXT NOT NULL,
  expires TEXT NOT NULL,
  created TEXT NOT NULL
);
CREATE TABLE setup_attempts (
  ip TEXT NOT NULL,
  at TEXT NOT NULL,
  ok INTEGER NOT NULL,               -- 0 = failed sign-in (counted by the rate limit)
  kind TEXT NOT NULL                 -- 'user' | 'admin'
);
CREATE INDEX setup_attempts_ip_at ON setup_attempts(ip, at);
CREATE TABLE google_clients (
  user_id TEXT PRIMARY KEY,
  client_id TEXT NOT NULL,
  client_secret_enc TEXT NOT NULL,
  updated TEXT NOT NULL
);
CREATE TABLE setup_log (
  at TEXT NOT NULL,
  user_id TEXT,                      -- NULL when nobody could be identified (bad state, failed sign-in, admin)
  ip TEXT,
  action TEXT NOT NULL,
  ok INTEGER NOT NULL,
  detail TEXT
);
CREATE INDEX setup_log_user_at ON setup_log(user_id, at);
