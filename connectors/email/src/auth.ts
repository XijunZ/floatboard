import { type Env, type User, nowISO } from "./env";

export async function sha256Hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function randomToken(bytes = 32): string {
  const b = crypto.getRandomValues(new Uint8Array(bytes));
  return btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Bearer user key → user, or null. */
export async function authUser(req: Request, env: Env): Promise<User | null> {
  const m = /^Bearer\s+(.+)$/.exec(req.headers.get("Authorization") ?? "");
  if (!m) return null;
  return userByKey(env, m[1].trim());
}

/** Constant-time-ish string comparison (no early exit on the first differing character). */
export function sameSecret(a: string, b: string): boolean {
  if (!b || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** Constant-time-ish comparison for the admin key. */
export function isAdmin(req: Request, env: Env): boolean {
  return sameSecret(req.headers.get("X-Admin-Key") ?? "", env.ADMIN_KEY);
}

/** User key → user, or null. */
export async function userByKey(env: Env, key: string): Promise<User | null> {
  if (!key) return null;
  return env.DB.prepare("SELECT id, name FROM users WHERE key_hash=?").bind(await sha256Hex(key)).first<User>();
}

/** Create a user; the returned key is the only time it exists in clear (only its hash is stored). */
export async function insertUser(env: Env, name: string): Promise<{ id: string; key: string }> {
  const id = crypto.randomUUID();
  const key = randomToken(32);
  await env.DB.batch([
    env.DB.prepare("INSERT INTO users(id,name,key_hash,created) VALUES(?,?,?,?)").bind(id, name, await sha256Hex(key), nowISO()),
    env.DB.prepare("INSERT INTO settings(user_id) VALUES(?)").bind(id),
  ]);
  return { id, key };
}
