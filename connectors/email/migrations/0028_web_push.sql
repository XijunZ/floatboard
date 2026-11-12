-- Web Push: one subscription per paired phone, and the engine's own keys (the VAPID key pair, made on first use).
CREATE TABLE app_push (
  device_id TEXT PRIMARY KEY,       -- app_devices.id
  user_id TEXT NOT NULL,
  endpoint TEXT NOT NULL,           -- the push service address (https)
  p256dh TEXT NOT NULL,             -- the phone's public key (base64url, 65 bytes)
  auth TEXT NOT NULL,               -- the phone's auth secret (base64url, 16 bytes)
  origin TEXT NOT NULL,             -- engine address the phone subscribed on (VAPID subject <origin>/app)
  created TEXT NOT NULL
);
CREATE INDEX app_push_user ON app_push(user_id);

CREATE TABLE app_keys (
  name TEXT PRIMARY KEY,            -- "vapid"
  value_enc TEXT NOT NULL,          -- encrypted with ENC_KEY (the private key as JWK)
  created TEXT NOT NULL
);
