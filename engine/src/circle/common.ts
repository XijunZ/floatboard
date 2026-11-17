/** Small shared pieces of Circle in the engine: the module switch, sealed (encrypted) JSON, the user's Claude client. */
import type { Env } from "../env";
import { decrypt, encrypt } from "../lib/crypto";
import { type Job, makeClient, HAIKU } from "../lib/llm";
import type Anthropic from "@anthropic-ai/sdk";

/** True while the Mac has Circle switched on (`settings.modules`, sent with the board). Circle's jobs skip otherwise. */
export async function circleOn(env: Env, userId: string): Promise<boolean> {
  const s = await env.DB.prepare("SELECT modules FROM settings WHERE user_id=?").bind(userId).first<{ modules: string | null }>();
  if (!s?.modules) return false;
  try { return JSON.parse(s.modules)?.circle === true; } catch { return false; }
}

export async function seal(env: Env, v: unknown): Promise<string> { return encrypt(env, JSON.stringify(v)); }
export async function unseal<T>(env: Env, s: string): Promise<T> { return JSON.parse(await decrypt(env, s)) as T; }

/** A Haiku client for one of Circle's jobs (metered as that job), or null without a Claude key. */
export async function haikuFor(env: Env, userId: string, job: Job, fetchFn: typeof fetch): Promise<Anthropic | null> {
  const u = await env.DB.prepare("SELECT anthropic_key_enc FROM users WHERE id=?").bind(userId).first<{ anthropic_key_enc: string | null }>();
  if (!u?.anthropic_key_enc) return null;
  return makeClient(await decrypt(env, u.anthropic_key_enc), fetchFn, { env, userId, job, model: HAIKU });
}

/** A short, single-line text, or "" for anything else. */
export const line = (v: unknown, max: number): string =>
  typeof v === "string" ? v.replace(/[\u0000-\u001f\u007f]+/g, " ").trim().slice(0, max) : "";
