-- Phone app (PWA at /app): paired phones, their passkeys, sign-in sessions, one-time pairing codes and sign-in challenges.
CREATE TABLE app_devices (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  name TEXT NOT NULL,
  created TEXT NOT NULL,
  last_seen TEXT,
  revoked INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX app_devices_user ON app_devices(user_id);

CREATE TABLE app_credentials (
  credential_id TEXT PRIMARY KEY,   -- base64url
  device_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  public_key TEXT NOT NULL,         -- base64url COSE key
  counter INTEGER NOT NULL DEFAULT 0,
  transports TEXT,                  -- JSON array
  created TEXT NOT NULL
);
CREATE INDEX app_credentials_user ON app_credentials(user_id);
CREATE INDEX app_credentials_device ON app_credentials(device_id);

CREATE TABLE app_sessions (
  token_hash TEXT PRIMARY KEY,      -- sha256 of the fb_session cookie value
  device_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  created TEXT NOT NULL,
  expires TEXT NOT NULL,
  last_used TEXT
);
CREATE INDEX app_sessions_device ON app_sessions(device_id);
CREATE INDEX app_sessions_expires ON app_sessions(expires);

CREATE TABLE app_pairings (
  code_hash TEXT PRIMARY KEY,       -- sha256 of the pairing code
  user_id TEXT NOT NULL,
  expires TEXT NOT NULL,
  used INTEGER NOT NULL DEFAULT 0,
  challenge TEXT                    -- the WebAuthn registration challenge, once options were asked for
);
CREATE INDEX app_pairings_expires ON app_pairings(expires);

CREATE TABLE app_challenges (
  id TEXT PRIMARY KEY,
  challenge TEXT NOT NULL,
  purpose TEXT NOT NULL,            -- 'login'
  expires TEXT NOT NULL,
  used INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX app_challenges_expires ON app_challenges(expires);
