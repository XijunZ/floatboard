import { sameSecret } from "../auth";
import type { Message } from "./types";

const SHARE = /fathom\.video\/(?:share|calls?|recordings?)\/([A-Za-z0-9_-]+)/i;

/** Normalise a Fathom webhook payload (field names vary by plan/version) into a Message for the recap path. */
export function fathomToMessage(p: any, sourceId: string): Message {
  const url: string = p.share_url ?? p.url ?? p.recording_url ?? "";
  const id = SHARE.exec(url)?.[1] ?? String(p.recording_id ?? p.id ?? crypto.randomUUID());
  const summary: string = p.default_summary?.markdown_formatted ?? p.summary?.markdown_formatted ?? p.summary ?? "";
  const items: string[] = (p.action_items ?? []).map((a: any) => {
    const who = a.assignee?.name ?? a.assignee?.email ?? "";
    return `- ${a.description ?? a.text ?? ""}${who ? ` (${who})` : ""}`;
  });
  const title: string = p.title ?? p.meeting_title ?? "Meeting";
  // Every link that names this meeting, so the recap email (which links to /calls/<number>) matches this delivery.
  // recording_id as a /calls/ number is a guess (Fathom doesn't document it); the action items' links are not.
  const refs = [p.share_url, p.url, p.recording_url, ...(p.action_items ?? []).map((a: any) => a.recording_playback_url),
    p.recording_id != null ? `https://fathom.video/calls/${p.recording_id}` : null].filter((x): x is string => typeof x === "string" && !!x);
  return {
    messageId: `fathom:${id}`, sourceId, from: "Fathom <no-reply@fathom.video>", to: [], cc: [],
    subject: title, date: p.scheduled_start_time ?? p.recording_start_time ?? p.created_at ?? new Date().toISOString(),
    labels: [], headers: {},
    text: [summary, items.length ? `Action items:\n${items.join("\n")}` : "", url].filter(Boolean).join("\n\n"),
    link: url,
    recapRefs: refs,
  };
}

/** The meeting's main key (stored as the summary's message id). Unchanged from earlier versions, so older rows still match. */
export function recapKey(m: Message): string {
  const id = SHARE.exec(m.link)?.[1] ?? SHARE.exec(m.text)?.[1];
  return id ? `fathom:${id}` : m.messageId;
}

const SHARE_ALL = /fathom\.video\/share\/([A-Za-z0-9_-]+)/gi;
const CALL_ALL = /fathom\.video\/calls?\/(\d+)/gi;

/** Fathom meeting links in a text or HTML body (used for recap emails, whose plain part has no links). */
export function fathomLinks(s: string): string[] {
  return [...new Set([...s.matchAll(/https?:\/\/(?:www\.)?fathom\.video\/(?:share|calls?)\/[A-Za-z0-9_-]+/gi)].map((x) => x[0]))];
}

/**
 * Every key that identifies this meeting: the main key first, then each Fathom share token and call number it carries.
 * The webhook and the email name the same meeting with different ids, so a recap is a duplicate when any key matches.
 */
export function recapKeys(m: Message): string[] {
  const s = [m.link, m.text, ...(m.recapRefs ?? [])].join("\n");
  const keys = [recapKey(m),
    ...[...s.matchAll(SHARE_ALL)].map((x) => `fathom:${x[1]}`),
    ...[...s.matchAll(CALL_ALL)].map((x) => `fathom:call:${x[1]}`)];
  return [...new Set(keys)];
}

/** A Standard Webhooks secret: "whsec_" followed by base64 of at least 16 bytes. */
export function isWebhookSecret(s: string): boolean {
  const m = /^whsec_([A-Za-z0-9+/]+={0,2})$/.exec(s);
  if (!m) return false;
  try { return atob(m[1]).length >= 16; } catch { return false; }
}

const SIGNATURE_TOLERANCE_S = 300;

/**
 * Checks a Fathom delivery (Standard Webhooks): HMAC-SHA256 over "<webhook-id>.<webhook-timestamp>.<raw body>" with the
 * base64-decoded secret, compared with each "v1,<base64>" entry of webhook-signature. Returns null when valid, else why not.
 */
export async function fathomSignatureProblem(secret: string, headers: Headers, rawBody: string, nowS = Date.now() / 1000): Promise<string | null> {
  const id = headers.get("webhook-id"), ts = headers.get("webhook-timestamp"), sig = headers.get("webhook-signature");
  if (!id || !ts || !sig) return "unsigned";
  if (!/^\d+$/.test(ts) || Math.abs(nowS - Number(ts)) > SIGNATURE_TOLERANCE_S) return "timestamp too old or invalid";
  const raw = Uint8Array.from(atob(secret.slice("whsec_".length)), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("raw", raw, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${id}.${ts}.${rawBody}`)));
  const expected = btoa(String.fromCharCode(...mac));
  const ok = sig.split(" ").some((e) => e.startsWith("v1,") && sameSecret(e.slice(3), expected));
  return ok ? null : "signature does not match";
}
