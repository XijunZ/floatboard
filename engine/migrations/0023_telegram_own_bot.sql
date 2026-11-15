-- A user's own Telegram bot (optional). When tg_bot_token_enc is set, that user's alerts and replies come from their bot
-- and their chat is linked through it; otherwise the engine's shared bot is used as before.
-- tg_bot_token_enc: the bot token, AES-GCM with ENC_KEY (never stored or shown in clear).
-- tg_bot_name: the bot's @username (without @), from getMe; builds the t.me link.
-- tg_hook_id: random id in the bot's webhook path /telegram/webhook/u/<tg_hook_id>.
-- tg_hook_secret_hash: SHA-256 of the secret_token given to setWebhook; updates must carry the matching header.
ALTER TABLE users ADD COLUMN tg_bot_token_enc TEXT;
ALTER TABLE users ADD COLUMN tg_bot_name TEXT;
ALTER TABLE users ADD COLUMN tg_hook_id TEXT;
ALTER TABLE users ADD COLUMN tg_hook_secret_hash TEXT;
CREATE UNIQUE INDEX users_tg_hook_id ON users(tg_hook_id);
