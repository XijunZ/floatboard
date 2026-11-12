import type { Env } from "./env";
import type { AlertItem } from "./run";
import { telegramAlert } from "./telegram";
import { pushToUser } from "./app/webpush";

let ntfyFetch: typeof fetch = (...a) => fetch(...a);
/** Tests replace the ntfy server. */
export function setNtfyFetch(f: typeof fetch) { ntfyFetch = f; }

export const NTFY_BASE = "https://ntfy.sh";

/** One way to reach a user's phone. Resolves false when the user hasn't set the channel up, true when sent; throws when sending fails. */
export type AlertChannel = { name: string; send: (env: Env, userId: string, item: AlertItem) => Promise<boolean> };

/** Web Push alert text: reason, due and sender. Never the email text. `why` is Claude's own one-line reason. */
export function alertBody(item: AlertItem): string {
  return [item.why, item.due && `Due: ${item.due.replace("T", " ")}`, item.sender && `From: ${item.sender}`].filter(Boolean).join("\n") || " ";
}

/**
 * ntfy alert text: the due date and a pointer to the app only. ntfy.sh is a public server where anyone who knows the
 * topic can read the alerts, so the reason, the sender and the email link are never sent there.
 */
export function ntfyBody(item: AlertItem): string {
  return [item.due && `Due: ${item.due.replace("T", " ")}`, "Open FloatBoard for details"].filter(Boolean).join("\n");
}

/**
 * POST an alert to an ntfy topic (throws on a non-2xx answer): title, `ntfyBody`, and a Click link to the user's phone app
 * (`<appOrigin>/app/`) when the engine's address is known; never the email link. HTTP header values must be single-line
 * ASCII-safe.
 */
export async function sendNtfy(topic: string, item: AlertItem, appOrigin?: string | null): Promise<void> {
  const headers: Record<string, string> = {
    Title: item.title.replace(/[\r\n]+/g, " ").slice(0, 120), Priority: "5", Tags: "warning",
  };
  if (appOrigin) headers.Click = `${appOrigin}/app/`;
  const r = await ntfyFetch(`${NTFY_BASE}/${encodeURIComponent(topic)}`, { method: "POST", headers, body: ntfyBody(item) });
  if (!r.ok) throw new Error(`ntfy failed (${r.status})`);
}

/** Add new channels (Web Push, ...) here; each is tried for every alert. */
export const CHANNELS: AlertChannel[] = [
  { name: "telegram", send: (env, userId, item) => telegramAlert(env, userId)(item) },
  {
    name: "webpush",
    send: (env, userId, item) => pushToUser(env, userId, { title: item.title, body: alertBody(item), url: item.link || "/app/" }),
  },
  {
    name: "ntfy",
    send: async (env, userId, item) => {
      const u = await env.DB.prepare("SELECT ntfy_topic, app_origin FROM users WHERE id=?").bind(userId).first<{ ntfy_topic: string | null; app_origin: string | null }>();
      if (!u?.ntfy_topic) return false;
      await sendNtfy(u.ntfy_topic, item, u.app_origin);
      return true;
    },
  },
];

/**
 * Alert sender for a user: sends to every channel they have, nothing at all when alerts are off. One channel failing
 * never stops the others; when every channel the user has failed the error is thrown, so the caller records the failure and retries. (A channel that is not set up is skipped, not a failure.) Throws only when no channel got through.
 */
export function alertFor(env: Env, userId: string): (item: AlertItem) => Promise<void> {
  return async (item) => {
    const s = await env.DB.prepare("SELECT alerts_on FROM settings WHERE user_id=?").bind(userId).first<{ alerts_on: number | null }>();
    if (s?.alerts_on === 0) return;
    const results = await Promise.allSettled(CHANNELS.map((c) => c.send(env, userId, item)));
    const sent = results.some((r) => r.status === "fulfilled" && r.value);
    const failed = results.flatMap((r, i) => r.status === "rejected" ? [`${CHANNELS[i].name}: ${(r.reason as Error)?.message ?? r.reason}`] : []);
    if (failed.length) {
      for (const f of failed) console.warn(JSON.stringify({ event: "alert_channel_failed", error: f }));
      if (!sent) throw new Error(failed.join("; ")); // every channel the user has failed
    }
  };
}
