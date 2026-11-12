import { randomToken, sameSecret, sha256Hex } from "./auth";
import { decrypt, encrypt } from "./crypto";
import { type Env, json } from "./env";
import { handleChatMessage, trace } from "./missed";
import type { AlertItem } from "./run";

let tgFetch: typeof fetch = (...a) => fetch(...a);
/** Tests replace the Telegram API. */
export function setTelegramFetch(f: typeof fetch) { tgFetch = f; }

/** A Telegram Bot API error answer (status is the HTTP status Telegram returned). */
class TelegramError extends Error { constructor(msg: string, readonly status: number) { super(msg); } }

async function tgCall<T = unknown>(token: string, method: string, body: unknown): Promise<T | undefined> {
  const r = await tgFetch(`https://api.telegram.org/bot${token}/${method}`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
  });
  const d = await r.json<{ description?: string; result?: T }>().catch(() => ({} as { description?: string; result?: T }));
  if (!r.ok) throw new TelegramError(`Telegram ${method} failed (${r.status}${d.description ? `: ${d.description}` : ""})`, r.status);
  return d.result;
}

/** Call the Bot API with `token` (default: the engine's shared bot); a no-op when there is no bot. */
async function tg(env: Env, method: string, body: unknown, token: string | undefined = env.TELEGRAM_BOT_TOKEN) {
  if (!token) return;
  await tgCall(token, method, body);
}

/** The bot token to use for a user: their own bot when they saved one, else the engine's shared bot. */
async function botTokenFor(env: Env, userId?: string | null): Promise<string | undefined> {
  if (userId) {
    const u = await env.DB.prepare("SELECT tg_bot_token_enc FROM users WHERE id=?").bind(userId).first<{ tg_bot_token_enc: string | null }>();
    if (u?.tg_bot_token_enc) return decrypt(env, u.tg_bot_token_enc);
  }
  return env.TELEGRAM_BOT_TOKEN;
}

/** Plain text message to a chat (throws on a Telegram error), sent by `botUser`'s own bot if they have one. */
export const tgSend = async (env: Env, chatId: string, text: string, botUser?: string | null) =>
  tg(env, "sendMessage", { chat_id: chatId, text }, await botTokenFor(env, botUser));

const esc = (s: string) => s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]!);

/** Telegram alert sender for a user (one channel of alerts.ts): no-op when Telegram isn't linked. Uses the user's own bot when set. */
export function telegramAlert(env: Env, userId: string): (item: AlertItem) => Promise<boolean> {
  return async (item) => {
    const u = await env.DB.prepare("SELECT telegram_chat_id AS chat, tg_bot_token_enc AS own FROM users WHERE id=?")
      .bind(userId).first<{ chat: string | null; own: string | null }>();
    const token = u?.own ? await decrypt(env, u.own) : env.TELEGRAM_BOT_TOKEN;
    if (!u?.chat || !token) return false;
    const lines = [`⚠️ <b>${esc(item.title)}</b>`, item.why && esc(item.why), item.due && `Due: ${esc(item.due.replace("T", " "))}`,
      item.sender && `From: ${esc(item.sender)}`].filter(Boolean);
    await tg(env, "sendMessage", {
      chat_id: u.chat, text: lines.join("\n"), parse_mode: "HTML",
      ...(item.link ? { reply_markup: { inline_keyboard: [[{ text: "Open email", url: item.link }]] } } : {}),
    }, token);
    return true;
  };
}

/** New one-time link code for a user (replaces any earlier one), for their own bot or else the engine's; null when neither exists. */
export async function newTelegramLink(env: Env, userId: string): Promise<string | null> {
  const own = await env.DB.prepare("SELECT tg_bot_name FROM users WHERE id=? AND tg_bot_token_enc IS NOT NULL").bind(userId)
    .first<{ tg_bot_name: string | null }>();
  const bot = own?.tg_bot_name || env.TELEGRAM_BOT_NAME;
  if (!bot) return null;
  const code = randomToken(18);
  await env.DB.prepare("UPDATE users SET link_code=? WHERE id=?").bind(code, userId).run();
  return `https://t.me/${bot}?start=${code}`;
}

// ---------------------------------------------------------------- a user's own bot

const BOT_TOKEN = /^\d{1,20}:[A-Za-z0-9_-]{20,100}$/;
const botId = (token: string) => token.split(":")[0];

