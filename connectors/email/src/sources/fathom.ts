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
  return {
    messageId: `fathom:${id}`, sourceId, from: "Fathom <no-reply@fathom.video>", to: [], cc: [],
    subject: title, date: p.scheduled_start_time ?? p.recording_start_time ?? p.created_at ?? new Date().toISOString(),
    labels: [], headers: {},
    text: [summary, items.length ? `Action items:\n${items.join("\n")}` : "", url].filter(Boolean).join("\n\n"),
    link: url,
  };
}

/** One key per meeting, whether the recap came by Fathom email or webhook. */
export function recapKey(m: Message): string {
  const id = SHARE.exec(m.link)?.[1] ?? SHARE.exec(m.text)?.[1];
  return id ? `fathom:${id}` : m.messageId;
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
