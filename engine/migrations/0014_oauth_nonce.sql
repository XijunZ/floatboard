-- Bind each Google OAuth state to the browser that started it: sha256 of a nonce held in a short-lived cookie.
ALTER TABLE oauth_states ADD COLUMN nonce_hash TEXT;