export type SaveBotResult = { ok: true; username: string; relinked: boolean } | { ok: false; status: number; error: string; why: string };

/**
 * Save `token` as the user's own bot: check it with getMe, point its webhook at /telegram/webhook/u/<random id> on
 * `origin` with a random secret_token (only its SHA-256 is kept), then store the token encrypted. A different bot than
 * before has its old webhook deleted (best effort) and the chat linked through it unlinked.
 */
export async function saveUserBot(env: Env, userId: string, token: string, origin: string): Promise<SaveBotResult> {
  const fail = (status: number, error: string, why: string): SaveBotResult => ({ ok: false, status, error, why });
  if (env.TELEGRAM_BOT_TOKEN && botId(token) === botId(env.TELEGRAM_BOT_TOKEN)) {
    return fail(400, "That is the engine's shared bot. Create your own bot with @BotFather and paste its token.", "engine bot token");
  }
  if (!BOT_TOKEN.test(token)) return fail(400, "That doesn't look like a bot token. Copy the whole token @BotFather sent you.", "malformed token");
  let me: { is_bot?: boolean; username?: string } | undefined;
  try {
    me = await tgCall(token, "getMe", {});
  } catch (e) {
    if (e instanceof TelegramError && e.status < 500) return fail(400, "Telegram didn't accept that bot token. Check it with @BotFather.", "getMe refused");
    return fail(502, "Couldn't reach Telegram to check the token. Try again in a minute.", `getMe failed: ${(e as Error).message}`);
  }
  const username = me?.username ?? "";
  if (!me?.is_bot || !/^\w{1,64}$/.test(username)) return fail(400, "Telegram didn't accept that bot token. Check it with @BotFather.", "not a bot");
  if (env.TELEGRAM_BOT_NAME && username.toLowerCase() === env.TELEGRAM_BOT_NAME.toLowerCase()) {
    return fail(400, "That is the engine's shared bot. Create your own bot with @BotFather and paste its token.", "engine bot username");
  }
  const taken = await env.DB.prepare("SELECT 1 FROM users WHERE id<>? AND tg_bot_token_enc IS NOT NULL AND lower(tg_bot_name)=lower(?)")
    .bind(userId, username).first();
  if (taken) return fail(400, "That bot is already used by someone else on this engine. Create a new bot with @BotFather.", `@${username} used by another user`);

  const old = await env.DB.prepare("SELECT tg_bot_token_enc, tg_bot_name FROM users WHERE id=?").bind(userId)
    .first<{ tg_bot_token_enc: string | null; tg_bot_name: string | null }>();
  const sameBot = !!old?.tg_bot_token_enc && old.tg_bot_name?.toLowerCase() === username.toLowerCase();
  const hookId = randomToken(18), secret = randomToken(32);
  try {
    await tgCall(token, "setWebhook", { url: `${origin}/telegram/webhook/u/${hookId}`, secret_token: secret, allowed_updates: ["message"] });
  } catch (e) {
    return fail(502, "Telegram didn't let the engine receive messages for that bot. Try again in a minute.", `setWebhook failed: ${(e as Error).message}`);
  }
  if (old?.tg_bot_token_enc && !sameBot) await dropWebhook(env, old.tg_bot_token_enc);
  // Same bot again: its chat still works. Any other change: the chat was linked through another bot, so link again.
  await env.DB.prepare(`UPDATE users SET tg_bot_token_enc=?, tg_bot_name=?, tg_hook_id=?, tg_hook_secret_hash=?
      ${sameBot ? "" : ", telegram_chat_id=NULL, link_code=NULL"} WHERE id=?`)
    .bind(await encrypt(env, token), username, hookId, await sha256Hex(secret), userId).run();
  return { ok: true, username, relinked: !sameBot };
}

/** Forget the user's own bot (deleting its webhook, best effort) and unlink the chat linked through it. False if there was none. */
export async function removeUserBot(env: Env, userId: string): Promise<boolean> {
  const old = await env.DB.prepare("SELECT tg_bot_token_enc FROM users WHERE id=?").bind(userId).first<{ tg_bot_token_enc: string | null }>();
  if (!old?.tg_bot_token_enc) return false;
  await dropWebhook(env, old.tg_bot_token_enc);
  await env.DB.prepare(`UPDATE users SET tg_bot_token_enc=NULL, tg_bot_name=NULL, tg_hook_id=NULL, tg_hook_secret_hash=NULL,
      telegram_chat_id=NULL, link_code=NULL WHERE id=?`).bind(userId).run();
  return true;
}

