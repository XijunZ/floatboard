-- Phone app (PWA at /app): paired devices (one per browser install), the user's passkeys, sign-in sessions, one-time
-- pairing codes and sign-in challenges.
CREATE TABLE app_devices (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  name TEXT NOT NULL,
  created TEXT NOT NULL,
  last_seen TEXT,
  revoked INTEGER NOT NULL DEFAULT 0,
  credential_id TEXT,               -- the passkey this device last signed in with (app_credentials.credential_id)
  install_hash TEXT                 -- sha256 of the browser install id the phone app keeps in localStorage
);
CREATE INDEX app_devices_user ON app_devices(user_id);
CREATE INDEX app_devices_install ON app_devices(install_hash);

CREATE TABLE app_credentials (
  credential_id TEXT PRIMARY KEY,   -- base64url
  device_id TEXT NOT NULL,          -- the device it was first paired on (the passkey belongs to the user)
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
  challenge TEXT                    -- the WebAuthn registration challenge, once options were asked for (a one-off marker once used)
);
CREATE INDEX app_pairings_expires ON app_pairings(expires);

CREATE TABLE app_challenges (
  id TEXT PRIMARY KEY,
  challenge TEXT NOT NULL,
  purpose TEXT NOT NULL,            -- 'login'
  expires TEXT NOT NULL,
  used INTEGER NOT NULL DEFAULT 0,
  ip_hash TEXT                      -- sha256 of the client address that asked (per-address cap)
);
CREATE INDEX app_challenges_expires ON app_challenges(expires);
CREATE INDEX app_challenges_ip ON app_challenges(ip_hash);

-- The engine address the user's phone app lives on (links in alerts: ntfy Click goes to <app_origin>/app/).
ALTER TABLE users ADD COLUMN app_origin TEXT;
