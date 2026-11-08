import { randomToken, sameSecret } from "./auth";
import { type Env, json } from "./env";
import { handleChatMessage, trace } from "./missed";
import type { AlertItem } from "./run";

let tgFetch: typeof fetch = (...a) => fetch(...a);
/** Tests replace the Telegram API. */
export function setTelegramFetch(f: typeof fetch) { tgFetch = f; }

async function tg(env: Env, method: string, body: unknown) {
  if (!env.TELEGRAM_BOT_TOKEN) return;
  const r = await tgFetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/${method}`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
  });
  if (!r.ok) {
    const d = await r.json<{ description?: string }>().catch(() => ({} as { description?: string }));
    throw new Error(`Telegram ${method} failed (${r.status}${d.description ? `: ${d.description}` : ""})`);
  }
}

/** Plain text message to a chat (throws on a Telegram error). */
export const tgSend = (env: Env, chatId: string, text: string) => tg(env, "sendMessage", { chat_id: chatId, text });

const esc = (s: string) => s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]!);

/** Alert sender for a user: no-op when Telegram isn't linked or alerts are off. */
export function alertFor(env: Env, userId: string): (item: AlertItem) => Promise<void> {
  return async (item) => {
    const u = await env.DB.prepare(`SELECT u.telegram_chat_id AS chat, s.alerts_on AS on_ FROM users u
        LEFT JOIN settings s ON s.user_id=u.id WHERE u.id=?`).bind(userId).first<{ chat: string | null; on_: number | null }>();
    if (!u?.chat || u.on_ === 0) return;
    const lines = [`⚠️ <b>${esc(item.title)}</b>`, item.why && esc(item.why), item.due && `Due: ${esc(item.due.replace("T", " "))}`,
      item.sender && `From: ${esc(item.sender)}`].filter(Boolean);
    await tg(env, "sendMessage", {
      chat_id: u.chat, text: lines.join("\n"), parse_mode: "HTML",
      ...(item.link ? { reply_markup: { inline_keyboard: [[{ text: "Open email", url: item.link }]] } } : {}),
    });
  };
}

/** New one-time link code for a user (replaces any earlier one); null when the engine has no bot. */
export async function newTelegramLink(env: Env, userId: string): Promise<string | null> {
  if (!env.TELEGRAM_BOT_NAME) return null;
  const code = randomToken(18);
  await env.DB.prepare("UPDATE users SET link_code=? WHERE id=?").bind(code, userId).run();
  return `https://t.me/${env.TELEGRAM_BOT_NAME}?start=${code}`;
}

/** Telegram → engine (setWebhook with secret_token). Handles "/start <code>". */
export async function telegramWebhook(req: Request, env: Env): Promise<Response> {
  if (!env.TELEGRAM_WEBHOOK_SECRET || !sameSecret(req.headers.get("X-Telegram-Bot-Api-Secret-Token") ?? "", env.TELEGRAM_WEBHOOK_SECRET)) {
    return json({ error: "unauthorized" }, 401);
  }
  const u = await req.json<any>().catch(() => null);
  const text: string = u?.message?.text ?? "";
  const chatId = u?.message?.chat?.id;
  const m = /^\/start\s+([A-Za-z0-9_-]+)/.exec(text);
  // Only a private chat can be linked: alerts carry task titles and senders, which must never go to a group.
  if (m && chatId != null && u?.message?.chat?.type !== "private") {
    await trace(env, "", String(u?.update_id ?? ""), "telegram link refused", "not a private chat");
  } else if (m && chatId != null) {
    const r = await env.DB.prepare("UPDATE users SET telegram_chat_id=?, link_code=NULL WHERE link_code=?").bind(String(chatId), m[1]).run();
    try {
      await tg(env, "sendMessage", { chat_id: chatId, text: r.meta.changes
        ? "Linked to FloatBoard ✅ You'll get critical actions here."
        : "That link has expired. Open Connections in FloatBoard and press Connect Telegram again." });
    } catch (e) {
      const owner = await env.DB.prepare("SELECT id FROM users WHERE telegram_chat_id=?").bind(String(chatId)).first<{ id: string }>().catch(() => null);
      await trace(env, owner?.id ?? "", String(u?.update_id ?? ""), "telegram reply failed", (e as Error).message);
    }
  } else if (chatId != null && text) {
    await handleChatMessage(env, String(chatId), text, String(u?.update_id ?? ""),
      { type: u?.message?.chat?.type, fromId: u?.message?.from?.id })
      .catch(async (e) => {
        const owner = await env.DB.prepare("SELECT id FROM users WHERE telegram_chat_id=?").bind(String(chatId)).first<{ id: string }>().catch(() => null);
        await trace(env, owner?.id ?? "", String(u?.update_id ?? ""), "missed: handler failed", (e as Error).message);
      });
  }
  return json({ ok: true }); // always 200 so Telegram doesn't retry
}