async function dropWebhook(env: Env, tokenEnc: string) {
  try { await tgCall(await decrypt(env, tokenEnc), "deleteWebhook", {}); }
  catch (e) { console.warn("telegram deleteWebhook failed:", (e as Error).message); }
}

// ---------------------------------------------------------------- webhooks

/** Telegram → engine for the shared bot (setWebhook with secret_token). Handles "/start <code>". */
export async function telegramWebhook(req: Request, env: Env): Promise<Response> {
  if (!env.TELEGRAM_WEBHOOK_SECRET || !sameSecret(req.headers.get("X-Telegram-Bot-Api-Secret-Token") ?? "", env.TELEGRAM_WEBHOOK_SECRET)) {
    return json({ error: "unauthorized" }, 401);
  }
  return handleUpdate(req, env, null);
}

/** Telegram → engine for one user's own bot (/telegram/webhook/u/<hook id>); only that bot's secret_token is accepted. */
export async function userBotWebhook(req: Request, env: Env, hookId: string): Promise<Response> {
  const row = await env.DB.prepare("SELECT id, tg_hook_secret_hash FROM users WHERE tg_hook_id=? AND tg_bot_token_enc IS NOT NULL")
    .bind(hookId).first<{ id: string; tg_hook_secret_hash: string | null }>();
  const given = req.headers.get("X-Telegram-Bot-Api-Secret-Token") ?? "";
  if (!row?.tg_hook_secret_hash || !given || given.length > 256 || !sameSecret(await sha256Hex(given), row.tg_hook_secret_hash)) {
    return json({ error: "unauthorized" }, 401);
  }
  return handleUpdate(req, env, row.id);
}

/**
 * One update from a bot. `owner` is the user whose own bot received it (null: the shared bot). A link code only links on
 * the bot it was made for: the shared bot links users without their own bot; a user's bot links only that user.
 */
async function handleUpdate(req: Request, env: Env, owner: string | null): Promise<Response> {
  const u = await req.json<any>().catch(() => null);
  const text: string = u?.message?.text ?? "";
  const chatId = u?.message?.chat?.id;
  const m = /^\/start\s+([A-Za-z0-9_-]+)/.exec(text);
  const ownerOf = async () => owner ?? (await env.DB.prepare("SELECT id FROM users WHERE telegram_chat_id=? AND tg_bot_token_enc IS NULL")
    .bind(String(chatId)).first<{ id: string }>().catch(() => null))?.id ?? "";
  // Only a private chat can be linked: alerts carry task titles and senders, which must never go to a group.
  if (m && chatId != null && u?.message?.chat?.type !== "private") {
    await trace(env, owner ?? "", String(u?.update_id ?? ""), "telegram link refused", "not a private chat");
  } else if (m && chatId != null) {
    const r = owner
      ? await env.DB.prepare("UPDATE users SET telegram_chat_id=?, link_code=NULL WHERE id=? AND link_code=? AND tg_bot_token_enc IS NOT NULL")
        .bind(String(chatId), owner, m[1]).run()
      : await env.DB.prepare("UPDATE users SET telegram_chat_id=?, link_code=NULL WHERE link_code=? AND tg_bot_token_enc IS NULL")
        .bind(String(chatId), m[1]).run();
    try {
      await tg(env, "sendMessage", { chat_id: chatId, text: r.meta.changes
        ? "Linked to FloatBoard ✅ You'll get critical actions here."
        : "That link has expired. Open Connections in FloatBoard and press Connect Telegram again." }, await botTokenFor(env, owner));
    } catch (e) {
      await trace(env, await ownerOf(), String(u?.update_id ?? ""), "telegram reply failed", (e as Error).message);
    }
  } else if (chatId != null && text) {
    await handleChatMessage(env, String(chatId), text, String(u?.update_id ?? ""),
      { type: u?.message?.chat?.type, fromId: u?.message?.from?.id }, owner)
      .catch(async (e) => {
        await trace(env, await ownerOf(), String(u?.update_id ?? ""), "missed: handler failed", (e as Error).message);
      });
  }
  return json({ ok: true }); // always 200 so Telegram doesn't retry
}
