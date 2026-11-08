-- Fathom's webhook signing secret ("whsec_…"), encrypted with ENC_KEY. When set, deliveries to the user's Fathom
-- address must carry a valid Standard Webhooks signature; when NULL, deliveries are accepted as before.
ALTER TABLE sources ADD COLUMN hook_secret_enc TEXT;
