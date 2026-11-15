-- Telegram is gone (alerts now go to the phone app and ntfy). Remove its tables, the users' chat links and bot tokens,
-- and its "missed:" chat log lines. Corrections already learned from "missed:" reports stay in feedback.
DROP TABLE IF EXISTS telegram_inbox;
DROP TABLE IF EXISTS missed_pending;
DROP INDEX IF EXISTS users_tg_hook_id;
ALTER TABLE users DROP COLUMN telegram_chat_id;
ALTER TABLE users DROP COLUMN link_code;
ALTER TABLE users DROP COLUMN tg_bot_token_enc;
ALTER TABLE users DROP COLUMN tg_bot_name;
ALTER TABLE users DROP COLUMN tg_hook_id;
ALTER TABLE users DROP COLUMN tg_hook_secret_hash;
DELETE FROM run_events WHERE run_id = 'telegram';
